# Lemonade Clipboard Bridge Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace OSC 52 clipboard with a TCP-based lemonade clipboard bridge that works through mosh + tmux + Neovim.

**Architecture:** Lemonade server on macOS (launchd) exposes pbcopy/pbpaste over TCP :2489. Existing persistent SSH dev tunnels carry RemoteForward for this port. Remote lemonade client connects to localhost:2489 for copy/paste. Neovim and tmux use lemonade as their clipboard provider on remote hosts.

**Tech Stack:** Nix, home-manager, nix-darwin, lemonade (Go), tmux 3.6a, Neovim, launchd

**Design doc:** `docs/plans/2026-04-03-lemonade-clipboard-bridge-design.md`

---

### Task 1: Add lemonade package and remove tcopy/tpaste

**Files:**
- Modify: `users/dev/home.base.nix`
- Delete: `assets/scripts/tcopy.bash`
- Delete: `assets/scripts/tpaste.bash`

**Step 1: Remove tcopy/tpaste definitions from home.base.nix**

In `users/dev/home.base.nix`, remove the `tcopy` and `tpaste` let-bindings (lines 7-18):

```nix
  # Remove this entire block:
  # Clipboard commands via tmux (work over SSH, inside tmux sessions)
  tcopy = pkgs.writeShellApplication {
    name = "tcopy";
    runtimeInputs = [ pkgs.tmux ];
    text = builtins.readFile "${assetsPath}/scripts/tcopy.bash";
  };

  tpaste = pkgs.writeShellApplication {
    name = "tpaste";
    runtimeInputs = [ pkgs.tmux ];
    text = builtins.readFile "${assetsPath}/scripts/tpaste.bash";
  };
```

Remove `tcopy` and `tpaste` from `home.packages` (lines 212-214):

```nix
    # Remove these two lines:
    tcopy
    tpaste
```

**Step 2: Add lemonade to home.packages**

Replace the clipboard section in `home.packages` with:

```nix
    # Remote clipboard (lemonade client talks to macOS server over SSH tunnel)
    pkgs.lemonade
```

**Step 3: Delete the tcopy/tpaste scripts**

```bash
rm assets/scripts/tcopy.bash assets/scripts/tpaste.bash
```

**Step 4: Verify nix builds**

```bash
nix eval .#darwinConfigurations.Y0FMQX93RR-2.system --apply 'x: "ok"'
```

Expected: `"ok"` (no build errors)

**Step 5: Commit**

```bash
git add users/dev/home.base.nix
git rm assets/scripts/tcopy.bash assets/scripts/tpaste.bash
git commit -m "Replace tcopy/tpaste with lemonade clipboard client

tcopy/tpaste relied on OSC 52 via tmux load-buffer -w, which
is broken through mosh. lemonade provides copy and paste over
TCP, tunneled via existing SSH connections."
```

---

### Task 2: Add RemoteForward for lemonade to SSH tunnel configs

**Files:**
- Modify: `scripts/update-ssh-config.sh`

**Step 1: Add RemoteForward 2489 to devbox-tunnel**

In `scripts/update-ssh-config.sh`, in the `devbox-tunnel` host block, add after the existing RemoteForward lines:

```
    # Lemonade clipboard (remote copy/paste to macOS)
    RemoteForward 2489 localhost:2489
```

**Step 2: Add RemoteForward 2489 to cloudbox-tunnel**

Same change in the `cloudbox-tunnel` host block:

```
    # Lemonade clipboard (remote copy/paste to macOS)
    RemoteForward 2489 localhost:2489
```

**Step 3: Verify and apply**

```bash
bash scripts/update-ssh-config.sh
grep 2489 ~/.ssh/config
```

Expected: Two lines showing `RemoteForward 2489 localhost:2489`

**Step 4: Commit**

```bash
git add scripts/update-ssh-config.sh
git commit -m "Add lemonade clipboard port to SSH tunnel configs

RemoteForward 2489 on devbox-tunnel and cloudbox-tunnel carries
lemonade clipboard traffic through the persistent SSH tunnels."
```

---

### Task 3: Add lemonade server launchd agent on macOS

