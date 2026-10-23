---
name: figma-mcp-setup
description: Use when an agent needs to read a Figma design (frames, layout, copy, components, rendered screenshots) from OpenCode, when setting up or rotating the Figma MCP token on macOS Keychain or cloudbox sops, when Figma tools are missing or failing, or when someone proposes Figma's official remote/desktop MCP server instead.
---

# Figma MCP Setup

Gives agent sessions **read-only** access to Figma designs through
[Framelink](https://github.com/GLips/Figma-Context-MCP) (`figma-developer-mcp`),
a local stdio MCP server that calls Figma's REST API with a personal access
token (PAT). The server is nix-built and pinned (`pkgs/figma-mcp-server`), the
token comes from platform secret storage, and the entry is disabled by default.

| Platform | Token storage | Injection trigger |
|----------|---------------|-------------------|
| macOS | Keychain item `figma-access-token` | `darwin-rebuild switch` |
| cloudbox | sops key `figma_access_token` (`/run/secrets/`) | `nixos-rebuild switch` + `home-manager switch` |

devbox gets no entry (personal host).

## Why not Figma's own MCP server

The internal MCP guide points at Figma's official server. Neither form of it
works from OpenCode on cloudbox:

| Option | Blocker |
|--------|---------|
| Remote, `https://mcp.figma.com/mcp` | OAuth only, and only for clients in Figma's [MCP Catalog](https://www.figma.com/mcp-catalog/) (Claude Code, Cursor, VS Code, ...). OpenCode's dynamic client registration gets **403** from `https://api.figma.com/v1/oauth/mcp/register`, and a PAT as a bearer gets **401**. Measured 2026-10-12. |
| Desktop, `http://127.0.0.1:3845/mcp` | Served by the Figma desktop app with Dev Mode on. There is no desktop app on a headless host. |

Revisit if OpenCode joins the catalog: the remote server has more tools
(`get_design_context`, `get_screenshot`, `get_variable_defs`, Code Connect),
but also write tools, so a swap would need its own read-only story.

## Tools

Both are reads. Nothing here can change a Figma file.

| Tool | What it does |
|------|--------------|
| `figma_get_figma_data(fileKey, nodeId?, depth?)` | Simplified node tree: layout, text content (the copy), styles, components. Pass `nodeId` to scope to one frame; a whole file can be huge. |
| `figma_download_figma_images(fileKey, nodes, localPath, pngScale?)` | Renders nodes to PNG/SVG on local disk. `localPath` is **relative to** `/tmp/opencode/figma-images` and cannot escape it. Read the PNG afterwards to look at the frame. |

Get `fileKey` and `nodeId` from a Figma link ("Copy link to selection"):
`https://www.figma.com/design/<fileKey>/<name>?node-id=12-345` means
`fileKey=<fileKey>`, `nodeId=12:345` (dash becomes colon).

**Quota is the binding constraint.** Both tools hit Figma's Tier 1 REST
endpoints (GET file / file nodes / images), and the limit follows the token
owner's **seat** in the plan that owns the file:

| Owner's seat | Tier 1 limit |
|---|---|
| View, Collab | **up to 20 per month**, total, and Figma may allow fewer |
| Dev, Full | 10-20 per minute, by plan |

On a View or Collab seat, a single exploratory session can spend the month.
Plan the calls: get the node links from the designer, fetch each frame once
with `nodeId` set and a small `depth`, and save what you learn (to the plan doc,
say) instead of fetching again. Put every node you want rendered into one
`figma_download_figma_images` call: that is one Tier 1 request per format (PNG, SVG)
instead of one per node. Files in a Starter-plan team are capped at about 6
reads a month whatever the seat.

The token's budget is shared: every session granted `figma`, and anything
else using the same person's PATs, draws on it.

## Using it

The entry is `enabled: false`. Grant it to a session:

```bash
oc-mcp-enable <session-id> figma        # an already-running session
opencode-launch --mcp figma ...         # a new session
```

The grant is per session and is lost when the serve restarts (nightly reset
included). Re-run `oc-mcp-enable` if the tools disappear.

## Get a token

The token owner must be able to open the files in Figma. A View seat works but
is capped at about 20 reads a month (see "Tools"); a Dev or Full seat is
what makes this practical.

1. Figma -> account menu -> **Settings** -> **Security** -> **Personal access
   tokens** -> **Generate new token**.
2. Expiration: the maximum, **90 days**. Figma no longer issues non-expiring PATs.
3. Scopes: **File content: Read only** (`file_content:read`). Leave every other
   scope at "No access". That one scope covers all four endpoints the server
   calls (`/v1/files/:key`, `/v1/files/:key/nodes`, `/v1/images/:key`,
   `/v1/files/:key/images`).
4. Copy it immediately. Figma shows it once.

Don't test it with curl against a file: that spends Tier 1 quota (one of ~20
a month on a View seat). The first real tool call tests it.

