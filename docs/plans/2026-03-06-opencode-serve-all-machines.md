# OpenCode Serve on All Machines + Launch Wrapper

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Enable headless opencode session launching from CLI on all four machines (devbox, cloudbox, macOS, crostini) with an ergonomic wrapper script and agent skill.

**Architecture:** Add `opencode serve` as a persistent service on cloudbox (NixOS systemd), macOS (launchd), and crostini (home-manager systemd user). Wire `OPENCODE_URL` into each machine's pigeon daemon. Install a cross-platform `opencode-launch` wrapper script. Deploy an opencode skill documenting usage.

**Tech Stack:** Nix (NixOS configuration.nix, nix-darwin launchd, home-manager systemd.user), shell scripting, opencode serve HTTP API.

---

### Task 1: Add opencode-serve to cloudbox

**Files:**
- Modify: `hosts/cloudbox/configuration.nix`

**Step 1: Add the opencode-serve systemd service**

Add after the pigeon target block (after line 200), mirroring devbox's definition:

```nix
  systemd.services.opencode-serve = {
    description = "OpenCode headless serve";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    path = [ pkgs.git pkgs.fzf pkgs.ripgrep ];
    serviceConfig = {
      Type = "simple";
      User = "dev";
      Group = "dev";
      WorkingDirectory = "/home/dev";
      ExecStart = "${pkgs.writeShellScript "opencode-serve-start" ''
        set -euo pipefail
        exec /home/dev/.nix-profile/bin/opencode serve --port 4096 --hostname 127.0.0.1
      ''}";
      Restart = "always";
      RestartSec = 10;
    };
  };
```

**Step 2: Add OPENCODE_URL to pigeon daemon**

In the pigeon-daemon ExecStart script, add after the `OP_SERVICE_ACCOUNT_TOKEN` export:

```bash
export OPENCODE_URL="http://127.0.0.1:4096"
```

**Step 3: Verify syntax**

Run: `nix flake check --no-build 2>&1 | head -20`
Expected: No errors related to cloudbox configuration.

**Step 4: Commit**

```bash
git add hosts/cloudbox/configuration.nix
git commit -m "feat: add opencode-serve service to cloudbox"
```

---

### Task 2: Add opencode-serve to macOS

**Files:**
- Modify: `users/dev/home.darwin.nix`

**Step 1: Add the opencode-serve launchd agent**

Add after the pigeon-daemon block (after line 158):

```nix
  # OpenCode headless serve (for launching sessions from CLI or Telegram)
  launchd.agents.opencode-serve = {
    enable = true;
    config = {
      ProgramArguments = [
        "${pkgs.writeShellScript "opencode-serve-start" ''
          exec ${opencode}/bin/opencode serve --port 4096 --hostname 127.0.0.1
        ''}"
      ];
      EnvironmentVariables = {
        HOME = config.home.homeDirectory;
        PATH = lib.concatStringsSep ":" [
          "${pkgs.git}/bin"
          "${pkgs.fzf}/bin"
          "${pkgs.ripgrep}/bin"
          "/usr/bin"
          "/bin"
        ];
      };
      RunAtLoad = true;
      KeepAlive = true;
      StandardOutPath = "${config.home.homeDirectory}/Library/Logs/opencode-serve.out.log";
      StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/opencode-serve.err.log";
    };
  };
```

**Problem:** The `opencode` derivation is defined as a `let` binding in `home.base.nix`, not passed as a module argument. The darwin module doesn't have access to it.

**Solution:** The launchd agent needs to reference the opencode binary. Since it's installed to `~/.nix-profile/bin/opencode`, use that path (same pattern as devbox):

