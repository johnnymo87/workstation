# Phase 10 — session-scoped MCP through the front door (patched.3)

Status: **DESIGN — fable GO-WITH-FIXES (deltas folded in); ready for SDD.**
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
   Plus `HttpApiEndpoint` defs mirroring `groups/mcp.ts`. **MEDIUM-3 (fable):** `WorkspaceRoutingQuery` fields must be spread into **ALL THREE** endpoint schemas, not just status — the middleware header (`workspace-routing.ts:17-21`) states any group applying `WorkspaceRoutingMiddleware` rejects requests carrying those params with a **400** unless every endpoint declares them; the bare `mcp.connect`/`disconnect` already do (`groups/mcp.ts:119,130`). **MEDIUM-4 (fable):** do NOT reuse the bare name `StatusMap` — `groups/session.ts:50` ALREADY exports `StatusMap = Record(String, SessionStatus.Info)` while `groups/mcp.ts:16` exports `StatusMap = Record(String, MCP.Status)`. Import the MCP one **aliased as `McpStatusMap`** or the endpoint silently advertises the wrong schema. `McpServerNotFoundError` is safe to reuse (shared `../errors`).
2. `handlers/session.ts` — add `const mcp = yield* MCP.Service` (identical to the existing `permissionSvc`/`questionSvc` pattern, lines 51-62; both handler groups are provided in the same layer, `server.ts:154-172`, so the service resolves). Three handlers, each `yield* requireSession(ctx.params.sessionID)` then delegate to `mcp.status()` / `mcp.connect(name)` / `mcp.disconnect(name)`, reusing the `Effect.catchTag("MCP.NotFoundError", …)` mapping from `handlers/mcp.ts:75-95`. Register via `.handle(...)`. **Mandatory comment** (Phase 8 convention, `groups/session.ts:116-121`): state that the response is **PROCESS-global, not session-scoped** — the sessionID exists solely so the front door can owner-route.
3. `sdk.gen.ts` + `types.gen.ts` — hand-add the 3 SDK methods + types (generated files patched by hand; Phase 8 precedent). Keep them in a SEPARATE patch file (`session-mcp-routes.patch`) so an upstream conflict here doesn't take down `session-door-routes.patch`.

### B. TUI (extend `tui-door-attach.patch`) — REWRITTEN per fable CRITICAL-1
**The original plan was wrong.** `dialog-mcp.tsx:59` is NOT "dialog open" — it sits inside `onTrigger`, reachable only AFTER a toggle. The dialog's `options` is a pure `createMemo` over `sync.data.mcp` (`dialog-mcp.tsx:28-46`) with **no fetch on open**. The store is populated ONLY at bootstrap (`sync.tsx:537`) and post-toggle. So through the door the common flow is: attach → bootstrap has no active session → global `/mcp` → 501 → `{}` → **dialog opens with zero options → toggle unreachable → dead feature.** Repointing bootstrap would not have saved it (session switches never refresh the store).

Revised TUI changes:
1. **Add a fetch-on-dialog-open** in `DialogMcp` (session-scoped, root-sid-resolved), writing through `sync.set("mcp", …)`. THIS is the fix that makes the dialog work; it also resolves the stale-store-on-session-switch case and most of MEDIUM-6.
2. **Repoint the toggle calls** `local.tsx:514` (`disconnect`) and `local.tsx:517` (`connect`), and the post-toggle refresh `dialog-mcp.tsx:59`, to the session-scoped methods.
3. **LEAVE `sync.tsx:537` (bootstrap) GLOBAL** — drop the planned repoint entirely. Its 501 through the door is already tolerated (no `throwOnError`; resolves to `{}`), bootstrap-time MCP state is stale-by-design, and fewer patch sites = less fuzz.
4. **HIGH-2 — resolve to the ROOT sid client-side** before every session-scoped MCP call (walk `parentID` up from the current session; the TUI already has it in the store). This is *correct*, not a workaround: MCP state is per-process, a child's process IS the parent's owner, and root sids are always pigeon-routed. See the hazard below.

### C. Door (workstation `pkgs/opencode-frontdoor/`)
Register as `session-path` (bare surface only; SDK is bare-only):
- `GET /session/{sessionID}/mcp`
- `POST /session/{sessionID}/mcp/{name}/connect`
- `POST /session/{sessionID}/mcp/{name}/disconnect`
Plus: header reconciliation counts (196 → 199 total, patch-only 7 → 10), `routes.snapshot.txt` note, explicit `classify()`/`dispatch()` assertions in `dispatch.test.ts`, and a `gate.sh` probe (GET only; POSTs are state-mutating — same rationale as Phase 9).

