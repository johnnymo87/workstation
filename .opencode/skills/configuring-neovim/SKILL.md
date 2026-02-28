# Testing and Debugging Neovim Config

Patterns for safely testing nvim configuration changes in this repo. For adding new config files, see [growing-nvim-config](../growing-nvim-config/SKILL.md).

## Architecture

```
assets/nvim/lua/user/*.lua    (source of truth in this repo)
        |
        v  home-manager switch
~/.config/nvim/lua/user/*.lua (deployed)
        |
        v  require("user.xxx") in extraLuaConfig
nvim loads at startup
```

Changes go to `assets/nvim/lua/user/`. They only take effect after `home-manager switch` (devbox) or `darwin-rebuild switch` (macOS).

## Core Technique: Headless Testing

Always test headlessly before deploying. This catches Lua errors immediately.

### Test the deployed config

```bash
# Quick smoke test (loads full config)
nvim --headless -c "quit" 2>&1

# Verify specific module loads
nvim --headless -c "lua print('atlassian:', require('user.atlassian') ~= nil)" -c "quit" 2>&1
```

### Test workstation assets before deploying

Load directly from the repo instead of the deployed location:

```bash
# Test a modified file without running home-manager switch
nvim --headless -u NONE \
  -c "lua package.path = '/path/to/workstation/assets/nvim/lua/?.lua;' .. package.path" \
  -c "lua local ok, err = pcall(require, 'user.atlassian'); if ok then print('OK') else print('ERROR: ' .. err) end" \
  -c "quit" 2>&1
```

### Test specific functionality

```bash
# Test HTML-to-markdown conversion (used by atlassian.lua)
nvim --headless -u NONE \
  -c "lua local r = vim.fn.system({'pandoc', '-f', 'html', '-t', 'gfm', '--wrap=none'}, '<h1>Test</h1><p>Hello</p>'); print(r)" \
  -c "quit" 2>&1

# Test with delay for async operations (LSP, network)
nvim --headless -c "sleep 2" -c "quit" 2>&1

# Profile startup time
nvim --startuptime /tmp/startup.log -c "quit" && tail -20 /tmp/startup.log
```

## Workflow

1. Edit files in `assets/nvim/lua/user/`
2. Test headlessly against the assets path (no deploy needed)
3. Fix any errors
4. Deploy: `home-manager switch --flake .#dev` or `darwin-rebuild switch`
5. Test headlessly against deployed config
6. Verify in a real nvim session

## Current Modules

| Module | Platforms | Purpose |
|--------|-----------|---------|
| `settings.lua` | all | Editor settings (clipboard, leader, display) |
| `mappings.lua` | all | Key mappings (terminal escape, whitespace strip) |
| `sessions.lua` | all | Auto-start vim-obsession for tmux-resurrect |
| `atlassian.lua` | macOS, cloudbox | `:FetchJiraTicket`, `:FetchConfluencePage` |

Platform gating: `atlassian.lua` is only `require()`d on Darwin and cloudbox (see `home.base.nix` `extraLuaConfig`).

## Troubleshooting

### Module not found after editing

The deployed files at `~/.config/nvim/lua/user/` are copies, not symlinks. Run `home-manager switch` to pick up changes.

### Error in pcall output

The error string from `pcall` includes file path and line number. Read that line in the `assets/` source.

### Test in clean environment

```bash
# No config at all
nvim -u NONE

# Minimal config
echo "vim.opt.number = true" > /tmp/minimal.lua
nvim -u /tmp/minimal.lua
```

## Dependencies

External tools used by nvim modules:

| Tool | Used by | Installed via |
|------|---------|---------------|
| `pandoc` | `atlassian.lua` | `pkgs.pandoc` in `home.base.nix` |
| `curl` | `atlassian.lua` | system |
| `jq` | `atlassian.lua` | system |
