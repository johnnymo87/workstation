# Full Neovim Migration from Dotfiles to Nix

## Problem

Neovim config is split across dotfiles (lazy.nvim, plugin specs, init.lua) and
workstation (3 nix-managed symlinks, 2 nix plugins). This causes:

1. **tabby-nvim is invisible on macOS** -- lazy.nvim's `reset_packpath`
   strips the nix-deployed plugin from the packpath, so OpenCode tab rename
   doesn't work.
2. **Config drift** -- settings.lua and mappings.lua exist in both repos
   with subtle differences.
3. **Complexity** -- two plugin managers (nix on devbox, lazy.nvim on macOS),
   individual file deployment workarounds on Darwin.

## Solution

Drop lazy.nvim entirely. Enable `programs.neovim` on Darwin. All plugins
and config managed by nix via home-manager.

## How the Wrapper Works

At our pinned home-manager revision (`82fb7de`), the neovim module sets
`wrapRc = false` and writes `~/.config/nvim/init.lua` from `extraLuaConfig`.
The wrapper only prepends nix plugin paths via `--cmd "set packpath^=..."` and
`--cmd "set rtp^=..."`. It does NOT use `-u /nix/store/.../init.lua`.

This means:
- `~/.config/nvim` remains in the rtp (by design, not accident)
- `require("user.settings")` finds `~/.config/nvim/lua/user/settings.lua`
- HM owns `~/.config/nvim/init.lua` -- dotfiles symlink must be removed first
- Plugins are also linked to `~/.local/share/nvim/site/pack/hm`

Sources: [home-manager neovim module][hm-nvim], [ChatGPT research][research]

## Plugin List

```nix
programs.neovim = {
  enable = true;
  defaultEditor = true;
  viAlias = true;
  vimAlias = true;

  plugins = with pkgs.vimPlugins; [
    vim-obsession                       # tmux-resurrect sessions
    tabby-nvim                          # OpenCode tab labels
    goyo-vim                            # distraction-free writing (:Goyo)
    mini-align                          # text alignment (ga/gA)
    plenary-nvim                        # lua utilities (telescope dep)
    telescope-fzy-native-nvim           # native telescope sorter
    telescope-nvim                      # fuzzy finder
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

  extraPackages = [ pkgs.ripgrep ];  # vim-ripgrep shells out to rg

  extraLuaConfig = ''
    require("user.settings")
    require("user.mappings")
    require("user.sessions")
    require("user.tabby")
    require("user.cursor_highlight")
    require("user.telescope")
    require("mini.align").setup()
  '' + lib.optionalString (isDarwin || isCloudbox) ''
    require("user.atlassian")
  '';
};
```

### Why `withPlugins` over `withAllGrammars`

`withAllGrammars` bundles every grammar in nixpkgs, causing longer rebuilds.
`withPlugins` with a curated subset is smaller and more intentional. The list
above covers languages we actually edit.

### Treesitter API

Our nixpkgs pin (2025-05-24, commit `42fc28b`) has the **legacy**
nvim-treesitter with `configs.lua` present. The old API
`require('nvim-treesitter.configs').setup { ... }` is correct. A future
nixpkgs update may switch to the `main` branch rewrite, which uses
`vim.treesitter.start()` instead. Cross that bridge when we get there.

## Config Modules (`assets/nvim/lua/user/`)

| Module | Action | Notes |
|--------|--------|-------|
| `settings.lua` | Keep | Already in workstation, no changes |
| `mappings.lua` | Update | Remove `<leader>gg` fugitive mapping |
| `sessions.lua` | Keep | Already in workstation, no changes |
| `tabby.lua` | Keep | Already in workstation, no changes |
| `atlassian.lua` | Keep | Already in workstation, no changes |
| `cursor_highlight.lua` | **New** | Move from dotfiles |
| `telescope.lua` | **New** | Move from dotfiles, set `auto_install = false` |

### `telescope.lua` (moved + modified)

The dotfiles version includes treesitter config and telescope setup in one
file. We keep this combined structure but change `auto_install = true` to
`auto_install = false` since nix provides grammars.