```nix
  launchd.agents.opencode-serve = {
    enable = true;
    config = {
      ProgramArguments = [
        "${config.home.homeDirectory}/.nix-profile/bin/opencode"
        "serve" "--port" "4096" "--hostname" "127.0.0.1"
      ];
      EnvironmentVariables = {
        HOME = config.home.homeDirectory;
        PATH = lib.concatStringsSep ":" [
          "${pkgs.git}/bin"
          "${pkgs.fzf}/bin"
          "${pkgs.ripgrep}/bin"
          "/usr/bin"
          "/bin"
        ];
      };
      RunAtLoad = true;
      KeepAlive = true;
      StandardOutPath = "${config.home.homeDirectory}/Library/Logs/opencode-serve.out.log";
      StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/opencode-serve.err.log";
    };
  };
```

**Step 2: Add OPENCODE_URL to pigeon daemon**

In the pigeon-daemon's EnvironmentVariables block, add:

```nix
OPENCODE_URL = "http://127.0.0.1:4096";
```

**Step 3: Commit**

```bash
git add users/dev/home.darwin.nix
git commit -m "feat: add opencode-serve launchd agent to macOS"
```

---

### Task 3: Add opencode-serve to crostini

**Files:**
- Modify: `users/dev/home.crostini.nix`

**Step 1: Add the opencode-serve systemd user service**

Add after the pigeon-daemon block (after line 112):

```nix
  # OpenCode headless serve (for launching sessions from CLI or Telegram)
  systemd.user.services.opencode-serve = {
    Unit = {
      Description = "OpenCode headless serve";
      After = [ "network-online.target" ];
      Wants = [ "network-online.target" ];
    };
    Service = {
      Type = "simple";
      WorkingDirectory = config.home.homeDirectory;
      Environment = [
        "HOME=${config.home.homeDirectory}"
        "PATH=${lib.makeBinPath [ pkgs.git pkgs.fzf pkgs.ripgrep ]}"
      ];
      ExecStart = "${pkgs.writeShellScript "opencode-serve-start" ''
        set -euo pipefail
        exec ${config.home.homeDirectory}/.nix-profile/bin/opencode serve --port 4096 --hostname 127.0.0.1
      ''}";
      Restart = "always";
      RestartSec = 10;
    };
    Install = {
      WantedBy = [ "default.target" ];
    };
  };
```

**Step 2: Add OPENCODE_URL to pigeon daemon**

In the pigeon-daemon ExecStart script, add after the `OP_SERVICE_ACCOUNT_TOKEN` export:

```bash
export OPENCODE_URL="http://127.0.0.1:4096"
```

**Step 3: Commit**

```bash
git add users/dev/home.crostini.nix
git commit -m "feat: add opencode-serve systemd user service to crostini"
```

---

### Task 4: Create opencode-launch wrapper script

**Files:**
- Modify: `users/dev/home.base.nix`

**Step 1: Add the wrapper script to home.packages**

In `home.base.nix`, add a new `let` binding (after `tpaste` around line 18):

```nix
  opencode-launch = pkgs.writeShellApplication {
    name = "opencode-launch";
    runtimeInputs = [ pkgs.curl pkgs.jq ];
    text = ''
      set -euo pipefail

      OPENCODE_URL="''${OPENCODE_URL:-http://127.0.0.1:4096}"

      usage() {
        echo "Usage: opencode-launch [directory] <prompt>"
        echo ""
        echo "Launch a headless opencode session."
        echo ""
        echo "  opencode-launch ~/projects/pigeon \"fix the test\""
        echo "  opencode-launch \"fix the test\"  # uses current directory"
        exit 1
      }

      if [ $# -eq 0 ]; then
        usage
      elif [ $# -eq 1 ]; then
        directory="$PWD"
        prompt="$1"
      else
        directory="$1"
        shift
        prompt="$*"
      fi

      # Resolve ~ to $HOME
      directory="''${directory/#\~/$HOME}"

      # Health check
      if ! curl -sf "$OPENCODE_URL/global/health" >/dev/null 2>&1; then
        echo "Error: opencode serve is not reachable at $OPENCODE_URL" >&2
        echo "Check: systemctl status opencode-serve (Linux) or launchctl list | grep opencode (macOS)" >&2
        exit 1
      fi

      # Create session
      session_response=$(curl -sf -X POST "$OPENCODE_URL/session" \
        -H "x-opencode-directory: $directory") || {
        echo "Error: failed to create session" >&2
        exit 1
      }

      session_id=$(echo "$session_response" | jq -r '.id')
      if [ -z "$session_id" ] || [ "$session_id" = "null" ]; then
        echo "Error: no session ID in response: $session_response" >&2
        exit 1
      fi

      # Send prompt
      curl -sf -X POST "$OPENCODE_URL/session/$session_id/prompt_async" \
        -H "x-opencode-directory: $directory" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg p "$prompt" '{parts: [{type: "text", text: $p}]}')" >/dev/null || {
        echo "Error: failed to send prompt to session $session_id" >&2
        exit 1
      }

      echo "Session launched: $session_id"
      echo "Directory: $directory"
      echo ""
      echo "Attach:  opencode attach $OPENCODE_URL --session $session_id"
      echo "Kill:    curl -sf -X DELETE $OPENCODE_URL/session/$session_id"
    '';
  };
```

