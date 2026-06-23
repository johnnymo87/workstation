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

### 3. Fix C — decouple serve heartbeat from the agent event loop (opencode-patched)
The deepest fix. Today the heartbeat fiber (`serve.ts`, `Schedule.spaced("5
seconds")`) shares the single event loop with the agent loop, so a busy turn
starves it — the root trigger. Move the heartbeat write to a **worker thread**
(or separate timer immune to main-loop starvation) so liveness reflects process
health, not event-loop availability. Requires editing
`serve-lease.patch`, rebuilding via `opencode-patched` `build-release.yml`, and
bumping the pin in `users/dev/home.base.nix`. See the opencode-patched cutover
runbook. Pairs with raising `staleServeMs` safely once heartbeats are reliable.

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
