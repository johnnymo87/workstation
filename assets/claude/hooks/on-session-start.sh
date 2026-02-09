#!/usr/bin/env bash
set -euo pipefail
input="$(cat)"
ppid="${PPID:-unknown}"

# Extract session info from hook input
transcript_path="$(printf '%s' "$input" | jq -r '.transcript_path // empty')"
session_id="$(printf '%s' "$input" | jq -r '.session_id // empty')"

# Primary storage: by session_id (robust, survives PID reuse)
if [[ -n "$session_id" ]]; then
    session_dir="${HOME}/.claude/runtime/sessions/${session_id}"
    mkdir -p "$session_dir"
    printf '%s\n' "$transcript_path" > "${session_dir}/transcript_path"
    printf '%s\n' "$ppid" > "${session_dir}/ppid"
fi

# Secondary: ppid-map for slash commands that only know PPID
if [[ -n "$session_id" && "$ppid" =~ ^[0-9]+$ ]]; then
    mkdir -p "${HOME}/.claude/runtime/ppid-map"
    printf '%s\n' "$session_id" > "${HOME}/.claude/runtime/ppid-map/${ppid}"
fi

# Tertiary: pane-map for tmux environments
# Skip if inside nvim terminal (multiple nvim terminals share TMUX_PANE)
if [[ -n "$session_id" && -n "${TMUX:-}" && -n "${TMUX_PANE:-}" && -z "${NVIM:-}" ]]; then
    socket_path="${TMUX%%,*}"
    socket_name=$(basename "$socket_path")
    pane_num="${TMUX_PANE#%}"
    pane_key="${socket_name}-${pane_num}"
    mkdir -p "${HOME}/.claude/runtime/pane-map"
    printf '%s\n' "$session_id" > "${HOME}/.claude/runtime/pane-map/${pane_key}"
fi

# Legacy: keep PPID-based dir for backward compatibility
dir="${HOME}/.claude/runtime/${ppid}"
mkdir -p "$dir"
printf '%s\n' "$transcript_path" > "${dir}/transcript_path"
printf '%s\n' "$session_id"      > "${dir}/session_id"

# Detect tmux session if running inside tmux
tmux_session=""
tmux_pane=""
tmux_pane_id=""
if [[ -n "${TMUX:-}" ]]; then
    tmux_session="$(tmux display-message -p '#{session_name}' 2>/dev/null || true)"
    tmux_pane="$(tmux display-message -p '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null || true)"
    tmux_pane_id="$(tmux display-message -p '#{pane_id}' 2>/dev/null || true)"
fi

# Detect controlling TTY for nvim RPC instance matching
# Hook stdin is piped (CC sends JSON), so `tty` won't work. Instead, read the PTY
# device from CC's own stdin fd, which is the terminal PTY inherited from nvim.
# This PTY path matches nvim_get_chan_info(chan).pty on the nvim side.
session_tty=""
if [[ -n "${NVIM:-}" && "$ppid" =~ ^[0-9]+$ ]]; then
    if [[ "$(uname)" == "Darwin" ]]; then
        # macOS: no /proc, use ps to get controlling terminal
        tty_name="$(ps -o tty= -p "$ppid" 2>/dev/null | sed 's/^[[:space:]]*//')"
        if [[ -n "$tty_name" && "$tty_name" != "??" ]]; then
            session_tty="/dev/$tty_name"
        fi
    else
        # Linux: read PTY device from CC's stdin fd
        session_tty="$(readlink "/proc/$ppid/fd/0" 2>/dev/null || true)"
        # Only accept PTY device paths
        if [[ "$session_tty" != /dev/pts/* && "$session_tty" != /dev/tty* ]]; then
            session_tty=""
        fi
    fi
fi

# Notify daemon of session start (fire-and-forget)
if [[ -n "$session_id" ]]; then
    ppid_num=0
    if [[ "$ppid" =~ ^[0-9]+$ ]]; then
        ppid_num="$ppid"
    fi

    # Capture process start time as epoch (for liveness validation)
    start_time=0
    if [[ "$ppid" =~ ^[0-9]+$ ]]; then
        if [[ "$(uname)" == "Darwin" ]]; then
            lstart=$(ps -o lstart= -p "$ppid" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            if [[ -n "$lstart" ]]; then
                start_time=$(date -j -f "%a %d %b %H:%M:%S %Y" "$lstart" "+%s" 2>/dev/null || echo "0")
            fi
        else
            # Linux: use stat on /proc/<pid>
            start_time=$(stat -c %Y "/proc/$ppid" 2>/dev/null || echo "0")
        fi
    fi

    # Auto-enable notifications with project dir as label
    notify_flag="true"
    if [[ -n "${session_dir:-}" && -f "${session_dir}/notify_label" ]]; then
        notify_label=$(cat "${session_dir}/notify_label")
    else
        notify_label="${PWD##*/}"
        if [[ -n "${session_dir:-}" ]]; then
            printf '%s\n' "$notify_label" > "${session_dir}/notify_label"
        fi
    fi

    json_payload=$(jq -n \
        --arg session_id "$session_id" \
        --argjson ppid "$ppid_num" \
        --argjson pid "$$" \
        --argjson start_time "$start_time" \
        --arg cwd "$PWD" \
        --arg nvim_socket "${NVIM:-}" \
        --arg tmux_session "$tmux_session" \
        --arg tmux_pane "$tmux_pane" \
        --arg tmux_pane_id "$tmux_pane_id" \
        --arg tty "$session_tty" \
        --argjson notify "$notify_flag" \
        --arg label "$notify_label" \
        '{session_id: $session_id, ppid: $ppid, pid: $pid, start_time: $start_time, cwd: $cwd, nvim_socket: $nvim_socket, tmux_session: $tmux_session, tmux_pane: $tmux_pane, tmux_pane_id: $tmux_pane_id, tty: $tty, notify: $notify, label: $label}')

    _dbg_dir="${HOME}/.claude/runtime/hook-debug"
    mkdir -p "$_dbg_dir"
    _dbg="${_dbg_dir}/session-start.$(date +%s%N).log"
    {
      echo "ts=$(date -Is) pid=$$ ppid=$PPID session=$session_id"
      echo "notify=$notify_flag label=$notify_label"
      echo "payload=$json_payload"
    } >"$_dbg"

    curl_output=$(curl -sS --connect-timeout 1 --max-time 2 \
        -X POST "http://127.0.0.1:4731/session-start" \
        -H "Content-Type: application/json" \
        -d "$json_payload" 2>&1) || true
    echo "curl_done output=$curl_output" >>"$_dbg"
fi

exit 0
