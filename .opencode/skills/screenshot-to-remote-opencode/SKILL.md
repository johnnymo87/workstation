---
name: screenshot-to-remote-opencode
description: Use when you need to share a screenshot with OpenCode running on a remote NixOS host (devbox or cloudbox) over SSH, since Ctrl+V image paste doesn't work remotely
---

# Screenshot to Remote OpenCode

## Overview

OpenCode supports pasting images from the clipboard with Ctrl+V, but this
only works when the agent can access the local OS clipboard. Over SSH, the
remote opencode process can't see your Mac's clipboard.

**Solution:** Take a screenshot locally, upload it to the remote NixOS host
(devbox or cloudbox), and reference the path. The `screenshot-to-devbox`
helper script is named for historical reasons but the mechanism is generic
to any remote SSH'd opencode session. The remote upload directory
(`~/.cache/claude-images/`) is also a historical name -- nothing reads
it that requires that exact path; renaming would just churn the script
and existing remote contents.

## Usage

From your Mac terminal (not inside SSH):

```bash
screenshot-to-devbox
```

Or use the alias:

```bash
ssdb
```

This will:
1. Open macOS screenshot selection (crosshairs)
2. Upload the selection to `~/.cache/claude-images/` on devbox
3. Copy the remote path to your clipboard

Then in your SSH'd opencode session:
```
Analyze this image: /home/dev/.cache/claude-images/screenshot-20240115-143022-12345-67890.png
```

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `DEVBOX_HOST` | `devbox` | SSH host alias |
| `SCREENSHOT_REMOTE_DIR` | `~/.cache/claude-images` | Remote directory for uploads (historical name) |

## How It Works

The script:
1. Uses `screencapture -i -x` to capture a selection silently
2. Generates a unique filename with timestamp and PID
3. Creates the remote directory with 700 permissions
4. Uploads via `scp` and sets 600 permissions on the file
5. Copies the remote path to clipboard via `pbcopy`

## Troubleshooting

**"Screenshot cancelled"**: You pressed Escape or clicked outside the selection. This is expected behavior.

**SSH connection fails**: Ensure your `devbox` host alias is configured in `~/.ssh/config` and SSH keys are set up.

**Permission denied on remote**: The script creates directories with `umask 077` and files with 600 permissions. If the parent directory has issues, check `~/.cache` permissions.

## Why Not Just Use iTerm2's it2ul?

iTerm2's `it2ul` upload tool can be flaky inside tmux (proprietary escape sequences don't always pass through cleanly for large files). This script uses standard `scp` which works reliably through any tmux session.

## Related

- [Clipboard (gclpr & OSC 52)](../clipboard/SKILL.md) - Text copy/paste over mosh/SSH
