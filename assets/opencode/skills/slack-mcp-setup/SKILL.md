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
  - **`slack`** — read **+ write** (can post messages and upload files)
  - **`slack-ro`** — read-**only** (cannot post or upload). Used by lgtm's read-only gather session (`opencode-launch --mcp slack-ro`).
- Both run a **pinned, nix-built** server (`localPkgs.slack-mcp-server`), **not** `npx -y slack-mcp-server@latest`. See "Why a pinned build" below.
- **Both are disabled by default** (`"enabled": false`) to keep slack tools out of normal sessions
- To use Slack: delegate to the `slack` agent, or launch with `--mcp slack` / `--mcp slack-ro`

**Why disabled by default?**
- Prevents accidental Slack API calls from main agents
- Reduces MCP server startup overhead when not needed
- Slack tools only available when explicitly enabled

> **What the tool env vars actually do (common gotcha):** the korotovsky server
> registers **all read tools by default**; each side-effecting tool is opt-in via
> its **own** env var. So if a
> session is missing the Slack *read* tools, that is **not** a server or
> token-scope problem — it is an **opencode gating/connection** issue:
> 1. the global `tools: {"slack_*": false, "slack-ro_*": false}` gate disables the
>    tools for every agent except the `slack` subagent, and
> 2. `enabled: false` means the server is never auto-connected — a session only
>    gets Slack if something runs `POST /mcp/<server>/connect` (which is what
>    `opencode-launch --mcp <server>` does).
>
> Note also that `--mcp` folds the tools into a **single prompt** (per-turn
> scope), and the in-memory connect is **lost on an opencode-serve restart**
> (no auto-reconnect while `enabled: false`). For durable interactive Slack use,
> delegate to the `@slack` subagent rather than relying on a per-turn `--mcp` fold.

### Which gate registers which tool

| Env var | Tool it registers | `slack` | `slack-ro` |
|---|---|---|---|
| (none — always on) | `channels_list`, `conversations_history`, `conversations_replies`, `conversations_search_messages`, `users_search`, … | yes | yes |
| `SLACK_MCP_ADD_MESSAGE_TOOL` | `conversations_add_message` (post) | yes | **no** |
| `SLACK_MCP_FILE_UPLOAD_TOOL` | `file_upload` (upload) | yes | **no** |
| `SLACK_MCP_ATTACHMENT_TOOL` | `attachment_get_data` (download) | yes | **yes** — download is a read |

`slack-ro`'s read-only guarantee is exactly the **absence** of the two write
gates. Adding a gate to `slack-ro` breaks lgtm's structural no-post property.

## Files

Requires `files:read` (download) and `files:write` (upload) on the app.

**Download** — `attachment_get_data`, by file ID (`Fxxxxxxxxxx`). Find IDs in the
`AttachmentIDs` field returned by `conversations_history` / `_replies` /
`_search_messages` (also `FileCount`, `HasMedia`). Text comes back as-is, binary
as base64, `image/*` as native MCP image content. **5 MB cap.**

**Upload** — `file_upload`. Required arg `channel_id` (a DM id like `D…` works).
Content from exactly one of:

- `content` — UTF-8 text (logs, snippets)
- `content_base64` — binary (e.g. a screenshot)
- `file_path` — **disabled here.** It requires `SLACK_MCP_FILE_UPLOAD_PATHS`,
  which is deliberately unset, so the MCP process gets no ambient read
  capability over local disk. Base64 the file yourself and use `content_base64`.

Optional: `thread_ts`, `title`, `filename`, `initial_comment`, `snippet_type`, `alt_txt`.

> **The server logs tool arguments at info level, including `file_upload`
> content.** Uploading a secret puts it in the MCP server's stderr as well as in
> Slack. (The PR description claims params are not logged for this tool; the
> shipped code logs them. Measured, not assumed.)

### Why a pinned build

`pkgs/slack-mcp-server` builds the Go server from a pinned upstream rev with a
vendored patch ([PR #334](https://github.com/korotovsky/slack-mcp-server/pull/334)),
because:

1. Upstream has **no upload tool** — download only. #334 adds `file_upload`.
2. `npx -y slack-mcp-server@latest` is an unpinned network fetch on every MCP
   start, for a process that holds a Slack **user** token.

The patch is vendored in-tree rather than `fetchpatch`ed: a PR's `.patch`
endpoint follows the branch and is therefore mutable.

**Upgrading:** bump `rev`/`hash` in `pkgs/slack-mcp-server/default.nix`,
re-download the patch, confirm `git apply --check` still passes. If #334 lands
upstream, delete the patch instead of carrying a merged change twice.

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
   - `files:read` (attachment download), `files:write` (file upload)
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
| `missing_scope` | App needs additional scopes. Add them in app settings, reinstall. Check what the token actually has: `curl -s -D- -o /dev/null -X POST https://slack.com/api/auth.test -H "Authorization: Bearer $(cat /run/secrets/slack_mcp_xoxp_token)" \| grep -i x-oauth-scopes` |
| `file_path is not allowed` on upload | Intentional — `SLACK_MCP_FILE_UPLOAD_PATHS` is unset. Use `content_base64`. |
| `attachment_get_data tool is disabled` | `SLACK_MCP_ATTACHMENT_TOOL` missing; re-run the home-manager switch. |
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
- `slack_attachment_get_data` - Download a file by ID (5 MB cap)
- `slack_file_upload` - Upload a file (`content` / `content_base64`; see Files above)

## References

- Repo: https://github.com/korotovsky/slack-mcp-server
- Auth docs: https://github.com/korotovsky/slack-mcp-server/blob/master/docs/01-authentication-setup.md#option-2-using-slack_mcp_xoxp_token-user-oauth
- macOS activation: `users/dev/opencode-config.nix` (`injectSlackMcpSecrets`)
- Cloudbox activation: `users/dev/opencode-config.nix` (`injectSlackMcpSecretsSops`)
- Slack agent: `assets/opencode/agents/slack.md`
- Pinned server build: `pkgs/slack-mcp-server/default.nix` (+ vendored `pr-334-file-upload.patch`)
