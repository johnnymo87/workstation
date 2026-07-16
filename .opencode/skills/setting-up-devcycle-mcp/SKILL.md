---
name: setting-up-devcycle-mcp
description: Use when setting up, rotating, or debugging the DevCycle feature-flag MCP for OpenCode on macOS Keychain or cloudbox sops. Covers why the hosted remote endpoint is unusable (no dynamic client registration) and the local dvc-mcp + client-credentials setup.
---

# Setting Up DevCycle MCP

## Why the local server (not the hosted remote)

DevCycle documents a hosted MCP at `https://mcp.devcycle.com/mcp`, but it is
**unusable from OpenCode**. Its OAuth authorization server does not advertise a
registration endpoint (RFC 7591 dynamic client registration), and both
OpenCode's native `type: remote` OAuth flow *and* the `mcp-remote` shim
hard-require DCR. Both fail identically:

```
Incompatible auth server: does not support dynamic client registration
```

So we use DevCycle's **local** MCP server instead — the `dvc-mcp` binary shipped
inside `@devcycle/cli`, run as an OpenCode `type: local` server. It
authenticates via **client credentials** (`DEVCYCLE_CLIENT_ID` /
`DEVCYCLE_CLIENT_SECRET`, plus optional `DEVCYCLE_PROJECT_KEY`) supplied through
the MCP entry's `environment` block. This mirrors the `pagerduty-mcp` /
`rollbar-mcp` token-gated pattern in this repo.

## How it's wired (already in the repo)

`users/dev/opencode-config.nix`:

- **`devcycle-mcp` wrapper** — `writeShellApplication` running
  `npx -y --package @devcycle/cli@6.3.2 dvc-mcp`.
- **`injectDevcycleMcpSecrets`** (macOS, Keychain) and
  **`injectDevcycleMcpSecretsSops`** (cloudbox, sops) activation blocks — splice
  an `mcp.devcycle` entry (`type: local`, `enabled: false`) into
  `~/.config/opencode/opencode.json`. They surface the entry when **either**
  auth mode is available:
  1. **Client credentials** in Keychain/sops → injected into the entry's
     `environment` block (durable, reproducible path — needs the IT ticket).
  2. **SSO** — `~/.config/devcycle/auth.yml` exists (from an interactive login)
     → entry emitted with **no** `environment`; `dvc-mcp` reads `auth.yml` +
     `user.yml` (project) off disk.

  Client creds win when both exist. If neither exists, the entry is **deleted**
  — so the plumbing is safe to land before either is set up (the MCP just
  doesn't appear).

Work-only: no inject block runs on devbox, so `mcp.devcycle` never
appears there.

## Interim path: SSO login (no IT ticket)

The client-credentials path needs a Client ID + Secret you may not be able to
self-serve (the dashboard gates "API Authentication details" behind an admin
role). Until the ticket lands, authenticate interactively with your own SSO
identity — `dvc-mcp` then reads the resulting tokens off disk. The refresh
token (`offline_access`) auto-renews, so this survives well beyond the 24h
access-token lifetime.

**On a machine with a browser (macOS):** the DevCycle CLI does it in one shot —
```bash
npx -y --package '@devcycle/cli@6.3.2' dvc login sso
npx -y --package '@devcycle/cli@6.3.2' dvc projects select
```

**On headless cloudbox** the CLI's own `dvc login sso` is unreliable (it binds a
localhost callback on a fixed port — only `8080/2194/2195/2196` are allowed,
default **2194** — and times out in 120s, which loses the SSH-forward race).
The robust approach is to drive the OAuth PKCE flow by hand (no live listener,
no timeout). The DevCycle CLI is a **pre-registered public client**
(`client_id=Ev9J0DGxR3KhrKaZwY6jlccmjl7JGKEX`), which is exactly why it works
where the hosted MCP's OAuth doesn't (no dynamic client registration needed).
The flow:

1. Generate PKCE (`code_verifier` = base64url(43 random bytes),
   `code_challenge` = base64url(sha256(verifier))) and build the authorize URL:
   `https://auth.devcycle.com/authorize` with `response_type=code`,
   `client_id=Ev9J…`, `redirect_uri=http://localhost:2194/callback`, `state`,
   `code_challenge`, `code_challenge_method=S256`,
   `audience=https://api.devcycle.com/`, `scope=offline_access`.
2. Open the URL in a browser, sign in. The browser redirects to
   `http://localhost:2194/callback?code=…&state=…` — it fails to load (nothing
   listens there); copy that URL and extract `code`.
3. Exchange: `POST https://auth.devcycle.com/oauth/token` (JSON) with
   `grant_type=authorization_code`, `client_id`, `code_verifier`, `code`,
   `redirect_uri`, `scope=offline_access` → `access_token` + `refresh_token`.
4. The API requires an **org-scoped** token. The first token is personal; use it
   to `GET https://api.devcycle.com/v1/organizations` (send a browser
   `User-Agent` — Cloudflare 403s the default `python-urllib` UA with error
   1010), then repeat steps 1-3 adding `&organization=<org_id>` to the authorize
   URL to get the org-scoped token.
