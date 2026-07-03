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

- **3 consecutive failures** (≈3 min wedged) → dump forensics, then
  `systemctl --user restart opencode-serve@<port>.service` (that one
  instance only).
- Skips units that aren't `active` (intentional stops, crash-loop backoff)
  and skips the whole run while `reset-workspace` holds
  `/tmp/reset-workspace.lock`.
- State + forensics live in `/tmp/opencode-serve-canary/`:
  - `<port>.fails` — consecutive-failure counter.
  - `wedge-<ts>-<port>/` — pre-restart dump: `/proc/<pid>/{status,wchan,syscall}`,
    per-thread `wchan` (`threads`), and cgroup
    `memory.{current,peak,max,stat,pressure}`, `cpu.pressure`, `cgroup.procs`.
    Captured BEFORE the restart because a SIGKILL destroys all evidence
    (the 2026-07-03 wedge left none).

Inspect activity:

```bash
systemctl --user list-timers opencode-serve-canary
journalctl --user -u opencode-serve-canary.service --since -1d
ls /tmp/opencode-serve-canary/
```

A canary restart in the journal looks like:
`RESTARTING wedged opencode-serve@4096.service (pid=...); forensics in ...`.
If you find one, read the dump (especially `threads` wait-channels and
`memory.pressure`) and attach it to a bead before it's lost to `/tmp`.

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
  `hosts/cloudbox/configuration.nix`, MemoryHigh=32G/MemoryMax=40G) and has
  the same wedge trap — parity tracked in beads.
- Durable fix candidates (beads): systemd watchdog patch (`sd_notify
  WATCHDOG=1` from the main loop → SIGABRT + core on freeze), and a
  dead-man's switch so the worker heartbeat degrades `health_state` when
  the main loop stops bumping a shared timestamp.
- The canary treats symptom, not cause: the heap driver is mega-sessions
  (7k+ messages) parking serves at the ceiling. Session rotation/compaction
  is the upstream hygiene fix.
