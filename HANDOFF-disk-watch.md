# Handoff: disk-watch (workstation) + what it unblocks in eng-agent-platform

Written 2026-08-29 by the previous session, which was terminating turns early.
Everything below is measured unless it says otherwise. Nothing here is committed
yet — see "State of the tree".

## TL;DR for whoever picks this up

A finished, tested, unreviewed-by-you change sits **uncommitted** in
`~/projects/workstation/.worktrees/disk-watch` (branch `disk-watch`, off
`origin/main`). It adds a disk threshold alarm to cloudbox. Tests pass 18/18 and
13/13 mutations are caught with a verified baseline.

**Remaining work is four steps**, in order:

1. Wire `users/dev/test-disk-watch.sh` into `flake.nix` as a `runCommand` check.
   Template: the `disk-cleanup-worktree-tests` block at `flake.nix:438`. It must
   pass the source in via the `DISK_WATCH_SRC` env seam, because a flake check
   cannot invoke `nix eval` inside its own build sandbox.
2. `nix flake check` (or at least build that one check).
3. Commit + push the branch. Solo repo convention here is a PR, but confirm with
   the human — `workstation` normally takes PRs, unlike `eng-agent-platform`.
4. `nix run home-manager -- switch --flake .#cloudbox` to actually deploy the
   timer. **Until this runs, the alarm does not exist.** Then verify:
   `systemctl --user list-timers disk-watch.timer`.

