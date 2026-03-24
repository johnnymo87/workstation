# GPG for Headless Sessions Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task.

**Goal:** Make GPG commit signing available in headless OpenCode sessions on devbox by keeping a persistent SSH tunnel from macOS, and warn in `opencode-launch` when the forwarded socket is missing.

**Architecture:** A macOS `launchd` agent maintains `ssh -N devbox-tunnel` in the background, keeping the GPG agent socket forwarded to devbox at all times. `opencode-launch` checks for the socket before launching sessions. No changes to devbox key management or `opencode-serve`.

**Tech Stack:** Nix (home-manager), launchd, SSH, shell scripting

**Design doc:** `docs/plans/2026-03-24-gpg-headless-sessions-design.md`

## Operational Notes

- **Work in:** `/home/dev/projects/workstation` on `main` branch (no worktree needed for this -- it's the active workstation repo).
- **GPG signing unavailable in this session.** Use `--no-gpg-sign` on all commits.
- **Nix escaping:** `opencode-launch` lives inside a Nix `writeShellApplication` block in `home.base.nix`. Shell `$` must be escaped as `''$` in Nix strings. The code snippets below show the raw bash; when editing the actual file, use `''${` instead of `${` for shell variable expansion.
- **Task 1 (launchd agent):** The code edit can be done from devbox. Full verification (launchd loading) requires macOS and is deferred to Task 4.
- **Task 4 (end-to-end verification):** Cannot be done by a subagent on devbox. It is a manual macOS verification checklist for the user.

## Task 0: Commit the design and plan docs

The design doc and this plan file are uncommitted in the workstation repo.

```bash
cd /home/dev/projects/workstation
git add docs/plans/2026-03-24-gpg-headless-sessions-design.md docs/plans/2026-03-24-gpg-headless-sessions-plan.md
git commit --no-gpg-sign -m "docs: add GPG headless sessions design and plan"
```

---

### Task 1: Add persistent SSH tunnel launchd agent on macOS

**Files:**
- Modify: `users/dev/home.darwin.nix` (after the `opencode-serve` launchd agent, around line 193)

**Step 1: Add the launchd agent definition**

Add the following after the `launchd.agents.opencode-serve` block (after line 193):

```nix
  # Persistent SSH tunnel to devbox for GPG agent forwarding.
  # Keeps RemoteForward /run/user/1000/gnupg/S.gpg-agent alive so headless
  # sessions on devbox can sign commits without an interactive SSH session.
  launchd.agents.devbox-tunnel = {
    enable = true;
    config = {
      ProgramArguments = [
        "${pkgs.openssh}/bin/ssh"
        "-N"              # No remote command
        "-o" "ExitOnForwardFailure=yes"
        "-o" "ServerAliveInterval=30"
        "-o" "ServerAliveCountMax=3"
        "devbox-tunnel"   # Uses ~/.ssh/config Host definition
      ];
      RunAtLoad = true;
      KeepAlive = true;
      StandardOutPath = "${config.home.homeDirectory}/Library/Logs/devbox-tunnel.out.log";
      StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/devbox-tunnel.err.log";
    };
  };
```

**Step 2: Verify the nix expression evaluates**

Run (on macOS, or check syntax only):

```bash
nix eval --raw .#homeConfigurations.dev.activationPackage 2>&1 | head -5
```

If not on macOS, at minimum verify the file parses:

```bash
nix-instantiate --parse users/dev/home.darwin.nix >/dev/null 2>&1 && echo "ok"
```

**Step 3: Commit**

```bash
git add users/dev/home.darwin.nix
git commit --no-gpg-sign -m "feat: add persistent SSH tunnel for GPG agent forwarding to devbox"
```

---

### Task 2: Add GPG socket warning to `opencode-launch`

**Files:**
- Modify: `users/dev/home.base.nix:20-85` (the `opencode-launch` shell application)

**Step 1: Add socket check after the health check block**

After the existing health check (the `fi` on line 55 of `home.base.nix`), add the following block. **Important:** This is inside a Nix `writeShellApplication` `text = '' ... '';` block. Shell `${VAR}` must be written as `''${VAR}` in Nix. The snippet below shows the Nix-escaped form as it should appear in the file:

```nix
      # GPG agent forwarding check (devbox only)
      GPG_SOCKET="/run/user/1000/gnupg/S.gpg-agent"
      if [ -d "/run/user/1000" ] && [ ! -S "$GPG_SOCKET" ]; then
        echo "Warning: GPG agent socket not found at $GPG_SOCKET" >&2
        echo "Signed commits will fail in this session." >&2
        echo "Ensure the devbox-tunnel SSH connection is active from macOS." >&2
        echo "" >&2
      fi
```

Note: In the actual Nix string, `$GPG_SOCKET` does not need escaping because it is a plain `$VAR` (not `${VAR}`). The `$PWD` and `$HOME` references elsewhere in this function use `''$` already -- follow the same pattern if you need `${...}` syntax.

Key details:
- The `[ -d "/run/user/1000" ]` guard ensures this check only runs on Linux devbox (not macOS or other platforms).
- Uses `[ ! -S ... ]` to check for a socket specifically.
- Prints to stderr so it doesn't interfere with script output parsing.

**Step 2: Verify the script still parses**

```bash
bash -n <(nix eval --raw .#homeConfigurations.dev.config.home.packages --apply 'pkgs: builtins.toString pkgs') 2>&1 || echo "skip full eval"
```

Or more simply, check the nix file parses:

```bash
nix-instantiate --parse users/dev/home.base.nix >/dev/null 2>&1 && echo "ok"
```

**Step 3: Commit**

```bash
git add users/dev/home.base.nix
git commit --no-gpg-sign -m "feat: warn in opencode-launch when GPG agent socket is missing"
```

---

### Task 3: Update troubleshooting docs

**Files:**
- Modify: `.opencode/skills/troubleshooting-devbox/SKILL.md` (GPG Agent Forwarding section, around line 205)

**Step 1: Add persistent tunnel note to the GPG section**

After the existing "Hardening Note" paragraph (around line 237), add:

```markdown
### Persistent Tunnel

A `launchd` agent on macOS (`devbox-tunnel`) keeps the GPG forwarding alive in the background.
This means headless OpenCode sessions on devbox can sign commits even without an interactive SSH shell.

Check tunnel status on macOS:
```bash
launchctl list | grep devbox-tunnel
```

If the tunnel is down, restart it:
```bash
launchctl kickstart -k gui/$(id -u)/org.nix-community.home.devbox-tunnel
```

`opencode-launch` warns if the forwarded socket is missing on devbox before launching a session.
```

**Step 2: Commit**

```bash
git add .opencode/skills/troubleshooting-devbox/SKILL.md
git commit --no-gpg-sign -m "docs: add persistent tunnel to GPG troubleshooting"
```

---

### Task 4: End-to-end verification (manual, macOS required)

> This task cannot be executed by a subagent on devbox. It is a checklist for the user to run on macOS after applying home-manager. Skip this task during subagent-driven execution and report it as "deferred to user."

**Step 1: On macOS, verify the launchd agent is loaded**

After applying home-manager:

```bash
launchctl list | grep devbox-tunnel
```

Expected: agent appears in list.

**Step 2: On devbox with no interactive SSH, verify socket exists**

```bash
test -S /run/user/1000/gnupg/S.gpg-agent && echo "socket present" || echo "socket missing"
```

Expected: `socket present`

**Step 3: Test `opencode-launch` with socket present**

```bash
opencode-launch ~/projects/anthropic-oauth-proxy "say hello"
```

Expected: no GPG warning, session launches normally.

**Step 4: Stop tunnel, test `opencode-launch` with socket absent**

On macOS:
```bash
launchctl bootout gui/$(id -u)/org.nix-community.home.devbox-tunnel
```

On devbox:
```bash
rm -f /run/user/1000/gnupg/S.gpg-agent
opencode-launch ~/projects/anthropic-oauth-proxy "say hello"
```

Expected: warning about missing GPG socket printed to stderr, session still launches.

**Step 5: Restart tunnel and verify signing works**

On macOS:
```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/org.nix-community.home.devbox-tunnel.plist
```

On devbox:
```bash
echo test | gpg --clearsign >/dev/null && echo "signing works"
```

Expected: `signing works`
