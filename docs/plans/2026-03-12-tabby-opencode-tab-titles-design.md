# Tabby + OpenCode Tab Titles

Show OpenCode session titles as nvim tab labels via tabby.nvim, with Gemini-shortened titles optimized for ~24 character display.

## Context

- One OpenCode instance per nvim tab is the primary workflow
- OpenCode sets terminal title via OSC to `"OC | {session title}"` (app.tsx:263-282)
- Neovim captures this as `b:term_title` on terminal buffers
- tabby.nvim provides a tab labeling plugin with an `override` API

## Data Flow

```
OpenCode TUI (in nvim :terminal)
  |-- sets terminal title via OSC: "OC | Debugging 500 errors"
  v
Neovim terminal emulator
  |-- captures in b:term_title
  v
tabby.nvim override function (called each tabline render)
  |-- scans tab windows for terminal buffers
  |-- matches b:term_title =~ "^OC | (.+)"
  |-- strips prefix, extracts raw title: "Debugging 500 errors"
  |-- compares to cached oc_title per tab
  |-- if changed: async Gemini call to shorten to ~24 chars
  |-- returns short_title
  v
Tab label: "Debug 500 errors"
```

## Title Resolution

| b:term_title | Tab label | Case |
|---|---|---|
| "OC \| Debugging 500 errors" | "Debug 500 errors" (Gemini-shortened) | Named session |
| "OpenCode" | "OpenCode" | Home view or unnamed session |
| "" or absent | (tabby default: buffer name) | No opencode or exited |
| (no terminal in tab) | (tabby default: buffer name) | Non-terminal tab |

## State Management

Per-tab cache: `{ [tabid] = { oc_title = string, short_title = string } }`

- Only call Gemini when `oc_title` changes (typically once per session lifetime)
- While Gemini processes, show truncated raw title as interim
- On Gemini response, update `short_title` and trigger `redrawtabline`
- Clean up stale entries when tabs close

## Gemini Integration

- Model: `gemini-2.5-flash-lite` (stable, cost-efficient)
- API: `generativelanguage.googleapis.com/v1beta/models/{model}:generateContent`
- Auth: `GOOGLE_GENERATIVE_AI_API_KEY` env var (available via sops on all platforms)
- Async via `vim.system()` curl (neovim 0.10+)
- Graceful fallback: if key missing/placeholder/call fails, truncate to 24 chars

## Periodic Refresh

A `vim.uv` timer (~3s) calls `redrawtabline` to ensure the override picks up `b:term_title` changes that happen asynchronously (e.g., OpenCode auto-naming after first message).

## Files

| File | Purpose |
|---|---|
| `assets/nvim/lua/user/tabby.lua` | Plugin config, override logic, Gemini shortening |
| `users/dev/home.base.nix` | Add tabby-nvim plugin + require (Linux) |
| `users/dev/home.darwin.nix` | Pattern 2 plugin install + Pattern 1 lua deploy |

## Cross-Platform Deployment

| Platform | Plugin | Lua config |
|---|---|---|
| Devbox/Cloudbox/Crostini | `programs.neovim.plugins` | `extraLuaConfig` require + `xdg.configFile` recursive |
| Darwin | `xdg.dataFile` to packpath | `xdg.configFile` single file (Pattern 1) |

On Darwin, tabby-nvim installs to `~/.local/share/nvim/site/pack/nix/start/tabby-nvim` and auto-loads. No dotfiles plugin manager changes needed.
