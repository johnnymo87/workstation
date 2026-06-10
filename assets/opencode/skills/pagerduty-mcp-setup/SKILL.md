---
name: pagerduty-mcp-setup
description: Use when setting up or rotating PagerDuty MCP auth for OpenCode on macOS Keychain or cloudbox sops, or when debugging missing PagerDuty tools.
---

# PagerDuty MCP Setup

Uses PagerDuty's official local MCP server with a PagerDuty User API token. The workstation wrapper is Nix-managed, pins `pagerduty-mcp==0.17.0`, injects the token from platform secret storage, and runs with `--enable-write-tools` so incident actions (resolve/acknowledge/reassign) are available. The MCP is `enabled: false` by default, so write tools only load when you deliberately switch the server on.

| Platform | Token storage | Injection trigger |
|----------|---------------|-------------------|
| macOS | Keychain | `darwin-rebuild switch` |
| cloudbox | sops (`/run/secrets/`) | `nixos-rebuild switch` + `home-manager switch` |

## Architecture

- `users/dev/opencode-config.nix` injects `.mcp.pagerduty` into `~/.config/opencode/opencode.json` after `mergeOpencode`.
- The MCP command points at a Nix `writeShellApplication` wrapper with `pkgs.uv` in `runtimeInputs`; the wrapper runs `uvx --from 'pagerduty-mcp==0.17.0' pagerduty-mcp --enable-write-tools`.
- The MCP is `enabled: false` by default to avoid normal-session startup cost and accidental PagerDuty calls. **Enabling it loads both read and write tools** (resolve/acknowledge/reassign incidents), so enable only when you intend to act.
- Write tools require a token whose user can manage the target incidents. A User API token acts as that user, so if you can resolve/ack the incident in the PagerDuty UI, the token can too.
- If the token is missing, activation deletes `.mcp.pagerduty` so stale credentials do not linger.

## Get A Token

Create a PagerDuty User API token from PagerDuty user settings:

1. Open PagerDuty in a browser.
2. Go to avatar -> My Profile -> User Settings.
3. In API Access, create a new API User Token.
4. Copy it once and store it immediately.

Use a user token whose account permissions cover both reading and acting on the incidents you care about (resolve/acknowledge/reassign). Do not commit account domains, schedule URLs, schedule IDs, team names, service names, or token values.

## macOS Setup

Store the token in Keychain:

```bash
security add-generic-password -a "$USER" -s pagerduty-user-api-key -w "PAGERDUTY_USER_TOKEN" -U
```

Apply:

```bash
sudo darwin-rebuild switch --flake ~/Code/workstation#Y0FMQX93RR-2
```

Verify without printing the token:

```bash
jq '{type:.mcp.pagerduty.type, command:.mcp.pagerduty.command, enabled:.mcp.pagerduty.enabled, hasToken:(.mcp.pagerduty.environment.PAGERDUTY_USER_API_KEY | type == "string" and length > 0)}' ~/.config/opencode/opencode.json
```

## Cloudbox Setup

Store the token in sops. If the token is in `/tmp/pd-api-key`, use this form so the token is not printed:

```bash
/run/wrappers/bin/sudo nix-shell -p sops -p jq --run 'token_json=$(jq -Rs . /tmp/pd-api-key); SOPS_AGE_KEY_FILE=/var/lib/sops-age-key.txt sops set secrets/cloudbox.yaml "[\"pagerduty_user_api_key\"]" "$token_json"; unset token_json'
rm -f /tmp/pd-api-key
```

Apply:

```bash
cd ~/projects/workstation
sudo nixos-rebuild switch --flake .#cloudbox
nix run home-manager -- switch --flake .#cloudbox
```

Verify without printing the token:

```bash
test -s /run/secrets/pagerduty_user_api_key
jq '{type:.mcp.pagerduty.type, command:.mcp.pagerduty.command, enabled:.mcp.pagerduty.enabled, hasToken:(.mcp.pagerduty.environment.PAGERDUTY_USER_API_KEY | type == "string" and length > 0)}' ~/.config/opencode/opencode.json
```

## Using PagerDuty

Enable temporarily, then restart OpenCode:

```bash
(umask 0077; jq '.mcp.pagerduty.enabled = true' ~/.config/opencode/opencode.json > /tmp/oc.json) && mv /tmp/oc.json ~/.config/opencode/opencode.json
```

Disable after use:

```bash
(umask 0077; jq '.mcp.pagerduty.enabled = false' ~/.config/opencode/opencode.json > /tmp/oc.json) && mv /tmp/oc.json ~/.config/opencode/opencode.json
```

OpenCode reads config at startup. Quit and restart OpenCode after changing MCP enablement or after applying new secrets.

## Rotation

Rotate when the token is revoked, compromised, no longer has needed permissions, or per your PagerDuty access policy.

1. Create a new PagerDuty User API token.
2. Store it using the macOS or cloudbox setup command above.
3. Apply the platform config.
4. Restart OpenCode.
5. Revoke the old token in PagerDuty after the new one is verified.

## Tools

PagerDuty documents 64 tools across 14 domains. The workstation wrapper passes `--enable-write-tools`, so **both read and write tools are available when the server is enabled**. Because the MCP is `enabled: false` by default, write tools never load in ordinary sessions — they appear only after you deliberately switch the server on. The read tools below are always part of the surface; the write tools (next paragraph) are the addition.

| Domain | Read tools |
|--------|------------|
| Alert Grouping | `list_alert_grouping_settings`, `get_alert_grouping_setting` |
| Alerts | `list_alerts_from_incident`, `get_alert_from_incident` |
| Change Events | `list_change_events`, `get_change_event`, `list_service_change_events`, `list_incident_change_events` |
| Incidents | `list_incidents`, `get_incident`, `get_outlier_incident`, `get_past_incidents`, `get_related_incidents`, `list_incident_notes` |
| Incident Workflows | `list_incident_workflows`, `get_incident_workflow` |
| Services | `list_services`, `get_service` |
| Teams | `list_teams`, `get_team`, `list_team_members` |
| Users | `get_user_data`, `list_users` |
| Schedules | `list_schedules`, `get_schedule`, `list_schedule_users` |
| On-Call | `list_oncalls` |
| Log Entries | `list_log_entries`, `get_log_entry` |
| Escalation Policies | `list_escalation_policies`, `get_escalation_policy` |
| Event Orchestrations | `list_event_orchestrations`, `get_event_orchestration`, `get_event_orchestration_router`, `get_event_orchestration_service`, `get_event_orchestration_global` |
| Status Pages | `list_status_pages`, `list_status_page_severities`, `list_status_page_impacts`, `list_status_page_statuses`, `get_status_page_post`, `list_status_page_post_updates` |

Write tools include resolving/acknowledging/reassigning/creating/updating incidents, adding incident notes, and managing services, teams, schedules, event orchestration rules, status page posts, and schedule overrides. They load whenever the server is enabled, so treat enabling the PagerDuty MCP as arming destructive actions: switch it on to act, switch it off when done.

## Troubleshooting

| Symptom | Check |
|---------|-------|
| No `.mcp.pagerduty` entry | Token missing from Keychain or sops; re-store and re-apply. |
| MCP status is failed | Run the generated command from `.mcp.pagerduty.command` manually and check `uvx`/network errors. |
| PagerDuty returns unauthorized | Token was revoked, copied incorrectly, or lacks account access. Rotate it. |
| `sudo must be owned by uid 0` | In OpenCode bash on cloudbox, use `/run/wrappers/bin/sudo` for the sops command. |
| EU account API errors | PagerDuty local server supports `PAGERDUTY_API_HOST=https://api.eu.pagerduty.com`; add explicit workstation support before using EU accounts. |
| Too many tools | Keep the MCP disabled until needed. Tool filtering would require an additional local proxy and is not configured. |

## References

- PagerDuty MCP support page: https://support.pagerduty.com/main/docs/pagerduty-mcp-server
- Technical docs: https://pagerduty.github.io/pagerduty-mcp-server/
- Tools reference: https://pagerduty.github.io/pagerduty-mcp-server/docs/tools/overview
- Local auth docs: https://pagerduty.github.io/pagerduty-mcp-server/docs/getting-started/authentication
- OpenCode activation: `users/dev/opencode-config.nix` (`injectPagerDutyMcpSecrets`, `injectPagerDutyMcpSecretsSops`)