Then add `opencode-launch` to the `home.packages` list.

**Step 2: Commit**

```bash
git add users/dev/home.base.nix
git commit -m "feat: add opencode-launch wrapper script"
```

---

### Task 5: Create launching-headless-sessions skill

**Files:**
- Create: `assets/opencode/skills/launching-headless-sessions/SKILL.md`
- Modify: `users/dev/opencode-skills.nix`

**Step 1: Create the skill file**

```markdown
---
name: launching-headless-sessions
description: Launch headless opencode sessions from CLI. Use when you need to start a new opencode session in the background to work on a task in parallel, or when spawning work on a specific directory.
allowed-tools: [Bash, Read]
---

# Launching Headless OpenCode Sessions

Start a new headless opencode session from the CLI without going through Telegram.

## Quick Start

```bash
# Launch in a specific directory
opencode-launch ~/projects/pigeon "fix the failing test in src/auth.ts"

# Launch in the current directory
opencode-launch "run the build and fix any type errors"
```

## What This Does

1. Health-checks the local `opencode serve` instance (port 4096)
2. Creates a new session via `POST /session`
3. Sends the prompt via `POST /session/{id}/prompt_async`
4. Prints the session ID and commands to attach or kill

The session runs headless. The pigeon plugin inside the session auto-registers
with the daemon, so you will receive Telegram notifications for stop/question events.

## Attaching to a Session

```bash
opencode attach http://localhost:4096 --session <session-id>
```

The session ID is printed by `opencode-launch`.

## Killing a Session

```bash
curl -sf -X DELETE http://localhost:4096/session/<session-id>
```

Or from Telegram: `/kill <session-id>`

## Listing Sessions

```bash
curl -s http://localhost:4096/session | jq
```

## Environment

- `OPENCODE_URL` defaults to `http://127.0.0.1:4096`
- Override if opencode serve runs on a different port

## Prerequisites

The `opencode serve` service must be running:

```bash
# Linux (NixOS)
systemctl status opencode-serve

# Linux (Crostini)
systemctl --user status opencode-serve

# macOS
launchctl list | grep opencode

# Direct health check (all platforms)
curl -s http://localhost:4096/global/health
```

## Troubleshooting

**"opencode serve is not reachable"**: The service isn't running. Start it:
- NixOS: `sudo systemctl start opencode-serve`
- Crostini: `systemctl --user start opencode-serve`
- macOS: `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/org.nix-community.home.opencode-serve.plist`

**Session created but no activity**: Check that the model provider API key is available in the opencode serve environment (e.g. `GOOGLE_GENERATIVE_AI_API_KEY` for Gemini).
```

**Step 2: Register the skill in opencode-skills.nix**

Add `"launching-headless-sessions"` to the `crossPlatformSkills` list.

**Step 3: Commit**

```bash
git add assets/opencode/skills/launching-headless-sessions/SKILL.md users/dev/opencode-skills.nix
git commit -m "feat: add launching-headless-sessions opencode skill"
```
