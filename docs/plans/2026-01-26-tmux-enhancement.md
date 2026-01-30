# Tmux Enhancement Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Enhance tmux with session persistence (resurrect/continuum), Catppuccin theme, and improved defaults — Linux-only first, Darwin migration later.

**Architecture:** Add tmux plugins via home-manager's `programs.tmux.plugins` with careful ordering (resurrect → catppuccin → continuum). Plugin-specific options go in each plugin's `extraConfig` to ensure correct load order. Resurrect data persists to `/persist/tmux/dev/resurrect` on Linux, `~/.local/state/tmux/resurrect` on Darwin.

**Tech Stack:** NixOS, home-manager, tmux 3.6a, tmuxPlugins.{resurrect,catppuccin,continuum}

---

## Part 1: Linux (Devbox) Enhancement

### Task 1: Create Linux-specific tmux config module ✅

**Files:**
- Create: `users/dev/tmux.linux.nix`
- Modify: `users/dev/home.nix` (add import)

**Completed:** Commit `63eee6b`

---

### Task 2: Update base tmux config with new defaults ✅

**Files:**
- Modify: `users/dev/home.base.nix` (programs.tmux section)

**Completed:** Commit `b1c19d2`

---

### Task 3: Apply and test on devbox ✅

**Completed:** Applied and verified working.

---

### Task 4: Document the migration status ✅

**Completed:** Commit `f7cb4ed`

---

## Part 1.5: Post-Implementation Fixes (ChatGPT Review)

> Based on ChatGPT review of our implementation. These fixes address security, portability, and system configuration gaps.

### Task 1.5a: Fix clipboard security and portability in extra.conf

**Files:**
- Modify: `assets/tmux/extra.conf`

**Changes:**
1. Change `set-clipboard on` → `set-clipboard external` (more secure - prevents apps inside tmux from setting clipboard)
2. Broaden `terminal-features` to cover more terminal types (xterm*, screen*, tmux*)

**Updated extra.conf:**

```bash
# OSC 52 clipboard support
# Allows applications (like Neovim) to write to the local clipboard via terminal escape sequences

# Accept OSC 52 from tmux itself, but not from applications inside tmux
# ('external' is more secure than 'on' which allows any app to set clipboard)
set -s set-clipboard external

# tmux 3.3+: required for passthrough escape sequences (-q suppresses errors on older versions)
set -gq allow-passthrough on

# Enable clipboard capability for common terminal types
# (broader matching for portability across iTerm2, WezTerm, kitty, nested tmux, etc.)
set -as terminal-features ',xterm*:clipboard'
set -as terminal-features ',screen*:clipboard'
set -as terminal-features ',tmux*:clipboard'
```

**Commit:** `git commit -m "fix(tmux): use set-clipboard external, broaden terminal-features"`

---

### Task 1.5b: Guard source-file for cross-platform safety

**Files:**
- Modify: `users/dev/home.base.nix` (programs.tmux.extraConfig)

**Change:**
Replace `source-file ~/.config/tmux/extra.conf` with guarded version that won't fail if file doesn't exist (important during gradual Darwin migration):

```bash
# Load extra config if it exists (safe during partial migration)
if-shell -b '[ -f ~/.config/tmux/extra.conf ]' 'source-file ~/.config/tmux/extra.conf'
```

**Commit:** `git commit -m "fix(tmux): guard source-file for cross-platform safety"`

---

### Task 1.5c: Add /persist/tmux to NixOS tmpfiles.rules

**Files:**
- Modify: `hosts/devbox/configuration.nix` (systemd.tmpfiles.rules)

