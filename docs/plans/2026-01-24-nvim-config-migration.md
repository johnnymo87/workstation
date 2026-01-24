# Neovim Config Migration Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Consolidate Neovim user config into workstation with platform detection, enabling progressive migration from dotfiles.

**Architecture:** Workstation's `assets/nvim/lua/` becomes the source of truth for user settings and mappings. Platform detection via `SSH_TTY` enables OSC 52 clipboard on remote sessions. On Darwin, files are deployed with `force = true` to overlay dotfiles. Plugin-dependent mappings are guarded with existence checks.

**Tech Stack:** Neovim Lua, NixOS home-manager, OSC 52

---

### Task 1: Consolidate user/settings.lua

**Files:**
- Modify: `assets/nvim/lua/user/settings.lua`

**Step 1: Write the consolidated settings.lua**

Replace current minimal content with full settings including platform detection:

```lua
-- Leader key (set early, before mappings and plugins)
vim.g.mapleader = ","
vim.g.maplocalleader = " "

-- Clipboard: use system clipboard
-- On SSH sessions, force OSC 52 provider for clipboard over terminal
if vim.env.SSH_TTY then
  vim.g.clipboard = "osc52"
end
vim.opt.clipboard = "unnamedplus"

-- Display
vim.opt.list = true
vim.opt.listchars = "tab:▷▷⋮,trail:·"
vim.opt.number = true
vim.opt.relativenumber = true
vim.opt.termguicolors = true
vim.opt.colorcolumn = "80,121"
vim.cmd("highlight ColorColumn ctermbg=235 guibg=#2c2d27")

-- Folding (treesitter-based)
vim.opt.foldmethod = "expr"
vim.opt.foldexpr = "nvim_treesitter#foldexpr()"
vim.opt.foldenable = false

-- Search
vim.opt.ignorecase = true
vim.opt.hlsearch = true
vim.opt.incsearch = true

-- Don't wrap lines
vim.opt.wrap = false

-- No swap/backup files
vim.opt.swapfile = false
vim.opt.backup = false
vim.opt.writebackup = false

-- Require save before switching buffers
vim.opt.hidden = false

-- Indentation
vim.opt.expandtab = true
vim.opt.copyindent = true
vim.opt.preserveindent = true
vim.opt.shiftwidth = 2
vim.opt.softtabstop = 2
vim.opt.tabstop = 2

-- netrw (built-in file explorer)
vim.g.netrw_keepj = ""
```

**Step 2: Verify syntax**

Run: `nvim --headless -c "luafile assets/nvim/lua/user/settings.lua" -c "q" 2>&1 || echo "Syntax OK"`

Expected: No errors

**Step 3: Commit**

```bash
git add assets/nvim/lua/user/settings.lua
git commit -m "feat(nvim): consolidate settings with SSH clipboard detection"
```

---

### Task 2: Consolidate user/mappings.lua

**Files:**
- Modify: `assets/nvim/lua/user/mappings.lua`

**Step 1: Write the consolidated mappings.lua**

Replace current minimal content with all mappings, using modern API and guarded plugin mappings:

```lua
-- Helper: only bind mapping if command exists (for plugin-dependent mappings)
local function map_if_cmd(cmd, mode, lhs, rhs, opts)
  if vim.fn.exists(":" .. cmd) == 2 then
    vim.keymap.set(mode, lhs, rhs, opts)
  end
end

-- Terminal mode: Ctrl-W a to escape back to normal mode
vim.keymap.set("t", "<C-w>a", [[<C-\><C-n>]], { noremap = true, silent = true })

-- Strip trailing whitespace
vim.keymap.set("n", "<leader>s", [[:%s/\s\+$//e<CR>]], { noremap = true, silent = true, desc = "Strip trailing whitespace" })

-- Copy current file's absolute path to clipboard
vim.keymap.set("n", "<leader>cp", function()
  vim.fn.setreg("+", vim.fn.expand("%:p"))
end, { noremap = true, desc = "Copy file path to clipboard" })

-- Plugin-dependent mappings (only bind if plugin is loaded)
map_if_cmd("Rg", "n", "<leader>rr", ":Rg ''<left>", { noremap = true, desc = "Ripgrep search" })
map_if_cmd("Git", "n", "<leader>gg", ":Git ", { noremap = true, desc = "Git (Fugitive)" })
```

**Step 2: Verify syntax**

Run: `nvim --headless -c "luafile assets/nvim/lua/user/mappings.lua" -c "q" 2>&1 || echo "Syntax OK"`

Expected: No errors

**Step 3: Commit**

```bash
git add assets/nvim/lua/user/mappings.lua
git commit -m "feat(nvim): consolidate mappings with guarded plugin bindings"
```

---

### Task 3: Update home.darwin.nix for recursive overlay

**Files:**
- Modify: `users/dev/home.darwin.nix:57-62`

**Step 1: Replace cherry-pick approach with recursive overlay**

