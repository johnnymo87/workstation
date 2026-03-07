# Atlassian Multi-Instance Support

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Support two Atlassian instances (default + alt) across all tools (nvim, acli, MCP) on macOS and cloudbox without leaking org-identifying info into version control.

**Architecture:** Generic profile names (`default`/`alt`) with credentials in Keychain (macOS) and sops (cloudbox). A `switch-atlassian` bash function swaps env vars for CLI tools. Two MCP server entries with wrapper scripts that read site URLs from credentials at runtime. Endpoint updated from deprecated `/v1/sse` to `/v1/mcp`.

**Tech Stack:** Nix (home-manager, NixOS), sops-nix, macOS Keychain, shell scripting, mcp-remote `--resource` flag.

---

### Task 1: Add alt sops secrets to cloudbox

**Files:**
- Modify: `secrets/cloudbox.yaml`
- Modify: `hosts/cloudbox/configuration.nix`

**Step 1: Add 4 new encrypted secrets to cloudbox.yaml**

Using `sops secrets/cloudbox.yaml`, add these keys alongside the existing `atlassian_*` entries:

```
atlassian_alt_api_token: <encrypted>
atlassian_alt_site: <encrypted>
atlassian_alt_email: <encrypted>
atlassian_alt_cloud_id: <encrypted>
```

**Step 2: Declare secrets in NixOS configuration**

In `hosts/cloudbox/configuration.nix`, after the existing `atlassian_cloud_id` secret declaration (around line 81), add:

```nix
    atlassian_alt_api_token = {
      owner = "dev";
      group = "dev";
      mode = "0400";
    };
    atlassian_alt_site = {
      owner = "dev";
      group = "dev";
      mode = "0400";
    };
    atlassian_alt_email = {
      owner = "dev";
      group = "dev";
      mode = "0400";
    };
    atlassian_alt_cloud_id = {
      owner = "dev";
      group = "dev";
      mode = "0400";
    };
```

**Verify:** `nix flake check` passes. Secrets are not committed in plaintext.

**Note:** This task requires access to the cloudbox age key to encrypt values. If the key is not available locally, create the sops entries with placeholder values and re-encrypt on the cloudbox itself.

---

### Task 2: Add switch-atlassian to macOS

**Files:**
- Modify: `users/dev/home.darwin.nix`

**Step 1: Load alt credentials at shell startup**

In `programs.bash.initExtra` (after the existing Atlassian block ending at line 210), add:

```bash
# Alt Atlassian config (from macOS Keychain)
ATLASSIAN_ALT_SITE_VAL="$(/usr/bin/security find-generic-password -s atlassian-alt-site -w 2>/dev/null)" && export ATLASSIAN_ALT_SITE="$ATLASSIAN_ALT_SITE_VAL"
unset ATLASSIAN_ALT_SITE_VAL

ATLASSIAN_ALT_EMAIL_VAL="$(/usr/bin/security find-generic-password -s atlassian-alt-email -w 2>/dev/null)" && export ATLASSIAN_ALT_EMAIL="$ATLASSIAN_ALT_EMAIL_VAL"
unset ATLASSIAN_ALT_EMAIL_VAL

ATLASSIAN_ALT_CLOUD_ID_VAL="$(/usr/bin/security find-generic-password -s atlassian-alt-cloud-id -w 2>/dev/null)" && export ATLASSIAN_ALT_CLOUD_ID="$ATLASSIAN_ALT_CLOUD_ID_VAL"
unset ATLASSIAN_ALT_CLOUD_ID_VAL

ATLASSIAN_ALT_VAL="$(/usr/bin/security find-generic-password -s atlassian-alt-api-token -w 2>/dev/null)" && export ATLASSIAN_ALT_API_TOKEN="$ATLASSIAN_ALT_VAL"
unset ATLASSIAN_ALT_VAL
```

**Step 2: Add switch-atlassian function**

In the same `programs.bash.initExtra` block, after the alt credential loading:

