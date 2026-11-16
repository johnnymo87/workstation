---
name: using-atlassian
description: Use when reading or writing Jira tickets, fetching Confluence pages, searching with JQL, adding comments, or downloading Atlassian attachments from this host.
---

# Using Atlassian (Jira + Confluence)

Two complementary tools. **Read this whole file before choosing one** — picking the wrong tool is the most common mistake.

- **Atlassian MCP** (`atlassian` MCP server): mutations, JQL/CQL search, arbitrary fields, and Confluence create/edit. This is the default for everything except rich reads. Tool names in this skill are the server's own; opencode exposes them as `atlassian_<tool>` (e.g. `atlassian_createJiraIssue`). The server is Atlassian MCP **v2**: only ~25 tools are in your tool list, and everything else is reached through `discover` (see "Tools not in your list" below).
- **nvim** (`:FetchJiraTicket` / `:FetchConfluencePage`): the best *read* path — it renders a ticket or page (plus threaded comments and image attachments) to Markdown on disk.

## Decision Matrix

| Workflow | Use |
|----------|-----|
| Read a Jira ticket as context (rendered Markdown + image attachments) | **nvim** `:FetchJiraTicket` |
| Read a Confluence page (with comments + PNG diagrams) | **nvim** `:FetchConfluencePage` |
| Archive Atlassian content to disk for offline reference | **nvim** |
| Create a new Jira ticket | **MCP** `createJiraIssue` |
| Edit a ticket's summary / description / status / assignee | **MCP** `editJiraIssue` / `transitionJiraIssue` |
| Add or edit a comment | **MCP** `addOrEditJiraIssueComment` |
| JQL search ("my open tickets in epic X") | **MCP** `searchJiraIssuesUsingJql` |
| Read non-default Jira fields (custom fields, labels, story points, sprint, fix version, parent epic) | **MCP** `getJiraIssue` |
| Read a service-desk request the human raised through a customer portal (the MCP and nvim answer 404) | `reading-jsm-portal-requests` skill |
| Raise a service-desk (portal) request, or reply on one, when the human asked you to | `reading-jsm-portal-requests` skill (`jsm-write.sh`) |
| Confluence page **body only**, no images/comments | Either; `confluence-to-md.sh` is lightest |
| Confluence with comments or attachments | **nvim** (only option) |
| Create / edit Confluence pages | **MCP** `createConfluenceContent` / `updateConfluenceContent` |
| CQL search | **MCP** `searchConfluence` |
| Anything else (transitions list, user lookup, worklogs, links, Confluence comments, ...) | **MCP** `discover`, then `executeRead` / `executeWrite` |

**Rule of thumb:**
- **Reading rich content (rendered Markdown + images + comments) → nvim.**
- **Mutations, JQL/CQL, arbitrary Jira fields, Confluence authoring → Atlassian MCP.**

## If the Atlassian MCP is unavailable: STOP and report

If you cannot get the `atlassian` MCP tools — `oc-mcp-enable` (or `opencode-launch --mcp
atlassian`) fails, the connect reports any status other than `connected`, or the tools never
appear in your tool list — **stop and tell the human**. Quote the error verbatim and say
which write you were about to make.

**Do not fall back to the Jira or Confluence REST API.** Your bash environment holds
`ATLASSIAN_EMAIL` / `ATLASSIAN_API_TOKEN` because the nvim read path and
`confluence-to-md.sh` need them. They are not a backup route for writes, and the human has
said so after an agent used them that way: on 2026-10-22, with the MCP failing to connect,
an agent posted and then edited a Jira comment over REST, which the human did not want.
"The MCP is down, so I used curl" is not acceptable for comments, ticket edits,
transitions, or Confluence pages. Waiting for the human costs less than an unsanctioned
write under their name.

Reads stay on their sanctioned path: nvim `:FetchJiraTicket` / `:FetchConfluencePage`,
`confluence-to-md.sh` and the `reading-jsm-portal-requests` helper do not depend on the MCP
and are fine to use while it is down.

The one REST write path is `reading-jsm-portal-requests`' `jsm-write.sh`, and it is for
portal requests only: the MCP cannot raise or comment on a request in a desk where the human
is just a customer. It is not a fallback for ordinary issues.