**Change:**
Add tmux persistence directory to tmpfiles so it's created at boot (home-manager can't create /persist/* without sudo):

```nix
systemd.tmpfiles.rules = [
  # Claude state
  "d /persist/claude 0700 dev dev -"
  "L+ /home/dev/.claude - - - - /persist/claude"
  # Projects directory on persistent volume
  "d /persist/projects 0755 dev dev -"
  # SSH directory on persistent volume (for devbox key)
  "d /persist/ssh 0700 dev dev -"
  "L+ /home/dev/.ssh - - - - /persist/ssh"
  # Tmux resurrect data on persistent volume
  "d /persist/tmux 0755 dev dev -"
  "d /persist/tmux/dev 0700 dev dev -"
];
```

**Note:** This requires `sudo nixos-rebuild switch` to take effect.

**Commit:** `git commit -m "fix(nixos): add /persist/tmux to tmpfiles.rules"`

---

### Task 1.5d: Add chmod to activation hook for explicit permissions

**Files:**
- Modify: `users/dev/tmux.linux.nix` (home.activation)

**Change:**
Add explicit chmod to ensure resurrect directory has correct permissions:

```nix
home.activation.ensureTmuxResurrectDir =
  lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    mkdir -p '${resurrectDir}'
    chmod 700 '${resurrectDir}'
  '';
```

**Commit:** `git commit -m "fix(tmux): add chmod to resurrect dir activation"`

---

### Task 1.5e: Apply fixes and verify

**Step 1:** Apply home-manager changes
```bash
home-manager switch --flake .#dev
```

**Step 2:** Apply NixOS changes (for tmpfiles)
```bash
sudo nixos-rebuild switch --flake .#devbox
```

**Step 3:** Verify extra.conf changes
```bash
grep "set-clipboard" ~/.config/tmux/extra.conf
# Expected: set -s set-clipboard external
```

**Step 4:** Verify tmux still works
```bash
tmux kill-server 2>/dev/null; tmux new -d -s test && tmux kill-session -t test
```

---

## Part 2: Darwin Migration (Future)

> **Note:** Execute Part 2 only after Part 1 is tested and working on devbox.

### Task 5: Prepare Darwin tmux module

**Files:**
- Create: `users/dev/tmux.darwin.nix`
- Modify: `users/dev/home.nix` (add import)

**Step 1: Create Darwin-specific tmux module**

Create `users/dev/tmux.darwin.nix`:

```nix
# Darwin-specific tmux configuration
# Uses XDG state directory for resurrect (no /persist volume on macOS)
#
# Plugin ordering is CRITICAL:
# 1. resurrect - must load before continuum
# 2. catppuccin - theme must load before continuum to avoid status-right conflicts
# 3. continuum - MUST BE LAST (uses status-right hook for autosave)
{ config, pkgs, lib, isDarwin, ... }:

let
  resurrectDir = "${config.xdg.stateHome}/tmux/resurrect";
in
lib.mkIf isDarwin {
  programs.tmux = {
    plugins = with pkgs.tmuxPlugins; [
      # 1. Resurrect: save/restore sessions
      {
        plugin = resurrect;
        extraConfig = ''
          set -g @resurrect-dir '${resurrectDir}'
          set -g @resurrect-strategy-nvim 'session'
          # Match nvim anywhere in command (tilde), restore as plain nvim (arrow)
          # Nix wraps nvim with complex --cmd flags that break session restore
          # NOTE: Quotes protect > from shell redirect during resurrect's eval
          set -g @resurrect-processes '"~nvim->nvim"'
        '';
      }

      # 2. Theme: Catppuccin (before continuum to avoid status-right conflicts)
      {
        plugin = catppuccin;
        extraConfig = ''
          set -g @catppuccin_flavor "mocha"

          # Window tabs: show window name (#W) so manual renames work
          set -g @catppuccin_window_text " #W"
          set -g @catppuccin_window_current_text " #W"

          # Right status: two pills with different colors (date darker, time lighter)
          set -g status-right "#[fg=#cdd6f4,bg=#313244] %d/%m #[fg=#cdd6f4,bg=#45475a] %H:%M:%S "
        '';
      }

      # 3. Continuum: auto-save/restore (MUST BE LAST)
      {
        plugin = continuum;
        extraConfig = ''
          set -g @continuum-restore 'on'
          set -g @continuum-save-interval '15'
          # NOTE: Do NOT enable @continuum-boot on macOS
          # It auto-launches tmux at login via AppleScript, triggers Accessibility
          # prompts, and opens surprise windows. Use iTerm2 profile to auto-attach instead.
        '';
      }
    ];
  };

  # Ensure resurrect directory exists with correct permissions
  home.activation.ensureTmuxResurrectDir =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      mkdir -p '${resurrectDir}'
      chmod 700 '${resurrectDir}'
    '';

  # Export TERMINFO_DIRS so non-Nix programs can find tmux-256color
  # macOS doesn't ship tmux terminfo entries, causing issues with system ncurses
  home.sessionVariables.TERMINFO_DIRS = lib.mkDefault
    "${pkgs.ncurses}/share/terminfo:${pkgs.tmux}/share/terminfo:/usr/share/terminfo";
}
```

**Step 2: Add import to home.nix**

```nix
{ pkgs, lib, ... }:

{
  imports = [
    ./home.base.nix
    ./home.linux.nix
    ./home.darwin.nix
    ./claude-skills.nix
    ./claude-hooks.nix
    ./tmux.linux.nix
    ./tmux.darwin.nix  # Add this line
  ];
}
```

**Step 3: Commit (but don't apply yet)**

```bash
git add users/dev/tmux.darwin.nix users/dev/home.nix
git commit -m "feat(tmux): add Darwin-specific module (not yet active)"
```

---

### Task 6: Deploy sessions.lua for Darwin nvim

**Context:** On Darwin, neovim is managed by dotfiles + Lazy, not home-manager. We need to:
1. Deploy `sessions.lua` via home-manager (Pattern 1 from gradual-dotfiles-migration)
2. Update Lazy spec to load it
3. Remove old vim-obsession user config from dotfiles

**Step 1: Add sessions.lua deployment to home.darwin.nix**

```nix
# In users/dev/home.darwin.nix, add alongside ccremote.lua deployment:
xdg.configFile."nvim/lua/user/sessions.lua".source = "${assetsPath}/nvim/lua/user/sessions.lua";
```

**Step 2: Commit on devbox**

```bash
git add users/dev/home.darwin.nix
git commit -m "feat(nvim): deploy sessions.lua on Darwin for tmux-resurrect"
git push
```

---

### Task 7: Update dotfiles on Darwin machine

**Prerequisites:** This task must be run on the Darwin machine, not devbox.

**Pre-flight check:** Ensure iTerm2 has "Applications in terminal may access clipboard" enabled.

**Step 1: Pull workstation changes**

```bash
cd ~/Code/workstation
git pull
```

**Step 2: Update Lazy spec in dotfiles**

Edit `~/Code/deprecated-dotfiles/.config/nvim/lua/plugins/vim-obsession.lua`:

```lua
-- vim-obsession for session management (tmux-resurrect integration)
return {
  "tpope/vim-obsession",
  lazy = false,
  config = function()
    -- Load sessions.lua (deployed by home-manager from workstation)
    require("user.sessions")
  end,
}
```

**Step 3: Remove old vim-obsession user config**

```bash
cd ~/Code/deprecated-dotfiles
rm .config/nvim/lua/user/vim-obsession.lua
git add -A
git commit -m "refactor(nvim): use workstation sessions.lua for vim-obsession"
git push
```

**Step 4: Apply darwin-rebuild**

```bash
cd ~/Code/workstation
darwin-rebuild switch --flake .#<hostname>
```

**Step 5: Verify sessions.lua is deployed**

```bash
ls -la ~/.config/nvim/lua/user/sessions.lua
# Should be a symlink to nix store
```

**Step 6: Test in nvim**

```bash
cd ~/Code/workstation  # or any project directory
nvim
# Should auto-start Obsession (check with :Obsess - shows "Obsessing")
:q
ls Session.vim  # Should exist
rm Session.vim  # Clean up
```

---

### Task 8: Remove tmux from deprecated-dotfiles

**Step 1: Remove tmux config from dotfiles**

```bash
cd ~/Code/deprecated-dotfiles
rm .tmux.conf
rm -rf .tmux/
git add -A
git commit -m "chore: migrate tmux to workstation"
git push
```

**Step 2: Clean up existing symlinks**

```bash
rm -f ~/.tmux.conf
rm -rf ~/.tmux/
```

**Step 3: Apply darwin-rebuild** (if not already done)

```bash
darwin-rebuild switch --flake .#<hostname>
```

**Step 4: Verify tmux on Darwin**

- Theme visible (Catppuccin mocha)
- Window names show correctly (#W not hostname)
- Session persistence works (C-a C-s to save, kill tmux, restart, C-a C-r to restore)
- Vi copy mode works
- OSC 52 clipboard works
- nvim restores with Session.vim

**Step 5: Update migration status**

Update `.claude/skills/gradual-dotfiles-migration/SKILL.md`:

```markdown
| Tmux | Workstation | Workstation | Fully migrated |
| Neovim | Workstation | Dotfiles + overlays | ccremote.lua, sessions.lua via Pattern 1 |
```

**Step 6: Commit and push**

```bash
git add .claude/skills/gradual-dotfiles-migration/SKILL.md
git commit -m "docs: mark tmux as fully migrated"
git push
```

---

## Summary

| Task | Description | Platform | Status |
|------|-------------|----------|--------|
| 1 | Create Linux tmux module with plugins | Devbox | ✅ |
| 2 | Update base tmux config | Both | ✅ |
| 3 | Apply and test | Devbox | ✅ |
| 4 | Document migration status | Devbox | ✅ |
| 1.5a-e | Post-implementation fixes | Devbox | ✅ (most done, 1.5a reverted for SSH) |
| 5 | Create Darwin tmux module | Devbox (code) | Future |
| 6 | Deploy sessions.lua for Darwin nvim | Devbox (code) | Future |
| 7 | Update dotfiles on Darwin | Darwin | Future |
| 8 | Remove tmux from dotfiles | Darwin | Future |

**Part 1 (Tasks 1-4):** ✅ Complete
**Part 1.5 (Fixes):** ✅ Complete (clipboard stayed `on` for SSH passthrough)
**Nvim Session Integration:** ✅ Complete (see follow-up section)
**Part 2 (Tasks 5-8):** Execute on Darwin machine when ready.

---

## Follow-up: Neovim Session Integration

To make `@resurrect-strategy-nvim 'session'` work properly, neovim session management was implemented separately. See [2026-01-27-nvim-session-management.md](2026-01-27-nvim-session-management.md) for the implementation plan.

This adds vim-obsession to auto-save `Session.vim` files in project directories, which tmux-resurrect uses to restore nvim state.
