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

The config dir `$GOOGLE_WORKSPACE_CLI_CONFIG_DIR` (or `~/.config/gws/` if unset)
holds credentials for ONE account at a time. The OAuth client accepts both
personal and work Google accounts -- whichever you sign in with during
`gws auth login` becomes the active account.

**Devbox / Cloudbox / macOS:** single config dir, single active account.
A `switch-gws` bash function (defined in `home.devbox.nix`) once supported a
second `~/.config/gws-alt/` profile; verify it still exists before relying on
it (`type switch-gws` and `ls ~/.config/gws-alt`).

**ALWAYS confirm with the user which Google account they want BEFORE running
`gws auth login`.** The current config dir alone doesn't tell you the intended
identity -- the previous token may have been minted for a different account
than the user wants now. Ask explicitly.

## Re-authenticating (All Platforms)

When `gws auth status` shows `token_valid: false`, re-authenticate.

**Critical gotchas (learned the hard way):**
- **Do NOT use `sleep`** -- it hangs in some environments. Check the listener
  immediately after launch; if it's not up, the launch failed.
- A bare `nohup ... &` can die when the shell is interrupted, taking the OAuth
  listener with it. Use `setsid nohup ... < /dev/null > log 2>&1 & disown` to
  fully detach.
- Verifying the listener is **mandatory**, not optional. If it's dead, the URL
  you give the user will 404 on callback and you'll waste their time.

```bash
# 1. Confirm with the user: which Google account do they want to authenticate?

# 2. Start login fully detached (survives Ctrl+C, no shell session ties)
rm -f /tmp/gws-auth.log
setsid nohup gws auth login < /dev/null > /tmp/gws-auth.log 2>&1 & disown

# 3. Grab the URL and verify the listener is alive (NO sleep -- check directly)
cat /tmp/gws-auth.log                   # shows URL with redirect_uri=http://localhost:<PORT>
ss -tlnp | grep <PORT>                  # MUST show a LISTEN line owned by gws
# If no listener: server died. Kill stale gws processes and retry step 2.

# 4. Give the user the URL. Confirm again which account they should select.

# 5. Browser redirects to http://localhost:<port>/?code=... which won't load
#    (localhost = remote machine, not user's laptop). User pastes the full
#    redirect URL back to you.

# 6. Relay the callback locally with curl:
curl -s "THE_FULL_REDIRECT_URL_FROM_THE_BROWSER"
# Should return: <html>...<title>Success</title>...</html>

# 7. Verify and confirm which account got authenticated:
gws auth status 2>&1 | grep -E "token_valid|project_id|client_id"
# token_valid: true. The redirect URL also contains hd=<domain> for work
# accounts (no hd for personal) -- use that to confirm the user got the
# account they intended.
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
