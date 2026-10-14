# Daytime reaping of idle build caches under disk pressure

Beads: `workstation-a8tr` (cargo `target/`), `workstation-qpb7` (Bazel output bases).
Host: cloudbox only. Everything lives in `users/dev/disk-cleanup.nix`, inside the existing
`lib.mkIf isCloudbox { ... }` block, next to `bazel-reap`.

## Why

On 2026-10-13 cloudbox's root disk (590G) reached 100%. It was freed by hand:

- 20 Bazel output bases with no live server that were either `lgtm-pr-*` or idle more than 3h (67G);
- 9 cargo `target/` dirs under `~/projects/{goose-patched*,honk*}` not built in 3h (~97G).

Nothing automatic touches cargo `target/` dirs. `bazel-reap` only reaps bases whose
workspace is GONE, so it cannot touch either population above. The nightly 03:00 cleanup
does reap every base with a dead server, but it runs only once a day, and the disk fills
within the working day.

## Decision: two reapers sharing one pressure rule

There are two separate units, because the deletion mechanics differ:

- **Bazel** needs `chmod -R u+w` and a marker-driven classification.
- **cargo** needs discovery under `~/projects` plus a /proc probe.

Folding cargo into `bazel-reap` would blur which guard protects which tree. Both use the
same pressure definition: the root filesystem's used percent (as `df` reports it) is at or
above `PRESSURE_PCT = 80`. That is 5 points below disk-watch's 85% alarm, so the reapers act
before a human is paged.

### Task 1: `cargo-reap` (new; `~/.local/bin/cargo-reap`, user service and timer)

Python, embedded the same way `venvSweepPy` is embedded. It reuses `pathsInUsePy`.

- **Discovery.** Under each root in `CARGO_REAP_ROOTS` (default `$HOME/projects`,
  space-separated), walk directories to depth 4. Never descend into `.git`, `node_modules`,
  or any `target`. A candidate is a directory named `target` that:
  - is not a symlink;
  - is owned by our uid;
  - contains `CACHEDIR.TAG` whose text includes `created by cargo`.

  Expected shapes are `~/projects/X/target` and `~/projects/X/.worktrees/Y/target`.
- **Idle age.** Seconds since the newest mtime among the target dir itself and every
  DIRECTORY below it to depth 3, plus regular FILES at depth 1 (`.rustc_info.json` is
  rewritten by cargo invocations). Only directories are walked at depth 2-3, because
  `deps/` holds tens of thousands of files. A stat error counts as "fresh" (keep).
