# Move eternal-machinery CI runners to gamebox, with devbox as failover

Status: approved by owner 2026-10-11; adversarial reviewer buy-in after two
rounds (label-flip failover, 2 runners on gamebox, separate PAT, flag-file
pause).

## Motivation

1. **Protect devbox.** CI jobs (two runner containers plus uncapped host
   nix-daemon builds) compete with the opencode serve pool and agents on devbox.
   Running them on gamebox in the common case removes that contention. (Whether
   em-ci contributed to the 2026-10-11 devbox meltdown is NOT established; this
   design does not depend on it.)
2. **Use owned, idle hardware.** gamebox is owned and mostly idle.

## Hosts

| | devbox | gamebox |
|---|---|---|
| Arch | aarch64 | x86_64 |
| CPU / RAM | 16 vCPU / 30 GB | i7-7700K 4C/8T / 16 GiB (+16 GiB swap) |
| Disk | root + 30 GB Hetzner Volume for containers | 512 GB NVMe, plain ext4, no LUKS |
| Network | datacenter, always on | office guest Wi-Fi or home Ethernet; Tailscale; moves |
| Other duty | opencode serve pool, agents | Sunshine game streaming (primary) |
| Secrets | sops-nix | none today |

## Decisions

- **Routing: host-side label reconciliation.** GitHub cannot express "prefer
  runner A, else B"; any idle runner carrying every requested label takes a job,
  and the match is evaluated at assignment time. So:
  - jobs request `["self-hosted","em-ci"]` (no arch label);
  - gamebox runners always carry `em-ci`;
  - devbox runner containers **stay running** (idle long-poll listeners), and a
    devbox timer removes the `em-ci` label from them while gamebox is online and
    adds it back while gamebox is offline.

  Removing a label is race-free: an in-flight job finishes, no new job is
  assigned. No container restarts means no workDir wipe (no cold job per
  failover) and Wi-Fi flapping costs nothing.

  Rejected: starting/stopping devbox containers (stop races assignment, every
  cycle wipes workDir, flapping churns); workflow-side routing (decides at queue
  time, strands jobs if gamebox drops after routing, needs a new repo secret); a
  shared always-on label (does not move load off devbox).
- **Sizing on gamebox:** two runners at 3 CPU / 5 GiB each. Keeps today's
  parallelism (ci.yml fans a PR into up to six heavy jobs; one runner would
  roughly double a cold full run). Host nix-daemon capped at `MemoryMax=3G`.
- **Fallback when gamebox is away:** devbox (not hosted).
- **Gaming contention:** gamebox runners are paused while a Sunshine stream is
  active. In-flight jobs are cancelled ("runner received a shutdown signal");
  **nobody reruns them automatically** — the owner or an agent reruns. Graceful
  drain rejected: it would delay the game indefinitely.
- **Credentials:** gamebox gets its **own** fine-grained PAT (eternal-machinery
  only, Administration RW), so it can be revoked independently. Accepted risk:
  it sits on an unencrypted disk in a physical box at an office.
