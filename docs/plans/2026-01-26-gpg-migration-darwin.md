# GPG Migration to Home-Manager (Darwin + Devbox)

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Migrate GPG configuration from manual files to home-manager, with platform-specific handling for macOS (local agent) and Linux devbox (forwarded agent).

**Architecture:** macOS runs the gpg-agent locally (keys live here), Linux devbox receives the agent socket via SSH forwarding (no local keys). On Darwin, we configure `services.gpg-agent` but **disable the launchd service** because gpg-agent's `--supervised` mode expects systemd-style socket activation (LISTEN_FDS), not launchd's `launch_activate_socket()` API. Instead, we let GnuPG auto-start the agent on demand (upstream recommended approach). The `no-autostart` option is Linux-only to prevent the forwarded socket from being clobbered.

**Tech Stack:** home-manager, NixOS, nix-darwin, GnuPG 2.4.x, pinentry-mac

**References:**
- ChatGPT research: `/tmp/research-gpg-migration-darwin-answer.md`
- GPG forwarding research: `/tmp/research-gpg-agent-forwarding-answer-1.md`
- Launchd socket activation research: `/tmp/research-gpg-agent-launchd-supervised-answer.md`
- GnuPG Agent Forwarding: https://wiki.gnupg.org/AgentForwarding
- home-manager gpg-agent launchd PR: https://github.com/nix-community/home-manager/pull/2964

---

## Pre-Migration Steps (Manual, on macOS)

Before applying home-manager changes, run these commands on macOS:

```bash
# 1. Back up existing GPG config
cp -r ~/.gnupg ~/.gnupg.backup.$(date +%Y%m%d)

# 2. Kill existing gpg-agent
gpgconf --kill gpg-agent

# 3. Check for brew/other launchd jobs keeping agent alive
launchctl list | grep -i gpg
# If any found, unload them:
# launchctl unload ~/Library/LaunchAgents/homebrew.mxcl.gnupg.plist (example)

# 4. Record current socket paths for reference
gpgconf --list-dir agent-socket
gpgconf --list-dir agent-extra-socket
```

---

### Task 1: Update GPG Settings in home.base.nix

**Files:**
- Modify: `users/dev/home.base.nix:112-124`

**Step 1: Read current GPG config**

Review the current state at lines 112-124.

**Step 2: Update programs.gpg settings**

Replace the GPG section with:

```nix
  # GPG - shared settings (both platforms)
  programs.gpg = {
    enable = true;
    package = pkgs.gnupg;  # Use nixpkgs GPG for consistency
    settings = {
      auto-key-retrieve = true;
      no-emit-version = true;
      # NOTE: no-autostart is NOT here - it's Linux-only (see home.linux.nix)
    };
    dirmngrSettings = {
      keyserver = "hkps://keys.openpgp.org";
    };
  };

  # common.conf is platform-specific - see home.linux.nix and home.darwin.nix
  # We remove the base definition here; each platform defines its own
```

**Step 3: Remove the common.conf definition from home.base.nix**

Delete the `home.file.".gnupg/common.conf"` block (lines 118-124 approximately).

**Step 4: Verify nix syntax**

Run: `cd ~/projects/workstation && nix flake check 2>&1 | head -20`

Expected: No syntax errors (may show warnings about dirty tree)

**Step 5: Commit**

```bash
git add users/dev/home.base.nix
git commit -m "refactor(gpg): update shared settings, remove platform-specific common.conf"
```

---

### Task 2: Add GPG Agent Service to home.darwin.nix

**Files:**
- Modify: `users/dev/home.darwin.nix:51-53`

**Step 1: Read current Darwin GPG overrides**

Review lines 51-53 which currently disable GPG.

**Step 2: Replace GPG overrides with full configuration**

Replace:
```nix
  # GPG: manages .gnupg/gpg.conf and common.conf
  programs.gpg.enable = lib.mkForce false;
  home.file.".gnupg/common.conf".enable = lib.mkForce false;
```

