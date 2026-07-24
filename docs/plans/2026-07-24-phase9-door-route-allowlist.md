# Phase 9 fix — front-door route allowlist for the on-door interactive TUI

Status: **DESIGN — fable GO-WITH-FIXES (deltas folded in below); ready for SDD.**
Beads: `workstation-mlve.3` (Phase 8), `workstation-mlve.4` (Phase 9), `workstation-mlve.11` (D4 door-side).
Parent: `docs/plans/2026-07-12-serve-reverse-proxy-plan.md`; opencode-patched `docs/plans/2026-07-22-phase8-tui-through-door.md`.

## Problem
After deploying Phase 8+9 (patched.2 binary + `oc-pool-attach`/`oc-auto-attach` → `$FRONTDOOR_URL`), new attach TUIs hang on the loading screen. Root cause is TWO-layered and I (the author) missed the second layer when I "verified the door supports Phase 9":

1. **Mixed-version window (known):** serves still run the old binary (they restart only via `reset-workspace`/pool-restart, not `home-manager switch`). Old serves lack the new session-scoped routes → HTML SPA fallback. Confirmed on `ses_0758d8b6effesRN7DTihfTONnc` (owner serve-2 :4098, old binary; `GET /session/:id/permissions|questions` → HTML).

2. **Door route allowlist (the miss):** the front door is a *deny-unknown* opaque proxy. `routes.classification.ts` is a hard allowlist; any route not in it → `class: "unrecognized" → action: "not-found-404"` (the door's own JSON 404, before it ever proxies). I conflated two door layers: `sid.ts` *ownership extraction* is generic (`/session/:sid/*`), but *route classification* is a strict enumerated table. **`GET /session/:id/permissions`, `GET /session/:id/questions`, `POST /session/:id/questions/:qid/reply`, `POST /session/:id/questions/:qid/reject` are NOT in the table** → the door 404s them regardless of serve version. This is the *primary* current blocker (hits before the serve version matters). Evidence: through the door, `/children` proxies (200) but `/permissions` → door 404 `{"error":"not_found"}`.

Deeper realization: **Phase 9 is the first time the FULL interactive TUI rides the door.** M2 (Phase 7) only routed the non-interactive clients (create / prompt_async / health / route) through it; attach was always direct-to-serve. So the door allowlist was never sized for the interactive TUI's much larger route surface. The 4 missing routes are what one stuck TUI happened to reveal; there may be more.

## The interactive TUI's route surface (audit input, from the patched.2 tree)
Distinct SDK calls the TUI makes (grep of `packages/tui/src`): session.{list,get,create,delete,fork,revert,unrevert,abort,todo,summarize,status,shell,messages,diff,command,update,children,permissions,questions,questionReply,questionReject}, permission.respond, event.{subscribe,on}, sync.start, plus non-session/resource calls: vcs.{status,get}, provider.{oauth,list,auth}, instance.dispose, mcp.{status,connect,disconnect}, lsp.status, config.{providers,get}, project.{directories,current}, path.get, command.list, auth.set, app.{agents}, find.files, formatter.status, global.upgrade, experimental.{workspace,console,session,resource,projectCopy,controlPlane,capabilities}.

Two buckets matter:
- **Bootstrap-path calls** (fire at load, BEFORE the user does anything): if ANY of these is door-denied/404/HTML, the TUI can hang or error on load — the actual stuck-screen risk. Must be identified precisely (read `sync.tsx` bootstrap + `app.tsx`/context providers' `onMount`).
- **Interactive/feature calls** (user-triggered): a denied route breaks that feature but should not hang load.

Door-registered bare `/session` paths today (allowlist): `{id}`, `/abort /children /command /diff /fork /init /message /message/{mid} /message/{mid}/part/{pid} /permissions/{permissionID} /prompt_async /revert /share /shell /summarize /todo /unrevert`, `/session/status`. **Missing: the 4 above.** (Also confirm globals: list/create `/session`, and the resource routes vcs/provider/config/project/path/command/app/find/formatter/lsp/mcp/auth/instance/experimental — each is classified somewhere; some are intentionally denied per D4.)

## Design

### Part A — Door: audit + register (workstation `pkgs/opencode-frontdoor/`)
1. **Exhaustive audit.** For EVERY route the on-door TUI calls (bootstrap first), determine the door's current classification by reading `routes.classification.ts` + `dispatch.ts` (or curling each through `:4700`). Produce a table: route → current class/action → verdict.
2. **Register the missing session-scoped routes** as `class: "session-path"` (bare surface; SDK v2 calls bare `/session/...` — confirmed `url: "/session/{sessionID}/permissions"`). At minimum the 4; plus anything else the audit finds that the TUI legitimately needs and the door 404s. Add `/api/*` mirrors iff the door's dual-surface convention requires it (the table pairs bare+`/api`; keep it consistent).
3. **Intentional denials (D4 / mlve.11) stay denied** — mcp.connect/disconnect, auth.set, provider.oauth.*, instance.dispose, experimental.* per the fable-verified per-route dispositions in the Phase 8 plan. The TUI must **degrade gracefully** on these (feature unavailable, no hang) — verified in Part B. Do NOT blanket-allow.
4. **Door tests (fable MEDIUM-3 — must be BUILT, not just "updated"; the table-derived tests do NOT fail closed on omission):** add **positive** `gate.sh` probes (`NON-DENY`, ~line 94) for all 4 routes (+ negative 404 pins if `/api` mirrors are declined); add explicit `classify()` assertions in `dispatch.test.ts`; update the header reconciliation block (`routes.classification.ts:4-9` "Patch-only routes / Total" counts); note in `routes.snapshot.txt` (191 lines, intentionally excludes patch-only routes) so the next auditor doesn't "reconcile" the entries away.
5. **Audit-table dispositions (fable LOW-1/2 + missing cases)** — record an explicit verdict for each, no code needed unless noted:
   - root/on-door TUI with no active session → `sdk.global.event` → door **410** forever (D6's "global events pass the filter" is FALSE through the door). Accept + document, or (stretch) connect the scoped stream to the newest-session set. `LOW`.
   - `GET /session/status`, `GET /permission`, `GET /question` (the FABLE-P5-F2 "revisit before Phase 7/9" notes) forward to the anchor but read per-process state → stale-but-cosmetic (`session.status` fires at bootstrap; view derives real status from messages). Disposition: accept+re-note or flip to `per-process-ro` 501.
   - `move-session` (control-plane `n`), `projectCopy`, `global.upgrade` → global-sideeffect 403/405, user-triggered, no hang → "denied-by-design, TUI shows error."
   - Door restart drops all SSE legs + the in-memory sticky map (mid-turn stickiness resets) → acceptable, state it.

### Pre-flight (fable HIGH-2 — VERIFY BEFORE relying on child reconcile)
The door resolves each `session_ids` member via a FLAT pigeon `/route` lookup (`resolve.ts:29`, no parent-walk); an unrouted sid degrades to the **anchor** (`resolve.ts:53-58`), whose per-process pending list for that child is empty → `200 []` → **silent** no-replay hole (neither hard-fail nor degrade catches it — it's not an error). Child sessions are minted INSIDE the owning serve by the Task tool; the door's minter placement never saw them. **Verify:** with a live subagent, `curl $PIGEON_DAEMON_URL/route?session_id=<child sid>` must resolve to the parent's owner (not degrade). If children are NOT routed, the door needs a parent-walk in `resolve.ts` (resolve child → its parent → parent's owner) OR reconcile must fetch only owner-confirmed sids. The Phase-8 gate item (a) — "a subagent permission asked at spawn renders + is answerable **through the door**" — is the acceptance test that detects this.

### Part B — TUI robustness (opencode-patched `tui-door-attach.patch`, cut patched.3) — SIMPLIFIED per fable MEDIUM-1/2
1. **`reconcilePending` must not brick the TUI.** Current: any reconcile `.error` throws → onOpen throws → infinite reconnect stuck-load. REVISE to a SIMPLE bounded policy (NO transient/permanent taxonomy — misclassification is worse than the ~7s it saves): count consecutive reconcile-attempt failures **of any kind**; after **N=3** (riding the existing ~1+2+4s backoff) → **proceed-degraded**: skip reconcile, let the pump start, show a **one-shot toast per episode**. Reconcile auto-retries on every subsequent reconnect (`sdk.tsx:263-266`), so degraded self-heals; reset the degraded flag + toast latch on the first successful reconcile. (Optional: short-circuit immediately on a definite JSON-404.)
2. **Degraded recovery = slow-cadence full RECONNECT, not a periodic re-fetch.** A periodic pending re-fetch would run concurrent with the event pump and reintroduce the stale-re-add race the current await-before-pump ordering avoids (`sse.ts:92-97` inject completes before `for await`). Instead, while degraded, schedule a slow full reconnect (~2–5 min) — the reconnect re-runs reconcile in the safe pre-pump position for free.
3. **Bootstrap resilience (LOW-3):** swap the non-blocking bootstrap `Promise.all` (`sync.tsx:533-551`) to `allSettled` while touching the area (a single rejection currently strands `status` before `"complete"`, breaking `--session --fork`). Fable confirmed NO bootstrap call currently 404s through the door (all registered; `mcp.status`→501 tolerated), so this is hardening, not the fix.
4. Re-verify: tui `tsgo`, sse/route + door-scope tests, `apply.sh` zero-fuzz; cut `v1.17.13-patched.3`.

### Part C — Deploy + gate (REORDERED per fable HIGH-1)
The serves' pinned binary is ALREADY patched.2 (has the server routes); they just haven't restarted. So the **outage fix is door change + reset-workspace — NO patched.3 required.** patched.3 (Part B) is *hardening*, cut afterward at leisure. Do NOT bury recovery behind a release cut.
- **Recovery (minutes, existing reviewed binaries):**
  1. Land Part A (door routes) → `sudo nixos-rebuild switch --flake .#cloudbox` + `sudo systemctl restart opencode-frontdoor`.
  2. `reset-workspace` (serves restart onto the already-pinned patched.2, which has the routes).
  3. Verify: `curl :4700/session/<sid>/permissions` → JSON `[]` (not 404, not HTML); door `RequestLogger` shows no 404/501/403/410 on a fresh on-door attach + subagent-permission flow.
- **Hardening (later):** cut `v1.17.13-patched.3` (Part B), bump pin (`patchedRevision=3` + 4 hashes), `home-manager switch`, next `reset-workspace`.
- **Live gate:** subagent permission renders + answerable **through the door** (this is the HIGH-2 detector — see pre-flight); session-switch; idle-migration; `audit/gate.sh` green.

## Questions — RESOLVED by fable
1. **Line for allowlist:** register them — (a) sid-in-path → `session-path` (owner-resolvable, leaks no topology); (b) shared-DB global reads → `global-ro`; per-process in-memory reads → `per-process-ro` 501 (like `/mcp`); (c) non-session-scopable mutations → stay denied (D4/mlve.11). All 4 routes are (a); none needs anchor-pin/broadcast (owner-routing IS their correct pinning, modulo the HIGH-2 child-routing check).
2. **reconcile policy:** bounded N=3 any-failure → degrade + one-shot toast + slow reconnect (no taxonomy, no periodic re-fetch). See Part B.
3. **Bootstrap enumeration:** static-first (done: `sync.tsx:464-548` + `project.tsx:41-58` + `data.tsx:551-565` + `sdk.tsx` open/onOpen/poll + `validate-session.ts` + session-view mount `sync.tsx:614-618`), then confirm dynamically via the door `RequestLogger` (`proxy.ts:437-455`) on a real attach — grep the door log for any 404/501/403/410.
4. **Denied-at-load:** NONE 404. `mcp.status`→501 tolerated; lsp/vcs/config/app.agents/project/path/provider.list all registered. Only load-path 404s are the 4 reconcile routes. (Add `allSettled`, LOW-3.)
5. **/api mirror:** bare REQUIRED (SDK bare-only, `sdk.gen.ts:4367-4482`). Add `/api` mirrors ONLY iff a patched serve actually answers `/api/session/<sid>/permissions` — probe once; else don't register phantom routes. Pin the decision in `gate.sh`.

## Fable confirmations (de-risked — don't re-litigate)
- The bootstrap route set is clean: the 4 missing routes are the COMPLETE door-404 set on the load path.
- Door mechanics safe: `{sessionID}`→`[^/]+` slash-bounded, table order immaterial, no overlap with `/permissions/{permissionID}`; multi-sid `/event` untouched; POST reply/reject auto-get mutating-sticky (desirable — pins to the turn owner); no `timeouts.ts` change.

## Hazards
- Blanket-allowing everything defeats the door's opacity/security goal (the whole point of the reverse proxy). Register deliberately.
- The door is a system service → route changes need `nixos-rebuild` + restart, NOT just home-manager.
- patched.3 is another fork cut + pin bump; keep `apply.sh` zero-fuzz.
