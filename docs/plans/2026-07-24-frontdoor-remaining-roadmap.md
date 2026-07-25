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
### 1. Deploy runbook + **stale-binary alerting** ← START HERE

**Finding that reframes this item (verified 2026-07-24 — do NOT re-derive, do NOT rebuild what already works):**
- The door canary **already has a version-drift check** (`hosts/cloudbox/configuration.nix:1293-1308`) and **it fired correctly 70 times** — once a minute, `18:59:03` → `20:08:00`, stopping exactly at the `20:08:38` door restart. It printed the precise diagnosis: `WARNING: version drift: running=/nix/store/5b0zm9wq…-opencode-frontdoor-1.0.0 execstart=/nix/store/qfy87m7l…/bin/opencode-frontdoor`. Incident #2 was debugged by hand for ~70 minutes while a correct machine-generated diagnosis reprinted every 60s into a journal nobody reads.
  → **Detection is not the gap. Delivery is.** Do NOT rewrite the door's detection.
- The door needs **no `/proc/<pid>/cmdline` parsing**: it self-reports its store path via `/healthz` (`"version":"/nix/store/…-opencode-frontdoor-1.0.0"`), which is strictly better than argv introspection (it's the identity of the code actually loaded). The earlier cmdline "gotcha" is moot for the door.
- The **serve canary has no drift check at all** — incident #1 (stale serves) had **zero** detection.
- **Serve self-reporting is useless here**: `/global/health` → `{"healthy":true,"version":"1.17.13"}` — the UPSTREAM semver, identical across patched.1/.2/.3. It could not have caught incident #1's patched.2-vs-.3 skew. The door's self-report trick does NOT transfer.
- **Serve drift must compare store paths.** Running: `readlink /proc/<MainPID>/exe` → `/nix/store/jdn33…-opencode-patched-1.17.13.3/bin/.opencode-wrapped` (works as root, carries the patch level). Reference is **NOT `ExecStart`** — that's the wrapper `…-opencode-serve-start`, whose hash is unrelated to the opencode package. The wrapper's last line is `exec /home/dev/.nix-profile/bin/opencode serve …`, so the reference is `readlink -f /home/dev/.nix-profile/bin/opencode`. Compare the `/nix/store/<hash>-<name>` prefix of each.
- **Delivery already exists**: pigeon `POST /alert {text,severity}` → Telegram (`pigeon/packages/daemon/src/app.ts:109`; `sendPlainAlert` is documented for exactly this "one-shot operational message from an external service" case). Daemon live at `http://127.0.0.1:4731`, `TELEGRAM_BOT_TOKEN`/`CHAT_ID` wired (`configuration.nix:487-488`). No systemd unit posts to it yet. Coupling: if 9.2's token is ever enabled, `checkAuth` gates POSTs and the canaries need it too.

**Explicit non-goal: do NOT auto-restart on drift.** `restartIfChanged = false` is deliberate — a door restart drops every SSE leg, a pool restart kills live sessions. Drift alerts inform a *human* decision about when to take the hit.

**STATUS: 1a/1b/1c/1d BUILT AND DEPLOYED 2026-07-25** (commits `592f898`, `6eb31a1`, `604f20e`, `4fa1d0a`, `7ac3156`, `57742ea`, `01779dc`, `783f8a8`; system `xmrgwqcb3gksnj58xnmz9whkq4fb7clj`). Deploy needed NO door/pool restart — only the canary units changed (verified byte-identical `opencode-frontdoor.service` / `opencode-serve@.service`), and oneshot canaries pick up new code on the next timer firing. Post-deploy verification: both canary units point at the intended scripts, both scripts reference helper `6j2qlnxllx97g1cshmgjsw96qkyijm6d-opencode-drift-alert`, that helper delivered a real Telegram end-to-end (retiring fable's "never executed" E1 for the delivery leg), and both canaries then ran clean and SILENT on a healthy pool. Note `systemctl cat <canary> | grep drift-alert` returns 0 and that is EXPECTED — the unit file holds only `ExecStart=`; the helper reference lives inside the referenced script. Fable verdict on the batch: SHIP WITH FIXES; the fixes are 1d. Fable-confirmed-sound: the `/proc`-vs-profile comparison, GC'd-`(deleted)`-path handling, pigeon 2xx genuinely meaning "Telegram accepted" (`app.ts:124-126` awaits `sendPlainAlert`; `notification-service.ts:492-505` throws on `!ok` → 502), `systemctl restart opencode-serve-pool.target` actually propagating via `partOf`, jq/argv metachar safety, heredoc rendering, throttle-clear gating across reboot/reset/wedge-restart.

**Signal-model decisions (1d), user-approved — do not silently revert:**
- **Serve drift alerts ONLY when dangerous**: (a) a drifting serve started BEFORE the door's current start (door restarted after it → may forward routes those serves lack = incident-1 shape), or (b) the episode survived >24h (i.e. a nightly 03:00 reset — incident-1's literal root cause). Benign drift is journal-only. **Why**: serve drift is the *designed steady state* here — `pull-workstation` auto-applies `home-manager switch` every 4h (verified running 13:21 and 17:31 on 2026-07-24), the pool deliberately isn't bounced, and 03:00 reconciles it. With ~27 opencode pin bumps in 6 weeks, alerting on all drift would fire ~4-5x/week demanding an action the user deliberately doesn't want mid-day, training them to ignore the channel — and the throttle would then SUPPRESS the alert exactly when drift turned dangerous. The door alert has no such problem (door drift is always an operator mistake), which is why it alerts unconditionally.
- **2-consecutive-pass dampening** on both canaries: following the runbook exactly still leaves a seconds-long true-drift window that a minutely canary would ping about.
- **Serve signature = `REF_PREFIX|DOOR_START_MONOTONIC`** (not the port list): the canary's own wedge-restart changing the drift set must not re-alert, and a door restart mid-episode must.
- **24h TTL re-alert** so an ignored alert re-pings instead of going permanently silent.
- **Never alert on unknown** (missing door timestamp, unverifiable pass, empty profile readlink) and never clear throttle state on unknown.

**Known-open (fable, deliberately not done here):**
- **The preventive fix is still unbuilt** — a `deploy-cloudbox` script encoding rebuild→restart-door→HM-switch→restart-pool ending in a post-condition staleness assertion, plus that same assertion inside `reset-workspace`'s restart path (incident 1's actual culprit was a reset that skipped its restart). Alerting is the backstop, not the fix; `pull-workstation` and `reset-workspace` bypass any wrapper, so both are needed. **User decision: build this first next session, before item 2.**
- **Never executed.** Deploy must include a controlled end-to-end test (one real alert + one forced drift episode).
- Devbox has the same staleness class with zero coverage (no door → no skew class; deferred, now noted in the runbook).