With:
```nix
  # GPG: fully managed by home-manager on Darwin
  # Agent runs locally (auto-starts on demand), keys live here, forwarded to devbox via SSH
  services.gpg-agent = {
    enable = true;
    defaultCacheTtl = 600;      # 10 minutes
    maxCacheTtl = 7200;         # 2 hours
    enableExtraSocket = false;  # We set path manually in extraConfig
    grabKeyboardAndMouse = false;  # Not needed for pinentry-mac (X11-only feature)
    pinentry.package = pkgs.pinentry_mac;
    extraConfig = ''
      # Pin extra-socket path for stable SSH RemoteForward config
      extra-socket ${config.home.homeDirectory}/.gnupg/S.gpg-agent.extra
    '';
  };

  # Disable home-manager's launchd socket-activated service (doesn't work with gpg-agent)
  # gpg-agent --supervised expects systemd-style LISTEN_FDS, not launchd's launch_activate_socket()
  # Instead, let GnuPG auto-start the agent on demand (upstream recommended approach)
  launchd.agents.gpg-agent.enable = lib.mkForce false;

  # Darwin common.conf - empty (no special options needed locally)
  home.file.".gnupg/common.conf".text = "";
```

**Why these specific options:**
- `pinentry.package` (not `pinentryPackage`): The old option was deprecated in home-manager PR #6900
- `grabKeyboardAndMouse = false`: Prevents adding "grab" to gpg-agent.conf (X11-only, not needed for pinentry-mac)
- `enableExtraSocket = false`: We set the path explicitly in `extraConfig` for stable SSH RemoteForward
- `launchd.agents.gpg-agent.enable = false`: The launchd socket-activated service doesn't work because gpg-agent's `--supervised` mode expects systemd-style `LISTEN_FDS` environment variables, not launchd's `launch_activate_socket()` API

**Step 3: Add prepareForHM cleanup for GPG files**

Add to the existing `prepareForHM` activation script:
```nix
    rm -f ~/.gnupg/gpg.conf 2>/dev/null || true
    rm -f ~/.gnupg/gpg-agent.conf 2>/dev/null || true
    rm -f ~/.gnupg/dirmngr.conf 2>/dev/null || true
    rm -f ~/.gnupg/common.conf 2>/dev/null || true
```

**Step 4: Verify nix syntax**

Run: `cd ~/projects/workstation && nix flake check 2>&1 | head -20`

Expected: No syntax errors

**Step 5: Commit**

```bash
git add users/dev/home.darwin.nix
git commit -m "feat(gpg): enable gpg-agent service on Darwin with pinentry-mac"
```

---

### Task 3: Update Linux GPG Config in home.linux.nix

**Files:**
- Modify: `users/dev/home.linux.nix`

**Step 1: Read current Linux GPG config**

Review the current masking and tmpfiles rules.

**Step 2: Add Linux-specific common.conf with no-autostart**

Add after the tmpfiles rules block:

```nix
  # GPG common.conf for devbox: no-autostart prevents local agent from clobbering
  # the forwarded socket. Do NOT use use-keyboxd here (causes issues with no-autostart).
  home.file.".gnupg/common.conf".text = ''
    no-autostart
  '';
```

**Step 3: Verify nix syntax**

Run: `cd ~/projects/workstation && nix flake check 2>&1 | head -20`

Expected: No syntax errors

**Step 4: Commit**

```bash
git add users/dev/home.linux.nix
git commit -m "feat(gpg): add Linux-specific common.conf with no-autostart"
```

---

### Task 4: Improve GPG_TTY Handling in Bash

**Files:**
- Modify: `users/dev/home.base.nix` (programs.bash.initExtra)

**Step 1: Find current GPG_TTY line**

Current: `export GPG_TTY=$(tty)`

**Step 2: Replace with tmux-aware version**

Replace the simple `export GPG_TTY=$(tty)` with:

```bash
      # GPG TTY - tmux-aware (from deprecated-dotfiles)
      if [ -n "$TMUX" ]; then
          export GPG_TTY=$(tmux display-message -p '#{pane_tty}')
      else
          export GPG_TTY=$(tty)
      fi
```

**Step 3: Verify nix syntax**

Run: `cd ~/projects/workstation && nix flake check 2>&1 | head -20`

Expected: No syntax errors

**Step 4: Commit**

```bash
git add users/dev/home.base.nix
git commit -m "fix(gpg): use tmux-aware GPG_TTY for better passphrase prompts"
```

---

### Task 5: Test on Devbox (Linux)

**Step 1: Apply home-manager on devbox**

Run: `cd ~/projects/workstation && nix run home-manager -- switch --flake .#dev`

Expected: Successful activation

