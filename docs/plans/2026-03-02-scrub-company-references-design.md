# Scrub Company References

Remove org-identifying metadata from public repo source. Not rewriting git history.

## Context

Cybersecurity flagged company references (URLs, project names, email addresses) in
this public repo. No secrets were leaked, but org-identifying metadata (domains,
Jira project keys, Atlassian IDs, GCP project names) should not be in public source.

## Strategy

Three buckets for every reference:

1. **Env var** -- actual value needed at runtime. Move to sops (cloudbox) / Keychain
   (macOS), export via bash initExtra, reference as `$VAR` in code.
2. **Anonymize** -- useful as documentation examples. Replace with generic
   placeholders (`PROJ-1234`, `company.atlassian.net`).
3. **Remove** -- incidental, no value. Delete or reword.

## New Env Vars

| Env var | Cloudbox source | macOS source |
|---------|----------------|--------------|
| `ATLASSIAN_SITE` | sops `atlassian_site` | Keychain `atlassian-site` |
| `ATLASSIAN_EMAIL` | sops `atlassian_email` | Keychain `atlassian-email` |
| `ATLASSIAN_CLOUD_ID` | sops `atlassian_cloud_id` | Keychain `atlassian-cloud-id` |
| `GOOGLE_CLOUD_PROJECT` | sops `google_cloud_project` | N/A (cloudbox only) |
| `BASECAMP_ACCOUNT_ID` | N/A (macOS only) | Keychain `basecamp-account-id` |

## File Changes

### Nix config (env var bucket)

- **`home.base.nix`** -- Remove hardcoded `ATLASSIAN_EMAIL` and `ATLASSIAN_CLOUD_ID`
  from `home.sessionVariables`.
- **`home.darwin.nix`** -- Add Keychain reads in `initExtra` for `ATLASSIAN_SITE`,
  `ATLASSIAN_EMAIL`, `ATLASSIAN_CLOUD_ID`, `BASECAMP_ACCOUNT_ID`.
- **`home.cloudbox.nix`** -- Add sops reads in `initExtra` for `ATLASSIAN_SITE`,
  `ATLASSIAN_EMAIL`, `ATLASSIAN_CLOUD_ID`. Move `GOOGLE_CLOUD_PROJECT` from
  hardcoded to sops-read.
- **`hosts/cloudbox/configuration.nix`** -- Declare new sops secrets.
- **`secrets/cloudbox.yaml`** -- Add new encrypted values.
- **`opencode-config.nix`** -- Replace hardcoded `espresso@wonder.com` with
  `$ATLASSIAN_EMAIL`, hardcoded `3671212` with `$BASECAMP_ACCOUNT_ID` (read from
  Keychain in activation script).

### Lua (env var bucket)

- **`atlassian.lua`** -- Replace all `wonder.atlassian.net` with
  `os.getenv("ATLASSIAN_SITE")`. Error if unset.

### Skill docs (anonymize bucket)

| Current | Replacement |
|---------|-------------|
| `wonder.atlassian.net` | `$ATLASSIAN_SITE` (commands) / `company.atlassian.net` (prose) |
| `COPS` / `COPS-1234` | `PROJ` / `PROJ-1234` |
| `COPS-4865` / "BA 2.0" | `PROJ-5678` / "Active Epic" |
| `712020:06f441a1-...` | `$ATLASSIAN_ASSIGNEE_ID` or placeholder |
| `3963715585`, `3963191313` | `1234567890`, `0987654321` |
| `spaces/CT/` | `spaces/ENG/` |
| `Product+Catalog+Service` | `Example+Page+Title` |
| `wonder-sandbox` | `$GOOGLE_CLOUD_PROJECT` or `my-gcp-project` |

Files affected:
- `assets/opencode/skills/using-atlassian-cli/SKILL.md`
- `assets/opencode/skills/using-atlassian-cli/REFERENCE.md`
- `assets/claude/skills/fetching-atlassian-content/SKILL.md`
- `assets/claude/skills/fetching-atlassian-content/REFERENCE.md`
- `.opencode/skills/setting-up-cloudbox/SKILL.md`

### Section headers (remove bucket)

| Current | Replacement |
|---------|-------------|
| `## Wonder Config` | `## Org Config` |
| "BA 2.0" references | "Active Epic" |

## New Skill

`.opencode/skills/scrubbing-company-references/SKILL.md` -- documents:
- What counts as a company reference
- The env var pattern (sops + Keychain)
- How to write anonymized doc examples
- Pre-commit grep checklist

## Setup After Apply

### macOS Keychain (one-time)

```bash
security add-generic-password -a atlassian -s atlassian-site -w "wonder.atlassian.net"
security add-generic-password -a atlassian -s atlassian-email -w "jmohrbacher@wonder.com"
security add-generic-password -a atlassian -s atlassian-cloud-id -w "70497edc-9c59-45b2-8e47-e46913d4c6cf"
security add-generic-password -a basecamp -s basecamp-account-id -w "3671212"
```

### Cloudbox sops (one-time)

```bash
sops secrets/cloudbox.yaml
# Add: atlassian_site, atlassian_email, atlassian_cloud_id, google_cloud_project
```

## Not Doing

- Git history rewrite -- values are in past commits, accepted risk
- Making repo private -- author refers people to it
- Encrypting these values on macOS differently than Keychain -- matches existing pattern