**LOW-10 (fable) — add negative pins + a child-session gate item:**
- `dispatch.test.ts`: assert global `GET /mcp` **still** classifies `per-process-ro` (501) and `POST /mcp/{name}/connect` **still** `global-sideeffect` (403). The plan says "unchanged by design" but nothing currently fails closed if a table edit fat-fingers those rows.
- Live gate: open the MCP dialog **in a child (subagent) session view** through the door and verify the toggle lands on the **parent's owner serve** — the acceptance test for the HIGH-2 fix (mirrors Phase 9's HIGH-2 detector).

Fable verified the door mechanics are safe: exact-match precedes pattern-match (`dispatch.ts:89-94`) so `GET /session/status` can't be shadowed; `{token}` → `[^/]+` is slash-bounded (`dispatch.ts:27`); no overlap with `/session/{sessionID}/message/{messageID}` or the bare `/mcp/{name}/connect`; `sid.ts:17` already extracts sids generically; and `connect` is not in `PROMOTING_SUFFIXES` (`place.ts:74-83`) so a toggle can't mint a bogus pigeon assignment.

**Unchanged by design:** global `GET /mcp` stays **501** and `POST /mcp/:name/connect|disconnect` stays **403**. Door opacity is preserved; the session-scoped path is the only supported route.

**Out of scope:** MCP OAuth routes (`/mcp/:name/auth*`) stay denied — browser-callback flows, genuinely global side effects.

## Hazards & known limitations

### HIGH-2 (fable) — child-session MCP calls silently mutate the WRONG process. MUST FIX.
Verified end-to-end: child (subagent) sessions have no pigeon assignment (`router.ts:110-113`), so `/route` 404s → `resolve.ts:49-58` degrades to the anchor. Critically, the door's write-vs-read split **deliberately lets `not-routed` MUTATIONS through to the anchor** — `proxy.ts:637-642` only 503s on `pigeon-unreachable`/`pigeon-error`, and its comment states *"Reads (and not-routed) still degrade to the anchor."* `requireSession` then **succeeds** on the anchor (shared storage). Net effect: opening the dialog in a child-session view shows the ANCHOR's MCP state, and toggling spawns the subprocess **on the anchor** while the subagent actually runs on (say) serve-2 — so the user "confirms" a connection the child's process does not have. Silent, state-mutating, wrong-process.
**Fix: client-side root-sid resolution (§B.4).** The door-side parent-walk (`workstation-sq1v`) is the proper general fix and is complementary — but do NOT block Phase 10 on it.

### Accepted limitations
1. **Migration drops the connection, silently.** `connect` lands on the owner serve ONLY; idle-migration/failover loses those tools. There is **no push signal**: MCP `ToolsChanged` events (`mcp/index.ts:443`) carry no sessionID, so the door's `session_ids`-scoped SSE filters them out. **The fetch-on-dialog-open (§B.1) is therefore the SOLE truth mechanism** — the dialog is accurate when opened, and nothing else will ever correct it. (Without §B.1 the stale store also *inverts the toggle*: `local.tsx:510-518` picks connect-vs-disconnect from the store, so a stale "connected" makes the toggle send `disconnect` to something already off.) Companion mitigation: the `opencode-config.nix` fix (Follow-ups) makes always-on servers exist on *every* serve at start, rendering migration-drop moot for the servers that matter.
2. **Root TUI with no active session** → bootstrap stays global `/mcp` → door 501 → empty store. Opening the dialog inside any session refetches (§B.1), so this is now cosmetic-only. Same shape as the accepted `/global/event` → 410 limitation.
3. **Cost:** enabling pool-wide via config means N serves × 1 subprocess per MCP server. Enable only what you need.
4. **LOW-7 — MCP toggles acquire turn-like stickiness.** A non-degraded mutating `POST .../connect` triggers `sticky.record(sid, target, now, 0)` (`proxy.ts:645-650`), so the next sticky hit renews the lease via `placeSession`. Almost certainly benign (HRW is deterministic; the pin matches where the session would activate), but it changes what the sticky map *means* — noted so the next stickiness debugger isn't surprised.
5. **LOW-8 — OAuth-requiring servers** will fail on `connect` (or attempt browser auth, `mcp/index.ts:911`); through the door the user just sees "failed". Expected, not a bug. Also: `connect` **bypasses `enabled: false`** — the nix force-disable is a *cost policy, not an enforcement boundary*, and this route makes that permanent. Security delta ≈ 0 (anything reaching :4700 can already `prompt_async` with arbitrary tools).
6. **Two TUIs on the same serve**: one session's toggle silently changes another session's available tools. Inherent to per-process state; document in the endpoint description.
   **OPERATOR MODEL — the dialog is NOT per-session isolation (confirmed with the user 2026-07-25).** The natural reading of "session-scoped MCP" is that a toggle affects only your session. It does not. `sessionID` is used *solely* to validate the session and let the door owner-route; the handler then calls `mcp.connect(name)` with **no session scoping** (`session-mcp-routes.patch`, `handlers/session.ts`). The real scope is **one of the 4 serve processes**, so a toggle reaches every session sharing that serve — subagents included — plus any *new* session that later lands there, until the next pool restart.
   Why it matters beyond tidiness: the reason these default to off is that several are **write-capable** (PagerDuty write tools, DevCycle delete feature/variable, Rollbar). A deliberate opt-in in one session silently arms those tools for unrelated concurrent sessions on the same serve; toggling off yanks them from a sibling mid-use. Exposure is bounded by the nightly 03:00 pool restart and by there being a single operator.
   *Not directly observed:* that the connected server's tools then actually surface in sibling sessions' prompts. The process-global connect is certain (quoted above); whether tool exposure is filtered per-session downstream was never tested, since testing means really enabling an MCP. Assume it does surface until someone checks.
   **Deliberately NOT fixed.** True per-session scoping needs per-session tool filtering in the MCP layer = another fork patch, against fable's standing advice ("per-process state × opaque router costs a fork patch each time… treat any NEW per-process feature as 'does this justify another patch?'") and its freeze-the-feature-surface recommendation. Documented instead.
