# Phase 10 — session-scoped MCP through the front door (patched.3)

Status: **DESIGN** (user chose session-scoped over door-broadcast; awaiting review → SDD).
Beads: `workstation-mlve` (epic), `workstation-mlve.11` (D4 door-side denials), new bead TBD.
Parent: `docs/plans/2026-07-12-serve-reverse-proxy-plan.md`; precedent: `docs/plans/2026-07-24-phase9-door-route-allowlist.md`.

## Problem
Through the front door the TUI can neither **see** nor **enable** MCP servers:
- `GET /mcp` → door **501** (`per-process-ro`, F3 — "MCP connection status is per-process").
- `POST /mcp/:name/connect|disconnect` → door **403** (`global-sideeffect`, D4/mlve.11 — "mutates per-process state").

Both denials are *correct* under the original reasoning (MCP state is per-process; the door must not fan out or forward per-process mutations to an arbitrary serve). But Phase 9 put the full interactive TUI behind the door, so the practical result is the MCP dialog is dead: empty status, toggling fails.

Verified live: direct-to-serve works instantly — `POST :4096/mcp/slack/connect` → `true`, spawns the subprocess, status flips to `connected`, and it is strictly per-process (`:4098` unaffected).

### Not to be confused with: the config-policy cause
Separately, **all 14 MCP servers are `enabled: false`** in the runtime config, and 13 injection blocks in `users/dev/opencode-config.nix` hard-replace each server object with `"enabled": false` *after* `mergeOpencode` (line 511, `jq -s '.[0] * .[1]'`, managed wins). **Zero** blocks preserve an existing value, so every `home-manager switch` silently wipes any opt-in. That is why the tools are absent today; it is NOT a door bug and NOT fixed by this plan. Tracked separately (see Follow-ups).

## Design — mirror the Phase 8 session-scoped pattern
A session-scoped path lets the door owner-route the request to the process that owns the session, for free, with zero new door capability. The handler then performs the same per-process MCP operation. This keeps the door a pure router (no fan-out, no partial-failure aggregation).

### A. Server (opencode-patched, new `session-mcp-routes.patch`)
Same 5-file shape as `session-door-routes.patch`.

1. `groups/session.ts` — add to `SessionPaths`:
   - `mcpStatus: ${root}/:sessionID/mcp`
   - `mcpConnect: ${root}/:sessionID/mcp/:name/connect`
   - `mcpDisconnect: ${root}/:sessionID/mcp/:name/disconnect`
   Plus `HttpApiEndpoint` defs mirroring `groups/mcp.ts`: status returns `StatusMap` and MUST keep `query: WorkspaceRoutingQuery` (the TUI bootstrap passes `{ workspace }`, `sync.tsx:537`); connect/disconnect take `params: { sessionID, name }` and reuse `McpServerNotFoundError`.
2. `handlers/session.ts` — add `const mcp = yield* MCP.Service` (identical to the existing `permissionSvc`/`questionSvc` pattern, lines 51-62). Three handlers, each `yield* requireSession(ctx.params.sessionID)` then delegate to `mcp.status()` / `mcp.connect(name)` / `mcp.disconnect(name)`, reusing the `Effect.catchTag("MCP.NotFoundError", …)` mapping from `handlers/mcp.ts:75-95`. Register via `.handle(...)`.
3. `sdk.gen.ts` + `types.gen.ts` — hand-add the 3 SDK methods + types (these are generated files patched by hand; Phase 8 precedent).

### B. TUI (extend `tui-door-attach.patch`)
Repoint the 4 MCP call sites to the session-scoped SDK methods **when an active session exists**, else fall back to the global call:
- `sync.tsx:537` — bootstrap `sdk.client.mcp.status({ workspace })`
- `dialog-mcp.tsx:59` — dialog open `sdk.client.mcp.status()`
- `local.tsx:514` — `mcp.disconnect({ name })`
- `local.tsx:517` — `mcp.connect({ name })`
The fallback keeps direct-to-serve behavior intact and is only reachable through the door in the no-active-session case (see Limitation 2).

### C. Door (workstation `pkgs/opencode-frontdoor/`)
Register as `session-path` (bare surface only; SDK is bare-only):
- `GET /session/{sessionID}/mcp`
- `POST /session/{sessionID}/mcp/{name}/connect`
- `POST /session/{sessionID}/mcp/{name}/disconnect`
Plus: header reconciliation counts (196 → 199 total, patch-only 7 → 10), `routes.snapshot.txt` note, explicit `classify()`/`dispatch()` assertions in `dispatch.test.ts`, and a `gate.sh` probe (GET only; POSTs are state-mutating — same rationale as Phase 9).

**Unchanged by design:** global `GET /mcp` stays **501** and `POST /mcp/:name/connect|disconnect` stays **403**. Door opacity is preserved; the session-scoped path is the only supported route.

**Out of scope:** MCP OAuth routes (`/mcp/:name/auth*`) stay denied — browser-callback flows, genuinely global side effects.

## Known limitations (accept + document)
1. **Migration drops the connection.** `connect` lands on the owner serve ONLY. An idle-migration or failover to another serve silently loses those tools. Mitigations, in order of preference: (a) fix the nix switch-reset bug and enable always-on servers in config, so *every* serve has them at start; (b) later, have a serve re-connect configured MCP servers on session adoption; (c) accept and re-toggle. **This plan does (c); (a) is the recommended companion follow-up.**
2. **Root TUI with no active session** → falls back to global `/mcp` → door 501 → empty MCP dialog. Same shape as the already-accepted `/global/event` → 410 limitation.
3. **Cost:** enabling pool-wide via config means N serves × 1 subprocess per MCP server. Enable only what you need.

## Deploy
Cut `v1.17.13-patched.3` → bump pin (`patchedRevision = "3"` + 4 platform SRI hashes) → `sudo nixos-rebuild switch --flake .#cloudbox` (door is a system service) → `home-manager switch --flake .#cloudbox` → restart the serve pool (`sudo systemctl restart opencode-serve-pool.target`).

Gate: MCP dialog through the door lists servers with real status; toggling connects/disconnects on the owner serve; `audit/gate.sh` green; door log shows no 404/501/403 on the session-scoped MCP paths.

## Follow-ups (separate from this plan)
- **`opencode-config.nix` switch-reset bug** — make the 13 injection blocks preserve an existing `enabled` value (e.g. read `.mcp.<name>.enabled // false` and reuse) so an opt-in survives `home-manager switch`. This is the actual reason MCP tools are absent today, and the companion to Limitation 1.
- **`workstation-sq1v`** — door mis-routes child (subagent) sids to the anchor (pigeon has no assignment for serve-minted children). Independent of this plan.
- **Part B / patched.3 reconcile hardening** — `N=3-then-degrade` + bootstrap `allSettled`; can ride the same patched.3 cut.

## Immediate mitigation (no code, available now)
Broadcast-connect the servers you need across the pool directly:
```bash
for p in 4096 4097 4098 4099; do curl -s -X POST "http://127.0.0.1:$p/mcp/<name>/connect" >/dev/null; done
```
Survives until the next pool restart. NOTE: a probe during diagnosis left `slack` connected on serve-0 (`:4096`) only — an asymmetric pool state that should be either spread or reverted.
