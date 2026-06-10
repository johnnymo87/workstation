---
name: rollbar-mcp-setup
description: Use when setting up or rotating Rollbar MCP auth for OpenCode on macOS Keychain or cloudbox sops, when triaging a Rollbar error paged via PagerDuty, or when debugging missing Rollbar tools.
---

# Rollbar MCP Setup

Uses Rollbar's official local MCP server (`@rollbar/mcp-server`, stdio) with a
Rollbar **project access token**. The workstation wrapper is Nix-managed, pins
the server version, injects the token from platform secret storage, and is
disabled by default.

| Platform | Token storage | Injection trigger |
|----------|---------------|-------------------|
| macOS | Keychain | `darwin-rebuild switch` |
| cloudbox | sops (`/run/secrets/`) | `nixos-rebuild switch` + `home-manager switch` |

## Architecture

- `users/dev/opencode-config.nix` injects `.mcp.rollbar` into `~/.config/opencode/opencode.json` after `mergeOpencode`.
- The MCP command points at a Nix `writeShellApplication` wrapper with `pkgs.nodejs` in `runtimeInputs`; the wrapper runs `npx -y '@rollbar/mcp-server@0.5.0'`.
- The MCP is `enabled: false` by default to avoid normal-session startup cost and accidental Rollbar calls.
- If the token is missing, activation deletes `.mcp.rollbar` so stale credentials do not linger.
- First run downloads the npm package into `~/.npm`; subsequent runs are cached. The wrapper needs outbound network on first use.

## Get A Token

Per Rollbar's docs (https://docs.rollbar.com/docs/access-tokens), project access
tokens live in **Project -> Settings -> Project Access Tokens**. Each project has
its own set; new projects start with four tokens, one per scope:

| Scope | Use |
|-------|-----|
| `read` | All GET requests — this is what the MCP read tools need |
| `write` | PATCH/DELETE — only needed for `update-item` |
| `post_server_item` | Sending events / source maps (not used here) |
| `post_client_item` | Client-side event sending (not used here) |

Steps:

1. Open Rollbar -> select the project -> Settings -> Project Access Tokens.
2. Use the existing `read`-scoped token, or create a new token with `read` scope
   (add `write` only if you want `update-item` to resolve/assign from the agent).
3. Copy it.

> Note: since April 2025, **newly created tokens are encrypted and shown only
> once at creation** — copy it immediately, you cannot view it again in the UI or
> API afterward. Existing pre-2025 tokens remain visible.

Do not commit account names, project names, project counters, or token values.

## macOS Setup

Store the token in Keychain:

```bash
security add-generic-password -a "$USER" -s rollbar-access-token -w "ROLLBAR_PROJECT_READ_TOKEN" -U
```

Apply:

```bash
sudo darwin-rebuild switch --flake ~/Code/workstation#Y0FMQX93RR-2
```

Verify without printing the token:

```bash
jq '{type:.mcp.rollbar.type, command:.mcp.rollbar.command, enabled:.mcp.rollbar.enabled, hasToken:(.mcp.rollbar.environment.ROLLBAR_ACCESS_TOKEN | type == "string" and length > 0)}' ~/.config/opencode/opencode.json
```

## Cloudbox Setup

Store the token in sops. If the token is in `/tmp/rollbar-token`, use this form so
the token is not printed:

```bash
/run/wrappers/bin/sudo nix-shell -p sops -p jq --run 'token_json=$(jq -Rs . /tmp/rollbar-token); SOPS_AGE_KEY_FILE=/var/lib/sops-age-key.txt sops set secrets/cloudbox.yaml "[\"rollbar_access_token\"]" "$token_json"; unset token_json'
rm -f /tmp/rollbar-token
```

Apply:

```bash
cd ~/projects/workstation
sudo nixos-rebuild switch --flake .#cloudbox
nix run home-manager -- switch --flake .#cloudbox
```

Verify without printing the token:

```bash
test -s /run/secrets/rollbar_access_token
jq '{type:.mcp.rollbar.type, command:.mcp.rollbar.command, enabled:.mcp.rollbar.enabled, hasToken:(.mcp.rollbar.environment.ROLLBAR_ACCESS_TOKEN | type == "string" and length > 0)}' ~/.config/opencode/opencode.json
```

## Using Rollbar

Enable temporarily, then restart OpenCode:

```bash
(umask 0077; jq '.mcp.rollbar.enabled = true' ~/.config/opencode/opencode.json > /tmp/oc.json) && mv /tmp/oc.json ~/.config/opencode/opencode.json
```

