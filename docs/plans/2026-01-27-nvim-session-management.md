# Neovim Session Management Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Enable neovim session persistence that integrates with tmux-resurrect, so nvim state is restored when tmux sessions are restored.

**Architecture:** Install vim-obsession via home-manager's `programs.neovim.plugins` to auto-save `Session.vim` files in project directories. Add Lua config to auto-start Obsession in project directories (detected by markers like `.git`, `flake.nix`). tmux-resurrect's existing `@resurrect-strategy-nvim 'session'` will use these files on restore.

**Tech Stack:** Neovim 0.11.5, vim-obsession, home-manager, tmux-resurrect

---

## Task 1: Add vim-obsession plugin via home-manager

**Files:**
- Modify: `users/dev/home.base.nix` (programs.neovim section)

**Step 1: Read current neovim config**

Read `users/dev/home.base.nix` to find the `programs.neovim` section.

**Step 2: Add plugins attribute with vim-obsession**

Update the `programs.neovim` block to include:

```nix
programs.neovim = {
  enable = true;
  defaultEditor = true;
  viAlias = true;
  vimAlias = true;

  # Session management for tmux-resurrect integration
  plugins = with pkgs.vimPlugins; [
    vim-obsession
  ];

  extraLuaConfig = ''
    require("user.settings")
    require("user.mappings")
    require("ccremote").setup()
  '';
};
```

**Step 3: Verify syntax**

Run: `nix flake check`
Expected: No errors

**Step 4: Commit**

```bash
git add users/dev/home.base.nix
git commit -m "feat(nvim): add vim-obsession plugin for session management"
```

---

## Task 2: Create session auto-start Lua module

**Files:**
- Create: `assets/nvim/lua/user/sessions.lua`

**Step 1: Create the sessions module**

Create `assets/nvim/lua/user/sessions.lua`:

```lua
-- Auto-start vim-obsession in project directories for tmux-resurrect integration
-- tmux-resurrect's @resurrect-strategy-nvim 'session' expects Session.vim in cwd
--
-- How it works:
-- 1. On VimEnter, check if we're in a "project" directory (has .git, flake.nix, etc.)
-- 2. If so, start Obsession to continuously save Session.vim
-- 3. tmux-resurrect will restore nvim with `nvim -S` using this file

local uv = vim.uv or vim.loop

-- Check if a file/directory exists
local function exists(path)
  return uv.fs_stat(path) ~= nil
end

-- Check if directory looks like a project root
local function is_project_dir(dir)
  local markers = {
    ".git",
    "flake.nix",
    "Cargo.toml",
    "go.mod",
    "package.json",
    "pyproject.toml",
    "Makefile",
  }
  for _, marker in ipairs(markers) do
    if exists(dir .. "/" .. marker) then
      return true
    end
  end
  return false
end

-- Decide whether to auto-start session recording
local function should_record_session()
  local dir = vim.fn.getcwd()

  -- Don't litter home or root with Session.vim
  if dir == vim.env.HOME or dir == "/" then
    return false
  end

  -- Need write permission to create Session.vim
  if vim.fn.filewritable(dir) ~= 2 then
    return false
  end

  -- Only record in project directories
  return is_project_dir(dir)
end

-- Auto-start Obsession on VimEnter in project directories
vim.api.nvim_create_autocmd("VimEnter", {
  group = vim.api.nvim_create_augroup("SessionsAutoStart", { clear = true }),
  callback = function()
    -- Skip if opened with arguments (e.g., nvim file.txt) - let user decide
    if vim.fn.argc() > 0 then
      return
    end

    if should_record_session() then
      -- Start recording to Session.vim in current directory
      -- silent! suppresses errors if Obsession isn't loaded
      vim.cmd("silent! Obsess")
    end
  end,
})
```

**Step 2: Verify file was created**

Run: `cat assets/nvim/lua/user/sessions.lua | head -10`
Expected: Shows the module header comment

**Step 3: Commit**

```bash
git add assets/nvim/lua/user/sessions.lua
git commit -m "feat(nvim): add session auto-start for tmux-resurrect integration"
```

---

## Task 3: Load the sessions module in neovim config

**Files:**
- Modify: `users/dev/home.base.nix` (extraLuaConfig)

**Step 1: Add require for sessions module**

Update the `extraLuaConfig` in `programs.neovim` to load the sessions module:

```nix
extraLuaConfig = ''
  require("user.settings")
  require("user.mappings")
  require("user.sessions")  -- Session management for tmux-resurrect
  require("ccremote").setup()
'';
```

