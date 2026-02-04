---
name: slack-mcp-setup
description: Set up Slack MCP server with macOS Keychain token storage. Use for initial setup or when tokens expire (invalid_auth error).
---

# Slack MCP Setup (macOS Keychain)

This workstation uses macOS Keychain to store Slack MCP tokens securely. Tokens are fetched at `darwin-rebuild switch` time and injected into OpenCode config.

## Initial Setup

### 1. Get Tokens from Slack

Open Slack in a web browser (https://app.slack.com or Okta tile). Must be in web client (URL like `app.slack.com/client/T.../...`).

#### Get XOXC Token

1. Open DevTools (Cmd+Option+I or F12)
2. Go to **Console** tab
3. Type `allow pasting` and press Enter
4. Run:
```javascript
JSON.parse(localStorage.localConfig_v2).teams[document.location.pathname.match(/^\/client\/([A-Z0-9]+)/)[1]].token
```
5. Copy the `xoxc-...` token

#### Get XOXD Token

1. In DevTools, go to **Application** tab (Chrome) or **Storage** tab (Firefox)
2. Expand **Cookies** → click Slack domain
3. Find cookie named **`d`** (single letter)
4. Double-click its Value, copy the `xoxd-...` value

**Firefox users**: Decode URL-encoded characters:
- `%2F` → `/`
- `%2B` → `+`

### 2. Store Tokens in Keychain

```bash
# Add XOXC token
security add-generic-password -a "$USER" -s slack-mcp-xoxc-token -w "xoxc-YOUR-TOKEN-HERE" -U

# Add XOXD token
security add-generic-password -a "$USER" -s slack-mcp-xoxd-token -w "xoxd-YOUR-TOKEN-HERE" -U
```

The `-U` flag updates if the item already exists.

### 3. Apply Configuration

```bash
darwin-rebuild switch --flake .#$(hostname -s)
```

The activation script will:
- Fetch tokens from Keychain
- Inject Slack MCP config into `~/.config/opencode/opencode.json`
- If tokens missing: delete any existing Slack config and warn

### 4. Verify

```bash
# Check config was created
jq '.mcpServers.slack' ~/.config/opencode/opencode.json

# Should show:
# {
#   "command": "npx",
#   "args": ["-y", "slack-mcp-server@latest", "--transport", "stdio"],
#   "env": {
#     "SLACK_MCP_XOXC_TOKEN": "xoxc-...",
#     "SLACK_MCP_XOXD_TOKEN": "xoxd-...",
#     "SLACK_MCP_CUSTOM_TLS": "1",
#     "SLACK_MCP_USER_AGENT": "Mozilla/5.0..."
#   },
#   "type": "stdio"
# }
```

### 5. Restart OpenCode

Restart OpenCode to load the new MCP server. First use triggers cache build (takes several minutes for large workspaces).

## Token Refresh

When you see `invalid_auth` errors, tokens have expired. Refresh them:

1. Get new tokens from Slack (see "Get Tokens from Slack" above)
2. Update Keychain:
```bash
security add-generic-password -a "$USER" -s slack-mcp-xoxc-token -w "NEW-XOXC-TOKEN" -U
security add-generic-password -a "$USER" -s slack-mcp-xoxd-token -w "NEW-XOXD-TOKEN" -U
```
3. Re-run: `darwin-rebuild switch --flake .#$(hostname -s)`
4. Restart OpenCode

## Troubleshooting

| Error | Solution |
|-------|----------|
| `invalid_auth` | Tokens expired. Refresh tokens (see above). |
| `cache not ready` | Wait for sync to complete. Large workspaces take 5-10 min. |
| Logged out of Slack | One-time fraud protection. Re-extract tokens. |
| No Slack config after switch | Check Keychain has both tokens: `security find-generic-password -s slack-mcp-xoxc-token` |

## Cache Files

Slack MCP creates cache files in working directory:

```
~/Library/Caches/slack-mcp-server/users_cache.json
~/Library/Caches/slack-mcp-server/channels_cache_v2.json
```

**Gitignore recommendation**: Add `.*.json` to `.gitignore` in repos where you use Slack MCP to avoid committing cache files.

## References

- Repo: https://github.com/korotovsky/slack-mcp-server
- Auth docs: https://github.com/korotovsky/slack-mcp-server/blob/master/docs/01-authentication-setup.md
- Activation script: `users/dev/opencode-config.nix` (home.activation.injectSlackMcpSecrets)
