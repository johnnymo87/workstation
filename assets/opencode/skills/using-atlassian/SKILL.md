---
name: using-atlassian
description: Use when reading or writing Jira tickets, fetching Confluence pages, searching with JQL, adding comments, or downloading Atlassian attachments from this devbox.
---

# Using Atlassian (Jira + Confluence)

Two complementary tools. **Read this whole file before choosing one** — picking the wrong tool is the most common mistake.

## Decision Matrix

| Workflow | Use |
|----------|-----|
| Read a Jira ticket as context (rendered Markdown + image attachments) | **nvim** `:FetchJiraTicket` |
| Read a Confluence page (with comments + PNG diagrams) | **nvim** `:FetchConfluencePage` |
| Archive Atlassian content to disk for offline reference | **nvim** |
| Create a new Jira ticket | **acli** (only option) |
| Edit a ticket's summary / description / status / assignee | **acli** (only option) |
| Add / update / delete a comment | **acli** (only option) |
| JQL search ("my open tickets in epic X") | **acli** (only option) |
| Read non-default Jira fields (custom fields, labels, story points, sprint, fix version, parent epic) | **acli** `workitem view --json \| jq` |
| Confluence page **body only**, no images/comments | Either; `confluence-to-md.sh` is lightest |
| Confluence with comments or attachments | **nvim** (only option) |
| Create / edit Confluence pages or comments | **Neither** — gap. Use REST API directly or web UI. |

**Rule of thumb:**
- **Reading rich content (rendered Markdown + images + comments) → nvim.**
- **Mutations, JQL, arbitrary Jira fields → acli.**

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

### Create a Jira ticket (acli)

```bash
acli jira workitem create --project PROJ --type Task \
  --summary "Add integration tests" --description-file desc.md \
  --assignee "$ATLASSIAN_ASSIGNEE_ID"
```

### Add a comment (acli)

```bash
acli jira workitem comment create --key PROJ-1234 --body "Reduces manual QA burden."
```

### JQL search (acli)

```bash
acli jira workitem search --jql \
  'project=PROJ AND assignee="'"$ATLASSIAN_ASSIGNEE_ID"'" AND statusCategory!=Done' --json | jq .
```

### Read arbitrary Jira fields (acli)

```bash
acli jira workitem view --key PROJ-1234 --json | jq '.fields.customfield_10001'
```

## Org Config

| Setting | Value |
|---------|-------|
| Subdomain | `$ATLASSIAN_SITE` |
| Project | `PROJ` |
| Default Assignee | `$ATLASSIAN_ASSIGNEE_ID` |
| Active Epic | `PROJ-5678` |

## Multiple Instances

Two Atlassian instances configured: `default` and `alt`. Shell startup loads `default`.

```bash
switch-atlassian alt    # swap ATLASSIAN_* env vars
# acli requires re-auth after switching: acli jira auth login --site ... --email ... --token < ...
# nvim re-reads env on each command, no re-auth needed
switch-atlassian default
```

## Ticket Writing Philosophy

- Lead with **impact** (problem / opportunity / benefit)
- Focus on **what** and **why**, minimal **how**
- Less technical detail than PRs
- Don't put the ticket number in the title

## Known Gap

**Neither tool can create or edit Confluence pages or comments.** For that, hit the Confluence REST API directly or use the web UI.

## Reference

See [REFERENCE.md](./REFERENCE.md) for:
- Full `acli` command reference (create / view / edit / delete / comments / JQL / auth)
- nvim fetch internals (which API endpoints, output format, threading, attachment behavior)
- `confluence-to-md.sh` body-only helper
- Environment variable setup (macOS Keychain / sops)
- Troubleshooting both tools

The `confluence-to-md.sh` helper script lives alongside this skill.
