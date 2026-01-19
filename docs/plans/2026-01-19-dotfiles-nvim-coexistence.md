# Dotfiles/Home-Manager Nvim Coexistence Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Refactor deprecated-dotfiles so home-manager can manage `ccremote.lua` on macOS without conflicting with the existing nvim configuration.

**Architecture:** Change dotfiles from symlinking the entire `~/.config/nvim` directory to symlinking individual children. Make `lua/` a real directory with child symlinks (`config/`, `plugins/`, `user/`), leaving room for home-manager to own `lua/ccremote.lua`. Update workstation's home.darwin.nix to handle the Darwin-specific nvim setup.

**Tech Stack:** Bash (dotfiles installer), Nix (home-manager), Neovim Lua

---

### Task 1: Refactor dotfiles install.sh for nvim

**Files:**
- Modify: `~/projects/deprecated-dotfiles/install.sh`

**Step 1: Update the nvim symlink section**

Find the current nvim section (around lines 44-48):
```bash
# Vim/Neovim
ln -sf "$DOTFILES_DIR/.vimrc" "$HOME/.vimrc"
mkdir -p "$HOME/.config"
rm -rf "$HOME/.config/nvim" 2>/dev/null || true
ln -sf "$DOTFILES_DIR/.config/nvim" "$HOME/.config/nvim"
```

Replace with:
```bash
# Vim/Neovim
ln -sf "$DOTFILES_DIR/.vimrc" "$HOME/.vimrc"
mkdir -p "$HOME/.config"

# Create nvim as a real directory with child symlinks
# This allows home-manager to manage additional files (e.g., lua/ccremote.lua)
NVIM_HOME="$HOME/.config/nvim"
NVIM_SRC="$DOTFILES_DIR/.config/nvim"

# Remove old monolithic symlink if it exists
if [ -L "$NVIM_HOME" ]; then
  rm "$NVIM_HOME"
fi
mkdir -p "$NVIM_HOME"

# Symlink top-level files
for f in init.lua lazy-lock.json; do
  [ -f "$NVIM_SRC/$f" ] && ln -sf "$NVIM_SRC/$f" "$NVIM_HOME/$f"
done

# Symlink top-level directories (except lua/)
for d in autoload ftplugin; do
  [ -d "$NVIM_SRC/$d" ] && ln -sfn "$NVIM_SRC/$d" "$NVIM_HOME/$d"
done

# Create lua/ as real directory with child symlinks
mkdir -p "$NVIM_HOME/lua"

# Symlink lua/ subdirectories
for d in config plugins user; do
  [ -d "$NVIM_SRC/lua/$d" ] && ln -sfn "$NVIM_SRC/lua/$d" "$NVIM_HOME/lua/$d"
done

# Symlink top-level lua files (ccremote.lua, etc.)
# On Nix machines, home-manager will replace this with its managed version
for f in "$NVIM_SRC/lua/"*.lua; do
  [ -f "$f" ] && ln -sf "$f" "$NVIM_HOME/lua/$(basename "$f")"
done
```

**Step 2: Commit in deprecated-dotfiles**

```bash
cd ~/projects/deprecated-dotfiles
git add install.sh
git commit -m "Refactor nvim install to use child symlinks

Instead of symlinking entire ~/.config/nvim directory, create it
as a real directory with child symlinks. This allows home-manager
to manage additional files like lua/ccremote.lua without conflict.

Structure after install:
~/.config/nvim/
├── init.lua -> dotfiles (symlink)
├── lazy-lock.json -> dotfiles (symlink)
├── autoload/ -> dotfiles (symlink)
├── ftplugin/ -> dotfiles (symlink)
└── lua/
    ├── config/ -> dotfiles (symlink)
    ├── plugins/ -> dotfiles (symlink)
    ├── user/ -> dotfiles (symlink)
    └── ccremote.lua -> dotfiles (symlink, replaced by HM on Nix machines)

Note: init.lua keeps require('ccremote').setup() - it works with either
the dotfiles or home-manager version of ccremote.lua."
```

