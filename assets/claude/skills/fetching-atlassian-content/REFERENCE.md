# Fetching Atlassian Content Reference

## Prerequisites

### Environment Variables
Configured via home-manager (macOS Keychain / sops-nix secrets):
- `ATLASSIAN_EMAIL`
- `ATLASSIAN_API_TOKEN`
- `ATLASSIAN_CLOUD_ID`

### Required Tools
- `nvim` - Neovim with `~/.config/nvim/lua/user/atlassian.lua`
- `curl` - HTTP requests
- `jq` - JSON parsing
- `pandoc` - HTML to Markdown conversion

## Fetching Confluence Pages

### Single Page

```bash
nvim --headless output.md \
  -c "FetchConfluencePage 3963715585" \
  -c "write" \
  -c "quit"
```

### Batch Fetch

```bash
for page_id in 3963715585 3963191313; do
  nvim --headless "page-${page_id}.md" \
    -c "FetchConfluencePage ${page_id}" \
    -c "write" \
    -c "quit"
done
```

### Extract Page ID from URL

```
https://wonder.atlassian.net/wiki/spaces/CT/pages/3963715585/Page+Title
                                                ^^^^^^^^^^
                                                 page ID
```

```bash
url="https://wonder.atlassian.net/wiki/spaces/CT/pages/3963715585/Page+Title"
page_id=$(echo "$url" | grep -oE '[0-9]{10}')
```

## Fetching Jira Tickets

```bash
nvim --headless ticket.md \
  -c "FetchJiraTicket COPS-1234" \
  -c "write" \
  -c "quit"
```

## Output Structure

```
./
├── output.md                              # Fetched page content
└── ticket.md                              # Fetched Jira ticket

~/.cache/atlassian-attachments/
├── confluence/
│   └── 3963715585/                        # Page ID
│       ├── diagram1.png
│       └── diagram2.png
└── jira/
    └── COPS-1234/                         # Ticket key
        ├── screenshot1.png
        └── diagram.jpg
```

## Content Format

### Confluence Page

```markdown
Page Title

> **Attachments downloaded to**: `~/.cache/atlassian-attachments/confluence/3963715585/`

[page content in markdown...]

<inline-comments>
  <comment>
    Author Name (Comment ID: 12345)

    Comment content...
  </comment>
</inline-comments>

<footer-comments>
  <comment>
    Author Name (Comment ID: 67890)

    Comment content...
  </comment>
</footer-comments>
```

### Jira Ticket

```markdown
COPS-1234 Ticket summary here

> **Attachments downloaded to**: `~/.cache/atlassian-attachments/jira/COPS-1234/`

[description in markdown...]

<comments>
  <comment>
    Author Name (2026-01-15T10:30:00.000-0500)

    Comment content...
  </comment>
</comments>
```

## Example Workflow

```bash
# User provides Confluence URL
URL="https://wonder.atlassian.net/wiki/spaces/CT/pages/3963715585/Product+Catalog+Service"
PAGE_ID=$(echo "$URL" | grep -oE '[0-9]{10}')

# Fetch with descriptive filename
nvim --headless product-catalog-service.md \
  -c "FetchConfluencePage ${PAGE_ID}" \
  -c "write" \
  -c "quit"

# Verify
ls -lh product-catalog-service.md
ls -lh ~/.cache/atlassian-attachments/confluence/${PAGE_ID}/
```

## Troubleshooting

### Fetch Fails

```bash
# Verify dependencies
which curl jq pandoc nvim

# Test API access
curl -s -u "$ATLASSIAN_EMAIL:$ATLASSIAN_API_TOKEN" \
  "https://api.atlassian.com/ex/confluence/$ATLASSIAN_CLOUD_ID/wiki/api/v2/pages/3963715585" | jq .

# Check Neovim plugin exists
ls -l ~/.config/nvim/lua/user/atlassian.lua
```

### Environment Variables Not Set

```bash
env | grep ATLASSIAN
# Should see: ATLASSIAN_EMAIL, ATLASSIAN_API_TOKEN, ATLASSIAN_CLOUD_ID
```

## Known Limitations

1. **Confluence: PNG only** - Only downloads PNG attachments. Jira downloads all image types.

2. **Confluence uses GraphQL** - Returns ADF for comments, converts to HTML then Markdown. May have formatting quirks.

3. **Comment threading** - Makes individual API calls per comment for parent info. Can be slow for pages with many comments.

4. **Read-only** - These commands only fetch content. For Jira CRUD, use `using-atlassian-cli` skill.

## Modifying Behavior

The source lives in `assets/nvim/lua/user/atlassian.lua` (deployed to `~/.config/nvim/lua/user/atlassian.lua`):

- `html_to_markdown()` - Converts HTML to GFM Markdown via `pandoc`
- `download_attachments()` - Confluence attachment download
- `download_jira_attachments()` - Jira attachment download
- `fetch_page_content()` - Confluence page fetch
- `fetch_jira_ticket()` - Jira ticket fetch
