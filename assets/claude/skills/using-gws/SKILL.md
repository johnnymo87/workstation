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
