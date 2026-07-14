---
name: atlassian-multi-instance
description: How the Atlassian instance is configured across macOS and cloudbox. Use when adding, removing, or debugging Atlassian instance profiles.
---

# Atlassian Instance Configuration

A single Atlassian instance (`default`) is configured across macOS and cloudbox. Credentials are stored under generic key names so org-identifying info stays out of version control. The setup is written so a second instance can be added later without restructuring (see "Adding a Second Instance").

## Architecture

```
Credentials (Keychain / sops)
        |
        v
Shell startup loads ATLASSIAN_* (site/email/cloud-id/api-token)
        |
        v
nvim (FetchJiraTicket/FetchConfluencePage) uses ATLASSIAN_* env vars

MCP server (separate path):
  atlassian  -->  wrapper reads site from Keychain/sops  -->  --resource https://{site}/ :3334
```

## Credential Storage

| Profile | macOS Keychain service | cloudbox sops key |
|---------|----------------------|-------------------|
| default | `atlassian-site` | `atlassian_site` |
| default | `atlassian-email` | `atlassian_email` |
| default | `atlassian-cloud-id` | `atlassian_cloud_id` |
| default | `atlassian-api-token` | `atlassian_api_token` |

## Files

| File | What it does |
|------|-------------|
| `users/dev/home.darwin.nix` | Loads default credentials from Keychain |
| `users/dev/home.cloudbox.nix` | Loads default credentials from sops |
| `users/dev/opencode-config.nix` | `mkAtlassianMcp` helper, one MCP server entry |
| `hosts/cloudbox/configuration.nix` | sops.secrets declarations for the 4 Atlassian keys |
| `secrets/cloudbox.yaml` | Encrypted secret values |
| `scripts/update-ssh-config.sh` | SSH tunnel for port 3334 (MCP OAuth callback) |

## Adding a Second Instance

If a second Atlassian account is needed again, add a generic profile name (e.g. `alt`) and wire it in parallel to `default`:

1. Choose a profile name (e.g., `alt`) -- keep it generic
2. Add 4 Keychain entries: `atlassian-alt-{site,email,cloud-id,api-token}`
3. Add 4 sops secrets: `atlassian_alt_{site,email,cloud_id,api_token}`
4. Declare secrets in `hosts/cloudbox/configuration.nix`
5. Load env vars in `home.darwin.nix` and `home.cloudbox.nix`, plus a `switch-atlassian`
   bash function that swaps `ATLASSIAN_SITE/EMAIL/CLOUD_ID/API_TOKEN` between profiles
   (stash the default values into `ATLASSIAN_DEFAULT_*` at load time for round-tripping)
6. Map the new sops keys in `assets/opencode/plugins/shell-env.ts`
7. Add a second `mkAtlassianMcp` call in `opencode-config.nix` with a new port (e.g. 3335)
8. Forward the new port in `scripts/update-ssh-config.sh`

## MCP Wrapper Pattern

The `mkAtlassianMcp` helper in `opencode-config.nix` generates `writeShellApplication` wrappers that read the site URL at runtime:

```nix
atlassian-mcp = mkAtlassianMcp {
  name = "atlassian-mcp";
  port = 3334;
  keychainService = "atlassian-site";
  sopsSecret = "atlassian_site";
};
```

This keeps org-identifying URLs out of the generated `opencode.managed.json`. The wrapper uses `--resource` to isolate the OAuth session, so additional instances can run simultaneously if added.

**Arg ordering matters:** `mcp-remote` parses positional args as `<url> [port] [flags...]`. The callback port MUST come before `--resource`:
```bash
# Correct: port as args[1]
npx -y mcp-remote@0.1.38 https://mcp.atlassian.com/v1/mcp/authv2 3334 --resource "https://${SITE}/"

# Wrong: --resource as args[1], port is never parsed
npx -y mcp-remote https://mcp.atlassian.com/v1/mcp/authv2 --resource "https://${SITE}/" 3334
```

## OAuth Token Cache

`mcp-remote` stores OAuth tokens in `~/.mcp-auth/mcp-remote-${version}/`. Cache is keyed by a hash of the server URL + resource + headers.

**Version-scoped invalidation:** When `mcp-remote` upgrades (e.g., 0.1.37 → 0.1.38), the cache directory name changes and all cached tokens are lost. Pin the version in the wrapper (`mcp-remote@0.1.38`) to prevent `npx -y` from auto-upgrading.

## Troubleshooting MCP "Failed" Status

If toggling an MCP on in OpenCode shows "Failed":

1. **Check the wrapper runs:** Run the nix store path directly (find it in `~/.config/opencode/opencode.json` under `mcp.<name>.command`)
2. **Check secrets exist:** `cat /run/secrets/atlassian_site` (Linux) or Keychain lookup (macOS)
3. **Check OAuth tokens:** `ls ~/.mcp-auth/mcp-remote-*/` -- look for `*_tokens.json`
4. **Re-auth if needed:** Run the wrapper manually, it prints an OAuth URL. Open in browser while SSH tunnel forwards the callback port (3334). The callback URL `localhost:3334/oauth/callback?code=...` tunnels back to the server.

## Re-authenticating OAuth (Headless Server)

When tokens expire or cache is invalidated:

```bash
# 1. Ensure SSH tunnel is active (port 3334 forwarded)
# 2. Clean stale cache
rm -rf ~/.mcp-auth/mcp-remote-*

# 3. Run wrapper manually (find path from opencode.json mcp.<name>.command)
timeout 120 /nix/store/...-atlassian-mcp/bin/atlassian-mcp 2>&1

# 4. Copy the authorization URL, open in local browser
# 5. Complete consent -- callback goes through SSH tunnel
# 6. Tokens are cached; toggle MCP on in OpenCode
```
