# Full Neovim Migration Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Migrate neovim from dotfiles + lazy.nvim to fully nix-managed via
home-manager, fixing the tabby tab rename bug and eliminating config drift.

**Architecture:** Enable `programs.neovim` on Darwin (remove `mkForce false`),
expand the shared `home.base.nix` plugin list and `extraLuaConfig`, remove all
Darwin-specific nvim workarounds, delete dotfiles nvim config entirely.

**Tech Stack:** Nix, home-manager (standalone), nix-darwin, neovim 0.11

**Design doc:** `docs/plans/2026-03-12-nvim-full-migration-design.md`

---

### Task 1: Add cursor_highlight.lua to workstation assets

**Files:**
- Create: `assets/nvim/lua/user/cursor_highlight.lua`

**Step 1: Create the file**

```lua
-- Toggle cursor line and column highlighting to quickly find the cursor.
-- Inspired by https://vim.fandom.com/wiki/Highlight_current_line

local function toggle_cursor_highlight()
    local cursorline = vim.wo.cursorline
    local cursorcolumn = vim.wo.cursorcolumn

    vim.wo.cursorline = not cursorline
    vim.wo.cursorcolumn = not cursorcolumn

    local highlight_group_settings = {
        CursorLine = { bg = 'DarkRed', fg = 'White' },
        CursorColumn = { bg = 'DarkRed', fg = 'White' }
    }

    for group, settings in pairs(highlight_group_settings) do
        vim.api.nvim_set_hl(0, group, settings)
    end
end

vim.api.nvim_set_keymap('n', '<C-K>', '', {
    noremap = true,
    silent = true,
    callback = toggle_cursor_highlight
})
```

**Step 2: Commit**

```bash
git add assets/nvim/lua/user/cursor_highlight.lua
git commit -m "feat(nvim): add cursor_highlight.lua to assets

Toggle cursor crosshair with Ctrl+K. Moved from dotfiles as
part of full neovim migration to nix."
```

---

### Task 2: Add telescope.lua to workstation assets

**Files:**
- Create: `assets/nvim/lua/user/telescope.lua`

**Step 1: Create the file**

This is the dotfiles version with `auto_install` changed to `false` (nix
provides grammars) and comments trimmed.

```lua
-- Treesitter configuration (grammars provided by nix, no runtime install)
require("nvim-treesitter.configs").setup({
  auto_install = false,
  highlight = {
    enable = true,
    additional_vim_regex_highlighting = false,
  },
  incremental_selection = {
    enable = true,
  },
  indent = {
    enable = true,
  },
})

-- Telescope configuration
require("telescope").setup({
  defaults = {
    mappings = {
      i = {
        ["<C-n>"] = "cycle_history_next",
        ["<C-p>"] = "cycle_history_prev",
        ["<C-j>"] = "move_selection_next",
        ["<C-k>"] = "move_selection_previous",
      },
    },
  },
})

local builtin = require("telescope.builtin")
vim.keymap.set("n", "<leader>ff", function() builtin.find_files({ hidden = true }) end, { desc = "Find files" })
vim.keymap.set("n", "<leader>fg", builtin.live_grep, { desc = "Live grep" })
vim.keymap.set("n", "<leader>fG", builtin.grep_string, { desc = "Grep string under cursor" })
vim.keymap.set("n", "<leader>fb", builtin.buffers, { desc = "Buffers" })
vim.keymap.set("n", "<leader>fh", builtin.help_tags, { desc = "Help tags" })

require("telescope").load_extension("fzy_native")
```

**Step 2: Commit**

```bash
git add assets/nvim/lua/user/telescope.lua
git commit -m "feat(nvim): add telescope.lua to assets

Treesitter + telescope config moved from dotfiles. Changed
auto_install to false since nix provides grammars."
```

---

### Task 3: Update mappings.lua -- remove fugitive mapping

**Files:**
- Modify: `assets/nvim/lua/user/mappings.lua`

**Step 1: Remove the fugitive mapping**

Remove line 21: `map_if_cmd("Git", "n", "<leader>gg", ":Git ", ...)`

Also remove the `map_if_cmd` helper function (lines 1-6) if the only
remaining caller (`<leader>rr`) can use a simpler guard. Actually, keep
`map_if_cmd` since it's still used by the Rg mapping.

Just delete line 21.

**Step 2: Commit**

```bash
git add assets/nvim/lua/user/mappings.lua
git commit -m "refactor(nvim): remove fugitive mapping from mappings.lua

vim-fugitive is being dropped as part of full nvim migration."
```

---

### Task 4: Delete dead files from workstation assets

**Files:**
- Delete: `assets/nvim/lua/ccremote.lua`
- Delete: `assets/nvim/.gitkeep`

**Step 1: Remove the files**