---

### Task 2: Push deprecated-dotfiles changes

**Step 1: Push to remote**

```bash
cd ~/projects/deprecated-dotfiles
git push origin main
```

---

### Task 3: Update workstation home.darwin.nix for nvim

**Files:**
- Modify: `~/projects/workstation/users/dev/home.darwin.nix`

**Step 1: Read the current home.darwin.nix**

```bash
cat ~/projects/workstation/users/dev/home.darwin.nix
```

Check current Darwin-specific config to understand what's there.

**Step 2: Add Darwin-specific nvim config**

The key insight: On Darwin, dotfiles manages nvim's init.lua (which already has `require("ccremote").setup()`). Home-manager only needs to:
1. Remove the dotfiles ccremote.lua symlink (to avoid conflict)
2. Deploy HM-managed `lua/ccremote.lua` in its place

Add to home.darwin.nix (inside the `config = lib.mkIf pkgs.stdenv.isDarwin` block):

```nix
    # On Darwin, dotfiles symlinks ccremote.lua but we want HM to manage it.
    # Remove the dotfiles symlink before HM tries to create its own.
    home.activation.prepareNvimForHM = lib.hm.dag.entryBefore ["checkLinkTargets"] ''
      rm -f ~/.config/nvim/lua/ccremote.lua 2>/dev/null || true
    '';

    # Deploy HM-managed ccremote.lua (dotfiles init.lua already loads it)
    xdg.configFile."nvim/lua/ccremote.lua".source = "${assetsPath}/nvim/lua/ccremote.lua";
```

Note: `assetsPath` should already be available from extraSpecialArgs in flake.nix.

**Step 3: Commit**

```bash
cd ~/projects/workstation
git add users/dev/home.darwin.nix
git commit -m "Add Darwin-specific ccremote.lua deployment

On Darwin, dotfiles manages nvim's init.lua which loads ccremote.
We deploy HM-managed ccremote.lua to replace the dotfiles symlink.

Includes activation script to remove dotfiles symlink before HM
creates its own (avoids checkLinkTargets conflict)."
```

---

### Task 4: Push workstation changes

**Step 1: Push to remote**

```bash
cd ~/projects/workstation
git push origin main
```

---

## CHECKPOINT: Pause here on devbox

Tasks 1-4 can be completed on the devbox. After pushing, pause and switch to macOS to continue with Task 5.

---

### Task 5: Test on macOS (must run on macOS)

**Prerequisites:** You must be on macOS for this task.

**Step 1: Pull deprecated-dotfiles and re-run installer**

```bash
cd ~/projects/dotfiles  # or wherever dotfiles is on macOS
git pull origin main
./install.sh
```

**Step 2: Verify nvim structure after install.sh**

```bash
ls -la ~/.config/nvim/
# Should show: init.lua, lazy-lock.json as symlinks, lua/ as DIRECTORY (not symlink)

ls -la ~/.config/nvim/lua/
# Should show: config/, plugins/, user/ as symlinks, ccremote.lua as symlink to dotfiles
```

**Step 3: Pull workstation and rebuild darwin**

```bash
cd ~/Code/workstation  # or your macOS path
git pull origin main
darwin-rebuild switch --flake .#Y0FMQX93RR-2  # adjust hostname as needed
```

**Step 4: Verify ccremote.lua replaced by HM**

```bash
ls -la ~/.config/nvim/lua/ccremote.lua
# Should now show symlink to Nix store (not dotfiles)
```

**Step 5: Test nvim loads correctly**

```bash
nvim -c ':CCList' -c ':q'
```

Expected: "ccremote: no instances registered" (not "Unknown command")

**Step 6: Test nvims function**

```bash
type nvims
nvims --version
```

Expected: Shows function definition, then nvim version with socket path on stderr.

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
