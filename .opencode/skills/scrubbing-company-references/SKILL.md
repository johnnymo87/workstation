---
name: Scrubbing Company References
description: Policy for keeping org-identifying metadata out of public source. Use when adding new config, writing skill docs, or reviewing for company references before committing.
---

# Scrubbing Company References

This is a public repo. Org-identifying metadata (company domains, Jira project
keys, Atlassian IDs, GCP project names, email addresses) must not appear in
committed source.

## What Counts as a Company Reference

- Company email addresses (e.g., `user@company.com`)
- Atlassian site URLs (e.g., `company.atlassian.net`)
- Atlassian Cloud IDs, account IDs, assignee IDs
- Jira project keys (e.g., `PROJ-1234`)
- GCP project names
- Basecamp account IDs
- Confluence space keys and page IDs (real ones)
- Internal project/epic names
- Any URL or identifier that ties back to a specific organization

## Strategy

Three buckets for every reference:

### 1. Env Var (runtime values)

Values needed at runtime go into per-platform secret storage and are exported
as env vars via bash initExtra.

| Platform | Storage | Export mechanism |
|----------|---------|-----------------|
| macOS | Keychain (`security add-generic-password`) | `initExtra` in `home.darwin.nix` |
| Cloudbox | sops-nix (`secrets/cloudbox.yaml`) | `initExtra` in `home.cloudbox.nix` |

Current env vars managed this way:

| Env var | Keychain service | sops key |
|---------|-----------------|----------|
| `ATLASSIAN_SITE` | `atlassian-site` | `atlassian_site` |
| `ATLASSIAN_EMAIL` | `atlassian-email` | `atlassian_email` |
| `ATLASSIAN_CLOUD_ID` | `atlassian-cloud-id` | `atlassian_cloud_id` |
| `ATLASSIAN_API_TOKEN` | `atlassian-api-token` | `atlassian_api_token` |
| `BASECAMP_ACCOUNT_ID` | `basecamp-account-id` | N/A |
| `GOOGLE_CLOUD_PROJECT` | N/A | `google_cloud_project` |

**To add a new env var:**
1. macOS: Add Keychain read in `users/dev/home.darwin.nix` initExtra
2. Cloudbox: Add sops secret in `hosts/cloudbox/configuration.nix`, add read in
   `users/dev/home.cloudbox.nix` initExtra, encrypt value in `secrets/cloudbox.yaml`
3. Reference as `$VAR_NAME` in code and docs

### 2. Anonymize (documentation examples)

Skill docs use generic placeholders instead of real values:

| Real pattern | Replacement |
|-------------|-------------|
| Company Atlassian site | `$ATLASSIAN_SITE` (commands) or `company.atlassian.net` (prose) |
| Jira project key | `PROJ` |
| Jira ticket | `PROJ-1234` |
| Atlassian assignee ID | `$ATLASSIAN_ASSIGNEE_ID` |
| Confluence page IDs | `1234567890` |
| Confluence space key | `ENG` |
| GCP project | `my-gcp-project` |
| Company email | `user@company.com` |

### 3. Remove (incidental references)

References with no documentation value -- delete or reword.

## Pre-Commit Checklist

Before committing, run these checks:

```bash
# Primary patterns
rg -i "wonder" --glob '!docs/plans/*' --glob '!.git/*'
rg "cops-[0-9]" -i --glob '!docs/plans/*' --glob '!.git/*'

# IDs and domains
rg "70497edc|712020:|3963715585|3963191313" --glob '!.git/*'

# Email patterns (check for company domains)
rg "@(wonder|company-name)\." --glob '!.git/*'
```

All should return zero matches (excluding plan docs which may reference the
scrubbing effort itself).

## Adding New Org Config

When you need a new org-identifying value at runtime:

1. Choose the env var name (e.g., `NEW_ORG_VALUE`)
2. Add Keychain service on macOS: `security add-generic-password -a account -s service-name -w "value"`
3. Add Keychain read in `home.darwin.nix` initExtra
4. Add sops key in `secrets/cloudbox.yaml` (if needed on cloudbox)
5. Add sops declaration in `hosts/cloudbox/configuration.nix`
6. Add sops read in `home.cloudbox.nix` initExtra
7. Update the env var table in this skill
