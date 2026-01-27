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
# NOTE: Resurrect data is "state" not "data", so we use xdg.stateHome
# (~/.local/state/tmux/resurrect) rather than xdg.dataHome
{ config, pkgs, lib, isDarwin, ... }:

let
  # Use stateHome for session state (not dataHome which is for persistent data)
  resurrectDir = "${config.xdg.stateHome}/tmux/resurrect";
in
lib.mkIf isDarwin {
  programs.tmux = {
    # Plugin ordering is CRITICAL - see tmux.linux.nix for explanation
    plugins = with pkgs.tmuxPlugins; [
      {
        plugin = resurrect;
        extraConfig = ''
          set -g @resurrect-dir '${resurrectDir}'
          set -g @resurrect-strategy-nvim 'session'
        '';
      }

      {
        plugin = catppuccin;
        extraConfig = ''
          set -g @catppuccin_flavor "mocha"
        '';
      }

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

### Task 6: Remove tmux from deprecated-dotfiles (on Darwin machine)

**Prerequisites:** This task must be run on the Darwin machine, not devbox.

**Pre-flight check:** Ensure iTerm2 has "Applications in terminal may access clipboard" enabled in Preferences for OSC 52 to work.

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

**Step 3: Apply darwin-rebuild**

```bash
cd ~/Code/workstation
git pull
darwin-rebuild switch --flake .#Y0FMQX93RR-2
```

Expected: tmux now fully managed by home-manager with Catppuccin theme

**Step 4: Verify on Darwin**

Same verification steps as Task 3:
- Theme visible
- Session persistence works
- Vi copy mode works
- OSC 52 clipboard works (requires iTerm2 preference)

**Step 5: Update migration status**

Update `.claude/skills/gradual-dotfiles-migration/SKILL.md`:

```markdown
| Tmux | Workstation | Workstation | Fully migrated |
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
| 1.5a | Fix clipboard security in extra.conf | Both | Pending |
| 1.5b | Guard source-file | Both | Pending |
| 1.5c | Add /persist/tmux to tmpfiles | Devbox | Pending |
| 1.5d | Add chmod to activation | Devbox | Pending |
| 1.5e | Apply and verify fixes | Devbox | Pending |
| 5 | Create Darwin tmux module | Devbox (code) | Future |
| 6 | Remove from dotfiles, apply | Darwin | Future |

**Part 1 (Tasks 1-4):** ✅ Complete
**Part 1.5 (Fixes):** In progress
**Part 2 (Tasks 5-6):** Execute later after Part 1.5 is verified working.
