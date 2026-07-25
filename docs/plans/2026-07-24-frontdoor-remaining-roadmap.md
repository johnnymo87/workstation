# Front door — remaining roadmap (post-Phase-10), fable-reprioritized

Status: **PLAN — fable-reviewed, order accepted by user; ready for SDD.**
Parent: `docs/plans/2026-07-12-serve-reverse-proxy-plan.md`.
Sub-plans: `2026-07-24-phase9-door-route-allowlist.md`, `2026-07-24-phase10-session-scoped-mcp.md`; opencode-patched `docs/plans/2026-07-22-phase8-tui-through-door.md`.
Beads: epic `workstation-mlve`; `mlve.3` (P8), `mlve.4` (P9), `mlve.11` (P10/D4), `mlve.5`–`mlve.10` (fast-follows), `workstation-sq1v` (P1 bug).

## Where we are
Phases 0-8 done and live. **Phase 9 done EXCEPT 9.2.** **Phase 10 (session-scoped MCP) shipped 2026-07-24** — `v1.17.13-patched.3`, door commit `61cb8b8`, pin `b356095`; MCP dialog verified working through the door.

Phases 9 and 10 were both *unplanned* — each was discovered by hitting a production outage after Phase 9 put the FULL interactive TUI behind the door for the first time (M2 had routed only non-interactive clients). Expect more of this tail unless the mechanical gates below land.

### Two incidents on 2026-07-24 (both fixed; both instructive)
1. **TUI freeze.** `reset-workspace` silently skipped the pool restart → serves stayed on the old binary → door(new routes) + serves(old) → new routes returned the **HTML SPA fallback** → TUI reconcile JSON-parsed HTML → threw → **infinite reconnect → frozen**. (reset-workspace root cause handed to a separate session.)
2. **MCP dialog 404.** Door is `restartIfChanged = false` (deliberate: a restart drops all SSE legs + the sticky map). `nixos-rebuild` installed the new binary and rewrote the unit but **left the old process running**. Fixed with an explicit `systemctl restart opencode-frontdoor`.

## Verified findings (independently confirmed — do NOT re-derive)
- **`checkAuth` gates POST + DELETE + `GET /route`** (`pigeon/packages/daemon/src/auth.ts:5-8`). Enabling the token therefore gates EVERY pigeon POST: `/place`, `/swarm/send`, `/session-start`, `/question-asked`, `/alert`.
- **`GET /sessions` is unauthenticated** (returns 200; yields session ids, cwds, pids, backend endpoints). So a `/route` token does **not** deliver the opacity goal. Any local process also finds the pool via `ss -tlnp`.
- **The pinned serve's `/doc` advertises the patch-added routes** (169 bare paths; `/session/{sessionID}/mcp`, `/permissions`, `/questions` all PRESENT). → the `/doc`-diff gate below is feasible.
- **The pool restarts nightly at 03:00** (`hosts/cloudbox/configuration.nix:1402`; serves observed starting `03:00:04`).
- **`.opencode/skills/rebuilding/SKILL.md` has ZERO mentions** of frontdoor / serve-pool / restartIfChanged.
- **Prose already failed once:** `2026-07-24-phase9-door-route-allowlist.md:69` already says route changes need a rebuild + restart — written the same day the door was then left stale. Documentation alone will not fix incident #2.

## Revised priority order (fable's, accepted)
### 1. Deploy runbook + **stale-binary canary tripwire** ← START HERE
Docs alone are insufficient (see above). Two parts:
- **1a Runbook**: canonical sequence — `nixos-rebuild` → **restart door** → `home-manager switch` → **restart pool** — into the parent plan's Deploy section AND `.opencode/skills/rebuilding/SKILL.md`. Explain *why* (`restartIfChanged = false` on both the door and `opencode-serve@`, deliberate to avoid dropping SSE legs / bouncing live sessions).
- **1b Tripwire**: extend the existing door canary (`hosts/cloudbox/configuration.nix:~1187`) to compare the RUNNING process's store path against the installed unit's `ExecStart`; mismatch → loud log/alert. Same for serves via the serve canary.
  - **GOTCHA (verified):** for the door, `readlink /proc/<pid>/exe` returns the **nodejs** store path, NOT the frontdoor one — the door runs `node .../libexec/opencode-frontdoor`. Must parse `/proc/<pid>/cmdline` (e.g. `tr '\0' ' ' < /proc/$PID/cmdline | grep -oE '/nix/store/[^ ]*frontdoor[^ /]*'`). For **serves**, `readlink /proc/<pid>/exe` DOES resolve to the opencode binary and works. The canary already extracts `ExecStart` via `systemctl show "$UNIT" -p ExecStart --value` (`configuration.nix:~161` inside the canary script).