```bash
switch-atlassian() {
  case "''${1:-}" in
    default)
      export ATLASSIAN_SITE="$ATLASSIAN_DEFAULT_SITE"
      export ATLASSIAN_EMAIL="$ATLASSIAN_DEFAULT_EMAIL"
      export ATLASSIAN_CLOUD_ID="$ATLASSIAN_DEFAULT_CLOUD_ID"
      export ATLASSIAN_API_TOKEN="$ATLASSIAN_DEFAULT_API_TOKEN"
      echo "Switched to default Atlassian instance ($ATLASSIAN_SITE)"
      ;;
    alt)
      export ATLASSIAN_SITE="$ATLASSIAN_ALT_SITE"
      export ATLASSIAN_EMAIL="$ATLASSIAN_ALT_EMAIL"
      export ATLASSIAN_CLOUD_ID="$ATLASSIAN_ALT_CLOUD_ID"
      export ATLASSIAN_API_TOKEN="$ATLASSIAN_ALT_API_TOKEN"
      echo "Switched to alt Atlassian instance ($ATLASSIAN_SITE)"
      ;;
    *)
      echo "Usage: switch-atlassian default|alt"
      echo "Current: $ATLASSIAN_SITE"
      return 1
      ;;
  esac
}
```

**Step 3: Save default credentials for round-tripping**

The existing Keychain reads set `ATLASSIAN_SITE` etc. directly. After those reads (and before the switch function), stash them so `switch-atlassian default` can restore them:

```bash
# Save default profile for switch-atlassian round-tripping
export ATLASSIAN_DEFAULT_SITE="$ATLASSIAN_SITE"
export ATLASSIAN_DEFAULT_EMAIL="$ATLASSIAN_EMAIL"
export ATLASSIAN_DEFAULT_CLOUD_ID="$ATLASSIAN_CLOUD_ID"
export ATLASSIAN_DEFAULT_API_TOKEN="$ATLASSIAN_API_TOKEN"
```

**Verify:** Open a new shell, run `switch-atlassian alt`, check `echo $ATLASSIAN_SITE`. Run `switch-atlassian default` to restore.

---

### Task 3: Add switch-atlassian to cloudbox

**Files:**
- Modify: `users/dev/home.cloudbox.nix`

**Step 1: Load alt credentials from sops**

In `programs.bash.initExtra`, after the existing Atlassian block (around line 101), add:

```bash
# Alt Atlassian config (from sops)
if [ -r /run/secrets/atlassian_alt_api_token ]; then
  export ATLASSIAN_ALT_API_TOKEN="$(cat /run/secrets/atlassian_alt_api_token)"
fi

if [ -r /run/secrets/atlassian_alt_site ]; then
  export ATLASSIAN_ALT_SITE="$(cat /run/secrets/atlassian_alt_site)"
fi

if [ -r /run/secrets/atlassian_alt_email ]; then
  export ATLASSIAN_ALT_EMAIL="$(cat /run/secrets/atlassian_alt_email)"
fi

if [ -r /run/secrets/atlassian_alt_cloud_id ]; then
  export ATLASSIAN_ALT_CLOUD_ID="$(cat /run/secrets/atlassian_alt_cloud_id)"
fi
```

**Step 2: Save default credentials and add switch function**

After the existing default credentials are loaded AND after the alt credentials, add the same `ATLASSIAN_DEFAULT_*` stash and `switch-atlassian` function as in Task 2. The function body is identical since it operates on env vars, not credential sources.

```bash
# Save default profile for switch-atlassian round-tripping
export ATLASSIAN_DEFAULT_SITE="$ATLASSIAN_SITE"
export ATLASSIAN_DEFAULT_EMAIL="$ATLASSIAN_EMAIL"
export ATLASSIAN_DEFAULT_CLOUD_ID="$ATLASSIAN_CLOUD_ID"
export ATLASSIAN_DEFAULT_API_TOKEN="$ATLASSIAN_API_TOKEN"

switch-atlassian() {
  case "''${1:-}" in
    default)
      export ATLASSIAN_SITE="$ATLASSIAN_DEFAULT_SITE"
      export ATLASSIAN_EMAIL="$ATLASSIAN_DEFAULT_EMAIL"
      export ATLASSIAN_CLOUD_ID="$ATLASSIAN_DEFAULT_CLOUD_ID"
      export ATLASSIAN_API_TOKEN="$ATLASSIAN_DEFAULT_API_TOKEN"
      echo "Switched to default Atlassian instance ($ATLASSIAN_SITE)"
      ;;
    alt)
      export ATLASSIAN_SITE="$ATLASSIAN_ALT_SITE"
      export ATLASSIAN_EMAIL="$ATLASSIAN_ALT_EMAIL"
      export ATLASSIAN_CLOUD_ID="$ATLASSIAN_ALT_CLOUD_ID"
      export ATLASSIAN_API_TOKEN="$ATLASSIAN_ALT_API_TOKEN"
      echo "Switched to alt Atlassian instance ($ATLASSIAN_SITE)"
      ;;
    *)
      echo "Usage: switch-atlassian default|alt"
      echo "Current: $ATLASSIAN_SITE"
      return 1
      ;;
  esac
}
```

