#!/usr/bin/env bash
set -euo pipefail

# Read hook input from Claude
input="$(cat)"
ppid="${PPID:-unknown}"

# Extract notification content and session_id from hook input
notification=$(printf '%s' "$input" | jq -r '.notification // empty' 2>/dev/null || true)
session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)

# Fallback: ppid-map
if [[ -z "$session_id" && -f "${HOME}/.claude/runtime/ppid-map/${ppid}" ]]; then
    session_id=$(cat "${HOME}/.claude/runtime/ppid-map/${ppid}")
fi

# Fallback: legacy PPID dir
if [[ -z "$session_id" && -f "${HOME}/.claude/runtime/${ppid}/session_id" ]]; then
    session_id=$(cat "${HOME}/.claude/runtime/${ppid}/session_id")
fi

# Exit early if no session tracking
if [[ -z "$session_id" ]]; then
    exit 0
fi

# Check if this session opted into notifications
session_dir="${HOME}/.claude/runtime/sessions/${session_id}"
if [[ ! -f "${session_dir}/notify_label" ]]; then
    exit 0
fi
label=$(cat "${session_dir}/notify_label")

# Send notification event to daemon (fire-and-forget)
json_payload=$(jq -n \
    --arg session_id "$session_id" \
    --arg label "$label" \
    --arg event "Notification" \
    --arg message "${notification:-Claude needs your attention}" \
    '{session_id: $session_id, label: $label, event: $event, message: $message}')

curl -sS --connect-timeout 1 --max-time 2 \
    -X POST "http://127.0.0.1:4731/stop" \
    -H "Content-Type: application/json" \
    -d "$json_payload" >/dev/null 2>&1 || true

exit 0