**Step 2: Verify common.conf**

Run: `cat ~/.gnupg/common.conf`

Expected:
```
no-autostart
```

**Step 3: Verify no local gpg-agent**

Run: `ps aux | grep gpg-agent | grep -v grep`

Expected: No output (no local agent running)

**Step 4: Verify socket exists (after SSH reconnect with forwarding)**

Reconnect SSH from macOS, then run:
```bash
ls -la /run/user/1000/gnupg/S.gpg-agent
```

Expected: Socket file exists (forwarded from macOS)

**Step 5: Test GPG signing**

Run: `echo "test" | gpg --clearsign`

Expected: Signed output (using forwarded agent)

**Step 6: Commit verification**

```bash
git commit --allow-empty -m "test: verify GPG signing on devbox"
git log --show-signature -1
```

Expected: "Good signature" in output

---

### Task 6: Test on Darwin (macOS)

**Step 1: Pull changes on macOS**

Run: `cd ~/Code/workstation && git pull`

**Step 2: Apply home-manager on Darwin**

Run: `home-manager switch --flake .#$(whoami)`

Expected: Successful activation (may need to handle file conflicts)

**Step 3: Verify launchd gpg-agent service is DISABLED**

Run: `launchctl list | grep gpg`

Expected: `org.nix-community.home.gpg-agent` should NOT appear (we disabled it because socket activation doesn't work). You may see GPGTools entries like `org.gpgtools.*` which are unrelated.

**Step 4: Verify socket paths**

Run:
```bash
gpgconf --list-dir agent-socket
gpgconf --list-dir agent-extra-socket
```

Expected:
- agent-socket: `~/.gnupg/S.gpg-agent`
- agent-extra-socket: `~/.gnupg/S.gpg-agent.extra`

**Step 5: Test GPG signing locally**

Run: `echo "test" | gpg --clearsign`

Expected: Signed output with pinentry-mac prompt. This command will auto-start the gpg-agent if not already running (which is the intended behavior since we disabled the launchd service).

**Step 6: Test SSH forwarding to devbox**

SSH to devbox and test signing there (should use forwarded agent).

---

### Task 7: Update SSH Config (if needed)

**Files:**
- Modify: `scripts/update-ssh-config.sh` (if socket path changed)

**Step 1: Verify current RemoteForward path**

Check that the SSH config uses:
```
RemoteForward /run/user/1000/gnupg/S.gpg-agent /Users/${USER}/.gnupg/S.gpg-agent.extra
```

**Step 2: Update if paths differ**

If `gpgconf --list-dir` shows different paths, update the script accordingly.

**Step 3: Regenerate SSH config on macOS**

Run: `./scripts/update-ssh-config.sh`

**Step 4: Test SSH forwarding**

```bash
ssh devbox
echo "test" | gpg --clearsign
```

Expected: Signed output using forwarded agent

---

### Task 8: Clean Up and Document

**Step 1: Remove backup (if migration successful)**

On macOS: `rm -rf ~/.gnupg.backup.*` (only after confirming everything works)

**Step 2: Update gradual-dotfiles-migration skill**

Update `.claude/skills/gradual-dotfiles-migration/SKILL.md` to mark GPG as migrated:

Change:
```
| GPG | Workstation | Dotfiles | Need full migration |
```

To:
```
| GPG | Workstation | Workstation | Fully migrated |
```

**Step 3: Final commit**

```bash
git add .claude/skills/gradual-dotfiles-migration/SKILL.md
git commit -m "docs: mark GPG as fully migrated to home-manager"
git push
```

---

## Rollback Plan

If something breaks:

1. **On macOS:** Restore backup: `rm -rf ~/.gnupg && mv ~/.gnupg.backup.YYYYMMDD ~/.gnupg`
2. **Re-enable dotfiles overrides:** Revert changes to `home.darwin.nix`
3. **Restart agent:** `gpgconf --kill gpg-agent && gpg-agent --daemon`

## Success Criteria

- [x] GPG signing works on macOS (local agent, auto-started on demand)
- [x] GPG signing works on devbox (forwarded agent)
- [ ] No manual GPG config files needed (all managed by home-manager)
- [x] pinentry-mac prompts work correctly on macOS
- [x] SSH forwarding works for git commit signing on devbox
- [x] No broken launchd service (disabled because socket activation incompatible with gpg-agent)