**Step 2: Verify syntax**

Run: `nix flake check`
Expected: No errors

**Step 3: Commit**

```bash
git add users/dev/home.base.nix
git commit -m "feat(nvim): load sessions module in extraLuaConfig"
```

---

## Task 4: Add Session.vim to global gitignore

**Files:**
- Modify: `users/dev/home.base.nix` (programs.git section)

**Step 1: Check current git config**

Read `users/dev/home.base.nix` to find the `programs.git` section.

**Step 2: Add global ignores for Session.vim**

Add `ignores` to the git config:

```nix
programs.git = {
  enable = true;
  signing.key = "0C0EF2DF7ADD5DD9";
  ignores = [
    "Session.vim"  # vim-obsession session files (for tmux-resurrect)
  ];
  settings = {
    # ... existing settings ...
  };
};
```

**Step 3: Verify syntax**

Run: `nix flake check`
Expected: No errors

**Step 4: Commit**

```bash
git add users/dev/home.base.nix
git commit -m "feat(git): add Session.vim to global gitignore"
```

---

## Task 5: Add resurrect-processes for nvim matching

**Files:**
- Modify: `users/dev/tmux.linux.nix` (resurrect extraConfig)

**Step 1: Read current resurrect config**

Read `users/dev/tmux.linux.nix` to find the resurrect plugin config.

**Step 2: Add @resurrect-processes setting**

Update the resurrect extraConfig to ensure nvim is properly matched on restore:

```nix
{
  plugin = resurrect;
  extraConfig = ''
    # Persist resurrect data to survive NixOS rebuilds
    set -g @resurrect-dir '${resurrectDir}'
    # Restore neovim sessions (requires vim-obsession saving Session.vim)
    set -g @resurrect-strategy-nvim 'session'
    # Ensure nvim is matched for restoration (Nix paths can confuse matching)
    set -g @resurrect-processes 'nvim vim vi'
  '';
}
```

**Step 3: Verify syntax**

Run: `nix flake check`
Expected: No errors

**Step 4: Commit**

```bash
git add users/dev/tmux.linux.nix
git commit -m "feat(tmux): add resurrect-processes for reliable nvim restore"
```

---

## Task 6: Apply and test the full integration

**Step 1: Apply home-manager changes**

Run: `home-manager switch --flake .#dev` (or via nix run)
Expected: Successful switch

**Step 2: Verify vim-obsession is installed**

Run: `nvim -c ":Obsess" -c ":q"` in a project directory
Expected: Creates Session.vim file

**Step 3: Test the auto-start behavior**

```bash
cd ~/projects/workstation
nvim
# Should see Obsession started (check with :Obsess - should show "Obsessing")
:q
ls Session.vim
```
Expected: Session.vim exists

**Step 4: Test tmux-resurrect integration**

1. Start tmux: `tmux new -s test`
2. Open nvim in a project: `cd ~/projects/workstation && nvim`
3. Open some files, make some splits
4. Save resurrect: `C-a C-s` (prefix + Ctrl-s)
5. Kill tmux: `tmux kill-server`
6. Start tmux again: `tmux`
7. Restore: `C-a C-r` (prefix + Ctrl-r)

Expected: nvim reopens with the same files/splits

**Step 5: Clean up test Session.vim**

Run: `rm ~/projects/workstation/Session.vim`

---

## Task 7: Update documentation

**Files:**
- Modify: `docs/plans/2026-01-26-tmux-enhancement.md` (add note about nvim sessions)

**Step 1: Add a note about nvim session integration**

Add a brief note to the tmux enhancement plan indicating that nvim session management was added as a follow-up.

**Step 2: Commit all remaining changes**

```bash
git add -A
git commit -m "docs: note nvim session integration in tmux plan"
```

---

## Summary

| Task | Description | Files |
|------|-------------|-------|
| 1 | Add vim-obsession plugin | `users/dev/home.base.nix` |
| 2 | Create sessions.lua module | `assets/nvim/lua/user/sessions.lua` |
| 3 | Load sessions module | `users/dev/home.base.nix` |
| 4 | Add Session.vim to gitignore | `users/dev/home.base.nix` |
| 5 | Add resurrect-processes | `users/dev/tmux.linux.nix` |
| 6 | Apply and test | (verification) |
| 7 | Update docs | `docs/plans/` |

**After completion:** When you restore a tmux session, any nvim instances that were running in project directories will be restored with their buffers, windows, and cursor positions intact.
