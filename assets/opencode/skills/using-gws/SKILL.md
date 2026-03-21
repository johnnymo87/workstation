---
name: using-gws
description: Use when interacting with Google Workspace APIs (Gmail, Drive, Docs, Sheets, Calendar) via the gws CLI. Covers account switching, available services, and common commands.
---

# Using GWS (Google Workspace CLI)

CLI tool for Google Workspace APIs. Docs: https://github.com/googleworkspace/cli

## Accounts

**Devbox** has two personal accounts with `switch-gws`:

```bash
switch-gws default   # jonathan.mohrbacher@gmail.com
switch-gws alt       # johnnymo87@gmail.com
gws auth status      # check current account
```

Default is `jonathan.mohrbacher@gmail.com` in new shells.

**Cloudbox/macOS** have a single work account (no switching needed).

## Auth on Devbox

When `gws auth status` shows `token_valid: false`, you need to re-authenticate:

```bash
# 1. Start login in the background (it spawns a localhost callback server)
nohup gws auth login > /tmp/gws-auth.log 2>&1 &
sleep 2
cat /tmp/gws-auth.log   # grab the URL

# 2. Give the user the URL to open in their browser
#    They select the correct Google account and authorize

# 3. The browser redirects to http://localhost:<port>/?code=...
#    but the browser can't reach devbox's localhost.
#    The user pastes back the redirect URL they landed on.

# 4. Relay the callback from inside the devbox using curl:
curl -s "THE_FULL_REDIRECT_URL_FROM_THE_BROWSER"
# Should return: <html>...<title>Success</title>...</html>

# 5. Verify:
gws auth status   # token_valid should now be true
```

This relay step is necessary because the OAuth callback targets `localhost`,
which resolves to the devbox -- not the user's browser machine. The user's
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
gws drive files get --params '{"fileId": "FILE_ID", "alt": "media"}' -o /path/to/output

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

## Enabled APIs (Devbox Personal Accounts)

Gmail, Drive, Docs, Sheets. Other APIs require enabling in the GCP project console.
