# PagerDuty MCP Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a PagerDuty MCP server to workstation-managed OpenCode config for macOS and cloudbox.

**Architecture:** Use a Nix-built local command wrapper that runs the official PagerDuty MCP server via pinned `uvx --from 'pagerduty-mcp==0.17.0' pagerduty-mcp` in default read-only mode. Inject the MCP config after `mergeOpencode` using the existing Slack-style platform secret pattern: macOS Keychain and cloudbox sops.

**Tech Stack:** Nix/home-manager, sops-nix, macOS Keychain, OpenCode MCP config, PagerDuty `pagerduty-mcp`.

---

### Task 1: Cloudbox Secret Declaration

**Files:**
- Modify: `hosts/cloudbox/configuration.nix`
- Modify: `secrets/cloudbox.yaml`

**Step 1: Add the secret declaration**

Add `pagerduty_user_api_key` to cloudbox `sops.secrets` near the other MCP/API tokens:

```nix
# PagerDuty MCP User API token
pagerduty_user_api_key = {
  owner = "dev";
  group = "dev";
  mode = "0400";
};
```

**Step 2: Encrypt the provided token**

Run from cloudbox without printing the token:

```bash
/run/wrappers/bin/sudo nix-shell -p sops -p jq --run 'token_json=$(jq -Rs . /tmp/pd-api-key); SOPS_AGE_KEY_FILE=/var/lib/sops-age-key.txt sops set secrets/cloudbox.yaml "[\"pagerduty_user_api_key\"]" "$token_json"; unset token_json'
rm -f /tmp/pd-api-key
```

Expected: `secrets/cloudbox.yaml` gains an encrypted `pagerduty_user_api_key` entry and no plaintext token appears in output.

### Task 2: OpenCode MCP Injection

**Files:**
- Modify: `users/dev/opencode-config.nix`

**Step 1: Add a Nix wrapper**

Define `pagerduty-mcp = pkgs.writeShellApplication { ... }` with `runtimeInputs = [ pkgs.uv ];` and `exec uvx --from 'pagerduty-mcp==0.17.0' pagerduty-mcp`.

**Step 2: Add Darwin activation injection**

Add `home.activation.injectPagerDutyMcpSecrets` gated by `isDarwin`. It should read Keychain service `pagerduty-user-api-key`, delete `.mcp.pagerduty` when missing, and inject a disabled local MCP when present.

**Step 3: Add cloudbox activation injection**

Add `home.activation.injectPagerDutyMcpSecretsSops` gated by `isCloudbox`. It should read `/run/secrets/pagerduty_user_api_key`, delete `.mcp.pagerduty` when missing, and inject the same disabled local MCP when present.

**Step 4: Preserve read-only behavior**

Do not pass `--enable-write-tools`.

### Task 3: Setup Skill

**Files:**
- Create: `assets/opencode/skills/pagerduty-mcp-setup/SKILL.md`
- Modify: `users/dev/opencode-skills.nix`

**Step 1: Register the skill**

Add `pagerduty-mcp-setup` to `workOnlySkills`.

**Step 2: Write setup documentation**

Document:

- Token creation/permission expectations.
- macOS Keychain storage.
- cloudbox sops storage.
- Apply and verify commands.
- Rotation flow.
- Read-only default and explicit write-tool opt-in caveat.
- Available tool domains and key read tools.
- Placeholder-only examples; no org domains, schedule IDs, or tokens.

### Task 4: Verification And PR

**Files:**
- All modified files.

**Step 1: Format/evaluate Nix**

Run:

```bash
nix flake check --no-build
```

Expected: evaluation succeeds.

**Step 2: Verify no secret leakage**

Run searches for plaintext tokens and org-specific PagerDuty values. Expected: no matches in tracked source.

**Step 3: Inspect diff**

Run `git diff` and verify only PagerDuty MCP/planning/beads changes are included.

**Step 4: Close bead and commit**

Close `workstation-ebg`, stage only relevant files, and commit.

**Step 5: Open PR**

Push branch `pagerduty-mcp` and create a GitHub PR with a concise summary and testing evidence.