## Tools not in your list: `discover` first

v2 lists a small set of primary tools directly: `getJiraIssue`, `createJiraIssue`,
`editJiraIssue`, `transitionJiraIssue`, `addOrEditJiraIssueComment`,
`listJiraIssueComments`, `searchJiraIssuesUsingJql`, `getConfluenceContent`,
`createConfluenceContent`, `updateConfluenceContent`, `searchConfluence`,
`getAccessibleAtlassianResources`, `atlassianUserInfo`, plus a few Teamwork Graph
and Loom tools. **The other ~400 operations are deferred** — e.g.
`listJiraIssueTransitions`, `lookupJiraAccountId`, `listJiraIssueAssignableUsers`,
`createJiraIssueLink`, `addOrEditJiraIssueWorklog`, `createConfluenceComment`,
`getConfluenceSpace`, `getContentFormatGuide`.

To use one:

1. Call `discover` with a natural-language `query` ("list transitions for a Jira
   issue"). It returns up to 5 matches with the exact operation name and inputs.
2. Call `executeRead` (reads), `executeWrite` (creates/updates), or
   `executeDestructive` (deletes) with `cloudId`, `name` (from discover), and a
   flat `inputs` object.

**Never guess an operation name** — a name that isn't in your tool list or a
`discover` result will fail. An operation missing from your tool list does not
mean the MCP can't do it; `discover` before concluding that. Do not flip the
server to `?tools=all` to avoid this step: that loads hundreds of tool schemas into
every turn's context.

`cloudId` is required by nearly every tool. Use `$ATLASSIAN_CLOUD_ID`, the
`getAccessibleAtlassianResources` result, or (per the server) a Jira/Confluence
URL for the site.

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
(`PROJ`), `issueType` (`Task`, `Bug`, `Story`, `Epic`, …), `summary`, and a
Markdown `description`. Set `assignee` to `$ATLASSIAN_ASSIGNEE_ID` (an account
ID). `parent` takes an epic/parent key; other custom fields go in
`additional_fields`.

**Format gotcha — always use GitHub-Flavored Markdown, never Jira wiki markup.** The Atlassian MCP (and the underlying Cloud REST API v3) expects descriptions and comment bodies in Markdown — `# heading`, `**bold**`, `` `code` ``, `[text](url)`, `| col | col |` tables — and converts to ADF on the way in. Jira wiki markup (`h2.`, `*bold*`, `{{code}}`, `[text|url]`, `|| col || col ||`) renders as literal text and is the most common mistake when an LLM drafts a ticket. If you see your description rendering with literal `h2.` or `{{...}}` in the Jira UI, you used wiki markup — re-edit with Markdown.

### Add a comment (MCP)

Call `addOrEditJiraIssueComment` with `cloudId`, the `issueIdOrKey` (`PROJ-1234`) and a Markdown `commentBody`. Omit `commentId` to add; pass one (from `listJiraIssueComments`) to edit, which **replaces the whole body**. Comment bodies follow the same rule: **Markdown only, never wiki markup.**

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

Create content with `createConfluenceContent` (`cloudId`, `parent` = `{"spaceId": ...}` or `{"spaceId": ..., "parentContentId": ...}`, `contentType` = `page` / `live_doc` / `blogpost` / …, `title`, `body`) and edit with `updateConfluenceContent` (`contentId`, `snapshotToken` from the latest `getConfluenceContent`, then a full `body` or granular `edits`). Both tool descriptions require reading the format guide first (`executeRead` with `name=getContentFormatGuide`) and honouring the space's instructions; follow them. Comments are deferred: `discover` → `createConfluenceComment`. For *reading* a page with its threaded comments and diagrams rendered, still prefer **nvim** `:FetchConfluencePage`.

## Reference

See [REFERENCE.md](./REFERENCE.md) for:
- Atlassian MCP v2 tool reference (Jira create / view / edit / transition / comments / JQL; Confluence create / edit / search; discover/execute)
- nvim fetch internals (which API endpoints, output format, threading, attachment behavior)
- `confluence-to-md.sh` body-only helper
- Environment variable setup (macOS Keychain / sops)
- Troubleshooting both tools

The `confluence-to-md.sh` helper script lives alongside this skill.