- **Thresholds.**
  - Reap if idle ≥ `CARGO_REAP_IDLE_H` (default 168h / 7 days, at any pressure). This is hygiene.
  - Reap if idle ≥ `CARGO_REAP_PRESSURE_IDLE_H` (default 3h) AND used% ≥ `PRESSURE_PCT`.
  - Seam: `CARGO_REAP_USED_PCT` overrides the `df` reading. Otherwise use
    `os.statvfs("/")` (used = (blocks - bfree) / (blocks - bfree + bavail), rounded up, which
    is df's formula). If statvfs fails, treat the reading as "not under pressure".
- **In use (keep).** `paths_in_use([target])` hits, i.e. a process has cwd, exe or an open fd
  under it. ALSO keep any target that a process MAPS a file from (scan
  `/proc/<pid>/maps` path column), so rust-analyzer's proc-macro server, which dlopens
  `.so` files from `target/debug/deps`, pins the target. If the probe raises (it cannot
  read /proc), keep everything and log it. Seam: `CARGO_REAP_PROC` (default `/proc`) is
  passed through to the probe.
- **Order and rate.** Collect the reapable candidates, then sort by idle age, oldest
  first. At most `CARGO_REAP_MAX` (default 3) per pass. The rest wait.
- **Delete.**
  1. Re-check in-use and idle age immediately before acting.
  2. `os.rename` the target into
     `CARGO_REAP_TRASH/<sanitised-path>.<pid>` (default `$HOME/.cache/cargo-reap/trash`,
     same filesystem; created if missing).
  3. `shutil.rmtree`.

  If the rename fails with EXDEV or anything else, skip that target and log it. Phase 0 of
  every pass purges whatever is left in the trash dir, so a partial delete is retried
  without reclassification.
- **Dry run.** `CARGO_REAP_DRY_RUN=1` classifies identically, logs `would reap`, and
  deletes nothing.
- **Log.** Lines are prefixed `[cargo-reap]`. Each line covers one of: keep (with its
  reason), reap (path, size in MB measured after the rename, idle hours), and a final
  total.
- **Exit status.** Always 0, matching the bazel-reap rationale.
- **Unit.** Oneshot, `Nice=19`, `IOSchedulingClass=idle`, `HOME=%h`,
  `PATH=/run/current-system/sw/bin`. Timer: `OnStartupSec=10min`, `OnUnitActiveSec=15min`.
- **Tests.** `users/dev/test-cargo-reaper.sh`. It follows the `test-bazel-reaper.sh`
  pattern: a `CARGO_REAP_SRC` seam, fixture trees, `check` helpers and a final
  `=== N passed, 0 failed ===`. It is wired as a flake check `cargo-reaper-tests` with an
  exact PASS-count pin. Cases:
  - idle 49h at low pressure is reaped;
  - idle 4h at low pressure is kept;
  - idle 4h at high pressure is reaped;
  - idle 1h at high pressure is kept;
  - no `CACHEDIR.TAG`, or a non-cargo tag, is ignored;
  - a symlinked `target` is ignored;
  - a process with its cwd inside the target keeps it (background `sleep` started there);
  - an unreadable /proc (`CARGO_REAP_PROC` pointed at an empty dir) keeps everything;
  - the rate limit holds, and the oldest go first;
  - a dry run deletes nothing;
  - a leftover in the trash is purged;
  - `.git`/`node_modules` are not descended into;
  - a target under `.worktrees/Y/` is found;
  - a missing root does not crash.

### Task 2: pressure tier in `bazel-reap` (`workstation-qpb7`)

Keep the orphan test exactly as it is. Add one more reap condition that applies only when
used% ≥ `PRESSURE_PCT` (seams `BAZEL_REAP_USED_PCT` and `BAZEL_REAP_PRESSURE_PCT`, default
80; `df` is read with `df --output=pcent /`). A base whose workspace still EXISTS is reaped
when ALL of these hold:

- the server is not alive (same pid check);
- the marker is readable (same as now);
- its idle age, measured as `command.log` mtime, is ≥ 30min for a workspace whose basename
  matches `lgtm-pr-*`, or ≥ 3h otherwise (seams `BAZEL_REAP_LGTM_IDLE_MIN`,
  `BAZEL_REAP_IDLE_MIN`);
- `command.log` exists (otherwise keep).

Invariant preserved and stated in the header: every base removed is still one the nightly
would remove (the nightly requires only a dead server). So the reaper never deletes
anything the nightly would keep. It now just deletes it earlier, and only under pressure.

The header's "THIS IS HYGIENE, NOT A DISK LEVER" paragraph must be amended with the
2026-10-13 measurement: Bazel held about 67G of reclaimable idle bases at 100% full. That
was true for orphans, and it is not true for idle live-workspace bases under pressure.

Rename-then-purge and `MAX_PER_PASS` apply unchanged. Re-check the server pid and idle age
immediately before the rename. Log the reason, e.g. `reaped NAME (... MB, idle Xh under
pressure NN%: WS)`.

Tests are added to `test-bazel-reaper.sh`, and the flake tally is bumped. Cases:

- a live workspace that is idle 4h is kept at low pressure and reaped at high pressure;
- a live workspace that is idle 1h is kept at high pressure;
- `lgtm-pr-*` idle 45min is reaped at high pressure, while non-lgtm idle 45min is kept;
- a live server is kept at high pressure;
- a missing `command.log` is kept at high pressure.

## Out of scope

- Nightly `disk-cleanup` changes.
- devbox.
- Shared output bases for lgtm.
- `lgtm-r926`.
