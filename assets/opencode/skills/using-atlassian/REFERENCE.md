# Atlassian Reference

Full details for both tools. SKILL.md has the decision matrix and quick-start; this file has command-level detail and troubleshooting.

## Environment & Auth

### Required Variables (set automatically by home-manager)

| Variable | Source (macOS) | Source (cloudbox) |
|----------|---------------|-------------------|
| `ATLASSIAN_SITE` | Keychain `atlassian-site` | sops `/run/secrets/atlassian_site` |
| `ATLASSIAN_EMAIL` | Keychain `atlassian-email` | sops `/run/secrets/atlassian_email` |
| `ATLASSIAN_CLOUD_ID` | Keychain `atlassian-cloud-id` | sops `/run/secrets/atlassian_cloud_id` |
| `ATLASSIAN_API_TOKEN` | Keychain `atlassian-api-token` | sops `/run/secrets/atlassian_api_token` |

Verify: `env | grep ATLASSIAN`

### Required Tools

- The `atlassian` MCP server (see the `atlassian-multi-instance` skill for how it's wired and authenticated). Provides all Jira/Confluence mutations, search, and field reads.
- `nvim` — with `~/.config/nvim/lua/user/atlassian.lua` (deployed from `~/projects/workstation/assets/nvim/lua/user/atlassian.lua`). The rich-read path.
- `curl`, `jq`, `pandoc`, `python3` — used by nvim and the `confluence-to-md.sh` helper.

The MCP authenticates over OAuth (not the `ATLASSIAN_API_TOKEN`); nvim and `confluence-to-md.sh` use the `ATLASSIAN_*` env vars. First-time MCP OAuth setup and re-auth are covered in the `atlassian-multi-instance` skill.

---

## Part 1: Atlassian MCP — Jira CRUD

All operations below are tool calls against the `atlassian` MCP server. Every
tool takes a `cloudId` (the MCP resolves the accessible cloud id; if it asks,
it's the `getAccessibleAtlassianResources` / `atlassianUserInfo` result). Keys
like `PROJ-1234` and project `PROJ` are examples.

### Create — `createJiraIssue`

Params: `projectKey` (`PROJ`), `issueTypeName` (`Task`, `Bug`, `Story`, `Epic`, …),
`summary`, Markdown `description`, and `assignee_account_id`
(`$ATLASSIAN_ASSIGNEE_ID`). Returns the new key, e.g. `PROJ-1234`
(browse: `https://$ATLASSIAN_SITE/browse/PROJ-1234`).

### Read — `getJiraIssue`

Params: `issueIdOrKey` (`PROJ-1234`), optional `fields`. Returns the full field
set including custom fields (e.g. `customfield_10001`), labels, story points,
sprint, fix version, parent epic.

Note: the description comes back as ADF (Atlassian Document Format), not
Markdown. For rendered Markdown of a ticket's description + comments +
attachments, use **nvim** instead.

### Update — `editJiraIssue` / `transitionJiraIssue`

- `editJiraIssue` — params `issueIdOrKey` plus the `fields` to change (`summary`,
  Markdown `description`, `assignee`, etc.).
- `transitionJiraIssue` — moves a ticket's status. First call
  `getTransitionsForJiraIssue` to get the valid transition id for the target
  status ("In Review"), then pass that `transitionId`.

### Search (JQL) — `searchJiraIssuesUsingJql`

Params: `jql`. Examples:

```
project=PROJ AND assignee="<accountId>" AND statusCategory!=Done
project=PROJ AND "Epic Link"=PROJ-5678 AND status!="Done"
```

### Comments — `addCommentToJiraIssue`

Params: `issueIdOrKey`, Markdown `commentBody`. (To read existing comments with
threading + attachments rendered, use **nvim**.)

### Example: Create a Bug Ticket

Call `createJiraIssue` with:
- `projectKey`: `PROJ`
- `issueTypeName`: `Bug`
- `summary`: "Fix authentication timeout on order submission"
- `assignee_account_id`: `$ATLASSIAN_ASSIGNEE_ID`
- `description` (Markdown):

  > Users experience authentication timeouts when submitting orders during peak
  > traffic. This causes order failures and user frustration. Issue appears
  > related to session token expiry not being refreshed before long-running
  > operations. Proposed fix: implement token refresh logic before order
  > submission API calls.

The response contains the new key, e.g. `PROJ-1234`
(open: `https://$ATLASSIAN_SITE/browse/PROJ-1234`).

### Best Practices

1. Lead with impact in the description
2. Verify epic assignment for Active Epic work → `PROJ-5678`
3. Use `accountId` for the assignee (more reliable than email); look it up with `lookupJiraAccountId` if needed
4. Confirm you're on the right instance before mutating (see Troubleshooting → Wrong instance)

---

## Part 1b: Atlassian MCP — Confluence authoring

The MCP closes the old gap where neither tool could write Confluence:

- `createConfluencePage` — params `spaceId`, `title`, Markdown `body`, optional `parentId`.
- `updateConfluencePage` — params `pageId`, `title`, Markdown `body` (and the current `version` if the tool requires it).
- `createConfluenceFooterComment` / `createConfluenceInlineComment` — add comments.
- `searchConfluenceUsingCql` — CQL search across spaces.

For *reading* a page with threaded comments and diagrams rendered to Markdown, still prefer **nvim** `:FetchConfluencePage` (Part 2) or the lighter `confluence-to-md.sh` (Part 3).

---

## Part 2: nvim — Fetch Atlassian Content as Markdown

Two `:user_command`s, both insert at cursor and download images to `~/.cache/atlassian-attachments/`. Headless invocation is the standard CLI usage.

### Output Locations

| Content | Markdown | Images |
|---------|----------|--------|
| Confluence | `./output.md` (current buffer) | `~/.cache/atlassian-attachments/confluence/{page_id}/` |
| Jira | `./ticket.md` (current buffer) | `~/.cache/atlassian-attachments/jira/{ticket_key}/` |

### Fetch a Jira Ticket

```bash
nvim --headless ticket.md \
  -c "FetchJiraTicket PROJ-1234" \
  -c "write" \
  -c "quit"
```

**What it does internally:**
- `GET /rest/api/3/issue/{key}?fields=key,summary,description,attachment&expand=renderedFields` — `renderedFields` returns HTML (not ADF).
- `GET /rest/api/3/issue/{key}/comment?expand=renderedBody` — comments with HTML bodies.
- HTML → Markdown via `pandoc -f html -t markdown-simple_tables-multiline_tables-smart --wrap=none`, then strips pandoc artifacts (fenced divs `:::`, `{#id .class}` attrs, autolink quirks).
- Downloads **all `image/*` mime-type attachments** via `/rest/api/3/attachment/content/{id}`.

**Output format:**

```markdown
PROJ-1234 Ticket summary here

> **Attachments downloaded to**: `~/.cache/atlassian-attachments/jira/PROJ-1234/`

[description in Markdown]

<comments>
  <comment>

    Author Name (2026-01-15T10:30:00.000-0500)

    Comment body in Markdown

  </comment>
</comments>
```

**Limitation:** comments are flat (no thread nesting yet — there's a TODO in the source).

### Fetch a Confluence Page

```bash
nvim --headless out.md \
  -c "FetchConfluencePage 1234567890" \
  -c "write" \
  -c "quit"
```

**Extract page ID from URL:**
```
https://company.atlassian.net/wiki/spaces/ENG/pages/1234567890/Page+Title
                                                 ^^^^^^^^^^
                                                  page ID
```
```bash
echo "$URL" | grep -oE '[0-9]{10}'
```

**What it does internally:**
- POSTs a GraphQL query to `/gateway/api/graphql` with `X-ExperimentalApi: confluence-agg-beta`. Pulls `title`, `body.anonymousExportView.value` (HTML), comments (`__typename`, `author`, `body.editor.value`, `commentId`).
- Requires `ATLASSIAN_CLOUD_ID` to build the page ARI: `ari:cloud:confluence:{cloud_id}:page/{page_id}`.
- Builds threaded comment hierarchy: one extra REST call per comment to `/wiki/api/v2/{inline-comments|footer-comments}/{id}` for `parentCommentId`. **Slow on pages with many comments.**
- Splits comments into `<inline-comments>` and `<footer-comments>` sections, recursively nested.
- Lists attachments via `/wiki/rest/api/content/{page_id}/child/attachment`, downloads **only `image/png`** via `.../{att_id}/download`. Other types silently skipped.

**Output format:**

```markdown
Page Title

> **Attachments downloaded to**: `~/.cache/atlassian-attachments/confluence/1234567890/`

[page body in Markdown]

<inline-comments>
  <comment>

    Author Name (Comment ID: 12345)

    Comment body...

    <comment>
      Reply Author (Comment ID: 12346)
      Nested reply body...
    </comment>

  </comment>
</inline-comments>

<footer-comments>
  <comment>
    ...
  </comment>
</footer-comments>
```

### Batch Fetch

```bash
for page_id in 1234567890 0987654321; do
  nvim --headless "page-${page_id}.md" \
    -c "FetchConfluencePage ${page_id}" \
    -c "write" \
    -c "quit"
done
```

### nvim Plugin Source

`~/projects/workstation/assets/nvim/lua/user/atlassian.lua` (deployed to `~/.config/nvim/lua/user/atlassian.lua`). Key functions:

- `html_to_markdown()` — pandoc + cleanup
- `download_attachments()` — Confluence (PNG only)
- `download_jira_attachments()` — Jira (any `image/*`)
- `fetch_page_content()` — Confluence GraphQL fetch
- `fetch_jira_ticket()` — Jira REST fetch
- `build_comment_hierarchy()` — Confluence comment threading

### Known nvim Limitations

1. **Confluence: PNG only.** Other image types and non-image attachments are silently skipped. (Jira downloads any `image/*`.)
2. **Confluence comment threading is slow** — one REST call per comment.
3. **Jira comments are flat** — no nesting (TODO in source).
4. **Read-only.** No mutations possible.
5. **Confluence body uses `anonymousExportView`** — pages requiring auth-aware rendering may differ.

---

## Part 3: `confluence-to-md.sh` (bundled helper)

Lighter-weight body-only Confluence fetch. Lives in this skill directory. Use when you just need the page body, no comments or images, and don't want to spin up nvim.

```bash
./confluence-to-md.sh 1234567890                  # writes to stdout
./confluence-to-md.sh 1234567890 page.md          # writes to file
```

What it does: `curl` `/wiki/api/v2/pages/{id}?body-format=view` → strips Confluence wrapper divs and `<a>` tags via Python → `pandoc -f html -t gfm --wrap=none` → `sed` cleanup. ~30 lines total.

---

## Troubleshooting

### Environment variables not set

```bash
env | grep ATLASSIAN
# Should see ATLASSIAN_SITE, ATLASSIAN_EMAIL, ATLASSIAN_CLOUD_ID, ATLASSIAN_API_TOKEN
```

**macOS** (missing `ATLASSIAN_API_TOKEN`):
```bash
/usr/bin/security find-generic-password -s atlassian-api-token -w
# Add if missing:
/usr/bin/security add-generic-password -a atlassian -s atlassian-api-token -w "YOUR_TOKEN"
```

**cloudbox** (missing):
```bash
cat /run/secrets/atlassian_api_token
# If missing, update secrets/cloudbox.yaml and re-apply NixOS
```

### Atlassian MCP not authenticated / tools missing

The `atlassian` MCP authenticates over OAuth, not the API token. If its tools
are missing or the server shows "Failed", see the `atlassian-multi-instance`
skill → "Troubleshooting MCP Failed Status" and "Re-authenticating OAuth". In
short: verify the site secret exists, check `ls ~/.mcp-auth/mcp-remote-*/` for
cached tokens, and re-run the wrapper manually to complete the OAuth consent
(callback tunnels through port 3334 on headless hosts).

### nvim fetch fails

```bash
# Verify dependencies
which curl jq pandoc nvim

# Test API access directly
curl -s -u "$ATLASSIAN_EMAIL:$ATLASSIAN_API_TOKEN" \
  "https://api.atlassian.com/ex/confluence/$ATLASSIAN_CLOUD_ID/wiki/api/v2/pages/1234567890" | jq .

# Check plugin is deployed
ls -l ~/.config/nvim/lua/user/atlassian.lua
```

### Wrong instance

If results look wrong, confirm which Atlassian site is configured:

```bash
echo "$ATLASSIAN_SITE"          # verify the configured instance
```