## Files to Delete from Workstation Assets

| File | Reason |
|------|--------|
| `assets/nvim/lua/ccremote.lua` | No longer used |
| `assets/nvim/.gitkeep` | Directory has other files now |

## `home.base.nix` Changes

- Expand `programs.neovim.plugins` (add 7 new plugins + vim-ripgrep)
- Add `extraPackages = [ pkgs.ripgrep ]`
- Expand `extraLuaConfig` (add cursor_highlight, telescope, mini.align)
- `xdg.configFile."nvim/lua/user"` recursive deploy stays as-is

## `home.darwin.nix` Changes

Remove all neovim workarounds:

| Line(s) | What | Action |
|----------|------|--------|
| 344 | `programs.neovim.enable = lib.mkForce false` | Delete |
| 348 | `xdg.configFile."nvim/lua/user".enable = lib.mkForce false` | Delete |
| 353-355 | Individual xdg.configFile for sessions/atlassian/tabby | Delete |
| 357-362 | xdg.dataFile packpath for tabby-nvim | Delete |
| 412-416 | prepareForHM nvim cleanup lines | Delete |

Add new prepareForHM cleanup to remove dotfiles init.lua before HM
collision check:

```nix
rm -f ~/.config/nvim/init.lua 2>/dev/null || true
rm -rf ~/.config/nvim/lua/user 2>/dev/null || true
```

## Dotfiles Cleanup

Delete `~/.config/nvim` from dotfiles entirely:

```
init.lua                    # replaced by extraLuaConfig
lazy-lock.json              # no more lazy.nvim
autoload/plug.vim           # legacy vim-plug
autoload/ruby.vim           # ruby helpers
ftplugin/*.vim, *.lua       # all ftplugins dropped
lua/config/lazy.lua         # lazy.nvim bootstrap
lua/plugins/*.lua           # all lazy specs
lua/ccremote.lua            # dropped
lua/user/aichat.lua         # dropped
lua/user/difftool.lua       # dropped (disabled)
lua/user/treesitter.lua     # dropped (commented out)
lua/user/cursor_highlight.lua  # moved to workstation
lua/user/telescope.lua      # moved to workstation
lua/user/settings.lua       # workstation has its own
lua/user/mappings.lua       # workstation has its own
lua/user/sessions.lua       # already nix symlink
lua/user/atlassian.lua      # already nix symlink
lua/user/tabby.lua          # already nix symlink
```

## Validation Checklist

After migration, verify on both platforms:

```bash
# 1. Correct nvim binary
type -a nvim  # should be nix profile, not dotfiles/homebrew

# 2. Clean startup
nvim --startuptime /tmp/nvim-startup.log +q
# Check for errors in log

# 3. Plugin health
nvim -c ':checkhealth' +q

# 4. Specific features
# - Tab rename works (tabby + Gemini)
# - :Telescope find_files works
# - Treesitter highlighting works (open a .lua file)
# - :Obsess starts session tracking
# - :Goyo enters distraction-free mode
# - ga in visual mode aligns text (mini.align)
# - :Rg searches with ripgrep
# - <C-K> toggles cursor crosshair
```

## Risks

1. **PATH shadowing on Darwin**: An old nvim binary earlier in PATH would
   bypass the nix wrapper. Verify with `type -a nvim`.
2. **Treesitter API migration**: A future nixpkgs update may switch to the
   `main` branch rewrite, breaking `configs.setup()`. Watch for
   `module 'nvim-treesitter.configs' not found` after flake updates.
3. **HM init.lua collision**: The dotfiles `~/.config/nvim/init.lua` must be
   removed before the first `darwin-rebuild switch`. The prepareForHM cleanup
   handles this, but if it runs after collision check, manual removal is
   needed first.

[hm-nvim]: https://github.com/nix-community/home-manager/blob/82fb7dedaad83e5e279127a38ef410bcfac6d77c/modules/programs/neovim.nix
[research]: /tmp/research-nvim-nix-migration-answer-1.md
