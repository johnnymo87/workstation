# Claude Code Remote Neovim Migration Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Migrate `nvims` bash function and `ccremote.lua` neovim plugin from deprecated-dotfiles to home-manager, enabling remote control of Claude Code sessions running in nvim terminal buffers.

**Architecture:** Deploy `ccremote.lua` as a top-level module at `assets/nvim/lua/ccremote.lua` (preserves `require("ccremote")` API). Deploy bash function via `builtins.readFile` pattern (no runtime sourcing). Update xdg.configFile to deploy entire `nvim/lua/` directory recursively.

**Tech Stack:** Nix, home-manager, Neovim Lua, Bash

---

### Task 1: Create bash assets directory and nvims function

**Files:**
- Create: `assets/bash/claude.bash`

**Step 1: Create the bash directory**

```bash
mkdir -p /home/dev/projects/workstation/assets/bash
```

**Step 2: Create the nvims function file**

Create `assets/bash/claude.bash`:

```bash
# Claude Code Remote: Start neovim with RPC socket for remote control
# Usage: nvims [files...]
#
# The socket allows external tools (Claude-Code-Remote) to send commands
# to Claude instances running in neovim terminal buffers.
#
# Security: Uses XDG_RUNTIME_DIR (mode 0700) when available, falls back to /tmp.

nvims() {
  local run_dir="${XDG_RUNTIME_DIR:-/tmp}"
  local dir
  dir="$(mktemp -d "$run_dir/nvims.XXXXXX")" || return
  chmod 700 "$dir" 2>/dev/null || true

  local socket="$dir/nvim.sock"

  # Print socket path for tooling that needs it
  echo "NVIM_LISTEN_ADDRESS=$socket" >&2

  command nvim --listen "$socket" "$@"
}
```

**Step 3: Commit**

```bash
git add assets/bash/claude.bash
git commit -m "Add nvims bash function for Claude Code Remote

Starts neovim with RPC socket in secure temp directory.
Uses XDG_RUNTIME_DIR when available for proper permissions."
```

---

### Task 2: Copy ccremote.lua to assets

**Files:**
- Create: `assets/nvim/lua/ccremote.lua`

**Step 1: Copy the plugin from deprecated-dotfiles**

```bash
cp /home/dev/projects/deprecated-dotfiles/.config/nvim/lua/ccremote.lua \
   /home/dev/projects/workstation/assets/nvim/lua/ccremote.lua
```

**Step 2: Verify the file**

```bash
head -20 /home/dev/projects/workstation/assets/nvim/lua/ccremote.lua
```

Expected: Should see the module header with usage comments.

**Step 3: Commit**

```bash
git add assets/nvim/lua/ccremote.lua
git commit -m "Add ccremote.lua neovim plugin for Claude Code Remote

Enables remote control of Claude Code sessions in terminal buffers.
Provides :CCRegister, :CCUnregister, :CCList, :CCSend commands.
Exposes RPC dispatch for external tools via nvim --remote-expr."
```

---

### Task 3: Update home.base.nix for bash function

**Files:**
- Modify: `users/dev/home.base.nix`

**Step 1: Add builtins.readFile for bash function**

In `users/dev/home.base.nix`, find the `programs.bash` section (around line 119) and update `initExtra`:

**Before:**
```nix
  # Bash
  programs.bash = {
    enable = true;
    shellAliases = {
      ll = "ls -la";
      ".." = "cd ..";
      "..." = "cd ../..";
    };
    initExtra = ''
      export GPG_TTY=$(tty)
      export HISTSIZE=10000
      export HISTFILESIZE=20000
      export HISTCONTROL=ignoredups:erasedups
      shopt -s histappend
    '';
  };
```

**After:**
```nix
  # Bash
  programs.bash = {
    enable = true;
    shellAliases = {
      ll = "ls -la";
      ".." = "cd ..";
      "..." = "cd ../..";
    };
    initExtra = ''
      export GPG_TTY=$(tty)
      export HISTSIZE=10000
      export HISTFILESIZE=20000
      export HISTCONTROL=ignoredups:erasedups
      shopt -s histappend

      # Claude Code Remote helpers
      ${builtins.readFile "${assetsPath}/bash/claude.bash"}
    '';
  };
```

**Step 2: Commit**

