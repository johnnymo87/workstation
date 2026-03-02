# Scrub Company References Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement
> this plan task-by-task.

**Goal:** Remove all org-identifying metadata from source, moving runtime values
to sops/Keychain and anonymizing documentation examples.

**Architecture:** Existing per-platform secret pattern (sops on cloudbox, Keychain
on macOS, exported via bash initExtra). No new infrastructure -- just extending the
pattern to cover org-identifying metadata that was previously hardcoded.

**Tech Stack:** Nix/home-manager, sops-nix, macOS Keychain, Lua (Neovim)

**Design doc:** `docs/plans/2026-03-02-scrub-company-references-design.md`

---

### Task 1: Remove hardcoded Atlassian config from home.base.nix

**Files:**
- Modify: `users/dev/home.base.nix:142-147`

**Step 1: Remove the hardcoded session variables block**

Delete the entire block:

```nix
  # Atlassian (non-secret config; API token set per-platform via Keychain/sops)
  # Only on work machines (macOS + cloudbox)
  home.sessionVariables = lib.mkIf (isDarwin || isCloudbox) {
    ATLASSIAN_EMAIL = "jmohrbacher@wonder.com";
    ATLASSIAN_CLOUD_ID = "70497edc-9c59-45b2-8e47-e46913d4c6cf";
  };
```

These values move to Keychain (macOS) and sops (cloudbox) in Tasks 2-3.

**Step 2: Commit**

```bash
git add users/dev/home.base.nix
git commit -m "Remove hardcoded Atlassian config from home.base.nix

Values move to per-platform secrets (Keychain/sops) in
subsequent commits."
```

---

### Task 2: Add Keychain reads for new env vars on macOS

**Files:**
- Modify: `users/dev/home.darwin.nix:166-177`

**Step 1: Add Keychain reads for ATLASSIAN_SITE, ATLASSIAN_EMAIL, ATLASSIAN_CLOUD_ID**

In the `programs.bash.initExtra` block, after the existing `ATLASSIAN_VAL` read
(line 172) and before the Azure DevOps PAT read (line 175), add reads for the
three new vars. Also add `ATLASSIAN_SITE` before the existing token read.

The full initExtra block should become (existing + new lines interleaved):

```nix
    initExtra = lib.mkAfter ''
      # GitHub API token for gh CLI (from macOS Keychain)
      GH_TOKEN_VAL="$(/usr/bin/security find-generic-password -s github-api-token -w 2>/dev/null)" && export GH_TOKEN="$GH_TOKEN_VAL"
      unset GH_TOKEN_VAL

      # Atlassian config (from macOS Keychain)
      ATLASSIAN_SITE_VAL="$(/usr/bin/security find-generic-password -s atlassian-site -w 2>/dev/null)" && export ATLASSIAN_SITE="$ATLASSIAN_SITE_VAL"
      unset ATLASSIAN_SITE_VAL

      ATLASSIAN_EMAIL_VAL="$(/usr/bin/security find-generic-password -s atlassian-email -w 2>/dev/null)" && export ATLASSIAN_EMAIL="$ATLASSIAN_EMAIL_VAL"
      unset ATLASSIAN_EMAIL_VAL

      ATLASSIAN_CLOUD_ID_VAL="$(/usr/bin/security find-generic-password -s atlassian-cloud-id -w 2>/dev/null)" && export ATLASSIAN_CLOUD_ID="$ATLASSIAN_CLOUD_ID_VAL"
      unset ATLASSIAN_CLOUD_ID_VAL

      # Atlassian API token for acli / nvim Atlassian commands (from macOS Keychain)
      ATLASSIAN_VAL="$(/usr/bin/security find-generic-password -s atlassian-api-token -w 2>/dev/null)" && export ATLASSIAN_API_TOKEN="$ATLASSIAN_VAL"
      unset ATLASSIAN_VAL

      # Azure DevOps PAT for private artifact registry (from macOS Keychain)
      AZDO_VAL="$(/usr/bin/security find-generic-password -s azure-devops-pat -w 2>/dev/null)" && export SYSTEM_ACCESSTOKEN="$AZDO_VAL"
      unset AZDO_VAL

      for file in ~/.bashrc.d/*.bashrc; do
        [ -r "$file" ] && source "$file"
      done
    '';
```