**Files:**
- Modify: `users/dev/home.darwin.nix`

**Step 1: Add launchd agent**

In `users/dev/home.darwin.nix`, after the `cloudbox-dev-tunnel` launchd agent block and before the `# ====` disabled programs section, add:

```nix
  # Lemonade clipboard server.
  # Exposes macOS pbcopy/pbpaste over TCP so remote sessions (via SSH
  # RemoteForward) can copy/paste to the local clipboard through mosh.
  launchd.agents.lemonade-server = {
    enable = true;
    config = {
      ProgramArguments = [
        "${pkgs.lemonade}/bin/lemonade"
        "server"
        "--allow" "127.0.0.1"
        "--port" "2489"
      ];
      RunAtLoad = true;
      KeepAlive = true;
      ThrottleInterval = 30;
      StandardOutPath = "${config.home.homeDirectory}/Library/Logs/lemonade-server.out.log";
      StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/lemonade-server.err.log";
    };
  };
```

**Step 2: Verify nix builds**

```bash
nix eval .#darwinConfigurations.Y0FMQX93RR-2.system --apply 'x: "ok"'
```

Expected: `"ok"`

**Step 3: Commit**

```bash
git add users/dev/home.darwin.nix
git commit -m "Add lemonade server launchd agent on macOS

Runs lemonade server on port 2489, accepting connections from
localhost only. The persistent SSH dev tunnels carry RemoteForward
2489 so remote lemonade clients reach this server."
```

---

### Task 4: Configure tmux to use lemonade for copy

**Files:**
- Modify: `assets/tmux/extra.conf`

**Step 1: Add copy-command for lemonade**

Replace the contents of `assets/tmux/extra.conf` with:

```tmux
# Clipboard support
# Two mechanisms:
# 1. OSC 52: works over plain SSH (terminal escape sequences)
# 2. lemonade: works over mosh (TCP via SSH tunnel on port 2489)
#
# Both can coexist: set-clipboard handles OSC 52, copy-command handles lemonade.
# tmux uses copy-command when set; OSC 52 still works for apps that emit it directly.

# Accept OSC 52 clipboard commands (fallback for plain SSH sessions)
set -s set-clipboard on

# tmux 3.3+: passthrough escape sequences
set -gq allow-passthrough on

# Enable clipboard capability for common terminal types
set -as terminal-features ',xterm*:clipboard'
set -as terminal-features ',screen*:clipboard'
set -as terminal-features ',tmux*:clipboard'

# Pipe tmux copy-mode selections to lemonade (works through mosh)
set -s copy-command 'lemonade copy'
```

**Step 2: Commit**

```bash
git add assets/tmux/extra.conf
git commit -m "Add lemonade copy-command to tmux clipboard config

tmux copy-mode selections now pipe to lemonade, which works
through mosh via the SSH tunnel. OSC 52 is kept as fallback
for plain SSH sessions."
```

---

### Task 5: Configure Neovim to use lemonade on remote hosts

**Files:**
- Modify: `assets/nvim/lua/user/settings.lua`

**Step 1: Replace the clipboard provider config**

In `assets/nvim/lua/user/settings.lua`, replace lines 5-10:

```lua
-- Clipboard: use system clipboard
-- On SSH sessions, force OSC 52 provider for clipboard over terminal
if vim.env.SSH_TTY then
  vim.g.clipboard = "osc52"
end
vim.opt.clipboard = "unnamedplus"
```

With:

```lua
-- Clipboard: use system clipboard
-- On remote hosts, use lemonade (TCP-based, works through mosh).
-- Falls back to OSC 52 if lemonade isn't available, then to default
-- provider detection (pbcopy/pbpaste on macOS).
if vim.fn.executable("lemonade") == 1 and (vim.env.SSH_TTY or vim.env.MOSH_KEY) then
  vim.g.clipboard = {
    name = "lemonade",
    copy = {
      ["+"] = { "lemonade", "copy" },
      ["*"] = { "lemonade", "copy" },
    },
    paste = {
      ["+"] = { "lemonade", "paste" },
      ["*"] = { "lemonade", "paste" },
    },
  }
elseif vim.env.SSH_TTY then
  vim.g.clipboard = "osc52"
end
vim.opt.clipboard = "unnamedplus"
```

