---
name: using-atlassian-cli
description: Jira CRUD operations via Atlassian CLI (acli). Use when creating, reading, updating, or deleting Jira tickets and comments.
---

# Using Atlassian CLI (acli)

Jira CRUD operations from the terminal using `acli`.

## Quick Start

```bash
# Auth (one-time)
echo "$ATLASSIAN_API_TOKEN" > /tmp/token.txt && \
  acli jira auth login --site wonder.atlassian.net --email "$ATLASSIAN_EMAIL" --token < /tmp/token.txt && \
  rm /tmp/token.txt

# Create ticket
acli jira workitem create --project COPS --type Task \
  --summary "Add integration tests" --description-file desc.md \
  --assignee "712020:06f441a1-e941-43ab-884f-4cb37b207f95"

# View ticket
acli jira workitem view --key COPS-1234 --json | jq .

# Edit ticket
acli jira workitem edit --key COPS-1234 --summary "Updated summary"

# Add comment
acli jira workitem comment create --key COPS-1234 --body "Comment text"
```

## Wonder Config

| Setting | Value |
|---------|-------|
| Subdomain | `wonder.atlassian.net` |
| Project | `COPS` |
| Default Assignee | `712020:06f441a1-e941-43ab-884f-4cb37b207f95` |
| BA 2.0 Epic | `COPS-4865` |

## Environment Variables

Set automatically by home-manager:

| Variable | Source (macOS) | Source (cloudbox) |
|----------|---------------|-------------------|
| `ATLASSIAN_EMAIL` | `home.sessionVariables` | `home.sessionVariables` |
| `ATLASSIAN_CLOUD_ID` | `home.sessionVariables` | `home.sessionVariables` |
| `ATLASSIAN_API_TOKEN` | macOS Keychain (`atlassian-api-token`) | sops (`/run/secrets/atlassian_api_token`) |

## Ticket Writing Philosophy

- Lead with **impact** (problem/opportunity/benefit)
- Focus on **what** and **why**, minimal **how**
- Less technical detail than PRs
- Don't include ticket number in title

## Reference

See [REFERENCE.md](./REFERENCE.md) for:
- Full CRUD command reference
- Comment operations
- JQL search examples
- Troubleshooting
- Example workflows