Then update `eng-agent-platform-k83` and write SDD §30 there (see "Owed to
eng-agent-platform" below).

## Why this exists (the measurement, not the story)

cloudbox's root filesystem hit **0 bytes free on 2026-08-28 at 18:25** and killed
a running automation episode mid-flight:

```
18:13:26  [goose] Invoking goose with tracker mono-blvq ...
18:25:30  run-maven-renovate.sh: line 581: echo: write error: No space left on device
18:25:30  maven-renovate.service: Main process exited, code=exited, status=1/FAILURE
```

That was the **second** such event in four days — 2026-08-25 20:18 reached 97%.
Both were rescued only because a human happened to look. `disk-cleanup.timer`
runs once daily at 03:00, so nothing watched the other 23 hours.

Series pulled from the nightly `Disk before/after` journal lines:

| day type   | overnight growth   | peak         |
| ---------- | ------------------ | ------------ |
| quiet (×3) | +47G, +48G, +55G   | 81%, 82%, 84% |
| active (×2)| +117G, +112G       | **97%, 100%** |

85% of 393G is 334G — above the worst quiet-day peak (314G), below both
incidents. Replayed against 2026-08-28 it fires ~13:30, **five hours before** the
box filled. Quiet on a normal day, early on a bad one.

## The design, and the two things review killed

`adversarial-reviewer-fable` was run on the design and found four blocking
defects. Two mattered enough to change the shape of the thing:

**The original design auto-ran the cleanup at 90%. That was wrong twice over,
and both were verified at the line level, not taken on faith:**

- `disk-cleanup.nix` runs `cleanup_nix` **first** (see the `# --- Main ---`
  block). The `cleaning-disk` skill documents that above ~90% a nix GC can
  generate enough I/O pressure that socket-activated sshd stops answering,
  needing a console reset. So triggering at 90% would launch the box-wedging
  step exactly and only inside the danger zone.
- It would not have helped anyway. The bazel purge **skips any output base whose
  server PID is alive** (`disk-cleanup.nix`, the `WARN: skipping output base`
  branch). A spike like these is *caused* by three live bazel servers holding
  12–25G each, so at peak pressure nearly everything worth reclaiming is exactly
  what gets skipped.

Constant hazard, near-zero benefit → **the shipped version only warns.** A test
pins this behaviourally (stubs `systemctl`, asserts it is never invoked).

Other review findings folded in: `OnUnitActiveSec` alone never fires (needs
`OnStartupSec` too); `Persistent=` is a no-op on monotonic timers; state-file
writes must never precede the alert.

## Design decisions worth not re-litigating

- **Channel:** reuses `pkgs/opencode-drift-alert`, the same helper the opencode
  canaries use (pigeon `/alert`, Bearer auth from
  `/run/secrets/pigeon_daemon_auth_token`). Verified live: authenticated POST
  returns 204. Do not invent a second channel.
- **Signature is `disk-warn`, a band — not the raw percentage.** A percentage
  signature makes 86→87 read as a new episode and defeats the helper's backoff
  entirely.
- **Recovery floor is 80%, not 85%.** Clearing the episode the moment we drop
  below the warn line means an 84↔86 sawtooth starts a fresh episode on every
  crossing, and the helper dedupes per episode — so it would alert on each one.
  The 80–85 gap is a deliberate dead band.
- **No `set -e`.** A nonzero exit puts `disk-watch.service` into `failed`, a
  state nobody reads, precisely when the disk is in trouble.

## The bug the test environment caught (read this before touching the suite)

The suite reported **17/17 green while shipping a script that aborts in
production.** The script interpolated `$USER` into the alert text; the systemd
unit sets only `HOME` and `PATH`, so under `set -u` that is an unbound variable
→ abort **before alerting** → unit `failed` at exactly 100% full. The green run
had inherited the developer's interactive `USER`.

`run_at()` in the suite now uses **`env -i`** with only `HOME` and `PATH`, mirroring
the unit exactly, and there is a dedicated assertion for the property. Do not
"simplify" that back to an inheriting `env`.

## Mutation testing: the first run was a lie

`/tmp/mut_dw.py` (may not survive a reboot; recreate from this description).
Its first run reported **caught=13, survived=0 — and it was worthless**, because
every mutant "failed" via the same two assertions. The unmutated source *also*
failed under that environment (the `$USER` bug), and "the suite fails" was being
read as "the mutation was caught."

The harness now runs a **baseline control first** and exits 2 if unmutated source
fails. Current honest result: **caught=13, survived=0, skipped=0**, each mutation
failing via its own specific assertion. If you change the script, re-run it, and
check *which* assertion catches each mutation — not just the total.

## State of the tree

```
~/projects/workstation/.worktrees/disk-watch   (branch: disk-watch, off origin/main)
   M users/dev/disk-cleanup.nix        <- driftAlert let-binding; disk-watch script + service + timer
  ?? users/dev/test-disk-watch.sh      <- 18 assertions
  ?? HANDOFF-disk-watch.md             <- this file (delete before committing, or keep — your call)
```

**Nothing is committed. Nothing is pushed. The timer is NOT deployed.**

`~/projects/eng-agent-platform` is clean and fully pushed through the §29 work.

Verification already done, and re-runnable:

```bash
cd ~/projects/workstation/.worktrees/disk-watch
nix --extra-experimental-features 'nix-command flakes dynamic-derivations' \
  eval --raw ".#homeConfigurations.cloudbox.config.home.file.\".local/bin/disk-watch\".text" \
  > /tmp/disk-watch.src
env -i PATH=/run/current-system/sw/bin:/usr/bin:/bin HOME=/home/dev \
  DISK_WATCH_SRC=/tmp/disk-watch.src bash users/dev/test-disk-watch.sh
```

## Owed to eng-agent-platform once this lands

- **`k83`** — close it, but only after the timer is actually deployed and
  `systemctl --user list-timers` shows it. The bead has the full incident
  history; add the 08-25 97% event, which the original bead did not know about.
- **SDD §30** in `docs/plans/2026-08-26-assist-migration-sdd.md` (next section
  number is 30). Cross-repo entry: what was built in `workstation`, why warn-only,
  and that it gates `yiy`.
- **`yiy` (P0)** — the merge gate's first real execution. See below.

## What I found about yiy, since it was the P0 I started on

The allow path still cannot be exercised, and now for a documented reason:

- `~/.local/state/lane-maven-renovate/pr/` **does not exist** — zero tracked PRs.
  `lane-ready.sh` is the only writer and the agent has never called it, because
  the first lane run after it shipped (16:00 on 08-28) is the one the disk killed
  at 18:25. So `k83` genuinely gates `yiy`; that is not a rationalisation.
- The two live lane-owned PRs are **#4355 and #4259** (both class `maven`, both
  MERGEABLE). Both are `REVIEW_REQUIRED`, so precondition 4 refuses them anyway.
  A dry run against either currently refuses at **precondition 1** (no per-PR
  state), which I confirmed by running it.
- Next scheduled lane run: **Mon 2026-08-31 16:00 EDT**.

To reach the allow path you need a PR that is both *tracked* (agent called
`lane-ready.sh`) and *approved at its current head by a non-author*. Neither
exists today. Do not fabricate state to get there — `lane-merge.sh:47-49`
explicitly documents that forging `LANE_STATE_ROOT` merged a PR it should not
have, which is why `PR_STATE_DIR` is not derived from it.

## A caution about how to verify things in this repo pair

The previous session's recurring failure was **asserting against shapes it had
not read** (~9 instances in one day). Two that cost real time:

- Fed `lane-owns.jq` labels as flat strings when it wants label *objects*
  (`[.labels[]?.name]`), got "zero owned PRs", and nearly concluded the predicate
  was broken. It fails loudly with exit 5; a stray `2>/dev/null` hid it.
- Wrote a test assertion grepping a file for a string that the file legitimately
  discusses in its own comments. Proves nothing. Assert behaviour, or assert the
  argv — never the mention.

One command to *look* before any command that *claims*.