**Step 2: Commit**

```bash
git add users/dev/home.darwin.nix
git commit -m "Add Keychain reads for Atlassian org config on macOS

ATLASSIAN_SITE, ATLASSIAN_EMAIL, ATLASSIAN_CLOUD_ID now read
from Keychain instead of hardcoded in Nix source."
```

---

### Task 3: Add sops secrets and reads for cloudbox

**Files:**
- Modify: `hosts/cloudbox/configuration.nix:60-65` (add secret declarations)
- Modify: `users/dev/home.cloudbox.nix:63-64` (remove hardcoded GCP project)
- Modify: `users/dev/home.cloudbox.nix:85-88` (add sops reads)

**Step 1: Declare new sops secrets in cloudbox configuration.nix**

After the `atlassian_api_token` block (line 65), add:

```nix
      # Atlassian org config (non-secret but org-identifying)
      atlassian_site = {
        owner = "dev";
        group = "dev";
        mode = "0400";
      };
      atlassian_email = {
        owner = "dev";
        group = "dev";
        mode = "0400";
      };
      atlassian_cloud_id = {
        owner = "dev";
        group = "dev";
        mode = "0400";
      };
      # GCP project name (org-identifying)
      google_cloud_project = {
        owner = "dev";
        group = "dev";
        mode = "0400";
      };
```

**Step 2: Remove hardcoded GOOGLE_CLOUD_PROJECT from home.cloudbox.nix**

Replace:

```nix
  # GCP project for Vertex AI (OpenCode auto-discovers this for google-vertex providers)
  home.sessionVariables.GOOGLE_CLOUD_PROJECT = "wonder-sandbox";
```

With a comment noting it moved to sops:

```nix
  # GCP project: read from sops in initExtra below (org-identifying, not in public source)
```

**Step 3: Add sops reads in home.cloudbox.nix initExtra**

After the existing `ATLASSIAN_API_TOKEN` read (line 88), add:

```bash
    # Atlassian org config (non-secret but org-identifying)
    if [ -r /run/secrets/atlassian_site ]; then
      export ATLASSIAN_SITE="$(cat /run/secrets/atlassian_site)"
    fi

    if [ -r /run/secrets/atlassian_email ]; then
      export ATLASSIAN_EMAIL="$(cat /run/secrets/atlassian_email)"
    fi

    if [ -r /run/secrets/atlassian_cloud_id ]; then
      export ATLASSIAN_CLOUD_ID="$(cat /run/secrets/atlassian_cloud_id)"
    fi

    # GCP project for Vertex AI
    if [ -r /run/secrets/google_cloud_project ]; then
      export GOOGLE_CLOUD_PROJECT="$(cat /run/secrets/google_cloud_project)"
    fi
```

**Step 4: Commit**

```bash
git add hosts/cloudbox/configuration.nix users/dev/home.cloudbox.nix
git commit -m "Move org-identifying config to sops on cloudbox

ATLASSIAN_SITE, ATLASSIAN_EMAIL, ATLASSIAN_CLOUD_ID, and
GOOGLE_CLOUD_PROJECT now read from sops secrets instead of
hardcoded Nix source."
```

**Note:** The actual sops values must be added manually:
`sops secrets/cloudbox.yaml` and add `atlassian_site`, `atlassian_email`,
`atlassian_cloud_id`, `google_cloud_project` keys.

---

### Task 4: Replace hardcoded values in opencode-config.nix (Basecamp)

**Files:**
- Modify: `users/dev/opencode-config.nix:120-157`

**Step 1: Add Keychain read for BASECAMP_ACCOUNT_ID**

In the `injectBasecampMcpSecrets` activation script, after the existing
`bc_username` and `bc_password` reads (lines 121-122), add:

```bash
      bc_account_id="$(/usr/bin/security find-generic-password -s basecamp-account-id -w 2>/dev/null || true)"
```

Update the guard condition (line 125) to also check `bc_account_id`:

```bash
      if [[ -z "''${bc_username}" ]] || [[ -z "''${bc_password}" ]] || [[ -z "''${bc_account_id}" ]]; then
```

**Step 2: Replace hardcoded values in the jq template**

In the jq invocation (line 140), add `--arg` for account_id and use vars
instead of literals:

```nix
        ${pkgs.jq}/bin/jq \
          --arg user "''${bc_username}" \
          --arg pass "''${bc_password}" \
          --arg home "$HOME" \
          --arg account_id "''${bc_account_id}" \
          '.mcp.basecamp = {
            "type": "local",
            "command": [
              ($home + "/Code/Basecamp-MCP-Server/.venv/bin/python"),
              ($home + "/Code/Basecamp-MCP-Server/basecamp_fastmcp.py")
            ],
            "enabled": false,
            "environment": {
              "BASECAMP_USERNAME": $user,
              "BASECAMP_PASSWORD": $pass,
              "BASECAMP_ACCOUNT_ID": $account_id,
              "USER_AGENT": ("Basecamp MCP Server (" + $user + ")")
            }
          }' "$runtime" > "$tmp"
```

Note: USER_AGENT now uses `$user` (the Basecamp username) instead of hardcoding
the company email. This is fine because the Basecamp username is typically an
email address anyway.

**Step 3: Commit**

```bash
git add users/dev/opencode-config.nix
git commit -m "Move Basecamp org config to Keychain

BASECAMP_ACCOUNT_ID read from Keychain. USER_AGENT uses the
Basecamp username instead of hardcoded company email."
```

---

### Task 5: Replace hardcoded URLs in atlassian.lua

**Files:**
- Modify: `assets/nvim/lua/user/atlassian.lua` (7 URL occurrences)

**Step 1: Add a helper function at the top of the module**

After line 1 (`local M = {}`), add:

```lua
-- Get Atlassian site from environment (e.g., "company.atlassian.net")
local function get_atlassian_site()
  local site = os.getenv("ATLASSIAN_SITE")
  if not site or site == "" then
    error("ATLASSIAN_SITE environment variable is not set. Set it in macOS Keychain (atlassian-site) or sops (cloudbox).")
  end
  return site
end
```

**Step 2: Replace all 7 occurrences**

Replace every `wonder.atlassian.net` with `' .. get_atlassian_site() .. '` in
the string concatenation context. Each line follows the pattern:

```lua
-- Before:
"--url 'https://wonder.atlassian.net/wiki/api/v2/%s/%s' " ..

-- After:
"--url 'https://" .. get_atlassian_site() .. "/wiki/api/v2/%s/%s' " ..
```

Apply this to all 7 lines: 72, 187, 247, 278, 381, 413, 527.

**Step 3: Commit**

```bash
git add assets/nvim/lua/user/atlassian.lua
git commit -m "Read Atlassian site from env var in atlassian.lua

Replace hardcoded wonder.atlassian.net with
os.getenv('ATLASSIAN_SITE'). Errors clearly if unset."
```

---

### Task 6: Anonymize skill docs (using-atlassian-cli)

**Files:**
- Modify: `assets/opencode/skills/using-atlassian-cli/SKILL.md`
- Modify: `assets/opencode/skills/using-atlassian-cli/REFERENCE.md`

**Step 1: Apply substitution table to SKILL.md**

| Find | Replace |
|------|---------|
| `wonder.atlassian.net` | `$ATLASSIAN_SITE` |
| `--project COPS` | `--project PROJ` |
| `COPS-1234` | `PROJ-1234` |
| `COPS-4865` | `PROJ-5678` |
| `712020:06f441a1-e941-43ab-884f-4cb37b207f95` | `$ATLASSIAN_ASSIGNEE_ID` |
| `## Wonder Config` | `## Org Config` |
| `BA 2.0 Epic` | `Active Epic` |

**Step 2: Apply substitution table to REFERENCE.md**

Same substitutions as above, plus:

| Find | Replace |
|------|---------|
| `project=COPS` | `project=PROJ` |
| `BA 2.0` | `Active Epic` |
| `https://wonder.atlassian.net/browse/COPS-1234` | `https://$ATLASSIAN_SITE/browse/PROJ-1234` |

**Step 3: Commit**

```bash
git add assets/opencode/skills/using-atlassian-cli/SKILL.md \
        assets/opencode/skills/using-atlassian-cli/REFERENCE.md
git commit -m "Anonymize Atlassian CLI skill docs

Replace company-specific values with generic placeholders
and env var references."
```

---

### Task 7: Anonymize skill docs (fetching-atlassian-content)