**Verify:** SSH to cloudbox, open new shell, test `switch-atlassian alt` and `switch-atlassian default`.

---

### Task 4: MCP wrapper scripts and dual server entries

**Files:**
- Modify: `users/dev/opencode-config.nix`

**Step 1: Create wrapper scripts**

In the `let` block of `opencode-config.nix`, add two `writeShellApplication` derivations. Each reads the site URL from the platform-appropriate credential source and execs `npx mcp-remote` with `--resource`:

```nix
atlassian-mcp = pkgs.writeShellApplication {
  name = "atlassian-mcp";
  runtimeInputs = [ pkgs.nodejs ];
  text =
    let
      siteRead = if isDarwin
        then ''SITE="$(/usr/bin/security find-generic-password -s atlassian-site -w 2>/dev/null)"''
        else ''SITE="$(cat /run/secrets/atlassian_site 2>/dev/null)"'';
    in ''
      ${siteRead}
      if [ -z "''${SITE:-}" ]; then
        echo "atlassian-mcp: could not read atlassian site" >&2
        exit 1
      fi
      exec npx -y mcp-remote https://mcp.atlassian.com/v1/mcp --resource "https://''${SITE}/" 3334
    '';
};

atlassian-alt-mcp = pkgs.writeShellApplication {
  name = "atlassian-alt-mcp";
  runtimeInputs = [ pkgs.nodejs ];
  text =
    let
      siteRead = if isDarwin
        then ''SITE="$(/usr/bin/security find-generic-password -s atlassian-alt-site -w 2>/dev/null)"''
        else ''SITE="$(cat /run/secrets/atlassian_alt_site 2>/dev/null)"'';
    in ''
      ${siteRead}
      if [ -z "''${SITE:-}" ]; then
        echo "atlassian-alt-mcp: could not read alt atlassian site" >&2
        exit 1
      fi
      exec npx -y mcp-remote https://mcp.atlassian.com/v1/mcp --resource "https://''${SITE}/" 3335
    '';
};
```

**Step 2: Replace MCP server entries**

Replace the existing `atlassian` entry in `opencodeOverlay.mcp` with:

```nix
atlassian = {
  type = "local";
  command = [ "${atlassian-mcp}/bin/atlassian-mcp" ];
  enabled = false;
};
atlassian-alt = {
  type = "local";
  command = [ "${atlassian-alt-mcp}/bin/atlassian-alt-mcp" ];
  enabled = false;
};
```

**Verify:** `nix flake check` passes. Inspect the generated `opencode.managed.json` to confirm both entries are present with wrapper script paths (not hardcoded URLs).

---

### Task 5: SSH tunnel for alt MCP port

**Files:**
- Modify: `scripts/update-ssh-config.sh`

**Step 1: Add port 3335 forward**

Find the existing `LocalForward 3334 localhost:3334` line and add below it:

```
LocalForward 3335 localhost:3335
```

**Verify:** Review the SSH config section for the cloudbox entry.

---

### Task 6: Manual setup steps (documentation only, not automated)

**macOS Keychain:** Run these commands once to add the alt credentials:

```bash
security add-generic-password -a "$USER" -s atlassian-alt-site -w "<alt-site>"
security add-generic-password -a "$USER" -s atlassian-alt-email -w "<alt-email>"
security add-generic-password -a "$USER" -s atlassian-alt-cloud-id -w "<alt-cloud-id>"
security add-generic-password -a "$USER" -s atlassian-alt-api-token -w "<alt-api-token>"
```

**cloudbox sops:** Edit on a machine with the cloudbox age key:

```bash
cd ~/projects/workstation  # or ~/Code/workstation on macOS
sops secrets/cloudbox.yaml
# Add: atlassian_alt_api_token, atlassian_alt_site, atlassian_alt_email, atlassian_alt_cloud_id
```

**Apply:**
- macOS: `sudo darwin-rebuild switch --flake ~/Code/workstation#Y0FMQX93RR-2`
- cloudbox: `sudo nixos-rebuild switch --flake .#cloudbox && nix run home-manager -- switch --flake .#dev`
