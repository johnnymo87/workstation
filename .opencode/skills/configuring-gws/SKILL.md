---
name: configuring-gws
description: Use when adding, removing, or debugging Google Workspace CLI (gws) accounts in the workstation repo. Covers sops secrets, credential assembly, OAuth token minting, and multi-account architecture.
---

# Configuring GWS (Google Workspace CLI)

Multi-account gws setup using separate config directories per account, with credentials from sops-nix.

## Architecture

```
sops secrets (per account)
    -> /run/secrets/gws_{default,alt}_*    (decrypted at boot)
    -> ~/.config/gws-{default,alt}/        (assembled at home-manager switch)
    -> GOOGLE_WORKSPACE_CLI_CONFIG_DIR     (set by switch-gws in bash)
```

Each account gets an isolated config directory containing `client_secret.json` (OAuth app) and `credentials.json` (user tokens). The `switch-gws` bash function swaps `GOOGLE_WORKSPACE_CLI_CONFIG_DIR`.

## Current Accounts

| Profile | Email | Config dir | GCP Project |
|---------|-------|-----------|-------------|
| default | jonathan.mohrbacher@gmail.com | `~/.config/gws-default/` | jonathan-mohrbacher |
| alt | johnnymo87@gmail.com | `~/.config/gws-alt/` | valid-cell-358023 |

## Files

| File | Role |
|------|------|
| `secrets/devbox.yaml` | Encrypted credentials (8 secrets: client_id, client_secret, refresh_token, project_id per account) |
| `hosts/devbox/configuration.nix` | sops-nix secret declarations |
| `users/dev/home.devbox.nix` | Credential assembly activation script + `switch-gws` function |

## Sops Secrets

| Secret | Description |
|--------|-------------|
| `gws_default_client_id` | OAuth client ID for default account |
| `gws_default_client_secret` | OAuth client secret for default account |
| `gws_default_refresh_token` | OAuth refresh token for default account |
| `gws_default_project_id` | GCP project ID for default account |
| `gws_alt_client_id` | OAuth client ID for alt account |
| `gws_alt_client_secret` | OAuth client secret for alt account |
| `gws_alt_refresh_token` | OAuth refresh token for alt account |
| `gws_alt_project_id` | GCP project ID for alt account |

## Adding a New Account

### Step 1: Create GCP OAuth client

1. Go to https://console.cloud.google.com/apis/credentials (signed in as the target account)
2. Create an OAuth 2.0 Client ID (type: Desktop app)
3. Add `http://localhost` as an authorized redirect URI
4. Add the target email as a test user in the OAuth consent screen
5. Enable required APIs (Gmail, Drive, Docs, Sheets, Calendar, etc.)
6. Download the client_secret.json -- note the `client_id`, `client_secret`, and `project_id`

### Step 2: Mint a refresh token (headless OAuth flow)

Since the devbox has no browser, do a manual code exchange:

```bash
# 1. Construct the OAuth URL
CLIENT_ID="your-client-id"
SCOPES="https://www.googleapis.com/auth/gmail.readonly https://www.googleapis.com/auth/drive.readonly ..."
ENCODED_SCOPES=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$SCOPES'))")
echo "https://accounts.google.com/o/oauth2/auth?client_id=${CLIENT_ID}&redirect_uri=http://localhost&response_type=code&scope=${ENCODED_SCOPES}&access_type=offline&prompt=consent"

# 2. Open URL in browser, sign in, approve. Redirect to localhost fails -- that's fine.
# 3. Copy the full URL from the address bar.
# 4. Extract the code parameter and exchange it:
curl -s -X POST https://oauth2.googleapis.com/token \
  -d "code=CODE_FROM_URL" \
  -d "client_id=$CLIENT_ID" \
  -d "client_secret=CLIENT_SECRET" \
  -d "redirect_uri=http://localhost" \
  -d "grant_type=authorization_code"
# Response contains refresh_token.
```

### Step 3: Add sops secrets

```bash
sudo nix-shell -p sops --run "SOPS_AGE_KEY_FILE=/persist/sops-age-key.txt sops set secrets/devbox.yaml '[\"gws_PROFILE_client_id\"]' '\"...\"'"
# Repeat for client_secret, refresh_token, project_id
```

### Step 4: Declare in NixOS and wire up

1. Add secret declarations to `hosts/devbox/configuration.nix` under `sops.secrets`
2. Add secret reading + `assemble_gws_account` call in `home.devbox.nix` activation script
3. Add the profile case to the `switch-gws` function in `home.devbox.nix`

### Step 5: Apply

```bash
sudo nixos-rebuild switch --flake .#devbox   # Deploys sops secrets
nix run home-manager -- switch --flake .#dev  # Assembles credential files
```

### Step 6: Verify

```bash
GOOGLE_WORKSPACE_CLI_CONFIG_DIR=~/.config/gws-PROFILE gws auth status
```

## Re-authing an Expired Token

Refresh tokens can expire (7 days for apps in "Testing" mode) or be revoked. Repeat Step 2 of "Adding a New Account" to mint a new refresh token, then update the sops secret:

```bash
sudo nix-shell -p sops --run "SOPS_AGE_KEY_FILE=/persist/sops-age-key.txt sops set secrets/devbox.yaml '[\"gws_PROFILE_refresh_token\"]' '\"NEW_TOKEN\"'"
sudo nixos-rebuild switch --flake .#devbox
nix run home-manager -- switch --flake .#dev
```

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `token_valid: false` | Expired/revoked refresh token | Re-auth (see above) |
| `client_config_error: missing project_id` | No `project_id` in client_secret.json | Add `gws_PROFILE_project_id` sops secret |
| `redirect_uri_mismatch` during OAuth | `http://localhost` not in OAuth client's redirect URIs | Add it in GCP Console |
| `access_denied` during OAuth | Email not an approved test user, or wrong OAuth app | Each GCP project can only auth its own test users |
| `403: API not enabled` | API not turned on in GCP project | Enable at `console.developers.google.com/apis/library` |
