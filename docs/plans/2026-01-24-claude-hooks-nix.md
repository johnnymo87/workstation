# Claude Code Hooks via Nix Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Deploy Claude Code hooks (SessionStart, Stop) via home-manager with proper dependency management.

**Architecture:** Create hook scripts in `assets/claude/hooks/`, wrap them with `writeShellApplication` for consistent dependencies (especially `tac` on macOS), deploy to `~/.claude/hooks/`, and add hook configuration to `managedSettings` for merge into `settings.json`.

**Tech Stack:** Nix, home-manager, bash, jq, curl, coreutils

---

## Summary

| Task | Description |
|------|-------------|
| 1 | Create hook scripts in assets |
| 2 | Create claude-hooks.nix module |
| 3 | Import module and add hooks to managedSettings |
| 4 | Apply and test |

---

## Task 1: Create Hook Scripts in Assets

**Files:**
- Create: `/home/dev/projects/workstation/assets/claude/hooks/on-session-start.sh`
- Create: `/home/dev/projects/workstation/assets/claude/hooks/on-stop.sh`

**Step 1: Create hooks directory**

```bash
mkdir -p /home/dev/projects/workstation/assets/claude/hooks
```

**Step 2: Create on-session-start.sh**

```bash
cat > /home/dev/projects/workstation/assets/claude/hooks/on-session-start.sh << 'SCRIPT'
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

    # Check if notify_label exists from previous opt-in
    notify_label=""
    notify_flag="false"
    if [[ -n "${session_dir:-}" && -f "${session_dir}/notify_label" ]]; then
        notify_label=$(cat "${session_dir}/notify_label")
        notify_flag="true"
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
        --argjson notify "$notify_flag" \
        --arg label "$notify_label" \
        '{session_id: $session_id, ppid: $ppid, pid: $pid, start_time: $start_time, cwd: $cwd, nvim_socket: $nvim_socket, tmux_session: $tmux_session, tmux_pane: $tmux_pane, tmux_pane_id: $tmux_pane_id, notify: $notify, label: $label}')

    curl -sS --connect-timeout 1 --max-time 2 \
        -X POST "http://127.0.0.1:4731/session-start" \
        -H "Content-Type: application/json" \
        -d "$json_payload" >/dev/null 2>&1 || true
fi

exit 0
SCRIPT
chmod +x /home/dev/projects/workstation/assets/claude/hooks/on-session-start.sh
```

**Step 3: Create on-stop.sh**

```bash
cat > /home/dev/projects/workstation/assets/claude/hooks/on-stop.sh << 'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

# Read hook input from Claude
input="$(cat)"
ppid="${PPID:-unknown}"

# Get session_id - prefer hook input (most reliable), fall back to mappings
session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)

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
    exit 0
fi

# Get transcript path from hook input
transcript_path=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null || true)

# Extract Claude's last assistant message with text content from transcript JSONL
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

# Send stop event to daemon (fire-and-forget)
json_payload=$(jq -n \
    --arg session_id "$session_id" \
    --arg label "$label" \
    --arg event "Stop" \
    --arg message "$last_message" \
    '{session_id: $session_id, label: $label, event: $event, message: $message}')

curl -sS --connect-timeout 1 --max-time 2 \
    -X POST "http://127.0.0.1:4731/stop" \
    -H "Content-Type: application/json" \
    -d "$json_payload" >/dev/null 2>&1 || true

exit 0
SCRIPT
chmod +x /home/dev/projects/workstation/assets/claude/hooks/on-stop.sh
```

**Step 4: Verify files created**

```bash
ls -la /home/dev/projects/workstation/assets/claude/hooks/
```

Expected: Two executable scripts.

**Step 5: Commit**

```bash
cd /home/dev/projects/workstation
git add assets/claude/hooks/
git commit -m "feat: add Claude Code hook scripts

SessionStart hook: tracks session metadata, notifies daemon
Stop hook: sends notification with last assistant message"
```

---

## Task 2: Create claude-hooks.nix Module

**Files:**
- Create: `/home/dev/projects/workstation/users/dev/claude-hooks.nix`

**Step 1: Create the module**

```bash
cat > /home/dev/projects/workstation/users/dev/claude-hooks.nix << 'NIX'
# Claude Code hooks deployment
# Wraps hook scripts with dependencies for cross-platform compatibility
{ config, lib, pkgs, assetsPath, ... }:

let
  # Dependencies for hook scripts
  # coreutils provides tac (not available on macOS by default)
  hookInputs = [
    pkgs.jq
    pkgs.curl
    pkgs.coreutils
  ];

  # Create a wrapper that sets PATH and execs the real script
  mkHook = name: scriptName: pkgs.writeShellApplication {
    name = "claude-hook-${name}";
    runtimeInputs = hookInputs;
    text = ''
      exec ${assetsPath}/claude/hooks/${scriptName} "$@"
    '';
  };

  hookStart = mkHook "session-start" "on-session-start.sh";
  hookStop = mkHook "stop" "on-stop.sh";

  # Absolute paths for settings.json (no tilde expansion needed)
  hooksDir = "${config.home.homeDirectory}/.claude/hooks";
in
{
  # Deploy wrapper scripts to ~/.claude/hooks/
  home.file.".claude/hooks/on-session-start.sh" = {
    source = "${hookStart}/bin/claude-hook-session-start";
    executable = true;
  };

  home.file.".claude/hooks/on-stop.sh" = {
    source = "${hookStop}/bin/claude-hook-stop";
    executable = true;
  };

  # Export hook paths for use in managedSettings (home.base.nix)
  # This is a custom option that home.base.nix will read
  options.claude.hooks = {
    sessionStartPath = lib.mkOption {
      type = lib.types.str;
      default = "${hooksDir}/on-session-start.sh";
      description = "Path to session start hook";
    };
    stopPath = lib.mkOption {
      type = lib.types.str;
      default = "${hooksDir}/on-stop.sh";
      description = "Path to stop hook";
    };
  };
}
NIX
```

