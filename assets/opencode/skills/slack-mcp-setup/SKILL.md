---
name: slack-mcp-setup
description: Set up Slack MCP server with token storage. Use for initial setup or when tokens expire (invalid_auth error). Covers macOS (Keychain) and cloudbox (sops).
---

# Slack MCP Setup

Slack MCP tokens are stored securely per-platform and injected into OpenCode config at activation time.

| Platform | Token storage | Injection trigger |
|----------|--------------|-------------------|
| macOS | Keychain | `darwin-rebuild switch` |
| cloudbox | sops (`/run/secrets/`) | `nixos-rebuild switch` + `home-manager switch` |

## Architecture

- **Slack MCP** is injected into opencode.json with tokens from Keychain (macOS) or sops (cloudbox)
- **MCP is disabled by default** (`"enabled": false`) to keep slack tools out of normal sessions
- To use Slack: manually enable the MCP, or delegate to the `slack` agent

**Why disabled by default?**
- Prevents accidental Slack API calls from main agents
- Reduces MCP server startup overhead when not needed
- Slack tools only available when explicitly enabled

## Getting Tokens from Slack

Open Slack in a web browser (https://app.slack.com or Okta tile). Must be in web client (URL like `app.slack.com/client/T.../...`).

### Get XOXC Token

1. Open DevTools (Cmd+Option+I or F12)
2. Go to **Console** tab
3. Type `allow pasting` and press Enter
4. Run:
```javascript
JSON.parse(localStorage.localConfig_v2).teams[document.location.pathname.match(/^\/client\/([A-Z0-9]+)/)[1]].token
```
5. Copy the `xoxc-...` token

### Get XOXD Token

1. In DevTools, go to **Application** tab (Chrome) or **Storage** tab (Firefox)
2. Expand **Cookies** -> click Slack domain
3. Find cookie named **`d`** (single letter)
4. Double-click its Value, copy the `xoxd-...` value

**Firefox users**: Decode URL-encoded characters:
- `%2F` -> `/`
- `%2B` -> `+`

## macOS Setup

### Store tokens

```bash
security add-generic-password -a "$USER" -s slack-mcp-xoxc-token -w "xoxc-YOUR-TOKEN" -U
security add-generic-password -a "$USER" -s slack-mcp-xoxd-token -w "xoxd-YOUR-TOKEN" -U
```

The `-U` flag updates if the item already exists.

### Apply

```bash
darwin-rebuild switch --flake .#$(hostname -s)
```

## Cloudbox Setup

### Store tokens in sops

From your local machine (needs the cloudbox age private key):

```bash
SOPS_AGE_KEY="<cloudbox-age-private-key>" sops --set '["slack_mcp_xoxc_token"] "xoxc-YOUR-TOKEN"' secrets/cloudbox.yaml
SOPS_AGE_KEY="<cloudbox-age-private-key>" sops --set '["slack_mcp_xoxd_token"] "xoxd-YOUR-TOKEN"' secrets/cloudbox.yaml
```

Or from cloudbox itself:

```bash
sudo cat /var/lib/sops-age-key.txt > /tmp/sops-age-key.txt
SOPS_AGE_KEY_FILE=/tmp/sops-age-key.txt sops --set '["slack_mcp_xoxc_token"] "xoxc-YOUR-TOKEN"' ~/projects/workstation/secrets/cloudbox.yaml
SOPS_AGE_KEY_FILE=/tmp/sops-age-key.txt sops --set '["slack_mcp_xoxd_token"] "xoxd-YOUR-TOKEN"' ~/projects/workstation/secrets/cloudbox.yaml
rm /tmp/sops-age-key.txt
```

### Apply

Commit and push the updated secrets file, then on cloudbox:

```bash
cd ~/projects/workstation && git pull
sudo nixos-rebuild switch --flake .#cloudbox    # Deploys sops secrets
nix run home-manager -- switch --flake .#cloudbox  # Injects into opencode.json
```

## Verify (both platforms)

```bash
jq '.mcp.slack' ~/.config/opencode/opencode.json
# Should show type, command, enabled: false, and environment with tokens
```

## Token Refresh

When you see `invalid_auth` errors, tokens have expired.

1. Get new tokens from Slack (see "Getting Tokens" above)
2. Store them (platform-specific, see above)
3. Apply configuration (platform-specific, see above)
4. Restart OpenCode

## Troubleshooting

| Error | Solution |
|-------|----------|
| `invalid_auth` | Tokens expired. Refresh tokens (see above). |
| `cache not ready` | Wait for sync to complete. Large workspaces take 5-10 min. |
| Logged out of Slack | One-time fraud protection. Re-extract tokens. |
| No Slack config after switch | macOS: check `security find-generic-password -s slack-mcp-xoxc-token`. Cloudbox: check `cat /run/secrets/slack_mcp_xoxc_token`. |

## Using Slack

### Option 1: Enable MCP temporarily

```bash
jq '.mcp.slack.enabled = true' ~/.config/opencode/opencode.json > /tmp/oc.json && mv /tmp/oc.json ~/.config/opencode/opencode.json
# Restart OpenCode, use slack tools
# Disable when done:
jq '.mcp.slack.enabled = false' ~/.config/opencode/opencode.json > /tmp/oc.json && mv /tmp/oc.json ~/.config/opencode/opencode.json
```

### Option 2: Delegate to slack agent

The slack agent enables the MCP automatically. Use it from OpenCode.

**Available tools:**
- `slack_channels_list` - List channels
- `slack_conversations_history` - Get channel messages
- `slack_conversations_replies` - Get thread replies
- `slack_conversations_search_messages` - Search messages with filters
- `slack_conversations_add_message` - Post messages (use carefully)

## References

- Repo: https://github.com/korotovsky/slack-mcp-server
- Auth docs: https://github.com/korotovsky/slack-mcp-server/blob/master/docs/01-authentication-setup.md
- macOS activation: `users/dev/opencode-config.nix` (`injectSlackMcpSecrets`)
- Cloudbox activation: `users/dev/opencode-config.nix` (`injectSlackMcpSecretsSops`)
- Slack agent: `assets/opencode/agents/slack.md`
