# Dotfiles/Home-Manager Nvim Coexistence Implementation Plan

> **Status:** ✅ COMPLETED

**Goal:** Refactor deprecated-dotfiles so home-manager can manage `ccremote.lua` on macOS without conflicting with the existing nvim configuration.

**Architecture:** Change dotfiles from symlinking the entire `~/.config/nvim` directory to symlinking individual children. Make `lua/` a real directory with child symlinks (`config/`, `plugins/`, `user/`), leaving room for home-manager to own `lua/ccremote.lua`. Update workstation's home.darwin.nix to handle the Darwin-specific nvim setup.

**Tech Stack:** Bash (dotfiles installer), Nix (home-manager), Neovim Lua

---

### Task 1: Refactor dotfiles install.sh for nvim ✅

**Files:**
- Modified: `~/projects/deprecated-dotfiles/install.sh`

Changed nvim from monolithic symlink to child symlinks:
```bash
# Create nvim as a real directory with child symlinks
NVIM_HOME="$HOME/.config/nvim"
NVIM_SRC="$DOTFILES_DIR/.config/nvim"

if [ -L "$NVIM_HOME" ]; then rm "$NVIM_HOME"; fi
mkdir -p "$NVIM_HOME"

# Symlink top-level files and directories
for f in init.lua lazy-lock.json; do
  [ -f "$NVIM_SRC/$f" ] && ln -sf "$NVIM_SRC/$f" "$NVIM_HOME/$f"
done
for d in autoload ftplugin; do
  [ -d "$NVIM_SRC/$d" ] && ln -sfn "$NVIM_SRC/$d" "$NVIM_HOME/$d"
done

# Create lua/ as real directory with child symlinks
mkdir -p "$NVIM_HOME/lua"
for d in config plugins user; do
  [ -d "$NVIM_SRC/lua/$d" ] && ln -sfn "$NVIM_SRC/lua/$d" "$NVIM_HOME/lua/$d"
done
for f in "$NVIM_SRC/lua/"*.lua; do
  [ -f "$f" ] && ln -sf "$f" "$NVIM_HOME/lua/$(basename "$f")"
done
```

---

### Task 2: Push deprecated-dotfiles changes ✅

Pushed to `origin/main`.

---

### Task 3: Update workstation home.darwin.nix for nvim ✅

**Files:**
- Modified: `users/dev/home.darwin.nix`

**Key insight:** The base config uses `recursive = true` for `nvim/lua`, which creates individual file entries. You cannot disable subdirectories with `enable = false` - you must disable the entire recursive deployment and explicitly deploy only what you need.

**Actual implementation:**
```nix
  # Disable the entire nvim/lua recursive deployment from base config
  # (it conflicts with dotfiles-managed nvim config)
  xdg.configFile."nvim/lua".enable = lib.mkForce false;

  # Deploy only ccremote.lua (dotfiles init.lua already loads it)
  xdg.configFile."nvim/lua/ccremote.lua".source = "${assetsPath}/nvim/lua/ccremote.lua";

  # On Darwin, dotfiles creates symlinks that HM also wants to manage.
  # Remove dotfiles symlinks before HM tries to create its own.
  home.activation.prepareForHM = lib.hm.dag.entryBefore ["checkLinkTargets"] ''
    rm -f ~/.config/nvim/lua/ccremote.lua 2>/dev/null || true
    rm -f ~/.claude/commands/ask-question.md 2>/dev/null || true
    rm -f ~/.claude/commands/beads.md 2>/dev/null || true
    rm -f ~/.claude/commands/notify-telegram.md 2>/dev/null || true
  '';
```

---

### Task 4: Push workstation changes ✅

Pushed to `origin/main`.

---

### Task 5: Test on macOS ✅

**Note:** install.sh clones dotfiles to `~/projects/dotfiles`, while you may also have `~/Code/dotfiles`. Keep them in sync.

**Steps completed:**
1. Pulled dotfiles and ran `./install.sh`
2. Verified nvim structure (lua/ is real directory, children are symlinks)
3. Synced `ask-question.md` between dotfiles and workstation (they had diverged)
4. Ran `sudo /run/current-system/sw/bin/darwin-rebuild switch --flake .#Y0FMQX93RR-2`
5. Build succeeded after fixing:
   - Disabled entire `nvim/lua` recursive deployment (not individual files)
   - Added activation script to remove dotfiles symlinks for claude commands

**Remaining verification (Task 5 Steps 4-6):**
```bash
# Verify ccremote.lua is HM-managed
ls -la ~/.config/nvim/lua/ccremote.lua
# Should point to Nix store

# Test nvim loads ccremote
nvim -c ':CCList' -c ':q'
# Expected: "ccremote: no instances registered"

# Test nvims function
type nvims
nvims --version
```

---

## Lessons Learned

1. **`recursive = true` creates file entries, not directory entries.** You cannot use `xdg.configFile."subdir".enable = false` to disable a subdirectory - you must disable the entire parent or list each file individually.

2. **HM activation scripts run before checkLinkTargets.** Use `lib.hm.dag.entryBefore ["checkLinkTargets"]` to remove conflicting symlinks before HM checks for them.

3. **Keep dotfiles repos in sync.** install.sh clones to `~/projects/dotfiles`, but you may edit in `~/Code/dotfiles`. Push changes and pull in both locations.

---

## Post-Migration Notes

After this migration:

1. **macOS (with nix-darwin) nvim structure:**
   ```
   ~/.config/nvim/
   ├── init.lua -> dotfiles (symlink, loads ccremote)
   ├── lazy-lock.json -> dotfiles (symlink)
   ├── autoload/ -> dotfiles (symlink)
   ├── ftplugin/ -> dotfiles (symlink)
   └── lua/
       ├── config/ -> dotfiles (symlink)
       ├── plugins/ -> dotfiles (symlink)
       ├── user/ -> dotfiles (symlink)
       └── ccremote.lua -> nix store (home-manager, replaces dotfiles symlink)
   ```

2. **Devbox nvim structure:** (unchanged, fully HM-managed)
   ```
   ~/.config/nvim/
   └── lua/ -> nix store (recursive symlink from assets/nvim/lua/)
   ```

3. **Non-Nix machines:** ccremote.lua comes from dotfiles, loaded by dotfiles init.lua. CCR works!

4. **Future migration path:** To fully migrate nvim to home-manager on macOS, gradually move dotfiles modules to workstation assets and update HM config.