Change from:
```nix
  # Disable the entire nvim/lua recursive deployment from base config
  # (it conflicts with dotfiles-managed nvim config)
  xdg.configFile."nvim/lua".enable = lib.mkForce false;

  # Deploy only ccremote.lua (dotfiles init.lua already loads it)
  xdg.configFile."nvim/lua/ccremote.lua".source = "${assetsPath}/nvim/lua/ccremote.lua";
```

To:
```nix
  # Deploy workstation's nvim/lua as overlay on dotfiles
  # Includes: ccremote.lua, user/settings.lua, user/mappings.lua
  # force = true ensures workstation files win over any dotfiles copies
  xdg.configFile."nvim/lua" = {
    source = "${assetsPath}/nvim/lua";
    recursive = true;
    force = true;
  };
```

**Step 2: Update prepareForHM cleanup**

Add cleanup for user/ directory to the activation script (around line 67-77). Add after the ccremote.lua cleanup:

```nix
    rm -rf ~/.config/nvim/lua/user 2>/dev/null || true
```

This ensures any dotfiles-created user/ directory is removed before home-manager creates symlinks.

**Step 3: Commit**

```bash
git add users/dev/home.darwin.nix
git commit -m "feat(darwin): use recursive nvim/lua overlay with force"
```

---

### Task 4: Test on devbox

**Step 1: Apply home-manager**

Run:
```bash
git add -A  # Stage for nix to see
nix run home-manager -- switch --flake .#dev
```

Expected: Build succeeds

**Step 2: Test settings loaded**

Run:
```bash
nvim --headless -c "lua print(vim.g.mapleader)" -c "q" 2>&1
```

Expected: `,`

**Step 3: Test clipboard detection (devbox is SSH)**

Run:
```bash
nvim --headless -c "lua print(vim.g.clipboard)" -c "q" 2>&1
```

Expected: `osc52`

**Step 4: Test mappings available**

Run:
```bash
nvim --headless -c "verbose nmap <leader>cp" -c "q" 2>&1 | head -5
```

Expected: Shows the mapping definition

**Step 5: Test copy-path mapping functionally**

Run:
```bash
nvim -c "e assets/nvim/lua/user/settings.lua" -c "normal ,cp" -c "lua print(vim.fn.getreg('+'))" -c "q" 2>&1 | tail -1
```

Expected: Full path to settings.lua

**Step 6: Commit staged changes if all tests pass**

```bash
git commit -m "test: verify nvim config migration on devbox"
```

(Note: This commit may be empty if no additional changes were made, which is fine)

---

### Task 5: Document dotfiles changes needed

**Files:**
- Create: `docs/plans/2026-01-24-nvim-config-migration.md` (append to this file)

**Step 1: Add "Darwin follow-up" section to this plan**

Append to the plan file:

```markdown
---

## Darwin Follow-up (manual steps on macOS)

After pushing these changes, on macOS:

1. **Pull workstation changes:**
   ```bash
   cd ~/Code/workstation && git pull
   ```

2. **Apply darwin-rebuild:**
   ```bash
   darwin-rebuild switch --flake .#Y0FMQX93RR-2
   ```

3. **Remove user/ from dotfiles:**
   ```bash
   cd ~/Code/deprecated-dotfiles
   rm .config/nvim/lua/user/settings.lua
   rm .config/nvim/lua/user/mappings.lua
   git add -A && git commit -m "chore: migrate user/settings and user/mappings to workstation"
   ```

4. **Verify nvim works:**
   ```bash
   nvim --version
   nvim -c "lua print(vim.g.mapleader)" -c "q"
   # Should print: ,
   ```

5. **Test that OSC 52 is NOT set locally:**
   ```bash
   nvim -c "lua print(vim.g.clipboard or 'nil')" -c "q"
   # Should print: nil (native clipboard on local macOS)
   ```
```

**Step 2: Commit plan update**

```bash
git add docs/plans/2026-01-24-nvim-config-migration.md
git commit -m "docs: add Darwin follow-up steps to nvim migration plan"
```

---

### Task 6: Push and finalize

**Step 1: Push all commits**

```bash
git push
```

**Step 2: Verify remote**

Run: `git log --oneline origin/main..HEAD`

Expected: 0 commits (all pushed)

---

## Darwin Follow-up (manual steps on macOS)

After pushing these changes, on macOS:

1. **Pull workstation changes:**
   ```bash
   cd ~/Code/workstation && git pull
   ```

2. **Apply darwin-rebuild:**
   ```bash
   darwin-rebuild switch --flake .#Y0FMQX93RR-2
   ```

3. **Remove user/ from dotfiles:**
   ```bash
   cd ~/Code/deprecated-dotfiles
   rm .config/nvim/lua/user/settings.lua
   rm .config/nvim/lua/user/mappings.lua
   git add -A && git commit -m "chore: migrate user/settings and user/mappings to workstation"
   ```

4. **Verify nvim works:**
   ```bash
   nvim --version
   nvim -c "lua print(vim.g.mapleader)" -c "q"
   # Should print: ,
   ```

5. **Test that OSC 52 is NOT set locally:**
   ```bash
   nvim -c "lua print(vim.g.clipboard or 'nil')" -c "q"
   # Should print: nil (native clipboard on local macOS)
   ```
