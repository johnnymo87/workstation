---
name: monitoring-serve-pool
description: Use when an opencode-serve pool member is unresponsive/wedged, when the serve-canary restarted a serve overnight, or when tuning the serve units' memory limits. Covers the "alive but frozen" failure mode, the canary timer, and where its forensics dumps land.
---

# Monitoring the OpenCode Serve Pool

Devbox runs K=2 pooled serves (`opencode-serve@4096/4097`, user units; see
`users/dev/serve-pool.nix`). This skill covers how we detect and recover a
**wedged** serve, and why the memory limits are shaped the way they are.

## The failure mode: "alive but frozen"

A serve can stall its main JS event loop for minutes while every existing
health signal stays green:

- `/global/health` times out and even **SIGTERM is ignored** — both need the
  JS loop (the SIGTERM handler is a `process.once` in serve-lease.patch).
- pigeon still sees a healthy serve: serve-lease **Fix C** moved the
  heartbeat to a worker thread, so it attests "worker can write sqlite",
  not "serve can serve".
- `Restart=always` never fires: with a `MemoryHigh` soft ceiling the kernel
  clamps usage by throttling/direct-reclaim in the allocating thread —
  the serve gets *slower*, never *dead*, so MemoryMax/OOM never trigger.

Observed for real on 2026-07-03 (`:4096`, SIGTERM 90s timeout → SIGKILL at
the nightly reset). Full post-mortem:
`docs/investigations/2026-07-03-serve-4096-wedge.md` (bead workstation-94g8,
bd memory `devbox-serve-4096-wedge-2026-07-03`).

## Detection + recovery: the canary timer

`opencode-serve-canary.timer` (user unit, minutely, defined in
`users/dev/home.devbox.nix`) probes each pool member's
`GET /global/health` with a 3s timeout:

- **7 consecutive failures** (≈7-8 min wedged, which outlasts the post-boot catalog/credential burn to prevent thrashing) → dump forensics, then
  `systemctl --user restart opencode-serve@<port>.service` (that one
  instance only).
- Skips units that aren't `active` (intentional stops, crash-loop backoff)
  and skips the whole run while `reset-workspace` holds
  `/tmp/reset-workspace.lock`.
- State + forensics live in `/tmp/opencode-serve-canary/`:
  - `<port>.fails` — consecutive-failure counter.
  - `wedge-<ts>-<port>/` — pre-restart dump: `/proc/<pid>/{status,wchan,syscall}`,
    per-thread `wchan` (`threads`), `wchan-series` (main-thread wait channel,
    20 samples at 100 ms — see below), `cpu-io-split`, `eu-stack.{1,2,3}`, and
    cgroup `memory.{current,peak,max,stat,pressure}`, `cpu.pressure`,
    `cgroup.procs`. Captured BEFORE the restart because a SIGKILL destroys all
    evidence (the 2026-07-03 wedge left none).

Inspect activity:

```bash
systemctl --user list-timers opencode-serve-canary
journalctl --user -u opencode-serve-canary.service --since -1d
ls /tmp/opencode-serve-canary/
```

A canary restart in the journal looks like:
`RESTARTING wedged opencode-serve@4096.service (pid=...); forensics in ...`.
If you find one, attach the dump to a bead before it's lost, and read it like
this.

### Read `wchan-series`, not the one-shot `wchan`

**A single wait-channel reading is not evidence.** Sampling a *healthy* serve by
hand returns `0` (running) or `do_epoll_wait` depending purely on when you look
— four of five healthy samples are indistinguishable from a wedged serve caught
mid-sleep. The one-shot `wchan` and `threads` files are kept for context only.

What discriminates is whether the main thread **ever returns to epoll** across
the window:

| `wchan-series` (20 samples @ 100 ms) | reading |
|---|---|
| `do_epoll_wait` recurring | event loop is FREE. An HTTP stall here is request serialization, **not** a blocked loop. |
| `hrtimer_nanosleep` solid, never returning to epoll | SQLite busy handler spinning |
| isolated `hrtimer_nanosleep` between `do_epoll_wait` | brief contention, loop recovering — normal |

The second row matters because `bun:sqlite`'s busy-wait runs on the **main JS
thread**: with `busy_timeout=5000`, one contended write freezes the event loop
for up to 5 s. That is not a cousin of the wedge signature above — it is a
mechanism that produces it. Measured: `hrtimer_nanosleep` continuously from
0.2 s to 3.4 s of a 4 s contended write, never once back to epoll.

`/proc/<tid>/syscall` would be richer but yama `ptrace_scope=1` on cloudbox
makes it unreadable; `wchan` is readable. Don't reach for the wrong file.

Note `cpu-io-split` reports `interval=` **measured**, not assumed. It is the
divisor for the utime/stime delta, so treat any hardcoded interval in a derived
CPU number as suspect — a wrong divisor keeps the output plausible while
silently scaling it (this one was ~5% off).

## Whole-pool crash-loop: the registry fences (exit 20 / exit 21)

If **every** serve is restarting on a ~10s cycle (`RestartSec=10`) right after a
deploy, suspect a registry fence before anything else. Confirm by mechanism:

```bash
systemctl status 'opencode-serve@4098' | grep -E 'Active|status=2[01]'
journalctl -u 'opencode-serve@4098' -n 30 --no-pager | grep FATAL
```

