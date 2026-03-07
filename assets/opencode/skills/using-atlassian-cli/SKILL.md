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
  acli jira auth login --site "$ATLASSIAN_SITE" --email "$ATLASSIAN_EMAIL" --token < /tmp/token.txt && \
  rm /tmp/token.txt

# Create ticket
acli jira workitem create --project PROJ --type Task \
  --summary "Add integration tests" --description-file desc.md \
  --assignee "$ATLASSIAN_ASSIGNEE_ID"

# View ticket
acli jira workitem view --key PROJ-1234 --json | jq .

# Edit ticket
acli jira workitem edit --key PROJ-1234 --summary "Updated summary"

# Add comment
acli jira workitem comment create --key PROJ-1234 --body "Comment text"
```

## Org Config

| Setting | Value |
|---------|-------|
| Subdomain | `$ATLASSIAN_SITE` |
| Project | `PROJ` |
| Default Assignee | `$ATLASSIAN_ASSIGNEE_ID` |
| Active Epic | `PROJ-5678` |

## Multiple Instances

Two Atlassian instances are configured: `default` and `alt`. Shell startup loads the default instance. To target the alt instance:

```bash
switch-atlassian alt    # swap ATLASSIAN_* env vars to alt instance
# ... run acli commands ...
switch-atlassian default  # restore
```

Re-authenticate after switching (`acli jira auth login` uses the active env vars).

## Environment Variables

Set automatically by home-manager:

| Variable | Source (macOS) | Source (cloudbox) |
|----------|---------------|-------------------|
| `ATLASSIAN_SITE` | macOS Keychain (`atlassian-site`) | sops (`/run/secrets/atlassian_site`) |
| `ATLASSIAN_EMAIL` | macOS Keychain (`atlassian-email`) | sops (`/run/secrets/atlassian_email`) |
| `ATLASSIAN_CLOUD_ID` | macOS Keychain (`atlassian-cloud-id`) | sops (`/run/secrets/atlassian_cloud_id`) |
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