```bash
git rm assets/nvim/lua/ccremote.lua
git rm assets/nvim/.gitkeep
```

**Step 2: Commit**

```bash
git commit -m "chore(nvim): remove ccremote.lua and .gitkeep from assets

ccremote.lua is no longer used. .gitkeep is unnecessary since
the directory contains other files."
```

---

### Task 5: Update home.base.nix -- plugins, extraLuaConfig, extraPackages

**Files:**
- Modify: `users/dev/home.base.nix`

This is the largest change. Expand the `programs.neovim` block.

**Step 1: Update the plugins list**

Replace the current `plugins` block (lines 383-387):

```nix
    plugins = with pkgs.vimPlugins; [
      vim-obsession
      tabby-nvim
    ];
```

With:

```nix
    plugins = with pkgs.vimPlugins; [
      vim-obsession
      tabby-nvim
      goyo-vim
      mini-align
      plenary-nvim
      telescope-fzy-native-nvim
      telescope-nvim
      (nvim-treesitter.withPlugins (p: with p; [
        bash c comment css csv diff dockerfile
        editorconfig git_config gitcommit gitignore go
        html http javascript json json5 lua luadoc
        make markdown markdown_inline nix python
        regex ruby sql ssh_config tmux toml
        typescript vimdoc xml yaml
      ]))
      (pkgs.vimUtils.buildVimPlugin {
        pname = "vim-ripgrep";
        version = "unstable-2026-01-13";
        src = pkgs.fetchFromGitHub {
          owner = "jremmen";
          repo = "vim-ripgrep";
          rev = "2bb2425387b449a0cd65a54ceb85e123d7a320b8";
          hash = "sha256-OvQPTEiXOHI0uz0+6AVTxyJ/TUMg6kd3BYTAbnCI7W8=";
        };
      })
    ];

    extraPackages = [ pkgs.ripgrep ];
```

**Step 2: Update extraLuaConfig**

Replace the current `extraLuaConfig` block (lines 389-396):

```nix
    extraLuaConfig = ''
      require("user.settings")
      require("user.mappings")
      require("user.sessions")    -- Session management for tmux-resurrect
      require("user.tabby")       -- OpenCode session titles in tab labels
    '' + lib.optionalString (isDarwin || isCloudbox) ''
      require("user.atlassian")   -- :FetchJiraTicket, :FetchConfluencePage
    '';
```

With:

```nix
    extraLuaConfig = ''
      require("user.settings")
      require("user.mappings")
      require("user.sessions")          -- tmux-resurrect session management
      require("user.tabby")             -- OpenCode session tab labels
      require("user.cursor_highlight")  -- Ctrl+K cursor crosshair toggle
      require("user.telescope")         -- treesitter + telescope + keymaps
      require("mini.align").setup()     -- text alignment (ga/gA)
    '' + lib.optionalString (isDarwin || isCloudbox) ''
      require("user.atlassian")         -- :FetchJiraTicket, :FetchConfluencePage
    '';
```

**Step 3: Commit**

```bash
git add users/dev/home.base.nix
git commit -m "feat(nvim): expand plugins and config for full migration

Add goyo, mini-align, plenary, telescope, treesitter, and
vim-ripgrep to nix-managed plugins. Add extraPackages for
ripgrep binary. Expand extraLuaConfig with cursor_highlight,
telescope, and mini.align setup."
```

---

### Task 6: Update home.darwin.nix -- remove nvim workarounds

**Files:**
- Modify: `users/dev/home.darwin.nix`

**Step 1: Remove the neovim force-disable (line 344)**

Delete:
```nix
  programs.neovim.enable = lib.mkForce false;
```

**Step 2: Remove the recursive deploy disable (line 348)**

Delete:
```nix
  xdg.configFile."nvim/lua/user".enable = lib.mkForce false;
```

**Step 3: Remove individual xdg.configFile entries (lines 350-355)**

Delete these lines (including comments):
```nix
  # Deploy only specific lua files ...
  xdg.configFile."nvim/lua/user/sessions.lua".source = "${assetsPath}/nvim/lua/user/sessions.lua";
  xdg.configFile."nvim/lua/user/atlassian.lua".source = "${assetsPath}/nvim/lua/user/atlassian.lua";
  xdg.configFile."nvim/lua/user/tabby.lua".source = "${assetsPath}/nvim/lua/user/tabby.lua";
```

**Step 4: Remove xdg.dataFile packpath entry (lines 357-362)**

Delete:
```nix
  # tabby.nvim: install plugin to packpath ...
  xdg.dataFile."nvim/site/pack/nix/start/tabby-nvim" = {
    source = pkgs.vimPlugins.tabby-nvim;
    recursive = true;
  };
```

**Step 5: Update prepareForHM cleanup**

