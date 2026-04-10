# Ephemeral GCP Workers for Monorepo Development

## Problem

The cloudbox (c4a-standard-4, 4 vCPU / 16 GB) is the primary development machine for a large JVM/Kotlin Bazel monorepo. Each opencode session consumes significant resources (Bazel server + Kotlin workers + language server + opencode process + Docker). Peak concurrency has reached 6-7 simultaneous sessions, trending upward. The machine can't keep up, but it sits idle most of the time, making it wasteful to simply upsize.

## Evidence (from opencode session DB + worktree analysis)

| Metric | Value |
|--------|-------|
| Monorepo size (clone) | 45 GB total, 8.9 GB `.git`, ~37 MB per worktree checkout |
| Active worktrees | 78 on current machine |
| Worktrees touched per day | 2-7 (peak 7) |
| OpenCode sessions per day | 1-3 (early March) -> 11-13 (April) |
| Peak hourly concurrency | 6-7 sessions (April 1, 6, 7) |
| Typical session pattern | Fits and starts: 30-60 min active, 2-4 hours idle, then resume |

## Architecture

```
                    ┌─────────────────────────┐
                    │  cloudbox (always-on)    │
                    │  c4a-standard-2          │
                    │  2 vCPU / 8 GB / 200 GB  │
                    │  ~$65/mo compute         │
                    │                          │
                    │  - pigeon-daemon         │
                    │  - cloudflared           │
                    │  - opencode-serve        │
                    │  - NFS server (history)  │
                    │  - pull-workstation      │
                    └────────────┬─────────────┘
                                 │ NFS mount (opencode history)
                                 │
              ┌──────────────────┼──────────────────┐
              │                  │                   │
    ┌─────────▼──────┐ ┌────────▼───────┐ ┌────────▼───────┐
    │  worker-1      │ │  worker-2      │ │  worker-3      │
    │  c4a-std-8     │ │  c4a-std-8     │ │  c4a-std-8     │
    │  on-demand     │ │  on-demand     │ │  on-demand     │
    │  suspend/resume│ │  suspend/resume│ │  suspend/resume│
    │                │ │                │ │                │
    │  - opencode(s) │ │  - opencode(s) │ │  - opencode(s) │
    │  - bazel       │ │  - bazel       │ │  - bazel       │
    │  - LSP         │ │  - LSP         │ │  - LSP         │
    │  - docker      │ │  - docker      │ │  - docker      │
    │  - pigeon      │ │  - pigeon      │ │  - pigeon      │
    │  - cloudflared │ │  - cloudflared │ │  - cloudflared │
    │  - gclpr       │ │  - gclpr       │ │  - gclpr       │
    └────────────────┘ └────────────────┘ └────────────────┘
         mosh              mosh              mosh
```

## Key Design Decisions

### On-demand + suspend/resume (not Spot)

Spot VMs are cheaper per-hour but a poor fit for the fits-and-starts usage pattern:
- Preemption can happen at any time (no guaranteed window) and kills warm JVMs, tmux sessions, uncommitted changes
- An idle VM is not safer from preemption than a busy one
- The 30-second "best effort" shutdown window is unreliable for state preservation

On-demand + suspend is actually cheaper for this pattern:
- 3h active + 7h suspended/day costs ~$32/mo compute per worker (vs ~$39/mo Spot running the full 10h)
- Suspended state preserves everything: tmux sessions, warm JVMs, uncommitted code, opencode processes
- Resume picks up exactly where you left off

### Workers can run multiple sessions

Each c4a-standard-8 (8 vCPU / 32 GB) can comfortably run 2-3 concurrent opencode sessions in tmux panes, each in its own worktree. This means:
- Peak of 6-7 sessions needs only 3-4 workers, not 7
- Lighter tasks (PR reviews, small fixes) can share a worker with heavier ones
- No hard-coded 1:1 mapping; the user decides how to distribute work

### Centralized opencode history (NFS from cloudbox)

All workers mount an NFS share from cloudbox for opencode history. This creates a single unified stream of session history across all workers, so:
- Spinning up a new worker gives you access to all past sessions
- Destroying a worker doesn't lose history
- The cloudbox is the single source of truth

### One Cloudflare tunnel per worker (pigeon)

Each worker runs its own cloudflared + pigeon-daemon so it's independently reachable via Telegram. Pigeon on each worker connects to the local opencode sessions, enabling remote interaction.

### Shared Bazel remote cache (GCS)

All workers share a GCS-backed Bazel remote cache. A build on worker-1 benefits from artifacts produced by worker-2. This also means fresh clones don't start with cold caches.

### Clipboard (gclpr)

Each worker has the gclpr private key (via sops-nix). SSH config uses `RemoteForward 2850` so clipboard works over mosh just like it does on cloudbox today.

### Static external IPs

Each worker gets a reserved static IP so mosh reconnects work across suspend/resume cycles. GCP doesn't release static IPs during suspend.

## CLI Tool: `worker`

