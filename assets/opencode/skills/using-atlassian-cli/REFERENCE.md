# Atlassian CLI Reference

## Prerequisites

### Environment Variables
Configured automatically by home-manager (session variables + secrets):
- `ATLASSIAN_EMAIL` — set in `home.base.nix`
- `ATLASSIAN_CLOUD_ID` — set in `home.base.nix`
- `ATLASSIAN_API_TOKEN` — macOS Keychain or sops (per-platform)

### Required Tools
- `acli` - Atlassian CLI
- `jq` - JSON parsing

## Authentication

```bash
# One-time login (file redirection required - piping doesn't work)
echo "$ATLASSIAN_API_TOKEN" > /tmp/token.txt && \
  acli jira auth login \
    --site wonder.atlassian.net \
    --email "$ATLASSIAN_EMAIL" \
    --token < /tmp/token.txt && \
  rm /tmp/token.txt

# Check status
acli jira auth status
```

## CRUD Operations

### Create Issue

```bash
acli jira workitem create \
  --project COPS \
  --type Task \
  --summary "Add integration tests for payment processing" \
  --description-file desc.md \
  --assignee "712020:06f441a1-e941-43ab-884f-4cb37b207f95"

# Issue types: Task, Bug, Story, Epic, etc.
```

### Read Issue

```bash
# Full details
acli jira workitem view --key COPS-1234 --json | jq .

# Specific fields
acli jira workitem view --key COPS-1234 --json | jq '.fields.summary'
```

### Update Issue

```bash
# Update summary/description
acli jira workitem edit \
  --key COPS-1234 \
  --summary "Add integration tests for payments (incl. refunds)" \
  --description-file desc-updated.md

# Update other fields
acli jira workitem edit --key COPS-1234 --assignee "user@example.com"
acli jira workitem edit --key COPS-1234 --status "In Review"
```

### Delete Issue

```bash
# Will prompt unless --yes
acli jira workitem delete --key COPS-1234 --yes
```

## Search (JQL)

```bash
# My open tickets
acli jira workitem search --jql \
  'project=COPS AND assignee="712020:06f441a1-e941-43ab-884f-4cb37b207f95" AND statusCategory!=Done'

# Open tickets in BA 2.0 epic
acli jira workitem search --jql \
  'project=COPS AND "Epic Link"=COPS-4865 AND status!="Done"' --json
```

## Comments

```bash
# List
acli jira workitem comment list --key COPS-1234 --json | jq .

# Create
acli jira workitem comment create --key COPS-1234 \
  --body "This reduces manual QA burden."

# Update last comment
acli jira workitem comment update --key COPS-1234 \
  --edit-last \
  --body "Updated: added retry logic."

# Update specific comment
acli jira workitem comment update --key COPS-1234 \
  --comment-id 123456 \
  --body "Updated comment"

# Delete
acli jira workitem comment delete --comment-id 123456
```

## Example Workflow: Create Bug Ticket

```bash
# 1. Write description
cat > bug-desc.md <<'EOF'
Users experience authentication timeouts when submitting orders during peak traffic.

This causes order failures and user frustration. Issue appears related to session
token expiry not being refreshed before long-running operations.

Proposed fix: implement token refresh logic before order submission API calls.
EOF

# 2. Create ticket
acli jira workitem create \
  --project COPS \
  --type Bug \
  --summary "Fix authentication timeout on order submission" \
  --description-file bug-desc.md \
  --assignee "712020:06f441a1-e941-43ab-884f-4cb37b207f95"

# 3. Verify (output shows key like COPS-1234)
# Open: https://wonder.atlassian.net/browse/COPS-1234
```

## Best Practices

1. **Lead with impact** - What's the problem? Why does it matter?
2. **Verify epic assignment** - BA 2.0 work -> `COPS-4865`
3. **Use accountId for assignee** - More reliable than email
4. **Verify environment** - `env | grep ATLASSIAN` before operations

## Troubleshooting

### Environment Variables Not Set

```bash
env | grep ATLASSIAN
# Should see ATLASSIAN_EMAIL, ATLASSIAN_CLOUD_ID, and ATLASSIAN_API_TOKEN
```

On macOS, if `ATLASSIAN_API_TOKEN` is missing:
```bash
# Check Keychain
/usr/bin/security find-generic-password -s atlassian-api-token -w

# Add if missing
/usr/bin/security add-generic-password -a atlassian -s atlassian-api-token -w "YOUR_TOKEN"
```

On cloudbox, if missing:
```bash
# Check sops secret
cat /run/secrets/atlassian_api_token

# If missing, update secrets/cloudbox.yaml and re-apply NixOS
```

### acli Not Authenticated

```bash
acli jira auth status

# Re-auth if needed
echo "$ATLASSIAN_API_TOKEN" > /tmp/token.txt && \
  acli jira auth login \
    --site wonder.atlassian.net \
    --email "$ATLASSIAN_EMAIL" \
    --token < /tmp/token.txt && \
  rm /tmp/token.txt
```
