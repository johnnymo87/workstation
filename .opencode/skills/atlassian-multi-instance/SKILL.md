---
name: atlassian-multi-instance
description: How multiple Atlassian instances are configured across macOS and cloudbox. Use when adding, removing, or debugging Atlassian instance profiles.
---

# Atlassian Multi-Instance Configuration

Two Atlassian instances (`default` and `alt`) are supported across macOS and cloudbox. Generic profile names avoid leaking org-identifying info into version control.

## Architecture

```
Credentials (Keychain / sops)
        |
        v
Shell startup loads ATLASSIAN_* (default) + ATLASSIAN_ALT_* + ATLASSIAN_DEFAULT_*
        |
        v
switch-atlassian default|alt  -->  swaps ATLASSIAN_SITE/EMAIL/CLOUD_ID/API_TOKEN
        |
        v
nvim, acli, etc. use ATLASSIAN_* env vars (unchanged)

MCP servers (separate path):
  atlassian      -->  wrapper reads site from Keychain/sops  -->  --resource https://{site}/ :3334
  atlassian-alt  -->  wrapper reads alt site                 -->  --resource https://{site}/ :3335
```

## Credential Storage

| Profile | macOS Keychain service | cloudbox sops key |
|---------|----------------------|-------------------|
| default | `atlassian-site` | `atlassian_site` |
| default | `atlassian-email` | `atlassian_email` |
| default | `atlassian-cloud-id` | `atlassian_cloud_id` |
| default | `atlassian-api-token` | `atlassian_api_token` |
| alt | `atlassian-alt-site` | `atlassian_alt_site` |
| alt | `atlassian-alt-email` | `atlassian_alt_email` |
| alt | `atlassian-alt-cloud-id` | `atlassian_alt_cloud_id` |
| alt | `atlassian-alt-api-token` | `atlassian_alt_api_token` |

## Files

| File | What it does |
|------|-------------|
| `users/dev/home.darwin.nix` | Loads default + alt from Keychain, defines `switch-atlassian` |
| `users/dev/home.cloudbox.nix` | Loads default + alt from sops, defines `switch-atlassian` |
| `users/dev/opencode-config.nix` | `mkAtlassianMcp` helper, two MCP server entries |
| `hosts/cloudbox/configuration.nix` | sops.secrets declarations for all 8 Atlassian keys |
| `secrets/cloudbox.yaml` | Encrypted secret values |
| `scripts/update-ssh-config.sh` | SSH tunnel for ports 3334 + 3335 (MCP OAuth callbacks) |

## Adding a Third Instance

1. Choose a profile name (e.g., `alt2`) -- keep it generic
2. Add 4 Keychain entries: `atlassian-alt2-{site,email,cloud-id,api-token}`
3. Add 4 sops secrets: `atlassian_alt2_{site,email,cloud_id,api_token}`
4. Declare secrets in `hosts/cloudbox/configuration.nix`
5. Load env vars in `home.darwin.nix` and `home.cloudbox.nix`
6. Add `alt2)` case to `switch-atlassian` in both files
7. Add a third `mkAtlassianMcp` call in `opencode-config.nix` with a new port
8. Forward the new port in `scripts/update-ssh-config.sh`

## MCP Wrapper Pattern

The `mkAtlassianMcp` helper in `opencode-config.nix` generates `writeShellApplication` wrappers that read the site URL at runtime:

```nix
atlassian-alt-mcp = mkAtlassianMcp {
  name = "atlassian-alt-mcp";
  port = 3335;
  keychainService = "atlassian-alt-site";
  sopsSecret = "atlassian_alt_site";
};
```

This keeps org-identifying URLs out of the generated `opencode.managed.json`. The wrapper uses `--resource` to isolate OAuth sessions per instance, so both can run simultaneously.

**Arg ordering matters:** `mcp-remote` parses positional args as `<url> [port] [flags...]`. The callback port MUST come before `--resource`:
```bash
# Correct: port as args[1]
npx -y mcp-remote@0.1.38 https://mcp.atlassian.com/v1/mcp 3334 --resource "https://${SITE}/"

# Wrong: --resource as args[1], port is never parsed
npx -y mcp-remote https://mcp.atlassian.com/v1/mcp --resource "https://${SITE}/" 3334
```

## OAuth Token Cache

`mcp-remote` stores OAuth tokens in `~/.mcp-auth/mcp-remote-${version}/`. Cache is keyed by a hash of the server URL + resource + headers.

**Version-scoped invalidation:** When `mcp-remote` upgrades (e.g., 0.1.37 → 0.1.38), the cache directory name changes and all cached tokens are lost. Pin the version in the wrapper (`mcp-remote@0.1.38`) to prevent `npx -y` from auto-upgrading.

## Troubleshooting MCP "Failed" Status

If toggling an MCP on in OpenCode shows "Failed":

1. **Check the wrapper runs:** Run the nix store path directly (find it in `~/.config/opencode/opencode.json` under `mcp.<name>.command`)
2. **Check secrets exist:** `cat /run/secrets/atlassian_site` (Linux) or Keychain lookup (macOS)
3. **Check OAuth tokens:** `ls ~/.mcp-auth/mcp-remote-*/` -- look for `*_tokens.json`
4. **Re-auth if needed:** Run the wrapper manually, it prints an OAuth URL. Open in browser while SSH tunnel forwards the callback port (3334/3335). The callback URL `localhost:3334/oauth/callback?code=...` tunnels back to the server.

## Re-authenticating OAuth (Headless Server)

When tokens expire or cache is invalidated:

```bash
# 1. Ensure SSH tunnel is active (ports 3334/3335 forwarded)
# 2. Clean stale cache
rm -rf ~/.mcp-auth/mcp-remote-*

# 3. Run wrapper manually (find path from opencode.json mcp.<name>.command)
timeout 120 /nix/store/...-atlassian-mcp/bin/atlassian-mcp 2>&1

# 4. Copy the authorization URL, open in local browser
# 5. Complete consent -- callback goes through SSH tunnel
# 6. Tokens are cached; toggle MCP on in OpenCode
```
