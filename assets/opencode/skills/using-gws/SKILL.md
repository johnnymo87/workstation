---
name: using-gws
description: Use when interacting with Google Workspace APIs (Gmail, Drive, Docs, Sheets, Calendar) via the gws CLI. Covers account switching, available services, and common commands.
---

# Using GWS (Google Workspace CLI)

CLI tool for Google Workspace APIs. Docs: https://github.com/googleworkspace/cli

## Config Directory

gws reads credentials from the directory in `GOOGLE_WORKSPACE_CLI_CONFIG_DIR`.
If the env var is unset, gws defaults to `~/.config/gws/`.

Always verify the env var points to the right place before debugging auth:

```bash
echo $GOOGLE_WORKSPACE_CLI_CONFIG_DIR   # should be ~/.config/gws or similar
ls "$GOOGLE_WORKSPACE_CLI_CONFIG_DIR"   # must contain client_secret.json + credentials.json
```

## Accounts

**Devbox** has two personal accounts with `switch-gws` (a bash function from `home.devbox.nix`):

```bash
switch-gws default   # jonathan.mohrbacher@gmail.com  -> ~/.config/gws/
switch-gws alt       # johnnymo87@gmail.com           -> ~/.config/gws-alt/
gws auth status      # check current account
```

Default is `jonathan.mohrbacher@gmail.com` in new shells.

**Cloudbox** has a single work account. `GOOGLE_WORKSPACE_CLI_CONFIG_DIR` is set
to `~/.config/gws/` in `home.cloudbox.nix`. No account switching needed.

**macOS** has a single work account (no switching needed).

## Re-authenticating (All Platforms)

When `gws auth status` shows `token_valid: false`, re-authenticate:

```bash
# 1. Start login in the background (spawns a localhost callback server)
nohup gws auth login > /tmp/gws-auth.log 2>&1 &

# 2. Wait, then grab the URL AND verify the listener is alive
sleep 2
cat /tmp/gws-auth.log                   # grab the URL
# Extract the port from the redirect_uri in the URL, then:
ss -tlnp | grep <PORT>                  # MUST show a LISTEN line
# If no listener, kill and retry step 1 -- the server died.

# 3. Give the user the URL to open in their browser
#    They select the correct Google account and authorize

# 4. The browser redirects to http://localhost:<port>/?code=...
#    but the browser can't reach the remote machine's localhost.
#    The user pastes back the full redirect URL from their address bar.

# 5. Relay the callback locally using curl:
curl -s "THE_FULL_REDIRECT_URL_FROM_THE_BROWSER"
# Should return: <html>...<title>Success</title>...</html>

# 6. Verify:
gws auth status   # token_valid should now be true
```

This relay step is necessary because the OAuth callback targets `localhost`,
which resolves to the remote machine -- not the user's browser. The user's
browser can't deliver the callback, so you replay it locally with `curl`.

## Quick Reference

```bash
# List recent emails
gws gmail users messages list --params '{"userId": "me", "maxResults": 5}'

# Read an email
gws gmail users messages get --params '{"userId": "me", "id": "MESSAGE_ID"}'

# Send email
gws gmail users messages send --params '{"userId": "me"}' --json '{
  "raw": "BASE64_ENCODED_RFC2822_MESSAGE"
}'

# List Drive files
gws drive files list --params '{"pageSize": 10}'

# Download a file from Drive (use get with alt=media, NOT the download subcommand)
# NOTE: -o path must be relative to cwd (gws rejects absolute/outside paths)
gws drive files get --params '{"fileId": "FILE_ID", "alt": "media"}' -o output.bin

# Read a Google Doc
gws docs documents get --params '{"documentId": "DOC_ID"}'

# Read a spreadsheet
gws sheets spreadsheets values get --params '{"spreadsheetId": "SHEET_ID", "range": "Sheet1!A1:D10"}'

# List calendar events
gws calendar events list --params '{"calendarId": "primary", "maxResults": 5}'
```

## Output Formats

```bash
gws ... --format json    # default
gws ... --format table
gws ... --format yaml
gws ... --format csv
```

## Enabled APIs

Depends on the GCP project backing each account. Common: Gmail, Drive, Docs,
Sheets, Calendar. Other APIs require enabling in the GCP project console.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `token_valid: false` | Expired/revoked refresh token | Re-authenticate (see above) |
| `client_config_exists: false` | Wrong config dir | Check `$GOOGLE_WORKSPACE_CLI_CONFIG_DIR` points to dir with `client_secret.json` |
| `403: insufficient scopes` with valid token | Token minted for different OAuth client or GCP project doesn't have the API enabled | Re-auth with correct account; verify API is enabled in GCP console |
| `-o` rejected with "outside the current directory" | Absolute or `..` path used | Use a relative path within cwd |