Replace the nvim-related cleanup lines (412-416):
```nix
    rm -f ~/.config/nvim/lua/ccremote.lua 2>/dev/null || true
    rm -f ~/.config/nvim/lua/pigeon.lua 2>/dev/null || true
    rm -f ~/.config/nvim/lua/user/sessions.lua 2>/dev/null || true
    rm -f ~/.config/nvim/lua/user/atlassian.lua 2>/dev/null || true
    rm -f ~/.config/nvim/lua/user/tabby.lua 2>/dev/null || true
```

With cleanup that handles the full dotfiles-to-nix transition:
```nix
    # Neovim: remove dotfiles-managed files before HM takes over
    rm -f ~/.config/nvim/init.lua 2>/dev/null || true
    rm -rf ~/.config/nvim/lua/user 2>/dev/null || true
    rm -rf ~/.config/nvim/lua/config 2>/dev/null || true
    rm -rf ~/.config/nvim/lua/plugins 2>/dev/null || true
    rm -f ~/.config/nvim/lua/ccremote.lua 2>/dev/null || true
    rm -f ~/.config/nvim/lua/pigeon.lua 2>/dev/null || true
```

**Step 6: Commit**

```bash
git add users/dev/home.darwin.nix
git commit -m "feat(nvim/darwin): enable programs.neovim, remove workarounds

Remove mkForce false, individual file deploys, packpath
workaround, and stale cleanup entries. Add prepareForHM
cleanup for dotfiles-to-nix transition. This enables the
nix neovim wrapper on Darwin."
```

---

### Task 7: Verify nix evaluation

**Step 1: Check that the flake evaluates without errors**

```bash
nix flake check 2>&1 | head -20
```

Expected: no errors (warnings are OK).

If there are evaluation errors, fix them before proceeding.

---

### Task 8: Remove dotfiles nvim config

This is in a **separate repo** (`~/Code/dotfiles`).

**Step 1: Remove the nvim config directory from dotfiles**

```bash
cd ~/Code/dotfiles
git rm -r .config/nvim/
git commit -m "chore: remove nvim config (migrated to workstation nix)"
```

**Step 2: Remove the dotfiles symlink from ~/.config/nvim**

The dotfiles install script likely created symlinks. Remove them:

```bash
rm -f ~/.config/nvim/init.lua
rm -rf ~/.config/nvim/lua
rm -rf ~/.config/nvim/autoload
rm -rf ~/.config/nvim/ftplugin
rm -f ~/.config/nvim/lazy-lock.json
```

Or if dotfiles symlinks the entire directory:
```bash
rm -rf ~/.config/nvim
```

The `prepareForHM` cleanup in Task 6 also handles this, but doing it
manually first is safer.

---

### Task 9: Apply and verify on Darwin

**Step 1: Apply the configuration**

```bash
cd ~/Code/workstation
sudo darwin-rebuild switch --flake .#Y0FMQX93RR-2
```

Expected: build succeeds, no errors.

**Step 2: Verify correct nvim binary**

```bash
type -a nvim
nvim --version | head -3
```

Expected: nvim from nix profile, version 0.11.5.

**Step 3: Verify clean startup**

```bash
nvim --startuptime /tmp/nvim-startup.log +q
grep -i error /tmp/nvim-startup.log
```

Expected: no errors.

**Step 4: Verify features**

Open nvim and test each feature:

```
:Telescope find_files          # telescope works
:Goyo                          # distraction-free mode
:Rg test                       # ripgrep search
:Obsess                        # session tracking starts
```

In a terminal buffer with OpenCode:
```
:echo b:term_title             # should show "OC | ..."
```
Check that the tab label is shortened (tabby working).

Open a `.lua` file and verify treesitter highlighting is active:
```
:InspectTree                   # should show syntax tree
```

Test mini.align: visual select some lines, press `ga=` to align on `=`.

Test cursor highlight: press `<C-K>` in normal mode.

**Step 5: Verify no leftover conflicts**

```bash
ls -la ~/.config/nvim/
```

Expected: `init.lua` symlink to nix store, `lua/` directory with
`user/` subdirectory containing nix-managed symlinks.

---

### Task 10: Final commit with design doc

**Step 1: Commit the design doc and plan**

```bash
cd ~/Code/workstation
git add docs/plans/2026-03-12-nvim-full-migration-design.md
git add docs/plans/2026-03-12-nvim-full-migration-plan.md
git commit -m "docs: add nvim migration design and implementation plan"
```

---

## Rollback Plan

If something breaks on Darwin:

1. Re-add `programs.neovim.enable = lib.mkForce false` to `home.darwin.nix`
2. Restore dotfiles nvim config from git: `cd ~/Code/dotfiles && git checkout HEAD~1 -- .config/nvim/`
3. Re-run dotfiles install script
4. `sudo darwin-rebuild switch --flake .#Y0FMQX93RR-2`