**Files:**
- Modify: `assets/claude/skills/fetching-atlassian-content/SKILL.md`
- Modify: `assets/claude/skills/fetching-atlassian-content/REFERENCE.md`

**Step 1: Apply substitution table to both files**

| Find | Replace |
|------|---------|
| `wonder.atlassian.net` | `company.atlassian.net` |
| `3963715585` | `1234567890` |
| `3963191313` | `0987654321` |
| `spaces/CT/` | `spaces/ENG/` |
| `Product+Catalog+Service` | `Example+Page+Title` |
| `product-catalog-service` | `example-page` |
| `COPS-1234` | `PROJ-1234` |

**Step 2: Commit**

```bash
git add assets/claude/skills/fetching-atlassian-content/SKILL.md \
        assets/claude/skills/fetching-atlassian-content/REFERENCE.md
git commit -m "Anonymize Atlassian content fetching skill docs

Replace company-specific Confluence page IDs, space keys,
and URLs with generic placeholders."
```

---

### Task 8: Anonymize cloudbox setup skill

**Files:**
- Modify: `.opencode/skills/setting-up-cloudbox/SKILL.md`

**Step 1: Replace all `wonder-sandbox` occurrences**

| Find | Replace |
|------|---------|
| `wonder-sandbox` | `my-gcp-project` |
| `the wonder-sandbox project` | `your GCP project` |
| `--project=wonder-sandbox` | `--project=my-gcp-project` |

There are ~6 occurrences across the file.

**Step 2: Commit**

```bash
git add .opencode/skills/setting-up-cloudbox/SKILL.md
git commit -m "Anonymize GCP project name in cloudbox setup skill"
```

---

### Task 9: Create scrubbing-company-references skill

**Files:**
- Create: `.opencode/skills/scrubbing-company-references/SKILL.md`
- Modify: `AGENTS.md` (add to skills table)

**Step 1: Write the skill**

Create `.opencode/skills/scrubbing-company-references/SKILL.md` documenting:
- What counts as a company reference
- The env var pattern (sops + Keychain)
- Anonymization conventions for docs
- Pre-commit grep checklist (patterns to search for)
- How to add new org-identifying values

**Step 2: Add to AGENTS.md skills table**

Add a row to the skills table:

```markdown
| [Scrubbing Company References](.opencode/skills/scrubbing-company-references/SKILL.md) | Policy for keeping org metadata out of public source |
```

**Step 3: Commit**

```bash
git add .opencode/skills/scrubbing-company-references/SKILL.md AGENTS.md
git commit -m "Add skill for scrubbing company references

Documents policy, env var pattern, anonymization conventions,
and pre-commit checklist."
```

---

### Task 10: Final verification grep

**Step 1: Run grep for remaining company references**

```bash
rg -i "wonder" --glob '!docs/plans/*' --glob '!.git/*'
```

This should return zero matches. If any remain, fix them.

**Step 2: Run grep for other org-identifying patterns**

```bash
rg -i "cops-[0-9]" --glob '!docs/plans/*' --glob '!.git/*'
rg "712020:" --glob '!docs/plans/*' --glob '!.git/*'
rg "3963715585\|3963191313" --glob '!docs/plans/*' --glob '!.git/*'
rg "70497edc" --glob '!docs/plans/*' --glob '!.git/*'
```

All should return zero matches.

**Step 3: Fix any remaining hits and commit**

---

### Task 11: Manual setup (not automated)

These require access to secrets and are done by the operator after merge.

**macOS Keychain:**

```bash
security add-generic-password -a atlassian -s atlassian-site -w "VALUE"
security add-generic-password -a atlassian -s atlassian-email -w "VALUE"
security add-generic-password -a atlassian -s atlassian-cloud-id -w "VALUE"
security add-generic-password -a basecamp -s basecamp-account-id -w "VALUE"
```

**Cloudbox sops:**

```bash
sops secrets/cloudbox.yaml
# Add keys: atlassian_site, atlassian_email, atlassian_cloud_id, google_cloud_project
```

**Apply:**

```bash
# macOS
sudo darwin-rebuild switch --flake ~/Code/workstation#Y0FMQX93RR-2

# Cloudbox
sudo nixos-rebuild switch --flake .#cloudbox
nix run home-manager -- switch --flake .#cloudbox
```