**Step 2: Verify syntax**

```bash
cd /home/dev/projects/workstation
nix-instantiate --parse users/dev/claude-hooks.nix
```

Expected: No errors (outputs parsed nix expression).

**Step 3: Commit**

```bash
cd /home/dev/projects/workstation
git add users/dev/claude-hooks.nix
git commit -m "feat: add claude-hooks.nix module

Wraps hook scripts with writeShellApplication for:
- Consistent PATH (jq, curl, coreutils)
- Cross-platform tac availability (macOS fix)
- Deploys to ~/.claude/hooks/"
```

---

## Task 3: Import Module and Add Hooks to managedSettings

**Files:**
- Modify: `/home/dev/projects/workstation/users/dev/home.nix`
- Modify: `/home/dev/projects/workstation/users/dev/home.base.nix`

**Step 1: Add import to home.nix**

Edit `/home/dev/projects/workstation/users/dev/home.nix`:

```nix
# Home-manager entry point
# Imports all modules - platform-specific ones use mkIf internally
{ pkgs, lib, ... }:

{
  imports = [
    ./home.base.nix
    ./home.linux.nix
    ./home.darwin.nix
    ./claude-skills.nix
    ./claude-hooks.nix   # <-- ADD THIS LINE
  ];
}
```

**Step 2: Add hooks to managedSettings in home.base.nix**

Find the `managedSettings` definition (around line 22) and add hooks:

```nix
  # Managed settings fragment - only keys we want to control
  # Claude Code's runtime state (feedbackSurveyState, enabledPlugins, etc.) is preserved
  # On Darwin, we skip statusLine to preserve the custom dotfiles statusline.sh
  managedSettings = {
    hooks = {
      SessionStart = [{
        matcher = "compact|startup|resume";
        hooks = [{
          type = "command";
          command = config.claude.hooks.sessionStartPath;
        }];
      }];
      Stop = [{
        hooks = [{
          type = "command";
          command = config.claude.hooks.stopPath;
        }];
      }];
    };
  } // lib.optionalAttrs (!pkgs.stdenv.isDarwin) {
    statusLine = {
      type = "command";
      command = lib.getExe claudeStatusline;
    };
  };
```

**Step 3: Verify nix evaluation**

```bash
cd /home/dev/projects/workstation
nix flake check --no-build 2>&1 | head -20
```

Expected: No errors (or only warnings).

**Step 4: Commit**

```bash
cd /home/dev/projects/workstation
git add users/dev/home.nix users/dev/home.base.nix
git commit -m "feat: wire up Claude hooks to settings

- Import claude-hooks.nix module
- Add hooks to managedSettings for merge into settings.json
- SessionStart: tracks sessions, notifies daemon
- Stop: sends Telegram notification with last message"
```

---

## Task 4: Apply and Test

**Step 1: Apply home-manager**

```bash
cd /home/dev/projects/workstation
home-manager switch --flake .#dev
```

Expected: Build succeeds, no errors.

**Step 2: Verify hooks deployed**

```bash
ls -la ~/.claude/hooks/
cat ~/.claude/hooks/on-stop.sh | head -10
```

Expected:
- Two files: `on-session-start.sh`, `on-stop.sh`
- Scripts start with Nix shebang and PATH setup

**Step 3: Verify settings merged**

```bash
jq '.hooks' ~/.claude/settings.json
```

Expected:
```json
{
  "SessionStart": [{"matcher": "compact|startup|resume", "hooks": [...]}],
  "Stop": [{"hooks": [...]}]
}
```

**Step 4: Test hooks manually**

```bash
# Test session-start hook
echo '{"session_id":"test-123","transcript_path":"/tmp/test.jsonl"}' | ~/.claude/hooks/on-session-start.sh
ls ~/.claude/runtime/sessions/test-123/

# Cleanup test
rm -rf ~/.claude/runtime/sessions/test-123
```

Expected: Creates session directory with metadata files.

**Step 5: Push changes**

```bash
cd /home/dev/projects/workstation
git push
```

**Step 6: E2E test**

1. Start a new Claude Code session
2. Run `/notify-telegram test-hooks`
3. Let Claude respond and stop
4. Check Telegram for notification

---

## Verification Checklist

After completion:
- [ ] `~/.claude/hooks/on-session-start.sh` exists and is executable
- [ ] `~/.claude/hooks/on-stop.sh` exists and is executable
- [ ] `~/.claude/settings.json` contains `hooks.SessionStart` and `hooks.Stop`
- [ ] Hook scripts have Nix-managed PATH (check shebang)
- [ ] Telegram notifications work end-to-end