```
worker up <name>         Create a new worker, or resume a suspended one
worker down <name>       Suspend a worker (preserves all state, stops compute billing)
worker destroy <name>    Fully delete a worker and its disks, release IP
worker list              Show workers with status, IP, uptime, session count
worker ssh <name>        mosh into a worker (auto-resolves IP from gcloud)
```

Implemented as a bash script using `gcloud compute` commands.

### Lifecycle

**First creation (`worker up foo`, no existing VM):**
1. Reserve static external IP `worker-foo-ip`
2. Create c4a-standard-8 VM `worker-foo` from baked NixOS image, 50 GB hyperdisk-balanced
3. Startup script: clone monorepo, mount NFS history from cloudbox, start pigeon + cloudflared
4. Firewall: TCP 22, UDP 60000-61000 (mosh)

**Suspend (`worker down foo`):**
1. `gcloud compute instances suspend worker-foo`
2. Compute billing stops. Disk + suspended memory state + static IP continue billing.

**Resume (`worker up foo`, existing suspended VM):**
1. `gcloud compute instances resume worker-foo`
2. VM resumes with full memory state. Tmux, JVMs, opencode processes all intact.
3. mosh reconnects automatically (same IP).

**Destroy (`worker destroy foo`):**
1. Delete VM + boot disk
2. Release static IP
3. OpenCode history persists on cloudbox (NFS)

## Baked NixOS Worker Image

A custom GCE image containing:
- NixOS base system (aarch64-linux)
- Full toolchain: Bazel/bazelisk, JDK 21, Kotlin, Node.js, Bun, Docker
- Cloud CLIs: gcloud, az, aws, kubectl
- Dev tools: neovim, tmux, opencode, mosh-server, devenv, protobuf
- pigeon-daemon + cloudflared (per-worker tunnel token injected at boot)
- gclpr client (key from sops-nix)
- NFS client config (mount cloudbox history share)
- Bazel config pointing at GCS remote cache

The image is rebuilt when the toolchain changes. Stored as a GCE custom image.

## Cost Estimate

### Typical usage: 3-4 workers, 3h active + 7h suspended per day

| Component | Monthly |
|-----------|---------|
| Cloudbox c4a-standard-2 (always-on) | ~$65 |
| Cloudbox 200 GB hyperdisk | ~$16 |
| 4 workers compute (3h active/day) | ~$129 |
| 4 x 50 GB hyperdisk (kept all month) | ~$16 |
| 4 suspended memory states (7h/day, 32 GB each) | ~$6 |
| 4 static IPs | ~$12 |
| GCS (image + bazel cache) | ~$5 |
| **Total** | **~$249** |

### Peak usage: 6-8 workers over a week (4 active, 4 suspended)

| Component | Monthly |
|-----------|---------|
| Cloudbox | ~$81 |
| 8 workers compute (4 active at 3h/day, 4 dormant) | ~$129 |
| 8 x 50 GB hyperdisk | ~$32 |
| Suspended state + IPs | ~$30 |
| GCS | ~$5 |
| **Total** | **~$277** |

### Current setup for comparison

| Component | Monthly |
|-----------|---------|
| Cloudbox c4a-standard-4 (always-on) | ~$131 |
| 200 GB hyperdisk | ~$16 |
| **Total** | **~$147** |

The ephemeral architecture costs ~$100-130/mo more, but provides 6-8x the peak compute capacity with full isolation between tasks.

## Memory leaks and zombie sessions

OpenCode processes leak memory over time (V8 heap grows from ~350 MB to 8+ GB) and can ignore SIGTERM, requiring SIGKILL. On the current always-on cloudbox, stale `/launch`ed sessions and subagents accumulate -- 16 zombie processes eating 10.5 GB RSS was observed in practice.

**How the worker architecture helps:**
- **Suspend stops the bleed.** A suspended VM's memory is frozen -- no leak growth during idle time.
- **Destroy is a hard reset.** No zombie accumulation across days/weeks.
- **Isolation.** A bloated worker can't starve other workers. Each has its own 32 GB.
- **More headroom.** 32 GB per worker vs 16 GB shared today.

**What doesn't change:**
- Within an active worker session, opencode still leaks. Multiple sessions on one worker will still compete for RAM.
- opencode-serve on cloudbox still leaks (mitigated by nightly restart).

The `worker destroy` lifecycle is the primary mitigation. No automated session reaper is planned; manual management via `worker list` (which should show memory usage) and `worker destroy` is sufficient.

## Scaling behavior

The suspend/resume model works well up to ~12 workers. Beyond that, the operational overhead (tunnel tokens, static IPs, NFS connections, disk costs for dormant workers) starts to add friction. If usage grows beyond 12 concurrent workers, revisit:
- Routing all workers through cloudbox's tunnel instead of individual tunnels
- Dynamic IPs with DNS-based lookup instead of static reservations
- Ephemeral create/destroy with faster boot instead of suspend/resume for short-lived tasks

## Phasing

1. Bake NixOS worker image + `worker up/down/destroy/list/ssh` CLI
2. Pigeon + cloudflared on workers (one tunnel per worker)
3. NFS on cloudbox for centralized opencode history
4. GCS Bazel remote cache
5. gclpr clipboard on workers
6. Downsize cloudbox to c4a-standard-2