```bash
git add users/dev/home.base.nix
git commit -m "Wire nvims bash function into home-manager

Uses builtins.readFile pattern to include bash/claude.bash
in programs.bash.initExtra (no runtime sourcing)."
```

---

### Task 4: Update home.base.nix for ccremote.lua

**Files:**
- Modify: `users/dev/home.base.nix`

**Step 1: Update xdg.configFile to deploy entire lua/ directory**

In `users/dev/home.base.nix`, find the neovim section (around line 106) and change the xdg.configFile entry:

**Before:**
```nix
  # Neovim Lua config files (kept separate from HM-managed init.vim)
  xdg.configFile."nvim/lua/user" = {
    source = "${assetsPath}/nvim/lua/user";
    recursive = true;
  };
```

**After:**
```nix
  # Neovim Lua config files (kept separate from HM-managed init.vim)
  # Deploys entire lua/ directory to support both user/ configs and top-level modules like ccremote
  xdg.configFile."nvim/lua" = {
    source = "${assetsPath}/nvim/lua";
    recursive = true;
  };
```

**Step 2: Update extraLuaConfig to load ccremote**

In the same file, find `programs.neovim.extraLuaConfig` (around line 100):

**Before:**
```nix
  programs.neovim = {
    enable = true;
    defaultEditor = true;
    viAlias = true;
    vimAlias = true;
    extraLuaConfig = ''
      require("user.settings")
      require("user.mappings")
    '';
  };
```

**After:**
```nix
  programs.neovim = {
    enable = true;
    defaultEditor = true;
    viAlias = true;
    vimAlias = true;
    extraLuaConfig = ''
      require("user.settings")
      require("user.mappings")
      require("ccremote").setup()
    '';
  };
```

**Step 3: Commit**

```bash
git add users/dev/home.base.nix
git commit -m "Wire ccremote.lua into home-manager neovim config

- Deploy entire nvim/lua/ directory (not just lua/user/)
- Load ccremote module and call setup() in extraLuaConfig"
```

---

### Task 5: Apply and test

**Step 1: Apply home-manager changes**

```bash
cd /home/dev/projects/workstation
home-manager switch --flake .#dev
```

Expected: Should complete without errors.

**Step 2: Verify bash function exists**

```bash
type nvims
```

Expected: Should show the function definition.

**Step 3: Verify ccremote.lua is deployed**

```bash
ls -la ~/.config/nvim/lua/ccremote.lua
```

Expected: Should show symlink to Nix store.

**Step 4: Test nvims starts with socket**

```bash
nvims --version
```

Expected: Should print `NVIM_LISTEN_ADDRESS=...` to stderr, then nvim version.

**Step 5: Test ccremote loads in nvim**

```bash
nvim -c ':CCList' -c ':q'
```

Expected: Should show "ccremote: no instances registered" message (not "Unknown command").

**Step 6: Commit verification notes (optional)**

If all tests pass, no additional commit needed. The implementation is complete.

---

### Task 6: Final integration test with Claude Code Remote

**Prerequisites:** Claude-Code-Remote project must have .env configured and npm installed.

**Step 1: Start nvim with socket**

```bash
nvims
```

Note the socket path from stderr output.

**Step 2: In nvim, open terminal and register**

```vim
:terminal
# (Claude Code would run here, but for testing just use the shell)
:CCRegister test-session
```

Expected: "ccremote: registered instance 'test-session'"

**Step 3: From another terminal, test RPC injection**

```bash
cd ~/projects/Claude-Code-Remote
NVIM_SOCKET=/path/from/step1/nvim.sock node test-nvim-injection.js test-session
```

Expected: Should show successful list, capture, and send operations.

**Step 4: If all passes, final commit**

```bash
git add -A
git commit -m "Complete Claude Code Remote nvim integration

Migration from deprecated-dotfiles complete:
- nvims bash function with secure socket creation
- ccremote.lua plugin for terminal buffer RPC control
- Tested with Claude-Code-Remote injection test"
```

---

## Post-Migration Cleanup

After verifying everything works:

1. The deprecated-dotfiles repo can be archived or the migrated files removed
2. On macOS, remove any conflicting symlinks to the old dotfiles
3. Update Claude-Code-Remote documentation if needed to reference the new setup