7. **`mcp_resource` divergence**: `experimental.resource.list` (`sync.tsx:538-540`) stays `global-ro` → anchor, so resource listings can disagree with owner-serve MCP status. Cosmetic.

## Deploy
Cut `v1.17.13-patched.3` → bump pin (`patchedRevision = "3"` + 4 platform SRI hashes) → `sudo nixos-rebuild switch --flake .#cloudbox` (door is a system service) → `home-manager switch --flake .#cloudbox` → restart the serve pool (`sudo systemctl restart opencode-serve-pool.target`).

Gate: MCP dialog through the door lists servers with real status; toggling connects/disconnects on the owner serve; **dialog opened in a CHILD-session view toggles the parent's owner serve** (HIGH-2 detector); `audit/gate.sh` green incl. the negative pins; door log shows no 404/501/403 on the session-scoped MCP paths.

**Pre-gate cleanup:** a diagnostic probe left `slack` connected on serve-0 (`:4096`) ONLY. Revert (`POST :4096/mcp/slack/disconnect`) or spread to all 4 serves BEFORE the gate run, or the "real status" check is polluted by asymmetric pool state.

## Sequencing decision (fable MEDIUM-5 — RAISED AND DECLINED)
Fable recommended landing the `opencode-config.nix` preserve-`enabled` fix FIRST (it's smaller — a jq change + `home-manager switch`, no fork cut/pin bump/pool restart — and it makes Limitation 1 moot for configured servers). **The user explicitly declined**: the goal here is the *dialog* (runtime control from the TUI), which works regardless of config because `connect` bypasses `enabled: false` (proven live). Recorded, not adopted.

One correction to fable's framing: the runtime toggle's effect does **not** evaporate on the next `home-manager switch` — a switch does not restart the serves (verified: serves survived the 13:49 switch). It evaporates on **pool restart or migration**. That narrows the argument for resequencing.

## Follow-ups (separate from this plan)
- ~~**`opencode-config.nix` switch-reset bug**~~ — **CLOSED 2026-07-25, won't fix (user decision).** The proposal was to make the injection blocks preserve an existing `enabled` value so an opt-in survives `home-manager switch`. Reopened once when a new fact landed — the pool restarts nightly at 03:00 (`configuration.nix:1402`; serves observed starting `03:00:11`), which combines with the switch-reset into "no durable path to *this MCP server is on tomorrow*": the runtime connect dies at 03:00, and the config it would re-read has already been reset to `false` (verified: all 14 servers `enabled=false` in `~/.config/opencode/opencode.json`, rewritten on every activation — and `pull-workstation` activates every 4h).
  **The user confirmed that is the intended design, not a defect:** the dialog is meant to be an as-needed, off-by-default, ad-hoc toggle, and the 03:00 reset is a welcome reset. So there is no durability requirement to satisfy. Do not "fix" this without re-asking — a preserved opt-in would silently make write-capable servers persist across days, inverting the intended fail-safe. (If a durable opt-in is ever wanted, prefer a declarative `mcpEnabled = [ … ]` list in nix over preserving hand-edits, so the on-set stays reviewable.)
- **`workstation-sq1v`** — door mis-routes child (subagent) sids to the anchor (pigeon has no assignment for serve-minted children). Independent of this plan.
- **Part B / patched.3 reconcile hardening** — `N=3-then-degrade` + bootstrap `allSettled`; can ride the same patched.3 cut.

## Immediate mitigation (no code, available now)
Broadcast-connect the servers you need across the pool directly:
```bash
for p in 4096 4097 4098 4099; do curl -s -X POST "http://127.0.0.1:$p/mcp/<name>/connect" >/dev/null; done
```
Survives until the next pool restart. NOTE: a probe during diagnosis left `slack` connected on serve-0 (`:4096`) only — an asymmetric pool state that should be either spread or reverted.
