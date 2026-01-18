---
description: Enable Telegram notifications for this Claude Code session
allowed-tools: [Bash, Read, Glob]
---

Enable Telegram notifications for this session so you'll be alerted when tasks complete.

**Label:** $ARGUMENTS

**Steps to register:**

1. **Find the current session ID** (prefer pane-map in tmux, fall back to ppid-map):
   ```bash
   # In tmux (but NOT nvim terminal): use pane-map
   # In nvim terminal or outside tmux: use ppid-map
   # (nvim terminals share TMUX_PANE, so must use PPID)
   if [[ -n "${TMUX:-}" && -n "${TMUX_PANE:-}" && -z "${NVIM:-}" ]]; then
       socket_path="${TMUX%%,*}"
       socket_name=$(basename "$socket_path")
       pane_num="${TMUX_PANE#%}"
       pane_key="${socket_name}-${pane_num}"
       cat ~/.claude/runtime/pane-map/$pane_key
   else
       cat ~/.claude/runtime/ppid-map/$PPID
   fi
   ```

   This gives you the session_id. Verify it exists:
   ```bash
   cat ~/.claude/runtime/sessions/<SESSION_ID>/transcript_path
   ```

2. **Register with the daemon:**
   ```bash
   curl -s -X POST "http://localhost:4731/sessions/enable-notify" \
       -H "Content-Type: application/json" \
       -d '{"session_id": "<SESSION_ID>", "label": "<LABEL>", "nvim_socket": ""}'
   ```

3. **Write notify_label** to session directory (hooks read from here):
   ```bash
   mkdir -p ~/.claude/runtime/sessions/<SESSION_ID>
   echo "<LABEL>" > ~/.claude/runtime/sessions/<SESSION_ID>/notify_label
   ```

4. **Register with ccremote** (if running inside nvim terminal):
   ```bash
   if [[ -n "${NVIM:-}" ]]; then
       nvim --server "$NVIM" --remote-expr "execute('CCRegister <LABEL>')"
   fi
   ```
   This enables targeted nvim RPC injection - multiple terminal tabs in the same nvim can each be addressed by their label.

**Label to use:** "$ARGUMENTS" (or current directory basename if empty)

After registering, confirm to the user:
- Whether registration succeeded
- The session ID and label used
- That they'll receive Telegram notifications when tasks complete
