# Tmux Darwin Migration Plan

> **For Claude on macOS:** This plan migrates tmux from deprecated-dotfiles (TPM) to workstation (home-manager). Read the gradual-dotfiles-migration skill first.

## Background: What Was Done on Linux

On the NixOS devbox, tmux is fully managed by home-manager with:

- **Base config** in `users/dev/home.base.nix`: prefix C-a, vi keys, mouse, 50k history, focus-events, truecolor, OSC 52 clipboard via `assets/tmux/extra.conf`
- **Linux plugins** in `users/dev/tmux.linux.nix`: resurrect → catppuccin → continuum (ordering critical)
- **Neovim session integration**: vim-obsession plugin auto-saves `Session.vim` in project directories via `assets/nvim/lua/user/sessions.lua`, and tmux-resurrect uses `nvim -S` to restore nvim state

### Key Lessons from Linux Implementation

1. **Plugin ordering matters**: resurrect → catppuccin → continuum. Continuum MUST be last (status-right hook).
2. **`@resurrect-processes` quoting**: The `->` in `~nvim->nvim` gets interpreted as a shell redirect during resurrect's `eval set`. Must wrap in double quotes: `'"~nvim->nvim"'`
3. **Catppuccin window naming**: Use `@catppuccin_window_text " #W"` (not `@catppuccin_window_default_text`). `#W` = window name, `#T` = pane title (shows hostname).
4. **`set-clipboard on` not `external`**: `external` breaks clipboard over SSH. Keep `on`.

---

## Pre-flight

Before starting, verify:
- [ ] iTerm2 → Preferences → General → Selection → "Applications in terminal may access clipboard" is **enabled** (required for OSC 52)
- [ ] `~/Code/workstation` is cloned and up to date (`git pull`)
- [ ] `~/Code/deprecated-dotfiles` is the current dotfiles repo

---

## Task 1: Create Darwin tmux module (on devbox or macOS)

**Files:**
- Create: `users/dev/tmux.darwin.nix`
- Modify: `users/dev/home.nix` (add import)

### Step 1: Create `users/dev/tmux.darwin.nix`

Model this after `users/dev/tmux.linux.nix` but with Darwin-specific paths:

```nix
# Darwin-specific tmux configuration with plugins
# Includes session persistence (resurrect/continuum) and Catppuccin theme
#
# Plugin ordering is CRITICAL:
# 1. resurrect - must load before continuum
# 2. catppuccin - theme must load before continuum to avoid status-right conflicts
# 3. continuum - MUST BE LAST (uses status-right hook for autosave)
#
# WARNING: Do NOT set status-right in extraConfig - it will clobber continuum's autosave hook
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
          # Restore neovim sessions (requires Session.vim from vim-obsession)
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
          # Using Catppuccin mocha colors: surface0 (#313244) and surface1 (#45475a)
          # Continuum will prepend its hook after this
          set -g status-right "#[fg=#cdd6f4,bg=#313244] %d/%m #[fg=#cdd6f4,bg=#45475a] %H:%M:%S "
        '';
      }

      # 3. Continuum: auto-save/restore (MUST BE LAST - uses status-right hook)
      {
        plugin = continuum;
        extraConfig = ''
          # Auto-restore session when tmux server starts
          set -g @continuum-restore 'on'
          # Auto-save every 15 minutes
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

**Key differences from Linux:**
- `resurrectDir` uses `xdg.stateHome` (~/.local/state/tmux/resurrect) instead of `/persist/tmux/`
- Adds `TERMINFO_DIRS` export (macOS lacks tmux terminfo)
- `@continuum-boot` explicitly NOT enabled (causes Accessibility prompt issues)

### Step 2: Add import to `users/dev/home.nix`

```nix
imports = [
  ./home.base.nix
  ./home.linux.nix
  ./home.darwin.nix
  ./claude-skills.nix
  ./claude-hooks.nix
  ./tmux.linux.nix
  ./tmux.darwin.nix  # Add this line
];
```

### Step 3: Commit

```bash
git add users/dev/tmux.darwin.nix users/dev/home.nix
git commit -m "feat(tmux): add Darwin-specific module"
```

---

## Task 2: Deploy sessions.lua for Darwin nvim

**Context:** On Darwin, neovim is managed by dotfiles + Lazy, not home-manager (`programs.neovim.enable = false`). We deploy shared Lua modules individually, like ccremote.lua.

**Files:**
- Modify: `users/dev/home.darwin.nix`

### Step 1: Add sessions.lua deployment

Add alongside the existing ccremote.lua deployment in `home.darwin.nix`:

```nix
# Deploy sessions.lua for tmux-resurrect nvim session integration
# (vim-obsession still installed by Lazy; this module auto-starts it in project dirs)
xdg.configFile."nvim/lua/user/sessions.lua".source = "${assetsPath}/nvim/lua/user/sessions.lua";
```

Also add to the `prepareForHM` activation hook:

```nix
rm -f ~/.config/nvim/lua/user/sessions.lua 2>/dev/null || true
```

### Step 2: Commit

```bash
git add users/dev/home.darwin.nix
git commit -m "feat(nvim): deploy sessions.lua on Darwin for tmux-resurrect"
```

---

## Task 3: Update dotfiles on Darwin machine

**Prerequisites:** Must be run on the Darwin machine.

### Step 1: Pull workstation

```bash
cd ~/Code/workstation
git pull
```

### Step 2: Update Lazy spec for vim-obsession

Edit `~/Code/deprecated-dotfiles/.config/nvim/lua/plugins/vim-obsession.lua`:

```lua
-- vim-obsession for session management (tmux-resurrect integration)
-- sessions.lua is deployed by home-manager from workstation
return {
  "tpope/vim-obsession",
  lazy = false,
  config = function()
    require("user.sessions")
  end,
}
```

### Step 3: Remove old vim-obsession user config

The old `user/vim-obsession.lua` auto-started Obsess everywhere without project detection. Our new `sessions.lua` (from workstation) is smarter.

```bash
cd ~/Code/deprecated-dotfiles
rm .config/nvim/lua/user/vim-obsession.lua
```

Also remove the commented-out require from `init.lua` if it exists:
```bash
# Check and edit if needed
grep "vim-obsession" .config/nvim/init.lua
```

### Step 4: Commit dotfiles changes

```bash
cd ~/Code/deprecated-dotfiles
git add -A
git commit -m "refactor(nvim): use workstation sessions.lua, remove old vim-obsession config"
git push
```

---

## Task 4: Remove tmux from deprecated-dotfiles

### Step 1: Remove tmux config from dotfiles

```bash
cd ~/Code/deprecated-dotfiles
rm .tmux.conf
rm -rf .tmux/
git add -A
git commit -m "chore: migrate tmux to workstation"
git push
```

### Step 2: Clean up existing symlinks/files

```bash
rm -f ~/.tmux.conf
rm -rf ~/.tmux/
```

---

## Task 5: Apply and verify

### Step 1: Apply darwin-rebuild

```bash
cd ~/Code/workstation
darwin-rebuild switch --flake .#<hostname>
```

If using standalone home-manager (no nix-darwin):
```bash
home-manager switch --flake .#dev
```

### Step 2: Reload tmux

```bash
tmux source-file ~/.config/tmux/tmux.conf
# Or kill and restart tmux for a clean state
```

### Step 3: Verify checklist

- [ ] Catppuccin mocha theme visible (dark background, colored status bar)
- [ ] Window tabs show window names (`#W`), not hostname
- [ ] Status-right shows date/time in two pills (different background shades)
- [ ] Prefix is C-a (not C-b)
- [ ] Vi copy mode works (prefix + [ to enter, v to select, y to yank)
- [ ] Mouse mode works (click to select pane, scroll to scroll)
- [ ] OSC 52 clipboard works (copy in tmux, paste outside)

### Step 4: Verify session persistence

```bash
# In tmux:
# 1. Open a few windows, rename one (prefix + ,)
# 2. Save session: C-a C-s
# 3. Kill tmux: tmux kill-server
# 4. Restart tmux
# 5. Restore: C-a C-r
# 6. Windows and names should be back
```

### Step 5: Verify nvim session restore

```bash
cd ~/Code/workstation  # or any project dir
nvim
# Check :Obsess shows "Obsessing" (auto-started by sessions.lua)
# Open some files, create splits
:q
ls Session.vim  # Should exist

# Now test tmux restore with nvim:
# 1. Open nvim in a project dir (don't pass file args)
# 2. Open files, splits
# 3. C-a C-s (save tmux session)
# 4. tmux kill-server
# 5. Restart tmux
# 6. C-a C-r (restore)
# 7. nvim should reopen with your files/splits

rm Session.vim  # Clean up test file
```

### Step 6: Update migration status

Edit `.claude/skills/gradual-dotfiles-migration/SKILL.md`, update the table:

```markdown
| Tmux | Workstation | Workstation | Fully migrated |
```

### Step 7: Commit and push

```bash
cd ~/Code/workstation
git add .claude/skills/gradual-dotfiles-migration/SKILL.md
git commit -m "docs: mark tmux as fully migrated on Darwin"
git push
```

---

## Summary

| Task | Description | Where |
|------|-------------|-------|
| 1 | Create `tmux.darwin.nix`, add import | devbox or macOS |
| 2 | Deploy `sessions.lua` via home.darwin.nix | devbox or macOS |
| 3 | Update Lazy spec, remove old vim-obsession config | macOS (dotfiles) |
| 4 | Remove tmux from deprecated-dotfiles | macOS (dotfiles) |
| 5 | Apply, verify everything works | macOS |

Tasks 1-2 can be done on devbox and pushed. Tasks 3-5 must be done on macOS.