- **exit 20** = port fence: the bound port != `OPENCODE_SERVE_EXPECTED_PORT`.
- **exit 21** = PID fence: `process.pid` != `OPENCODE_SERVE_EXPECTED_PID`. The
  overwhelmingly likely cause is that a wrapper stopped `exec`ing the serve, so the
  serve became a *child* of the wrapper shell and no longer carries its `$$`.
  `users/dev/test-serve-pid-fence.sh` (run by `nix flake check`) exists to stop that
  reaching a host at all, so seeing this in production means something bypassed CI.

**Recovery does NOT require a new binary**, which is the point of `unset ⇒ unarmed`.
Both fences disarm when their variable is absent, so removing the export from the
wrapper and rebuilding brings the pool back up unfenced (degraded, not down):

```bash
# in the workstation checkout, remove the offending `export OPENCODE_SERVE_EXPECTED_PID=$$`
sudo nixos-rebuild switch --flake ".#$(hostname)"
```

Then fix the wrapper properly and re-arm. Do not "fix" a crash-loop by deleting the
fence permanently — the fence is what prevents a throwaway serve from repointing a
live pool slot and invalidating its session leases (the 2026-07-25 incident, 76
sessions routed to a closed port for hours).

**Relaunching a pool member by hand** must reproduce the wrapper's shape, or it will
trip the fence it is subject to:

```bash
bash -c 'export OPENCODE_SERVE_EXPECTED_PID=$$; exec opencode serve --port 4098 --hostname 127.0.0.1'
```

## Memory limits: why Max-only

The serve units are `MemoryMax=6G` with **no MemoryHigh** (revised
2026-07-03). Rationale: the 4G-high/5G-max split created a 1G-wide
throttle-forever band — exactly the wedge zone above. With Max-only, a
ballooned serve is OOM-killed and `Restart=always` brings it back in ~10s;
sessions persist in the shared `opencode.db` and TUIs reconnect. The
aggregate backstop is `user-1000.slice` `MemoryHigh=20G`
(`hosts/devbox/configuration.nix`, sized for the 30G host) plus earlyoom.

`TimeoutStopSec=15` on the serve units: a frozen loop provably never runs
the SIGTERM handler, so the old default (90s) only stalled the nightly
reset; healthy stops take 1–2s.

## Known gaps / follow-ups

- Cloudbox runs the same architecture (K=4, system units,
  `hosts/cloudbox/configuration.nix`) and has the same wedge trap. Its limits
  are **`MemoryMax=14G`, `MemorySwapMax=1G`, no `MemoryHigh`,
  `TimeoutStopSec=15`** as of 2026-08-02 (this doc previously said
  `MemoryHigh=32G/MemoryMax=40G`, which was the pre-fix band). **Verify limits
  on cgroupfs, not `systemctl show`** — a unit re-realized into a new slice
  without a process restart reports the new values while the kernel has dropped
  the controller entirely. To address this, cloudbox runs the liveness canary as
  SYSTEM units (`systemd.services.opencode-serve-canary` + `.timer` in
  `hosts/cloudbox/configuration.nix`), running as ROOT, with forensics in
  root-owned `/var/lib/opencode-serve-canary/`.
  - On cloudbox, inspect the canary via SYSTEM commands:
    `systemctl list-timers opencode-serve-canary` and
    `journalctl -u opencode-serve-canary.service` (do NOT use `--user`).
  - Note: the inspector wedge-watcher + `BUN_INSPECT` NAMED-JS-stacks forensics
    are NOT ported to cloudbox (deferred; forensic-only, would require adding
    `BUN_INSPECT` to every cloudbox serve). **Before porting it for a MEMORY
    question, read the next bullet** — main-process JS stacks are the wrong
    address space for cloudbox's bursts. For a wedge (CPU/loop) question it is
    still the right instrument.
- Durable fix candidates (beads): systemd watchdog patch (`sd_notify
  WATCHDOG=1` from the main loop → SIGABRT + core on freeze), and a
  dead-man's switch so the worker heartbeat degrades `health_state` when
  the main loop stops bumping a shared timestamp.
- The canary treats symptom, not cause — but **the cause stated here until
  2026-08-03 was wrong**, and it is worth knowing why before repeating it. This
  doc asserted "the heap driver is mega-sessions (7k+ messages) parking serves
  at the ceiling". On cloudbox that is refuted twice over:
  - Mega-sessions/message history **as standing memory** is dead: `assign_total`
    vs memory *r* = −0.18…0.33, and the serve with 191 assignments sat at 0.65 G
    while one with 38 sat at 2.65 G.
  - The burst memory is **not in the opencode process at all**. It is in the
    serve unit's **child processes** — the per-directory LSP and MCP fleet.
    Measured 2026-08-03 on `:4098`: cgroup anon 6.55 G = main process 1.88 G +
    **44 children holding 6.31 G** (16 `tsserver` at 3.05 G, 11 MCP servers).
    Instances are never evicted (`InstanceStore` is an unbounded `Map`, no
    TTL/LRU), so the fleets are never reaped — 9 TypeScript language servers for
    a single repo.

  **The scope trap that hid this**, because it will recur: the step-3 sampler read
  `threads`/`fds`/`rss` from `/proc/MainPID` but `anon`/`swap`/`pagetables` from
  the **cgroup**. Any comparison across those two scopes is meaningless, and it
  produced a confident, wrong headline ("28 GiB allocated without opening a
  thread or fd" — true of the main process only).

  Full analysis: `docs/plans/2026-08-03-cloudbox-serve-memory-spine.md` (S1,
  bead `workstation-vpid`); the never-reaped fleet is `workstation-rdsq.1`.
  Session rotation/compaction remains good hygiene, just not the memory fix.