### 2. Part B reconcile hardening (patched.4) — the freeze-class cap
Per `2026-07-24-phase9-door-route-allowlist.md:42-44`: bounded `reconcilePending` — N=3 consecutive failures (any kind, no transient/permanent taxonomy) → proceed-degraded + one-shot toast + slow reconnect; NO periodic re-fetch. Plus bootstrap `Promise.all` → `allSettled` (`sync.tsx:533-551`). **Would have prevented incident #1.** Carry `sq1v`'s interim fix in the same cut: scope reconcile to owner-confirmed (routed) sids so it never silently returns `[]` for children.

### 3. `sq1v` — door-side parent-walk (P1, LIVE not latent)
Subagent permissions are answerable only when the parent happens to own the anchor (~1 in 4). Fix: on the not-routed branch in `resolve.ts`, resolve child → parent → owner. Cheaper than feared: the door **already** GETs the anchor's `/session/{sid}` in `place.ts` (`checkSidExists`), and `parentID` is **immutable** → cache child→root forever (bounded LRU), so the FABLE-S1 blocking hazard is paid once per child sid. Then add a counter on "not-routed mutation forwarded to anchor" (`proxy.ts:637-641`); if ~zero after a week, tighten that branch to 503 — data-driven, retires the silent-wrong-process class.

### 4. Mechanical gates (can interleave with 2-3)
- **`/doc`-diff classification gate** (~50 lines): run the PINNED binary from the nix store (not the live pool), fetch `/doc`, feed every path × method through the door's `classify()`, **fail the build on any `unrecognized`**. Would have caught Phase 9's four missing routes pre-deploy. Turns the hand-maintained reconciliation header (`routes.classification.ts:5-9`) into a checked invariant. Running it against LIVE serves also yields a version-skew detector.
- **Denial telemetry**: the `/doc` gate catches *unclassified* routes (Phase 9 shape) but NOT *classified-but-denied-yet-needed* (Phase 10 shape), which aren't enumerable a priori. Door already logs denials (`proxy.ts:465-478`) → daily 404-unrecognized/403/501 report.
- **HTML-poison guard** (small, high value): a `session-path` response with `content-type: text/html` is ALWAYS a stale serve's SPA fallback. Rewrite to a JSON 502 at the door → kills incident #1's class generically for every future skew window.

### 5. Phase 9.2 — grep-guard NOW, token DEFERRED
The grep-guard "no non-frontdoor callers" test delivers the real invariant (tooling doesn't depend on pool internals) at ~zero risk. **The token is near-theater on this box** (see verified findings) and carries a coordinated multi-process env rollout — exactly the deploy shape that caused both incidents; a missed client → 401 on `/place` → placement silently skipped → lease-less anchor turns. Defer until a second host exists or item 1's tooling can sequence it. If ever done, `GET /sessions` must be gated too or the token means nothing.

### 6. Backlog unchanged
`mlve.7`–`mlve.10` (door-down fallbacks, DELETE-503 doc, per-client behavior matrix), `mlve.5`/`mlve.6` (P3).

## Open decision for the user (reopened by a new fact)
The `users/dev/opencode-config.nix` fix (13 MCP injection blocks hard-reset `"enabled": false` after `mergeOpencode`, wiping any opt-in on every switch) was **declined** partly on the correct point that a `home-manager switch` does not restart serves. But **the pool restarts nightly at 03:00**, so runtime MCP connects evaporate every night and there is **no durable path** to "this MCP server is on tomorrow" — the Phase 10 dialog is effectively a daily-reset toggle. May still be acceptable; decide with this fact on the table.

## Architecture notes (fable)
- **Anchor-degrade is the recurring silent-failure generator** (`sq1v`, FABLE-B1, Phase-10 HIGH-2 are all one shape: "unknown → anchor" is right for shared-DB reads, silently wrong for per-process or mutating). Item 3 is the minimal path to shrinking it; no broader redesign.
- **Per-process state × opaque router costs a fork patch each time** (`session-door-routes.patch`, `session-mcp-routes.patch`, hand-edited generated SDK files) — real accumulating fork debt. Treat any NEW per-process feature as "does this justify another patch?" rather than default-yes; consider upstreaming the session-scoped route pattern.
- **Recommendation: freeze the feature surface.** After items 1-4 everything left is docs and P2/P3 polish. Spend marginal hours on gates, not capabilities.