- **Arch:** x86_64 becomes the common CI arch, aarch64 the fallback. This
  **reverses** the PR-2 rationale (`eternal-machinery
  docs/plans/2026-10-07-ci-self-hosted-plan.md`: "CI runs on ARM, which matches
  devbox, where the live stack runs"). NIFs, sidecar C++ and Chromium will
  usually be tested on an arch production does not run. Accepted by owner.

## Components

### 1. Shared module `modules/em-ci-runners.nix`

Refactored from `hosts/devbox/em-ci.nix`. Options:

- `runners` — attrset container-name → `{ n, hostAddress, localAddress }`.
  Container names stay `em-ci-1`, `em-ci-2` on both hosts: the nixos-containers
  module caps names at 11 chars (`ve-<name>`), and the egress fence matches
  `ve-em-ci-+`.
- `namePrefix` — GitHub runner name prefix: `devbox` / `gamebox`
  (→ `devbox-em-ci-1`, `gamebox-em-ci-2`).
- `cpus`, `memoryMax` — per-container `CPUQuota`, `MemoryMax`, `EM_CI_CPUS`.
- `stateDevice` — optional block device mounted at `/var/lib/nixos-containers`.
- `nameservers` — container resolvers (default `1.1.1.1 9.9.9.9 1.0.0.1`).
- `patSecret` — sops secret name for the registration PAT.
- `watchdogMinFreeGiB` — root free-space guard.

Carried over unchanged: egress fence, nix-ld, `ProtectHome=tmpfs`, syscall
filter, `SYSTEMD_NSPAWN_TMPFS_TMP=0`, disk watchdog, PAT bind mount and
`restartUnits`, `autoStart = true`.

NAT: set `networking.nat.externalInterface = null`. The NixOS NAT module then
masquerades on every out-interface (it emits `-o` only when non-null), which
covers gamebox's Ethernet-or-Wi-Fi egress. No custom rule.

### 2. gamebox

- Runners `gamebox-em-ci-1`, `gamebox-em-ci-2`, 3 CPU / 5 GiB each.
- Container state on the root NVMe; watchdog stops both below 10 GiB free.
- Host nix-daemon: `MemoryMax=3G`, CPU capped; `max-jobs = 2`, `cores = 4`.
  Builds requested from a container run in the daemon's cgroup, outside the
  container caps.
- Flake: add `sops-nix.nixosModules.sops` and `devenvPkg` to gamebox. sops
  decrypts with the host SSH key (`sops.age.sshKeyPaths`); new
  `secrets/gamebox.yaml`, encrypted on devbox (where plaintext lives) to the
  age recipient derived from gamebox's host key.
- Built on gamebox itself (devbox cannot build x86_64).

### 3. devbox

- Same module, existing 30 GB Volume, two runners at 4 CPU / 6 GiB (unchanged),
  containers always running.
- New system timer `em-ci-failover` (1-min tick, idempotent reconciler) — see
  below. Has its own Telegram send (LoadCredential, same bot/chat as
  em-ci-monitor); there is no shared event path to reuse.

### 4. Streaming pause (gamebox)

The Sunshine hook never touches the container units directly:

- Pause is a flag file, `/run/em-ci/paused`, and the container units carry
  `unitConfig.ConditionPathExists = "!/run/em-ci/paused"`. A start attempt
  while paused (rebuild with a changed container config, sops `restartUnits`,
  the container's own `Restart=on-failure`, an admin) is a skipped condition:
  inactive, not failed, no restart loop.
- `em-ci-pause.service`: `Type=exec`, `ExecStart=sleep infinity`,
  `RuntimeMaxSec=8h` (stale-pause ceiling),
  `ExecStartPre=touch /run/em-ci/paused`,
  `ExecStartPost=systemctl --no-block stop container@em-ci-{1,2}`,
  `ExecStopPost=-` (dash: tolerated during shutdown) `rm -f /run/em-ci/paused`
  then `systemctl --no-block start` both containers **unless**
  `em-ci-disk-watchdog` is in failed state. `ExecStopPost` runs on every stop
  path, including `RuntimeMaxSec` expiry.
- **No `Conflicts=`.** It is bidirectional: any container start would stop the
  pause unit and end the pause mid-stream.
- Sunshine `global_prep_cmd`: `do` = `/run/current-system/sw/bin/systemctl
  --no-block start em-ci-pause.service`; `undo` = same with `stop`. Absolute
  path (Sunshine's user unit sets `PATH = mkForce null`); `--no-block` so the
  game launch is not held for a container shutdown (up to ~90 s), and so a
  non-zero exit cannot abort the launch for a slow stop.
- polkit: user `gamer` may `start`/`stop` exactly `em-ci-pause.service`; no
  other unit.
- `em-ci-reconcile` timer on gamebox (5 min): pause active → containers stopped;
  pause inactive and watchdog not failed → containers running. Covers `undo`
  never running (Sunshine crash, Moonlight disconnect leaving an app running).

### 5. eternal-machinery `ci.yml`

- `selfhosted='["self-hosted","em-ci"]'`.
- `HEAVY_RUNNER` validation is an exact string match (`ci.yml:233-239`) and the
  repo variable currently holds the 3-label value, so the change must accept
  **both** values during transition: a `case` arm maps the old
  `["self-hosted","em-ci","ARM64"]` to the new `$selfhosted`. Sequence: merge →
  flip the variable → remove the old arm in a later PR.

## Failover reconciler (devbox `em-ci-failover`)

Each tick, `GET /repos/johnnymo87/eternal-machinery/actions/runners` with
devbox's PAT, then:

- `gamebox online` := any runner named `gamebox-*` has `status == online`.
- Desired devbox label state: `em-ci` **absent** if gamebox has been online for
  the last 3 ticks; **present** if gamebox has been offline for the last 3
  ticks; otherwise unchanged (hysteresis lives in the unit's StateDirectory).
- Initial desired state (empty StateDirectory): `present` — the safe side —
  until 3 online ticks.
- Compare desired state against each devbox runner's labels in the GET payload
  every tick, and call the API **only on drift** (`POST .../runners/{id}/labels`
  / `DELETE .../runners/{id}/labels/em-ci`). Checking every tick, not only on
  transitions, is required because a re-registration (config change, PAT
  rotation) resets labels to the configured set, which includes `em-ci`.
  Calling only on drift avoids 404s from deleting an absent label feeding the
  error counter.
- gamebox offline for > 6 h → Telegram alert (a pause cannot last that long,
  `RuntimeMaxSec=8h`; otherwise a dead gamebox would leave devbox carrying CI
  silently forever).
- API error/timeout → no change (fail-static). 10 consecutive errors → Telegram.
- Each desired-state transition → Telegram notice.

Known behaviour, stated rather than solved:
- After a hard network cut GitHub keeps a runner `online` for an unmeasured
  window. Jobs queued meanwhile are delayed, not lost. A job running when Wi-Fi
  drops is failed by GitHub after ~10 min. Worst-case failover delay ≈
  offline-flip + 3 ticks. Measure at rollout step 4 and tune.
- Streams shorter than 3 ticks: jobs queue briefly, no failover.
- gamebox returns mid-devbox-job: the label is removed, the job finishes.
- Office ↔ home network change: in-flight downloads may fail; accepted.
- **gamebox online but every job fails fast** (disk floor, nix-daemon down):
  not handled here. The reconciler is the lever for it later (strip
  gamebox's label on N consecutive setup failures). Follow-up bead.

## Monitoring

em-ci-monitor (devbox) keeps its devbox checks unchanged — containers stay
running, so "devbox runners online" and "containers active" remain valid. It
gains: gamebox runner names (offline is informational, not an alert, since
pausing is normal) and an alert if `em-ci-failover` is failed or has not run for
5 min.

Out of scope (separate bead): healthchecks stays green while devbox is
alive-but-starved, because em-ci-monitor runs outside the starved user slice.

## Rollout

Each step reversible; repo variable `FORCE_HOSTED=true` remains the escape hatch.

1. Module refactor applied to devbox only; no behaviour change.
2. eternal-machinery ci.yml: accept both `HEAVY_RUNNER` values, request
   `["self-hosted","em-ci"]`. Merge, then flip the variable. No-op while only
   devbox runners exist.
3. gamebox: sops-nix, own PAT, two runners. From inside a container on the
   office network: `dig @1.1.1.1 github.com` must answer (guest networks may
   block outbound :53; if so, add a host-side forwarder on `hostAddress` plus a
   fence exception for port 53 to that one address before the LOCAL drop).
   Both hosts online; verify a full CI run passes on x86_64.
4. devbox: `em-ci-failover` reconciler + monitor changes. Measure offline-flip
   latency by cutting gamebox's network.
5. Sunshine pause unit, polkit rule, gamebox reconciler. Test the polkit-denied
   path (a failing `do` must not block gaming).
6. Later PR: remove the old `HEAVY_RUNNER` arm from ci.yml.

## Testing

- `nix flake check` evaluates both hosts (gamebox eval-only in CI).
- Failover reconciler: shell test with stubbed API responses — offline×3 → add
  label; online×3 → remove; mixed → unchanged; label drift → re-asserted;
  no drift → no API write; API error → no-op; 10 errors → alert; empty state →
  present; gamebox offline > 6 h → alert.
- Per-host post-deploy checks from the existing `em-ci.nix` header: runners
  online, egress fence drops a private address, PAT unreadable by `em-ci`.
