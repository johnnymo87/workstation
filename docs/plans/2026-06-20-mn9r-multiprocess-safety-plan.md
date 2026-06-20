# mn9r — Multi-Process Safety for the K-Serve Pool — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (or subagent-driven-development) to implement this plan milestone-by-milestone. This is an EPIC-level master plan: M1 is broken into bite-sized TDD tasks and is executable now; M2–M7 are specified at milestone granularity (files, approach, tests, risks, deps) and must each be expanded to bite-sized tasks when reached. Do the milestones in dependency order. Re-read `bd show workstation-mn9r` for the canonical decision record.

**Goal:** Make the pool of K opencode-serve processes safe to share one host + one `opencode.db`: a correct per-session lease (≤1 serve runs a session's agent loop), DB-FD/cutover safety, and a serve-pool supervisor — deployable on all devices.

**Architecture (decided 2026-06-20, ChatGPT deep-research `/tmp/research-serve-lease-channel-answer.md`):** **A′ — direct SQLite CAS from each serve against a SEPARATE pigeon-owned routing DB** (not HTTP; not naive shared-DDL in `opencode.db`). Revised authority model: *pigeon is the sole **assignment/generation/epoch** authority; SQLite is the **lease** authority; serves mutate only their own fenced lease/heartbeat rows via canonical CAS, validated against `session_assignment` + `routing_meta`.* Pigeon owns routing-schema migrations; serves assert `routing_schema_version` + `ddl_checksum` at boot and **fail closed** on mismatch.

**Tech stack:** pigeon = Node + better-sqlite3 (single writer of schema/migrations). opencode serve = Bun + Effect-TS + Drizzle/SQLite (lease CAS via a dedicated lease adapter). workstation = NixOS (cloudbox system unit, devbox/crostini `systemd.user`, macOS `launchd`) + home-manager. opencode patched via `opencode-patched/patches/*.patch` (git-diff format, `apply.sh`).

---

## Prerequisites (state)

- **`/event` session-scope patch** — DONE (`opencode-patched/patches/event-session-scope.patch`, #7 in `apply.sh`, in deployed build). Enables per-session placement.
- **zao4 ingress router (K=1)** — PR #4 OPEN, awaiting user merge. Built the routing tables + (buggy) lease CAS + HRW placement + health poller + `GET /route`. mn9r hardens and extends it. M1 below does NOT require PR #4 to be merged (it's pigeon-repo code; can branch off `zao4-ingress-router` or `main` after merge).
- **Confirmed facts** (recon 2026-06-20): pigeon's routing tables live in `pigeon-daemon.db` (env `PIGEON_DAEMON_DB_PATH`, default `${cwd}/data/pigeon-daemon.db`) — **separate from `opencode.db`**. `OPENCODE_DB`/`OPENCODE_DISABLE_CHANNEL_DB` set NOWHERE today. opencode v1.17.7 source for patches lives at `/tmp/opencode/v1177-apply` (worktree of `~/projects/opencode`, re-materialize: `git -C ~/projects/opencode worktree add /tmp/opencode/v1177-apply 4ed4f749e`).

---

## Milestone map (dependency-ordered)

| M | Title | Repo | Shared-tree / restart? | Depends on | Risk |
|---|---|---|---|---|---|
| **M1** | Harden lease CAS contract (`routing_meta`, fenced acquire/renew/release, epoch fence, concurrency stress test) | pigeon (single-writer) | no / no | — | med (correctness) |
| **M2** | Pin `OPENCODE_DB` + `OPENCODE_DISABLE_CHANNEL_DB` on all launchers (bead oxg8) | workstation | YES / serve restart | — | low |
| **M3** | `createNext` read-back (bead p196) | opencode-patched | no / rebuild | — | low |
| **M4** | Serve-side lease participation (bootstrap + heartbeat + agent-loop acquire/renew/release) | opencode-patched | no / rebuild | M1, M2 | **high** |
| **M5** | Serve-pool supervisor (boot K, per-device sizing, restart-fanout target) | workstation | YES / serve restart | M4, M2 | **high** |
| **M6** | Atomic binary cutover + maintenance fence (epoch bump, drain, zero-FD verify) | pigeon + opencode + workstation | YES / serve restart | M4, M5 | **high** |
| **M7** | Client migration to discovery + per-session `/event`; remove `:4096` | workstation | YES / serve restart | M5 | med |
| M8 | Elasticity (K_min/K_max autoscale) — optional, slow, last | pigeon + workstation | — | M5 | low (deferred) |

**Coordination:** the sibling session `ses_11fe4a568ffe5...` (cfp/T13, DONE) co-edits the shared `workstation` tree. Before ANY shared-tree edit (M2/M5/M6/M7): `git pull --rebase`, edit, `git status` pre-commit, `git commit -- <explicit paths>` (never `git add .`), ping sibling with exact files. Settled regions to NOT touch in `hosts/cloudbox/configuration.nix`: cfp `let`-block (~:40-44), cfp service (~:780-828), nix-daemon sops-template/EnvironmentFile (~:935-950); and `opencode-config.nix` `injectAigatewayBaseUrl` (~:774-879, sibling's file — coordinate the pool-restart-hook edit in M5).

---

## M1 — Harden the lease CAS contract (pigeon)

**Why first:** pure pigeon-repo (single-writer), no serve restart, no shared-tree. Fixes 3 real correctness bugs in the *shipped* CAS and establishes the contract M4's serve-side code depends on. The K>1 safety proof is a concurrency stress test asserting ≤1 live owner.

**Files:**
- Modify: `packages/daemon/src/routing/route-schema.ts` (add `routing_meta` + `routing_schema_version`; bump schema version; compute `ddl_checksum`)
- Modify: `packages/daemon/src/routing/route-repo.ts:215-289` (rewrite `acquireCAS`, `renewCAS`, `release`; add `RoutingMetaRepo`)
- Modify: `packages/daemon/src/routing/router.ts` (wire `binaryEpoch` from `routing_meta`; pass through `placeSession`/`touch`/`sweep`)
- Modify: `packages/daemon/src/config.ts` (add `PIGEON_BINARY_EPOCH` default 0; read `routing_meta` as source of truth at boot)
- Modify/Create tests: `packages/daemon/test/routing/route-repo.test.ts`, new `packages/daemon/test/routing/lease-cas-concurrency.test.ts`

**Branch:** if PR #4 still OPEN → branch `mn9r-lease-cas` off `zao4-ingress-router` (stacks on the router) OR add to PR #4; if PR #4 MERGED → off `origin/main`. Decide at execution time via `gh pr view 4 --json state`.

### The corrected SQL (from ChatGPT answer lines 199-276 — the contract)

`routing_meta` (canonical epoch + schema version, single row):
```sql
CREATE TABLE IF NOT EXISTS routing_meta (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  schema_version INTEGER NOT NULL,
  ddl_checksum   TEXT NOT NULL,
  binary_epoch   INTEGER NOT NULL,
  updated_at     INTEGER NOT NULL
);
```

**acquire** — validate assignment + epoch in BOTH insert and conflict paths (fixes Hole 1: stale lower-gen insert when row absent):
```sql
INSERT INTO session_lease (session_id, serve_id, instance_uuid, owner_generation, lease_expires_at, heartbeat_at, binary_epoch)
SELECT @sid, @serve, @uuid, sa.owner_generation, @now + @ttlMs, @now, rm.binary_epoch
FROM session_assignment sa JOIN routing_meta rm ON rm.id = 1
WHERE sa.session_id=@sid AND sa.desired_serve_id=@serve AND sa.owner_generation=@gen AND rm.binary_epoch=@epoch
ON CONFLICT(session_id) DO UPDATE SET
  serve_id=excluded.serve_id, instance_uuid=excluded.instance_uuid, owner_generation=excluded.owner_generation,
  lease_expires_at=excluded.lease_expires_at, heartbeat_at=excluded.heartbeat_at, binary_epoch=excluded.binary_epoch
WHERE EXISTS (SELECT 1 FROM session_assignment sa JOIN routing_meta rm ON rm.id=1
              WHERE sa.session_id=excluded.session_id AND sa.desired_serve_id=excluded.serve_id
                AND sa.owner_generation=excluded.owner_generation AND rm.binary_epoch=excluded.binary_epoch)
  AND ( session_lease.binary_epoch < excluded.binary_epoch
        OR (session_lease.binary_epoch = excluded.binary_epoch AND session_lease.owner_generation < excluded.owner_generation)
        OR (session_lease.binary_epoch = excluded.binary_epoch AND session_lease.owner_generation = excluded.owner_generation
            AND (session_lease.lease_expires_at <= @now
                 OR (session_lease.serve_id = excluded.serve_id AND session_lease.instance_uuid = excluded.instance_uuid))) );
```
> **Epoch-steal caveat:** the `binary_epoch < excluded.binary_epoch` branch lets a new-epoch serve steal an old-epoch lease immediately. Keep it ONLY because M6's cutover drains+stops old serves first. If that guarantee weakens, drop this branch and wait for expiry.

**renew** — check assignment + epoch (fixes Hole 3):
```sql
UPDATE session_lease SET lease_expires_at=@now+@ttlMs, heartbeat_at=@now
WHERE session_id=@sid AND serve_id=@serve AND instance_uuid=@uuid AND owner_generation=@gen AND binary_epoch=@epoch
  AND EXISTS (SELECT 1 FROM session_assignment sa JOIN routing_meta rm ON rm.id=1
              WHERE sa.session_id=@sid AND sa.desired_serve_id=@serve AND sa.owner_generation=@gen AND rm.binary_epoch=@epoch);
```

**release** — fence by full token (fixes Hole 2):
```sql
DELETE FROM session_lease
WHERE session_id=@sid AND serve_id=@serve AND instance_uuid=@uuid AND owner_generation=@gen AND binary_epoch=@epoch;
```

### Bite-sized tasks

**Task M1.1 — `routing_meta` schema + repo (TDD)**
1. Write failing test: `RoutingMetaRepo.get()` returns the seeded row `{schemaVersion, binaryEpoch:0}`; `bumpEpoch()` increments under a txn. (`route-repo.test.ts`)
2. Run → FAIL (no `routing_meta`).
3. Add `routing_meta` + `routing_schema_version` to `route-schema.ts` (seed `id=1, binary_epoch=0, schema_version=<n>, ddl_checksum=<hash of routing DDL>`); add `RoutingMetaRepo` to `route-repo.ts`.
4. Run → PASS. 5. Commit (`feat(routing): routing_meta canonical epoch + schema-version row (mn9r)`).

**Task M1.2 — fenced `release` (TDD)** — test: a stale `(serve,uuid,gen,epoch)` release does NOT delete a newer owner's lease; the matching owner's release does. Implement fenced DELETE. Commit.

**Task M1.3 — assignment-validated `acquireCAS` (TDD)** — tests: (a) acquire with NO existing lease row but a STALE `owner_generation` < assignment's is REJECTED (Hole 1); (b) higher-gen wins; (c) same-gen self-renew idempotent; (d) same-gen expired steal; (e) epoch mismatch rejected. Implement the SELECT-validated UPSERT. Commit.

**Task M1.4 — assignment+epoch `renewCAS` (TDD)** — tests: renew fails after pigeon bumps `owner_generation`; fails after `routing_meta.binary_epoch` bumps; succeeds for the current owner at the current epoch. Implement. Commit.

**Task M1.5 — wire epoch through router (TDD)** — `IngressRouter` reads `binary_epoch` from `routing_meta` (not the hardwired `0`); `placeSession`/`touch`/`sweep`/`reassignFromDeadServe` thread the current epoch. Update `router.ts` + config. Tests adjust. Commit.

**Task M1.6 — concurrency stress test (THE safety proof)** — new `lease-cas-concurrency.test.ts`: spawn N worker threads/processes (better-sqlite3 on the same temp DB file, WAL) hammering acquire/renew/expire/gen-bump/release on a shared session set; assert **never >1 live owner** at any instant and that gen/epoch bumps always evict the prior owner. This is the cross-binding correctness gate M4 extends. Commit.

**Task M1.7 — gate + push** — root `npm test` + `npm run typecheck` green; push branch; if extending PR #4, run shepherding-pull-requests monitor.

**M1 risks:** (a) WAL snapshot staleness — never treat a read as authoritative; only `changes()>0` grants ownership. (b) better-sqlite3 vs Bun binding differences deferred to M4 (M1 proves the SQL contract with better-sqlite3). (c) schema migration: routing tables use `CREATE TABLE IF NOT EXISTS` with no versioning today — add `routing_schema_version` now so M4's serve can assert it.

---

## M2 — Pin `OPENCODE_DB` + `OPENCODE_DISABLE_CHANNEL_DB` (bead oxg8) (workstation, all devices)

**Why:** K serves sharing `opencode.db` requires every writer to resolve the SAME absolute file; today none pin it → latent channel-suffixed-DB split-brain. Independent of M1.

**Files (mirror the `OPENCODE_EXPERIMENTAL_OUTPUT_TOKEN_MAX` precedent at `home.base.nix:836-840` — shell var + per-unit copy):**
- Shells: `users/dev/home.base.nix` `sessionVariables` (~:823-846) → add `OPENCODE_DB` (absolute, e.g. `${config.home.homeDirectory}/.local/share/opencode/opencode.db`) + `OPENCODE_DISABLE_CHANNEL_DB="1"`.
- serve units: cloudbox `hosts/cloudbox/configuration.nix:541-558`; devbox `home.devbox.nix:434-447`; crostini `home.crostini.nix:139-147`; macOS `home.darwin.nix:133-157` (shell export).
- pigeon-daemon (×4): cloudbox `:395-414`, devbox `hosts/devbox/configuration.nix:240-244`, crostini `home.crostini.nix:104-109`, macOS `home.darwin.nix:106-117`.
- lgtm-run `hosts/cloudbox/configuration.nix:467-478`; nightly reset timers `hosts/devbox/configuration.nix:297-300`, `hosts/cloudbox/configuration.nix:846-849`.
- Confirm the absolute path matches opencode's resolver: `OPENCODE_DB` relative → `join(Global.Path.data, OPENCODE_DB)`; absolute → used as-is (`core/database/database.ts:43-55`). Use absolute to be unambiguous.

**Tests/verify:** `nix flake check` / per-host eval; after the user's rebuild, `systemctl show opencode-serve -p Environment` shows the var; `lsof` confirms all serves + pigeon hold the SAME `opencode.db` FD. Host-gate per device (paths differ: cloudbox/devbox `/home/dev`, macOS `/Users/...`).

**Coordination:** shared-tree; touches `configuration.nix` (sibling territory) — pull --rebase, explicit pathspec, ping. **Activation restarts opencode-serve** → user runs the switch (or the 4h auto-puller picks it up).

**Risk:** an existing `opencode.db` at the default location must be the one pinned (don't orphan history). Verify the resolved default path before pinning.

---

## M3 — `createNext` read-back (bead p196) (opencode-patched)

**Why:** read-after-write canonicalization so register/start see the durable row (not the hand-built in-memory `Info`). Independent; low risk.

**Files:** new `opencode-patched/patches/createnext-readback.patch` (against `session/session.ts:579`: `return result` → `return yield* get(result.id)`; `get` exists at `:582`). Register in `apply.sh` `PATCHES=()` (~:77-85) + document in header/README.

**Tasks (TDD against `/tmp/opencode/v1177-apply`):** add/extend a session-create test asserting the returned object equals `fromRow(get(id))` (round-trip-normalized). Generate patch via `git diff`. Verify `apply.sh` applies cleanly on a fresh v1.17.7 worktree. Commit to opencode-patched.

**Risk:** the durable write at `:577` is already synchronous (projector runs in-txn), so this is a correctness/normalization guard, not a race fix — keep the change minimal (one line + test).

---

## M4 — Serve-side lease participation (opencode-patched) — **HIGH BLAST RADIUS**

> **Detailed implementation-ready spike:** `docs/plans/2026-06-20-mn9r-m4-serve-lease-plan.md` (recon-verified insertion points + exact lease CAS SQL + 7 TDD tasks). It surfaces two design gaps this section assumed away — **D1 serve identity bootstrap** (serve_instance is pigeon-minted today) and **D2 behavior when no assignment exists** — both needing a decision before coding.

**Why:** the core of mn9r — serves must hold a fenced lease to run a session's agent loop. Depends on M1 (contract) + M2 (shared DB pin).

**New patch `serve-lease.patch` (+ maybe a new `packages/core/src/serve/` module). Insertion points (v1.17.7):**
1. **Lease adapter** (new): a dedicated SQLite connection to the **routing DB** (NOT `opencode.db`) — path via a new env (e.g. `OPENCODE_ROUTING_DB` = pigeon's `PIGEON_DAEMON_DB_PATH`, or a dedicated `routing.db`). Boot assertion: read `routing_schema_version`/`ddl_checksum`; **fail closed** on mismatch. Short `busy_timeout` + retry/jitter; **do NOT** run on the hot Bun loop with 5s timeout — consider a Worker. Implements acquire/renew/release using M1's exact fenced SQL.
2. **Serve bootstrap** (`cli/cmd/serve.ts:19-22`, between `Server.listen` and `Effect.never`): generate `instance_uuid`; check `routing_meta.binary_epoch` fence (refuse to start if stale); `INSERT serve_instance`; `Effect.forkScoped` a heartbeat timer (process-level, NOT per-request-instance — recon risk flag #1); add finalizer to mark serve dead on shutdown.
3. **Agent-loop lease** (`session/prompt.ts`): wrap `runLoop` at `:1407` with `Effect.acquireRelease` — acquire on the real Idle→Running transition (NOT before `ensureRunning`, recon risk flag #1: double-acquire), fenced release on exit (success/cancel/interrupt). **Renewal = a TTL/3 (~10s) timer fiber with jitter**, NOT per-iteration. Per-iteration `:1142-1143` = a guard (check lease validity before a long/side-effecting step; pause/cancel if can't renew before safety margin). Treat the `shell()` path (`:1410-1415`) too if it counts as holding the session.

**Failure semantics:** start run → require successful acquire (no acquire, no loop). Continue run → only while local lease deadline valid; retry renew w/ jitter; never proceed past the deadline.

**Tests:** unit-test the lease adapter against a temp routing DB (reuse M1's contract tests cross-binding). Extend M1's concurrency stress test to include a Bun/Drizzle writer alongside better-sqlite3 (cross-binding multi-writer proof). Integration: two serves + one session → exactly one runs; kill the owner → other acquires after expiry/gen-bump.

**Risks (recon-flagged):** Bun event-loop stalls from sync SQLite (measure canary p99 with lease writes on; Worker if needed); lease boundary correctness (acquire only on Idle→Running; `onBusy` is NOT a reliable acquire hook); the routing DB path/availability at serve boot; patch must apply cleanly against v1.17.7 and survive opencode upgrades.

---

## M5 — Serve-pool supervisor (workstation, all devices) — **HIGH BLAST RADIUS**

**Why:** boot/manage K warm serves on fixed loopback ports sharing `opencode.db`. Depends on M4 (serves must lease before pooling) + M2.

**Approach:** a systemd **target** `opencode-serve-pool.target` wanting K templated units `opencode-serve@<port>.service` (so ONE restart fans out — per sibling's flag). Per-device K via host-gating (`isCloudbox` K=4; `isDevbox` K=2; `isCrostini` K=1; macOS K=2 — tune). Authored 4×: cloudbox **system** (`hosts/cloudbox/configuration.nix`, mirror `opencode-serve` :519-638 + cfp service :793-828), devbox/crostini **`systemd.user`** (`home.devbox.nix`/`home.crostini.nix`), macOS **`launchd.agents`** (`home.darwin.nix`, one agent per port). Each unit: distinct `--port`, shared `OPENCODE_DB` (M2), `instance_uuid` per boot (M4), the routing-DB env.

**Also:** update pigeon-daemon `PIGEON_SERVE_ENDPOINTS` to list the K ports (cloudbox `:395-414` etc.); add the sops auth token (`PIGEON_DAEMON_AUTH_TOKEN` via the `nix-daemon-github-token` sops-template idiom at `:935-950`) + `127.0.0.1` bind. **Update `injectAigatewayBaseUrl`'s restart line** (sibling's `opencode-config.nix:774-879`) to bounce `opencode-serve-pool.target` instead of `opencode-serve.service` — COORDINATE with sibling (their file).

**Tests/verify:** per-host eval; after rebuild, `systemctl status opencode-serve-pool.target` shows K active; pigeon `GET /route` distributes across K; `lsof` shows K serves on one `opencode.db`.

**Risk:** macOS launchd has no "target" — emulate with K agents + a wrapper for fan-out restart. cgroup memory: K=4 @ M=80 ≈ 3.3 GB (fine under 32 GiB cap). Don't bounce the whole pool on every rebuild (`restartIfChanged=false` like aigateway :751 where appropriate).

---

## M6 — Atomic binary cutover + maintenance fence (pigeon + opencode + workstation) — **HIGH BLAST RADIUS**

**Why:** safely swap the serve binary across K writers without two epochs running. Depends on M4 + M5.

**Approach:** procedure = router `accepting_new_work=false` → mark all serves `draining` → wait active turns finish (or abort by policy) → stop all serve processes → (optional SQLite checkpoint) → **bump `routing_meta.binary_epoch` under `BEGIN IMMEDIATE`** → start new serves → resume. Old serves can't renew/acquire across the epoch (M1 fences). A real **maintenance fence** honored by EVERY launcher (pigeon, oc-launch, lgtm, reset timers, user shells); **verify zero `opencode.db` FDs** before swap (`lsof`). Wire `PIGEON_BINARY_EPOCH`/`routing_meta` bump into a pigeon control route or a workstation deploy script.

**Tests:** simulate cutover in pigeon tests (epoch bump → old-epoch acquire/renew rejected). Operational dry-run script with `--check` that asserts zero FDs + old-epoch heartbeats ceased before declaring success.

**Risk:** this is the most operationally dangerous milestone — gate behind explicit dry-run + the removal/op-acceptance gates from `2026-06-17-process-per-session-design.md` §12/§13.

---

## M7 — Client migration + remove `:4096` (workstation) 

**Why:** clients must discover the owning serve (`GET /route`) + open per-session `/event`, instead of the single `:4096`. Depends on M5.

**Consumers to migrate (recon list):** `opencode-launch`/`opencode-send`/`lgtm-sessions` (`home.base.nix`), `lgtm-run` (`configuration.nix:469`), `reset-workspace` (`pkgs/reset-workspace/default.nix`), pigeon-daemon `OPENCODE_URL` (×4), fp-digest (devbox `:363-367`), `opencode-llm-audit` (pgrep-based — may need per-instance log fds). Then remove the single `:4096` endpoint + `opencode-serve.service` (superseded by the pool target).

**Risk:** broad blast radius across reliability tooling (reset, audit, digest). Migrate behind the removal gate; keep `:4096` until every consumer is proven on discovery.

---

## Open sub-decisions (resolve at execution time)

1. **Routing DB file:** dedicated `routing.db` vs reuse `pigeon-daemon.db`. Lean **dedicated routing.db** (clean ownership; serves open only routing tables) — but `pigeon-daemon.db` already has the tables + CAS. Decide in M1 (affects schema location) — if dedicated, split routing tables out of `pigeon-daemon.db` into `routing.db` and point both pigeon + serves at it.
2. **Serve lease I/O threading:** inline dedicated connection vs Bun Worker. Start inline w/ short busy_timeout + jitter; move to Worker only if canary p99 regresses (measure in M4).
3. **Renewal cadence constant:** TTL=30s, renew=TTL/3≈10s, jitter ±10-20%. Confirm against pool-probe harness.
4. **Per-device K:** cloudbox 4 / devbox 2 / crostini 1 / macOS 2 — tune empirically.
5. **`opencode-llm-audit`** under a pool: today it tails one serve log fd; needs per-instance fds or a switch to the aigateway ledger.

## Related beads (fold in / close as milestones land)

- `workstation-oxg8` (pin OPENCODE_DB) = **M2**. `workstation-p196` (createNext read-back) = **M3**. Both are sub-components of mn9r — close them when their milestone lands.
- `workstation-zao4` (broker/reconstitutor design) — parent; ensure §5 reconstitution still holds under the hardened lease.
- Dependency note: bead shows mn9r `DEPENDS ON k6na` (Phase-0 measurement gate). The measurement is effectively DONE (design §0 has the K=1/2/4/8 table; `l1qc` closed). Treat k6na as satisfied; the replace decision is green-lit.

---

## Execution handoff

M1 is executable now (pigeon repo, no deps). M2 and M3 are independently executable (parallelizable). M4–M7 are gated as in the map. Recommended order: **M1 → (M2 ∥ M3) → M4 → M5 → M6 → M7**.
