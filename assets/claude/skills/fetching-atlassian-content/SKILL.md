# Fetching Atlassian Content

Export Confluence pages and Jira tickets to local Markdown files with image attachments via Neovim.

## Quick Start

```bash
# Fetch Confluence page
nvim --headless output.md -c "FetchConfluencePage 3963715585" -c "write" -c "quit"

# Fetch Jira ticket
nvim --headless ticket.md -c "FetchJiraTicket COPS-1234" -c "write" -c "quit"

# Extract page ID from URL
echo "https://wonder.atlassian.net/wiki/spaces/CT/pages/3963715585/Title" | grep -oE '[0-9]{10}'
```

## Output Locations

| Content | Markdown | Images |
|---------|----------|--------|
| Confluence | `./output.md` | `~/.cache/atlassian-attachments/confluence/{page_id}/` |
| Jira | `./ticket.md` | `~/.cache/atlassian-attachments/jira/{ticket_key}/` |

## What Gets Fetched

**Confluence pages:**
- Page title and body as Markdown
- Inline and footer comments
- PNG attachments

**Jira tickets:**
- Summary, description, and comments as Markdown
- All image attachments (PNG, JPG, etc.)

## When to Use

- Archiving content for offline reference
- Gathering context before implementation
- Preserving images from tickets/pages

**Note:** For Jira CRUD operations (create/update/delete), use the `using-atlassian-cli` skill instead.

## Reference

See [REFERENCE.md](./REFERENCE.md) for:
- Batch fetching multiple pages
- Output format details
- Troubleshooting
- Known limitations