This checks for lemonade + remote session first (works in both SSH and mosh), falls back to OSC 52 for SSH-only, and defaults to native clipboard on macOS.

Note: `MOSH_KEY` is not a real env var we've verified exists in mosh sessions. The implementer should check what env vars mosh-server sets (e.g., `MOSH_SERVER_SIGNAL_TMOUT`, `MOSH_SERVER_NETWORK_TMOUT`) and use the appropriate one, or simply detect "not local" via absence of macOS-specific signals. An alternative is to just check `vim.fn.executable("lemonade") == 1` without the remote check -- on macOS, lemonade is also installed but pbcopy/pbpaste is preferred. The simplest correct approach may be to check for lemonade AND check that we're not on macOS (Darwin):

```lua
local is_remote = vim.fn.has("mac") == 0 and vim.fn.has("macunix") == 0
```

The implementer should verify which detection works and pick the simplest correct one.

**Step 2: Commit**

```bash
git add assets/nvim/lua/user/settings.lua
git commit -m "Use lemonade clipboard provider on remote hosts

Neovim on remote hosts uses lemonade for copy/paste (works
through mosh via SSH tunnel). Falls back to OSC 52 for plain
SSH, and to pbcopy/pbpaste on macOS."
```

---

### Task 6: Deploy and test

**Step 1: Push to remote**

```bash
git push origin HEAD:main
```

**Step 2: Deploy macOS**

```bash
sudo darwin-rebuild switch --flake ~/Code/workstation#Y0FMQX93RR-2
```

Verify lemonade server is running:
```bash
launchctl list | grep lemonade
lemonade paste  # should return current clipboard contents
```

**Step 3: Re-run update-ssh-config.sh**

```bash
bash scripts/update-ssh-config.sh
```

Verify:
```bash
grep 2489 ~/.ssh/config
```

**Step 4: Restart dev tunnel launchd agents** (to pick up new RemoteForward)

```bash
launchctl kickstart -k gui/$(id -u)/org.nix-community.home.devbox-dev-tunnel
launchctl kickstart -k gui/$(id -u)/org.nix-community.home.cloudbox-dev-tunnel
```

**Step 5: Deploy to devbox**

```bash
ssh devbox "cd ~/projects/workstation && git fetch && git checkout origin/main && nix run home-manager -- switch --flake .#dev"
```

Then restart tmux on devbox:
```bash
ssh devbox "tmux kill-server"
# Wait a moment, then reconnect
mosh devbox -- tmux new -s 1
```

**Step 6: Test clipboard**

On devbox (via mosh + tmux):
```bash
# CLI copy test
echo "lemonade-test" | lemonade copy
# Cmd+V on macOS should paste "lemonade-test"

# CLI paste test
# Copy "hello-from-mac" on macOS (Cmd+C), then:
lemonade paste
# Should print "hello-from-mac"

# Neovim test
nvim /tmp/test.txt
# Type some text, yank a line with yy
# Cmd+V on macOS should paste the line

# Neovim paste test
# Copy text on macOS, then p in nvim should paste it
```

**Step 7: Deploy to cloudbox**

Same as devbox but with `--flake .#cloudbox`.

**Step 8: Commit any fixes, push**

```bash
git push origin HEAD:main
```

---

### Task 7: Update OSC 52 skill documentation

**Files:**
- Modify: `.opencode/skills/osc52-clipboard/SKILL.md`

**Step 1: Update the skill**

Update the skill to document the lemonade clipboard bridge as the primary mechanism for mosh sessions, with OSC 52 as fallback for plain SSH. Mention:
- lemonade server runs on macOS via launchd
- SSH tunnels carry RemoteForward 2489
- tmux `copy-command` pipes to lemonade
- Neovim auto-detects lemonade on remote hosts
- `lemonade copy` and `lemonade paste` replace `tcopy`/`tpaste`

**Step 2: Commit**

```bash
git add .opencode/skills/osc52-clipboard/SKILL.md
git commit -m "Update clipboard skill for lemonade bridge"
```
