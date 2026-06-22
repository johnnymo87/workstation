---
name: scrubbing-company-references
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
| `GOOGLE_CLOUD_PROJECT` | `google-cloud-project` | `google_cloud_project` |
| `BUILDBUDDY_HOST` | `buildbuddy-host` | `buildbuddy_host` |
| `BUNDLE_<HOST>` (composed) | `bundle-source-host` + `bundle-source-token` | `bundle_source_host` + `bundle_source_token` |

**To add a new env var:**
1. macOS: Add Keychain read in `users/dev/home.darwin.nix` initExtra
2. Cloudbox: Add sops secret in `hosts/cloudbox/configuration.nix`, add read in
   `users/dev/home.cloudbox.nix` initExtra, encrypt value in `secrets/cloudbox.yaml`
3. Reference as `$VAR_NAME` in code and docs

### 1a. Vendor-Encoded Env Var Names

Some tools mandate env var names that themselves encode the vendor host —
e.g., Bundler's `BUNDLE_<HOST_UPPER_WITH_DOTS_AS_DOUBLE_UNDERSCORES>` for
private gem source credentials. The literal name `BUNDLE_FURY__FRESHREALM__COM`
in source leaks the host even when the value is in a secret store.

Solution: store the host as a separate secret too, then compose the env var
name dynamically at shell init:

```bash
# Cloudbox (sops): both bundle_source_host and bundle_source_token
if [ -r /run/secrets/bundle_source_host ] && [ -r /run/secrets/bundle_source_token ]; then
  _bundle_host="$(cat /run/secrets/bundle_source_host)"
  _bundle_var="BUNDLE_$(printf '%s' "$_bundle_host" | tr '[:lower:]' '[:upper:]' | sed 's/\./__/g')"
  export "$_bundle_var=$(cat /run/secrets/bundle_source_token)"
  unset _bundle_host _bundle_var
fi

# macOS (Keychain): bundle-source-host and bundle-source-token
_bundle_host="$(/usr/bin/security find-generic-password -s bundle-source-host -w 2>/dev/null)"
_bundle_token="$(/usr/bin/security find-generic-password -s bundle-source-token -w 2>/dev/null)"
if [ -n "$_bundle_host" ] && [ -n "$_bundle_token" ]; then
  _bundle_var="BUNDLE_$(printf '%s' "$_bundle_host" | tr '[:lower:]' '[:upper:]' | sed 's/\./__/g')"
  export "$_bundle_var=$_bundle_token"
  unset _bundle_var
fi
unset _bundle_host _bundle_token
```

The same pattern generalizes to any tool with a `<TOOL>_<HOST>=...` env var
convention. If only one such host is needed, two secrets (`<tool>_source_host`
and `<tool>_source_token`) cover it; if multiple, store a list and loop.

### 1b. Templating Secrets Into Config Files

When a config file in `$HOME` (`~/.bazelrc`, `~/.npmrc`, etc.) needs an
org-identifying URL or hostname, **do not use `home.file.<path>`** — that
embeds the value in the Nix store as a publicly-readable file. Instead, use
a `home.activation.generate<File>` script that reads from sops/Keychain at
activation time and writes the file directly.

Pattern (see `home.activation.generateNpmrc` and `generateBazelrc` in
`users/dev/home.base.nix` for working examples):

```nix
home.activation.generateFooConfig = lib.mkIf (isDarwin || isCloudbox)
  (lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    OUT="$HOME/.foorc"
    rm -f "$OUT"
    VALUE=""
    ${if isCloudbox then ''
      [ -r /run/secrets/foo_url ] && VALUE=$(cat /run/secrets/foo_url)
    '' else ''
      VALUE=$(/usr/bin/security find-generic-password -s foo-url -w 2>/dev/null || true)
    ''}
    {
      echo "# Managed by home-manager — edits will be overwritten"
      [ -n "$VALUE" ] && echo "url = $VALUE"
    } > "$OUT"
  '');
```

Trade-off: home-manager won't symlink-manage the file, so it survives
home-manager removal (orphan); accept that for the sake of keeping the secret
out of the Nix store and out of source.

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
# Primary patterns (company names + product/org slugs)
rg -i "wonder|freshrealm|food-truck|blueapron" --glob '!docs/plans/*' --glob '!.git/*' --glob '!**/issues.jsonl'
rg "cops-[0-9]" -i --glob '!docs/plans/*' --glob '!.git/*' --glob '!**/issues.jsonl'

# Container registries + AKS cluster identifiers (infra hosts/names encode org).
# Generic patterns on purpose -- do NOT paste the private namespace/deployment
# strings here; those live only in skill INTERNAL.md companions (Confluence).
rg -i "azurecr\.io|akscluster" --glob '!docs/plans/*' --glob '!.git/*' --glob '!**/issues.jsonl'

# IDs and domains
rg "70497edc|712020:|3963715585|3963191313" --glob '!.git/*' --glob '!**/issues.jsonl'

# Email patterns (check for company / vendor domains)
rg "@(wonder|freshrealm|company-name)\." --glob '!.git/*' --glob '!**/issues.jsonl'

# GCS bucket leaks (bucket names often encode the GCP project)
rg "storage\.googleapis\.com/[a-z0-9-]+|gs://" --glob '!docs/plans/*' --glob '!.git/*' --glob '!**/issues.jsonl'
```

All should return zero matches (excluding plan docs, which may reference the
scrubbing effort itself, and `.beads/issues.jsonl`, which preserves issue
history that may legitimately mention these as past context).

## Adding New Org Config

When you need a new org-identifying value at runtime:

1. Choose the env var name (e.g., `NEW_ORG_VALUE`)
2. Add Keychain service on macOS: `security add-generic-password -a account -s service-name -w "value"`
3. Add Keychain read in `home.darwin.nix` initExtra
4. Add sops key in `secrets/cloudbox.yaml` (if needed on cloudbox)
5. Add sops declaration in `hosts/cloudbox/configuration.nix`
6. Add sops read in `home.cloudbox.nix` initExtra
7. Update the env var table in this skill
