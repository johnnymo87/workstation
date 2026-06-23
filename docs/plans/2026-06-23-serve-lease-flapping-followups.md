# Serve-lease "session lease lost mid-run" — fix + follow-ups

**Date:** 2026-06-23
**Status:** Fix A+B landed & deployed to **devbox only**. Follow-ups below.

## The bug (root cause, for context)

`die("session lease lost mid-run for <sid>")` was **false-positive dead-serve
detection** in the mn9r multi-serve pool. `opencode serve` is single-threaded;
a CPU-heavy turn (or GC/swap stall) blocks its event loop and starves the 5s
heartbeat fiber. After `PIGEON_SERVE_STALE_MS` (default 15s) of heartbeat
silence, pigeon's `ServeHealthPoller.sweepStale` (serveLiveness=`self` path)
declared the *live, busy* serve dead and `IngressRouter.reassignFromDeadServe`
migrated **every** session off it — bumping `owner_generation` + changing
`desired_serve_id`. The serve still executing the turn then failed its next
`renewCAS` → die. Evidence on devbox: 32/33 assignments at gen>1 (up to 48),
both serves flapping; serve-0 had 6h continuous uptime yet its session was
migrated away.

Key files:
- pigeon: `packages/daemon/src/routing/router.ts` (`reassignFromDeadServe`,
  `placeSession`), `serve-health-poller.ts`, `route-repo.ts`, `config.ts`.
- serve patch: `~/projects/opencode-patched/patches/serve-lease.patch`
  (`withSessionLease` in `prompt.ts`; hardcoded `TTL=30_000`, renew every 10s;
  serve heartbeat fiber in `cli/cmd/serve.ts`).
- routing DB: `/home/dev/projects/pigeon/packages/daemon/data/pigeon-daemon.db`.

## What landed (DONE)

- **Fix A (pigeon, origin/main `08b4c95`):** `reassignFromDeadServe` skips any
  session whose lease on the dead serve is still valid (`lease.serveId===serveId
  && lease.leaseExpiresAt > now`). Only the owning serve can renew its own lease
  (full-token-fenced `renewCAS`), so a live lease proves the serve is alive. A
  genuinely dead serve stops renewing → lease expires → migrates then. Tests:
  router.test.ts 7b/7c + reworked the old 7 and the poller integration test.
  Full daemon suite 516 pass.
- **Fix B (workstation, origin/main `c5b257a`):** `PIGEON_SERVE_STALE_MS=20000`
  on devbox/cloudbox/darwin pigeon-daemon env. Ceiling = `serveLeaseTtl(30s) −
  serveRenewInterval(10s) = 20s` (above it a dead serve lingers in `listHealthy`
  past lease expiry and can be re-picked).
- **Deployed: devbox only.** `nixos-rebuild switch` done; pigeon-daemon PID
  2899087, env live, validated (a real serve-1 false-death event occurred with
  zero gen inflation and zero lease-lost stops).
- **Fix D (opencode-patched, main `9c59d8b`, bead workstation-oqa1):** DONE in
  source + patch, TDD'd RED→GREEN, pushed. NOT yet built/deployed (still on
  release `v1.17.7-patched.3`). `withSessionLease` renewal fiber now re-acquires
  (rotating the lease token via a `Ref`) on a failed renew when the assignment
  still points at this serve; only a genuine reassignment to a *different* serve
  dies "session lease lost mid-run". Release finalizer releases the currently-held
  token. Reworked the old "lease lost mid-run" test → "re-acquires and continues
  when generation bumps but assignment still points to us"; added "fail-closed when
  reassigned to a different serve mid-run".

## Local TDD environment for opencode-patched (HARD-WON — reuse this)

The patched-build CI (`build-release.yml`) only runs `bun run script/build.ts
--all`; it NEVER runs the lease tests. To TDD patch changes locally:

- **bun version matters.** The Nix bun (`1.3.3`, `~/.nix-profile/bin/bun`, read-only
  store) lacks `node:sqlite` and CANNOT EVEN LOAD `routing-lease.ts` (the dead
  non-bun branch's `await import("node:sqlite")` fails resolution). Use the
  standalone **`/tmp/opencode/bun/bin/bun` (1.3.14)** installed via
  `BUN_INSTALL=/tmp/opencode/bun curl -fsSL https://bun.sh/install | bash`.
- **Worktree:** `/tmp/opencode/oqa1-src` = `git worktree add --detach <path>
  v1.17.7` from `/home/dev/projects/opencode` (which has the v1.17.7 tag despite
  being on an old `dev` branch — do NOT disturb that checkout; it has a foreign
  untracked `why-agent-swarms.md`). Apply patches via
  `/home/dev/projects/opencode-patched/patches/apply.sh <worktree>`, then
  `bun install` (uses `/tmp/opencode/bun/bin/bun`, ~6s, 4610 pkgs).
  NOTE: `/tmp` is ephemeral — if it's gone post-reboot, recreate from scratch.
- **Run tests:** `cd /tmp/opencode/oqa1-src/packages/opencode && /tmp/opencode/bun/bin/bun test test/session/prompt.test.ts -t "<name substring>"`. Lease tests have 10–14s waits (renewal interval is 10s).
- **Typecheck:** `bun run typecheck` (tsgo). Pre-existing error `session.ts(944)`
  TS2719 (from `createnext-readback.patch`) is UNRELATED — ignore it. Build uses
  bun transpile (strips types), so it doesn't block.
- **Pre-existing baseline flake:** `"leased run: guard terminates run loop if
  lease deadline is exceeded"` fails in this env (orthogonal `checkLeaseDeadline`
  loop-top timing under the mock). NOT a regression from any patch edit.

## Regenerating a single patch (serve-lease.patch) cleanly

serve-lease.patch is a diff vs the state AFTER `createnext-readback`. Only
serve-lease touches `prompt.ts`/`prompt.test.ts` (verify for any new file you
edit, e.g. `serve.ts`, with `grep -l <file> patches/*.patch`). Procedure used for
Fix D:
1. Fresh worktree at v1.17.7 (`/tmp/opencode/oqa1-regen`).
2. `git apply` patches in order THROUGH `createnext-readback`; `git add -A &&
   git commit` a base.
3. `git apply` the ORIGINAL `serve-lease.patch`.
4. `cp` your edited files (from oqa1-src) over the worktree's copies.
5. `git add -A && git diff --cached > serve-lease.new.patch`.
6. **Verify:** fresh worktree + temp patches dir with the new patch + run
   `apply.sh` (whole stack must apply) + `diff -q` resulting files vs oqa1-src
   (must be byte-identical). Index-hash abbreviation differs 9- vs 10-char —
   cosmetic, `git apply` ignores it.

## Build + cutover (Fix C+D together, per user decision)

1. `gh workflow run build-release.yml --field version=1.17.7 --field revision=4`
   (current live = `v1.17.7-patched.3` → produces `v1.17.7-patched.4`). Watch the
   run; it builds linux+macos and cuts a release.
2. Bump the opencode-patched pin in `users/dev/home.base.nix` (~line 70-92, the
   per-platform URLs + sha256 hashes). NOTE: `update-opencode-patched.yml` auto-PRs
   this every 8h — either wait for/merge that PR or compute hashes manually.
3. `nix run home-manager -- switch --flake .#dev` on devbox; cloudbox/darwin pick
   it up on their next switch. Restart serves (serve-pool) so the new binary runs.

NOTE: pigeon-daemon runs the **live checkout** via `tsx` (not watch). Fix A
needs a `git pull` of the checkout to origin/main + a daemon restart to activate
on a host. The pigeon checkout is **shared** and had another session's
`swarm-send-tool` WIP; my commit was pushed via an isolated worktree (local
`main` is intentionally `ahead 1, behind 3` and reconciles on next rebase).

## Follow-ups

### 1. Deploy A+B to cloudbox (bead) — HIGHEST VALUE
cloudbox is K=4 (worse flapping surface). On cloudbox:
```
cd ~/projects/pigeon && git stash list   # check for foreign WIP first
git pull --ff-only origin main           # or rebase if local commits exist
cd ~/projects/workstation && git pull
sudo nixos-rebuild switch --flake .#cloudbox   # applies PIGEON_SERVE_STALE_MS, restarts pigeon-daemon (picks up Fix A)
```
Verify: `systemctl show pigeon-daemon -p Environment | grep STALE`; daemon
`NRestarts=0`; monitor `pigeon-daemon.db` max(owner_generation) is stable and no
`lease lost` stops. (pigeon-daemon is a **system** unit on cloudbox.)

### 2. Deploy A+B to darwin/macbook (bead) — must run ON the Mac
`git pull` both repos; `sudo darwin-rebuild switch --flake .#Y0FMQX93RR-2`;
restart the pigeon launchd agent. pigeon-daemon is a **launchd** agent there.

### 3. Fix C — decouple serve heartbeat from the agent event loop (opencode-patched) — NEXT
The deepest fix; user wants it done before the cutover. Today the heartbeat
fiber lives in `packages/opencode/src/cli/cmd/serve.ts` (the
`Flag.OPENCODE_ROUTING_DB && Flag.OPENCODE_SERVE_ID` block; in serve-lease.patch
~patch-lines 1157–1195): `lease.heartbeat(serveId)` repeated on
`Effect.repeat(Schedule.spaced("5 seconds"))` + `Effect.forkScoped`, sharing the
single JS event loop with the agent run loop. A CPU-heavy/synchronous turn starves
it → pigeon sees stale `serve_instance.heartbeat_at` → false dead-serve. `heartbeat`
just does `UPDATE serve_instance SET heartbeat_at=@now, health_state='healthy'
WHERE serve_id=@serveId` against the routing DB.

Design: run the heartbeat on a **`node:worker_threads` Worker** so it ticks
independent of the main loop. The worker opens its OWN `bun:sqlite` handle to
`OPENCODE_ROUTING_DB` (path via env/workerData), runs the UPDATE every 5s, and
exits on a stop message / `markDead` stays on the main thread's `addFinalizer`.
Keep the whole thing gated on the routing flags (unset = no-op, byte-identical to
today). Worker file likely a new `packages/opencode/src/serve/heartbeat-worker.ts`
(or inline via `new Worker(new URL(...))`). Watch: bun Worker + bun:sqlite in a
worker, graceful termination on SIGTERM/scope-close, and that `script/build.ts`
bundles the worker entry.

TDD: extend `packages/opencode/test/cli/serve/serve-process.test.ts` (live
subprocess test already seeds a routing DB and asserts registration/draining).
Add a test that spins the serve, then asserts `serve_instance.heartbeat_at`
keeps advancing across a window even though nothing drives the main loop (and
ideally while a synthetic busy turn runs). serve.ts is touched by serve-lease.patch
(confirm `grep -l "cmd/serve.ts" patches/*.patch` → only serve-lease) so regenerate
serve-lease.patch with the same procedure above. Pairs with later raising
`staleServeMs` once heartbeats are starvation-proof.

### 4. Fix D — re-acquire-before-die in `withSessionLease` (opencode-patched)
Soften the kill: on a failed `renew` (leaseLost), attempt a fresh `acquire`
before `Effect.die`. If the session is still assigned to this serve (e.g. the
generation bumped but rendezvous re-picked the same serve), re-acquire and
continue; only die if another instance demonstrably holds the lease
(`acq.assignmentExists` for a different owner). Reduces false kills from benign
generation churn. Edit `serve-lease.patch` `withSessionLease` (the
`Deferred.succeed(leaseLost)` branch). Same build/pin cycle as Fix C.

### 5. Routing DB cruft (optional, P3)
`pigeon-daemon.db` has ~32 dormant assignments at high generations (up to 48) —
cosmetic; `IngressRouter.sweep` ages them out. Only clean if it bothers you;
do NOT delete rows for live sessions.

## Verification protocol (any host)
After deploy, watch `pigeon-daemon.db`: `max(owner_generation)` and
`sum(owner_generation)` should be flat; `serve_instance` recovers to healthy
after transient staleness; `journalctl -u pigeon-daemon | grep "lease lost"`
stays empty. A serve being briefly flagged unhealthy is now harmless (live-lease
sessions are not evicted).
