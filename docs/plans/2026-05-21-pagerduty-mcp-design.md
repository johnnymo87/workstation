# PagerDuty MCP Design

## Goal

Configure OpenCode to query PagerDuty through the official PagerDuty MCP server for schedules, on-call rosters, services, incidents, and related read-only account data.

## External Findings

PagerDuty documents two supported MCP modes:

- Local stdio server: `uvx pagerduty-mcp` or Docker.
- Hosted remote server: `https://mcp.pagerduty.com/mcp`, with `https://mcp.eu.pagerduty.com/mcp` for EU accounts.

The local server authenticates with a PagerDuty User API token in `PAGERDUTY_USER_API_KEY`. EU accounts may also set `PAGERDUTY_API_HOST=https://api.eu.pagerduty.com`. The server is read-only by default; write tools are exposed only when started with `--enable-write-tools`.

## Chosen Approach

Use the local read-only stdio server through a Nix-built wrapper:

- `users/dev/opencode-config.nix` defines a `writeShellApplication` wrapper with `pkgs.uv` in `runtimeInputs`.
- OpenCode receives the wrapper path as the MCP command, so sessions do not depend on an ad-hoc `uvx` on `PATH`.
- The wrapper uses `uvx --from 'pagerduty-mcp==0.17.0' pagerduty-mcp`, matching PagerDuty's local server while pinning the package version to avoid surprise upstream changes.

The remote hosted endpoint was rejected because it would require injecting an `Authorization` header into OpenCode remote MCP config and diverges from the existing Slack-style local secret injection pattern. Docker was rejected because it adds startup overhead and does not match existing workstation MCP conventions.

## Secret Flow

macOS stores the token in Keychain service `pagerduty-user-api-key`. The Darwin activation hook reads it after `mergeOpencode`, deletes `.mcp.pagerduty` if missing, and injects the MCP config if present.

cloudbox stores the token in sops key `pagerduty_user_api_key`, decrypted to `/run/secrets/pagerduty_user_api_key`. The cloudbox activation hook mirrors the Darwin behavior.

No PagerDuty account domains, schedule URLs, schedule IDs, or token values are committed in source. Documentation uses placeholders only.

## OpenCode Shape

Injected MCP config:

```json
{
  "type": "local",
  "command": ["/nix/store/...-pagerduty-mcp/bin/pagerduty-mcp"],
  "enabled": false,
  "environment": {
    "PAGERDUTY_USER_API_KEY": "..."
  }
}
```

The MCP is disabled by default to avoid startup overhead and accidental PagerDuty calls from ordinary sessions. Users can enable it temporarily in `~/.config/opencode/opencode.json` when needed.

## Documentation

Add a deployed work-only setup skill at `assets/opencode/skills/pagerduty-mcp-setup/SKILL.md` and register it in `users/dev/opencode-skills.nix`.

The skill documents:

- How to create or obtain a PagerDuty User API token.
- How to store it in macOS Keychain.
- How to store it in cloudbox sops.
- How to apply and verify the OpenCode config.
- Rotation flow.
- Read-only vs write-tool behavior.
- Available tools by domain.

## Verification

Run Nix evaluation checks that cover the modified modules, inspect the generated/injected config shape where possible, and run source scrubbing searches for tokens and org-identifying PagerDuty references before committing.