Disable after use:

```bash
(umask 0077; jq '.mcp.rollbar.enabled = false' ~/.config/opencode/opencode.json > /tmp/oc.json) && mv /tmp/oc.json ~/.config/opencode/opencode.json
```

OpenCode reads config at startup. Quit and restart OpenCode after changing MCP
enablement or after applying new secrets.

## Tools

The server exposes (verified against `@rollbar/mcp-server` v0.5.0):

| Tool | Purpose |
|------|---------|
| `get-item-details(counter, max_tokens?, project?)` | Given an item number, fetch item details + last occurrence (stack trace). Built-in truncation (default 20k tokens). The core triage tool. |
| `list-items(status?, level?, environment?, page?, limit?, query?, project?)` | List/search items by status, level, environment, query. |
| `get-top-items(environment, project?)` | Top items in the last 24h for an environment. |
| `get-deployments(limit, project?)` | List deploys — correlate an error with a recent deploy. |
| `get-version(version, environment, project?)` | Version details for a version string + environment. |
| `get-replay(environment, sessionId, replayId, delivery?, project?)` | Session replay metadata/payload. |
| `list-projects()` | List configured projects (names only, never tokens). |
| `update-item(itemId, status?, level?, ...)` | Mutate an item (resolve/assign/etc.). **Requires `write` scope.** |

Single project uses `ROLLBAR_ACCESS_TOKEN`. For multiple projects, the server
also supports a `.rollbar-mcp.json` config file (or `ROLLBAR_CONFIG_FILE`); the
workstation wrapper currently wires the single-token env var only.

## Paged-About-Rollbar Triage Flow

This MCP is the Rollbar half of the on-call flow; PagerDuty is the other half
(see `pagerduty-mcp-setup`). Enable both, restart OpenCode, then:

1. **PagerDuty:** `get_incident` / `list_alerts_from_incident` for the paging
   incident.
2. **Extract the Rollbar link** from the alert body. It usually lands in
   `body.cef_details.client_url` or a links/contexts array. Robustly, scan all
   URL-ish fields for `rollbar.com`. The link looks like
   `https://rollbar.com/{account}/{project}/items/{counter}/`. The trailing
   number is the **project counter** (not the global item id).
3. **Rollbar:** `get-item-details(counter=<that number>)` -> stack trace, last
   occurrence, frequency. `get-deployments` to check for a correlated deploy.

Equivalent raw curl (extract the link from PagerDuty):

```bash
curl -s "https://api.pagerduty.com/incidents/$INCIDENT_ID/alerts" \
  -H "Authorization: Token token=$PD_TOKEN" \
  -H "Accept: application/vnd.pagerduty+json;version=2" \
| jq -r '.. | strings | select(test("rollbar\\.com"))' | sort -u
```

## Rotation

Rotate when the token is revoked, compromised, no longer has needed permissions,
or per your Rollbar access policy.

1. Create or regenerate a `read`-scoped Rollbar project access token.
2. Store it using the macOS or cloudbox setup command above.
3. Apply the platform config.
4. Restart OpenCode.
5. Disable/expire the old token in Rollbar after the new one is verified.

## Troubleshooting

| Symptom | Check |
|---------|-------|
| No `.mcp.rollbar` entry | Token missing from Keychain or sops; re-store and re-apply. |
| MCP status is failed | Run the generated command from `.mcp.rollbar.command` manually; check `npx`/network errors and that node can reach the npm registry. |
| Rollbar returns unauthorized | Token revoked, copied incorrectly, lacks `read` scope, or belongs to a different project. Rotate it. |
| `update-item` fails with permission error | Token lacks `write` scope; the default read token is intentionally read-only. |
| `sudo must be owned by uid 0` | In OpenCode bash on cloudbox, use `/run/wrappers/bin/sudo` for the sops command. |
| Wrong project's items | Token is project-scoped. Use the token for the project the error lives in, or wire multi-project config. |

## References

- Rollbar MCP server: https://github.com/rollbar/rollbar-mcp-server
- npm package: https://www.npmjs.com/package/@rollbar/mcp-server
- Rollbar MCP setup docs: https://docs.rollbar.com/docs/mcp-server-setup
- Access tokens (scopes, where to find them): https://docs.rollbar.com/docs/access-tokens
- REST API getting started: https://docs.rollbar.com/reference/getting-started-1
- OpenCode activation: `users/dev/opencode-config.nix` (`injectRollbarMcpSecrets`, `injectRollbarMcpSecretsSops`)
- PagerDuty half of the flow: `pagerduty-mcp-setup`
