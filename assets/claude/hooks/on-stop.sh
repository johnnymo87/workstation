#!/usr/bin/env bash
set -euo pipefail

# Debug probe: log stdin delivery to isolate hook execution issues
_dbg_dir="${HOME}/.claude/runtime/hook-debug"
mkdir -p "$_dbg_dir"
_dbg="${_dbg_dir}/stop.$(date +%s%N).log"
exec 2>>"$_dbg"

# Read hook input from Claude
input="$(cat || true)"
ppid="${PPID:-unknown}"

# Log probe data
{
  echo "ts=$(date -Is) pid=$$ ppid=$PPID"
  echo "stdin_bytes=${#input}"
  echo "input=$input"
} >>"$_dbg"

# Get session_id - prefer hook input (most reliable), fall back to mappings
session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)
echo "checkpoint=session_id val=$session_id" >>"$_dbg"

# Fallback 1: ppid-map
if [[ -z "$session_id" && -f "${HOME}/.claude/runtime/ppid-map/${ppid}" ]]; then
    session_id=$(cat "${HOME}/.claude/runtime/ppid-map/${ppid}")
fi

# Fallback 2: legacy PPID dir
if [[ -z "$session_id" && -f "${HOME}/.claude/runtime/${ppid}/session_id" ]]; then
    session_id=$(cat "${HOME}/.claude/runtime/${ppid}/session_id")
fi

# Exit early if no session tracking
if [[ -z "$session_id" ]]; then
    echo "checkpoint=EXIT_no_session" >>"$_dbg"
    exit 0
fi

# Check if this session opted into notifications
session_dir="${HOME}/.claude/runtime/sessions/${session_id}"
legacy_dir="${HOME}/.claude/runtime/${ppid}"

label=""
if [[ -f "${session_dir}/notify_label" ]]; then
    label=$(cat "${session_dir}/notify_label")
elif [[ -f "${legacy_dir}/notify_label" ]]; then
    label=$(cat "${legacy_dir}/notify_label")
else
    # Not opted in, skip notification
    echo "checkpoint=EXIT_no_label session_dir=$session_dir" >>"$_dbg"
    exit 0
fi
echo "checkpoint=label val=$label" >>"$_dbg"

# Get transcript path from hook input
transcript_path=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null || true)
echo "checkpoint=transcript path=$transcript_path exists=$(test -f "$transcript_path" 2>/dev/null && echo y || echo n)" >>"$_dbg"

# Extract Claude's last assistant message with text content from transcript JSONL
# Brief delay to let CC flush the assistant message to disk before we read.
# CC fires the Stop hook ~40ms after writing the assistant entry, but the write
# may still be in Node.js/OS buffers. Without this, we read the N-1 message.
sleep 0.2

last_message=""
if [[ -n "$transcript_path" && -f "$transcript_path" ]]; then
    # Limit scan to last 3000 lines, reverse, then find first assistant message
    last_message=$(
        tail -n 3000 "$transcript_path" 2>/dev/null \
        | tac \
        | while IFS= read -r line; do
            text=$(jq -r '
              select(.type=="assistant")
              | .message.content[]?
              | select(.type=="text")
              | .text
            ' <<<"$line" 2>/dev/null || true)

            if [[ -n "$text" && "$text" != "null" ]]; then
              printf '%s' "$text"
              break
            fi
          done
    ) || true
fi

# Fallback if no message found
if [[ -z "$last_message" ]]; then
    last_message="Task completed"
fi
echo "checkpoint=message len=${#last_message}" >>"$_dbg"

# Send stop event to daemon (fire-and-forget)
json_payload=$(jq -n \
    --arg session_id "$session_id" \
    --arg label "$label" \
    --arg event "Stop" \
    --arg message "$last_message" \
    '{session_id: $session_id, label: $label, event: $event, message: $message}')
echo "checkpoint=payload len=${#json_payload}" >>"$_dbg"

curl_output=$(curl -sS --connect-timeout 1 --max-time 2 \
    -X POST "http://127.0.0.1:4731/stop" \
    -H "Content-Type: application/json" \
    -d "$json_payload" 2>&1) || true
echo "checkpoint=curl_done output=$curl_output" >>"$_dbg"

exit 0