## Cloudbox setup

With the token in `/tmp/figma-token`, store it so it is never printed:

```bash
cd ~/projects/workstation   # or a worktree of it
/run/wrappers/bin/sudo nix-shell -p sops -p jq --run 'token_json=$(jq -Rs . /tmp/figma-token); SOPS_AGE_KEY_FILE=/var/lib/sops-age-key.txt sops set secrets/cloudbox.yaml "[\"figma_access_token\"]" "$token_json"; unset token_json'
rm -f /tmp/figma-token
```

Commit `secrets/cloudbox.yaml` (it is encrypted), then apply:

```bash
sudo nixos-rebuild switch --flake .#cloudbox          # materializes /run/secrets/figma_access_token
nix run home-manager -- switch --flake .#cloudbox     # writes .mcp.figma into opencode.json
```

The sops key must exist before `hosts/cloudbox/configuration.nix` declares
`figma_access_token`, or the nixos-rebuild fails. They land together.

**Then restart the serves.** opencode reads its config, and expands the
`{file:}` token reference, when a serve starts. Serves started before the
switch don't have `mcp.figma`, and `oc-mcp-enable` reports it as "not
configured". Run `reset-workspace` (see the workstation repo-local `resetting-workspace` skill) or
wait for the 3 AM nightly reset.

## macOS setup

```bash
security add-generic-password -a "$USER" -s figma-access-token -w "FIGMA_PAT" -U
sudo darwin-rebuild switch --flake ~/Code/workstation#Y0FMQX93RR-2
```

## Verify

```bash
jq '.mcp.figma | {command, enabled, key: .environment.FIGMA_API_KEY}' ~/.config/opencode/opencode.json
# key must be a {file:...} reference, never the token itself.
```

Then grant it to a session and call `figma_get_figma_data` on a known node.

## Hardening (do not undo)

- **Telemetry off.** Upstream sends usage events to PostHog by default. The
  package wrapper sets `FRAMELINK_TELEMETRY=off` and `DO_NOT_TRACK=1`.
- **`--env /dev/null`.** Upstream loads `<cwd>/.env` with override=true, so a
  stray `.env` could replace `FIGMA_API_KEY` or set `FIGMA_PROXY`.
- **`--image-dir /tmp/opencode/figma-images`.** Confines downloads. It is under
  `/tmp` so agents can read the PNGs without a permission prompt.
- **Pinned closure.** Built from the upstream tag with its pnpm lockfile, not
  `npx -y`, because the process holds a token that can read every file its owner
  can.

## Rotation (every 90 days at most)

1. Mint a new token as above (same single scope).
2. Store it with the cloudbox `sops set` command or the macOS `security` command.
3. Cloudbox: commit `secrets/cloudbox.yaml`, then `nixos-rebuild switch`. No
   home-manager switch is needed (opencode.json holds only a file reference),
   but running serves expanded that reference at startup and still hold the
   old token: restart them (`reset-workspace`, or the nightly reset). macOS:
   `darwin-rebuild switch`, then restart OpenCode.
4. Only then revoke the old token in Figma. Revoking first makes every figma
   call 403 until the serves restart.

## Troubleshooting

| Symptom | Check |
|---------|-------|
| `MCP server 'figma' is not configured on this host` | Check `jq .mcp.figma ~/.config/opencode/opencode.json`. Null: the secret is missing or the switch hasn't been applied. Present: the serve started before the switch; restart it. |
| `403` / `Forbidden` from a tool | Token expired (90-day cap), lacks `file_content:read`, or the owner cannot open that file. Right after a rotation: the serve still holds the old token; restart it. |
| `429` rate limit | Seat quota. `X-Figma-Rate-Limit-Type: low` means a View/Collab seat (about 20 Tier 1 calls a month); wait for the reset, or use a token from a Dev/Full-seat owner. |
| `resolves outside the allowed image directory` | `localPath` must be relative, e.g. `my-frame`, not `/tmp/...`. |
| Gemini-tier subagent returns empty while figma is granted | Test the server against Gemini (workstation repo-local `opencode-agents` skill, "Testing a new MCP server against Gemini"); if it fails, add `figma*: false` to the Gemini-tier agents. |

## References

- Server: https://github.com/GLips/Figma-Context-MCP (MIT)
- Package: `pkgs/figma-mcp-server/default.nix` (bump instructions inside)
- Activation: `users/dev/opencode-config.nix` (`figmaMcpCommand`, `injectFigmaMcpSecrets`, `injectFigmaMcpSecretsSops`)
- PAT scopes: https://developers.figma.com/docs/rest-api/scopes/
- Figma official MCP (for when OpenCode is admitted): https://developers.figma.com/docs/figma-mcp-server/
