---
name: osc52-clipboard
description: Use when copy/paste doesn't work over SSH, or clipboard not syncing between local and remote, or setting up terminal remoting
---

# OSC 52 Clipboard Setup

## Overview

OSC 52 is an escape sequence that allows remote terminals to write to the local system clipboard over SSH.

## Requirements

1. **Local terminal** must support OSC 52
2. **tmux** must be configured to pass through
3. **neovim** must use OSC 52 provider

## Local Terminal Support

| Terminal | Support |
|----------|---------|
| WezTerm | Works out of the box |
| kitty | Works (may need `clipboard_control` config) |
| GNOME Terminal / VTE | Does NOT support OSC 52 |
| iTerm2 | Works with "Allow clipboard access" enabled |

## tmux Configuration

Enable clipboard pass-through:

```tmux
set -s set-clipboard on
```

## Neovim Configuration

In `init.lua` on the remote:

```lua
vim.g.clipboard = "osc52"
```

## Testing

1. SSH into remote
2. Run: `printf '\033]52;c;%s\a' "$(echo -n 'test' | base64)"`
3. Paste locally - should see "test"

If it doesn't work, check your local terminal settings.
