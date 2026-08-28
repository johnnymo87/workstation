---
name: slack-mcp-setup
description: Set up Slack MCP server with xoxp User OAuth token. Use for initial setup or token rotation. Covers macOS (Keychain) and cloudbox (sops).
---

# Slack MCP Setup

Uses a registered Slack app with User OAuth (`xoxp-*` token) for stable authentication.
No browser cookie scraping -- tokens don't expire unless revoked.

| Platform | Token storage | Injection trigger |
|----------|--------------|-------------------|
| macOS | Keychain | `darwin-rebuild switch` |
| cloudbox | sops (`/run/secrets/`) | `nixos-rebuild switch` + `home-manager switch` |

## Architecture

- **Slack MCP** is injected into opencode.json with the xoxp token from Keychain (macOS) or sops (cloudbox)
- Two server variants are injected:
  - **`slack`** — read **+ write** (`SLACK_MCP_ADD_MESSAGE_TOOL=true`, so the post-message tool is registered)
  - **`slack-ro`** — read-**only** (omits `SLACK_MCP_ADD_MESSAGE_TOOL`, so only read tools register; cannot post). Used by lgtm's read-only gather session (`opencode-launch --mcp slack-ro`).
- **Both are disabled by default** (`"enabled": false`) to keep slack tools out of normal sessions
- To use Slack: delegate to the `slack` agent, or launch with `--mcp slack` / `--mcp slack-ro`

**Why disabled by default?**
- Prevents accidental Slack API calls from main agents
- Reduces MCP server startup overhead when not needed
- Slack tools only available when explicitly enabled

> **What `SLACK_MCP_ADD_MESSAGE_TOOL` actually does (common gotcha):** it enables
> the **write** tool (`conversations_add_message`) **only**. The korotovsky server
> registers **all read tools by default** regardless of this env var. So if a
> session is missing the Slack *read* tools, that is **not** a server or
> token-scope problem — it is an **opencode gating/connection** issue:
> 1. the global `tools: {"slack_*": false, "slack-ro_*": false}` gate denies the
>    tools for any session without a matching `slack_*` **allow** rule in its own
>    `session.permission`, and
> 2. `enabled: false` means the server is never auto-connected at instance boot —
>    a session only gets Slack if something runs `POST /mcp/<server>/connect`
>    (`opencode-launch --mcp <server>` at launch, `oc-mcp-enable` after).
>
> The in-memory connect is still **lost on an opencode-serve restart** (or any
> instance dispose), but for Slack that no longer means re-enabling by hand: the
> `mcp-autoconnect` plugin reconnects any *gated* server the session holds a
> durable `<name>_*` allow grant for, at the start of the next turn. Slack is
> gated (that is what the `tools` map above does), so it qualifies; an ungated
> server such as `atlassian` does not. See
> `docs/plans/2026-08-28-mcp-grant-liveness.md`. The permission grant itself is
> persistent — `opencode-launch --mcp` and `oc-mcp-enable` both write it into
> `session.permission`, which is a SQLite row, not per-turn state.

## Getting the xoxp Token

### Prerequisites

You need a registered Slack app with User OAuth scopes. If you don't have one:

1. Go to [api.slack.com/apps](https://api.slack.com/apps) and create a new app (or use an existing one)
2. Under **OAuth & Permissions**, add these User Token Scopes:
   - `channels:history`, `channels:read`
   - `groups:history`, `groups:read`
   - `im:history`, `im:read`, `im:write`
   - `mpim:history`, `mpim:read`, `mpim:write`
   - `users:read`
   - `chat:write`
   - `search:read`
   - `usergroups:read`, `usergroups:write`
3. Get the app approved by a workspace admin
4. **Install the app** to your workspace

### Copy the token

1. Go to your app's page at [api.slack.com/apps](https://api.slack.com/apps)
2. Click **OAuth & Permissions**
3. Copy the **User OAuth Token** (starts with `xoxp-`)

## macOS Setup

### Store token

```bash
security add-generic-password -a "$USER" -s slack-mcp-xoxp-token -w "xoxp-YOUR-TOKEN" -U
```

The `-U` flag updates if the item already exists.

### Apply

```bash
sudo darwin-rebuild switch --flake ~/Code/workstation#Y0FMQX93RR-2
```

## Cloudbox Setup

### Store token in sops

From cloudbox:

```bash
sudo nix-shell -p sops --run "SOPS_AGE_KEY_FILE=/var/lib/sops-age-key.txt sops set secrets/cloudbox.yaml '[\"slack_mcp_xoxp_token\"]' '\"xoxp-YOUR-TOKEN\"'"
```

### Apply

Commit and push the updated secrets file, then on cloudbox:

```bash
cd ~/projects/workstation && git pull
sudo nixos-rebuild switch --flake .#cloudbox          # Deploys sops secrets
nix run home-manager -- switch --flake .#cloudbox     # Injects into opencode.json
```

## Verify (both platforms)

```bash
jq '{slack: .mcp.slack, "slack-ro": .mcp."slack-ro"}' ~/.config/opencode/opencode.json
# Both should show type, command, enabled: false, and environment with SLACK_MCP_XOXP_TOKEN.
# slack also has SLACK_MCP_ADD_MESSAGE_TOOL: "true"; slack-ro must NOT (read-only).
```

## Token Refresh

xoxp tokens from registered apps don't expire on their own. You only need to re-issue if:
- The app is uninstalled/reinstalled
- The token is explicitly revoked
- The app's scopes change (requires reinstall)

If you do need to refresh:
1. Go to [api.slack.com/apps](https://api.slack.com/apps) -> your app -> **OAuth & Permissions**
2. Copy the new User OAuth Token
3. Store it (platform-specific, see above)
4. Apply configuration (platform-specific, see above)
5. Restart OpenCode

## Troubleshooting

| Error | Solution |
|-------|----------|
| `invalid_auth` | Token revoked or app uninstalled. Get new token from app OAuth page. |
| `missing_scope` | App needs additional scopes. Add them in app settings, reinstall. |
| `not_authed` | Token not injected. Check Keychain/sops storage, re-apply config. |
| No Slack config after switch | macOS: `security find-generic-password -s slack-mcp-xoxp-token`. Cloudbox: `cat /run/secrets/slack_mcp_xoxp_token`. |

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
- Auth docs: https://github.com/korotovsky/slack-mcp-server/blob/master/docs/01-authentication-setup.md#option-2-using-slack_mcp_xoxp_token-user-oauth
- macOS activation: `users/dev/opencode-config.nix` (`injectSlackMcpSecrets`)
- Cloudbox activation: `users/dev/opencode-config.nix` (`injectSlackMcpSecretsSops`)
- Slack agent: `assets/opencode/agents/slack.md`