5. Write `~/.config/devcycle/auth.yml` (mode 0600):
   ```yaml
   sso:
     accessToken: "<org-scoped access_token>"
     refreshToken: "<refresh_token>"
     personalAccessToken: "<personal access_token>"
     orgs:
       <org_id>:
         accessToken: "<org-scoped access_token>"
         refreshToken: "<refresh_token>"
   ```
   and `~/.config/devcycle/user.yml`:
   ```yaml
   project: <project-key>
   org:
     id: <org_id>
     name: <org name>
     display_name: <org display name>
   ```
6. `nix run home-manager -- switch --flake .#<host>` — the inject block sees
   `auth.yml` and emits the `mcp.devcycle` entry (no `environment`).

Verify: `npx -y --package '@devcycle/cli@6.3.2' dvc projects current --headless`
should print your project, and `opencode mcp debug devcycle` (or an MCP
`tools/list` handshake against the wrapper) should return 21 tools.

When the client credentials arrive, add them per below; they take precedence and
the SSO files become unnecessary.

`enabled: false` is intentional — toggle on per-session via `/mcp` in the TUI.
DevCycle exposes ~24 tools, several of them **writes** (`create_feature`,
`update_feature`, `delete_feature`, `create_variable`,
`set_self_targeting_override`, …), so default-off keeps that surface — and its
context cost — out of every session until you deliberately want it.

## Obtaining the credentials (one-time, in DevCycle)

Client credentials are DevCycle **Management API** credentials, generated in the
DevCycle dashboard:

1. DevCycle dashboard → **Settings → Service Accounts** (or **API / Access
   Tokens** in some orgs) → create a service account / API client.
2. Copy the **Client ID** and **Client Secret** (the secret is shown once).
3. Note the **Project Key** you want as the MCP's default project (optional —
   the MCP can `select_project` at runtime, but a default is convenient).

Reference: <https://docs.devcycle.com/cli-mcp/mcp-reference#authentication-methods>

## Storing the credentials

### cloudbox (sops)

1. Declare the three secrets in `hosts/cloudbox/configuration.nix` (alongside
   `pagerduty_user_api_key` / `rollbar_access_token`):

   ```nix
   sops.secrets.devcycle_client_id = { owner = "dev"; };
   sops.secrets.devcycle_client_secret = { owner = "dev"; };
   sops.secrets.devcycle_project_key = { owner = "dev"; };   # optional
   ```

2. Add the values to `secrets/cloudbox.yaml`:

   ```bash
   sops secrets/cloudbox.yaml
   # add:
   #   devcycle_client_id: <id>
   #   devcycle_client_secret: <secret>
   #   devcycle_project_key: <project-key>
   ```

3. Apply system + home:

   ```bash
   sudo nixos-rebuild switch --flake .#cloudbox     # materializes /run/secrets/devcycle_*
   nix run home-manager -- switch --flake .#cloudbox # runs injectDevcycleMcpSecretsSops
   ```

See the `managing-secrets` skill for the full sops workflow.

### macOS (Keychain)

```bash
security add-generic-password -a "$USER" -s devcycle-client-id     -w "<id>"
security add-generic-password -a "$USER" -s devcycle-client-secret -w "<secret>"
security add-generic-password -a "$USER" -s devcycle-project-key   -w "<project-key>"   # optional
nix run home-manager -- switch --flake .#Y0FMQX93RR-2   # runs injectDevcycleMcpSecrets
```

## Verification

After the home-manager switch:

```bash
jq '.mcp.devcycle' ~/.config/opencode/opencode.json   # type:local, environment has the creds
opencode mcp debug devcycle                            # connects + lists tools
```

`environment` should carry `DEVCYCLE_CLIENT_ID` + `DEVCYCLE_CLIENT_SECRET` (and
`DEVCYCLE_PROJECT_KEY` if you set it). If `mcp.devcycle` is absent, the inject
block didn't find the credentials — re-check Keychain/sops.

On NixOS hosts, restart the serve pool so running sessions pick up the new MCP
(do it when the pool is idle — it's shared):

```bash
sudo systemctl restart opencode-serve-pool.target
```

Then in a TUI session: `/mcp` → enable `devcycle`, and try
_"List all features in my DevCycle project"_.

## Rotation / teardown

- **Rotate:** update the secret in sops (`sops secrets/cloudbox.yaml`) or
  Keychain (`security delete-generic-password -s devcycle-client-secret` then
  re-add), then re-run the host's home-manager switch.
- **Remove entirely:** delete the credentials from sops/Keychain and run the
  home-manager switch — the inject block strips `mcp.devcycle` when the
  client id/secret are gone.

## Sanity-check the local server standalone

```bash
DEVCYCLE_CLIENT_ID=... DEVCYCLE_CLIENT_SECRET=... \
  npx -y --package '@devcycle/cli@6.3.2' dvc-mcp
```

Without creds it prints `No authentication found` and exits 1 — that's the
signal the bin resolves and the env-var contract is what's missing.

## Related

- `users/dev/opencode-config.nix` — `devcycle-mcp` wrapper + `injectDevcycleMcp*`
  activations
- `managing-secrets` skill — sops workflow for cloudbox secrets
- `rollbar-mcp-setup` / `pagerduty-mcp-setup` skills — the same token-gated
  local-MCP pattern
- DevCycle MCP docs — <https://docs.devcycle.com/cli-mcp/mcp-reference>
