---
name: using-atlassian
description: Use when reading or writing Jira tickets, fetching Confluence pages, searching with JQL, adding comments, or downloading Atlassian attachments from this devbox.
---

# Using Atlassian (Jira + Confluence)

Two complementary tools. **Read this whole file before choosing one** — picking the wrong tool is the most common mistake.

- **Atlassian MCP** (`atlassian` MCP server): mutations, JQL/CQL search, arbitrary fields, and Confluence create/edit. This is the default for everything except rich reads.
- **nvim** (`:FetchJiraTicket` / `:FetchConfluencePage`): the best *read* path — it renders a ticket or page (plus threaded comments and image attachments) to Markdown on disk.

## Decision Matrix

| Workflow | Use |
|----------|-----|
| Read a Jira ticket as context (rendered Markdown + image attachments) | **nvim** `:FetchJiraTicket` |
| Read a Confluence page (with comments + PNG diagrams) | **nvim** `:FetchConfluencePage` |
| Archive Atlassian content to disk for offline reference | **nvim** |
| Create a new Jira ticket | **MCP** `createJiraIssue` |
| Edit a ticket's summary / description / status / assignee | **MCP** `editJiraIssue` / `transitionJiraIssue` |
| Add a comment | **MCP** `addCommentToJiraIssue` |
| JQL search ("my open tickets in epic X") | **MCP** `searchJiraIssuesUsingJql` |
| Read non-default Jira fields (custom fields, labels, story points, sprint, fix version, parent epic) | **MCP** `getJiraIssue` |
| Confluence page **body only**, no images/comments | Either; `confluence-to-md.sh` is lightest |
| Confluence with comments or attachments | **nvim** (only option) |
| Create / edit Confluence pages or comments | **MCP** `createConfluencePage` / `updateConfluencePage` |

**Rule of thumb:**
- **Reading rich content (rendered Markdown + images + comments) → nvim.**
- **Mutations, JQL/CQL, arbitrary Jira fields, Confluence authoring → Atlassian MCP.**

## Quick Start

### Read a Jira ticket (nvim)

```bash
nvim --headless ticket.md -c "FetchJiraTicket PROJ-1234" -c "write" -c "quit"
# → ticket.md (Markdown), images in ~/.cache/atlassian-attachments/jira/PROJ-1234/
```

### Read a Confluence page (nvim)

```bash
nvim --headless out.md -c "FetchConfluencePage 1234567890" -c "write" -c "quit"
# → out.md (Markdown + threaded comments), PNGs in ~/.cache/atlassian-attachments/confluence/1234567890/

# Extract page ID from URL:
echo "https://company.atlassian.net/wiki/spaces/ENG/pages/1234567890/Title" | grep -oE '[0-9]{10}'
```

### Create a Jira ticket (MCP)

Call the `atlassian` MCP's `createJiraIssue` tool with `cloudId`, `projectKey`
(`PROJ`), `issueTypeName` (`Task`, `Bug`, `Story`, `Epic`, …), `summary`, and a
Markdown `description`. Set the assignee to `$ATLASSIAN_ASSIGNEE_ID`.

**Format gotcha — always use GitHub-Flavored Markdown, never Jira wiki markup.** The Atlassian MCP (and the underlying Cloud REST API v3) expects descriptions and comment bodies in Markdown — `# heading`, `**bold**`, `` `code` ``, `[text](url)`, `| col | col |` tables — and converts to ADF on the way in. Jira wiki markup (`h2.`, `*bold*`, `{{code}}`, `[text|url]`, `|| col || col ||`) renders as literal text and is the most common mistake when an LLM drafts a ticket. If you see your description rendering with literal `h2.` or `{{...}}` in the Jira UI, you used wiki markup — re-edit with Markdown.

### Add a comment (MCP)

Call `addCommentToJiraIssue` with the `issueIdOrKey` (`PROJ-1234`) and a Markdown `commentBody`. Comment bodies follow the same rule: **Markdown only, never wiki markup.**

### JQL search (MCP)

Call `searchJiraIssuesUsingJql` with a `jql` string, e.g.
`project=PROJ AND assignee="<accountId>" AND statusCategory!=Done`.

### Read arbitrary Jira fields (MCP)

Call `getJiraIssue` with the `issueIdOrKey`. It returns the full field set (custom fields, labels, story points, sprint, fix version, parent epic). For rendered Markdown of the description + comments + image attachments, use **nvim** instead.

## Org Config

| Setting | Value |
|---------|-------|
| Subdomain | `$ATLASSIAN_SITE` |
| Project | `PROJ` |
| Default Assignee | `$ATLASSIAN_ASSIGNEE_ID` |
| Active Epic | `PROJ-5678` |

## Ticket Writing Philosophy

- Lead with **impact** (problem / opportunity / benefit)
- Focus on **what** and **why**, minimal **how**
- Less technical detail than PRs
- Don't put the ticket number in the title

## Confluence Authoring (MCP)

Create pages with `createConfluencePage` and edit them with `updateConfluencePage` (pass `cloudId`, `spaceId`/`pageId`, `title`, and Markdown `body`). Footer/inline comments are also available via the MCP's Confluence comment tools. For *reading* a page with its threaded comments and diagrams rendered, still prefer **nvim** `:FetchConfluencePage`.

## Reference

See [REFERENCE.md](./REFERENCE.md) for:
- Full Atlassian MCP tool reference (Jira create / view / edit / transition / comments / JQL; Confluence create / edit / search)
- nvim fetch internals (which API endpoints, output format, threading, attachment behavior)
- `confluence-to-md.sh` body-only helper
- Environment variable setup (macOS Keychain / sops)
- Troubleshooting both tools

The `confluence-to-md.sh` helper script lives alongside this skill.