- **1a Runbook**: canonical sequence — `nixos-rebuild` → **restart door** → `home-manager switch` → **restart pool** — into the parent plan's Deploy section AND `.opencode/skills/rebuilding/SKILL.md`. Explain *why* (`restartIfChanged = false` on both, deliberate). Include how to check drift by hand: `journalctl -u opencode-frontdoor-canary | grep drift`.
- **1b Door drift → throttled Telegram alert**: keep the existing detection untouched; add an alert on the mismatch branch. **Throttling is mandatory** — the raw signal fires every 60s (70× today). One alert per drift *episode*: write the signature (`running|execstart`) to `$STATE/drift-alerted`; alert only when the computed signature differs from the stored one; clear the file when drift clears so a later episode re-alerts. Factor the alert into a shared nix `let` helper for reuse by 1c.
- **1c Serve drift detection + alert**: add to the existing per-port loop; compare store-path prefixes as above; same throttle (`$STATE/$PORT.drift-alerted`) and same shared helper. Inherit the loop's existing guards (skip inactive units, skip while the `reset-workspace` lock is held).

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

## ~~Open decision for the user~~ — RESOLVED 2026-07-25
The question was: the `users/dev/opencode-config.nix` injection blocks hard-reset `"enabled": false` on every activation (and `pull-workstation` activates every 4h), while the pool restarts nightly at 03:00 — so runtime MCP connects evaporate nightly and there is **no durable path** to "this MCP server is on tomorrow".

**Resolved: intended behavior, no work.** The user's model is that the MCP dialog is an as-needed, off-by-default, ad-hoc toggle, and 03:00 is a welcome reset. No durability requirement exists. See `2026-07-24-phase10-session-scoped-mcp.md` Follow-ups (closed won't-fix, incl. why a preserved opt-in would invert the intended fail-safe for write-capable servers).

**But a real gap surfaced while confirming it:** the dialog is **not per-session isolation** — the toggle is process-global across one of the 4 serves, so it reaches sibling sessions (subagents included) and later arrivals on that serve until the nightly restart. That matters because the default-off rationale is that several servers are write-capable. Documented as an accepted limitation (Phase 10 plan, Limitation 6); deliberately not fixed, since true per-session scoping means another fork patch against fable's freeze-the-surface advice.

## Architecture notes (fable)
- **Anchor-degrade is the recurring silent-failure generator** (`sq1v`, FABLE-B1, Phase-10 HIGH-2 are all one shape: "unknown → anchor" is right for shared-DB reads, silently wrong for per-process or mutating). Item 3 is the minimal path to shrinking it; no broader redesign.
- **Per-process state × opaque router costs a fork patch each time** (`session-door-routes.patch`, `session-mcp-routes.patch`, hand-edited generated SDK files) — real accumulating fork debt. Treat any NEW per-process feature as "does this justify another patch?" rather than default-yes; consider upstreaming the session-scoped route pattern.
- **Recommendation: freeze the feature surface.** After items 1-4 everything left is docs and P2/P3 polish. Spend marginal hours on gates, not capabilities.
