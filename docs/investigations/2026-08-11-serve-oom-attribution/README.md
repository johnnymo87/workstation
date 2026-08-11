# Serve OOM attribution (W2f)

**Date:** 2026-08-11 · **Bead:** `workstation-yvxh.14` (closed) ·
**Follow-ups:** `workstation-yvxh.15` (P1), `workstation-rdsq.4` (P2)

## Answer

Serve OOM is **not** a latent production defect. Both `opencode-serve@4097`
OOM kills in a clean 6-day window were **vitest workers running inside the
serve's own cgroup** — our workload shape, not production load.

| | |
|---|---|
| Window | 2026-08-05 12:27 → 08-11 11:36 (~6 days) |
| Real OOM kills | 42 — 20 agent scopes, 17 bazel, **3 serve@4097**, 2 hogtest |
| Serve OOM → orphans | 1 turn each, created 30 s and 7 s before the kill |
| Orphans in window | 30 total (~4.6/day) |
| Explained by OOM | 2 (6.7%) |
| Explained by write-lock | 0 (0%) |
| **Unexplained** | **28 (93%)** → `workstation-yvxh.15` |

Do **not** "fix" this by raising the serve cap — that just lets a test suite
consume more before dying and enlarges the blast radius for the real serve.

## Three instrument traps, all hit here

**1. Counting OOM *attempts* as OOM *events*.** The prescribed grep returned
26,653 lines; 26,569 were on one day. Taxonomy:

| line | count | is it a kill? |
|---|---|---|
| `invoked oom-killer` | 5,986 | no — an attempt |
| `no killable processes` | 20,621 | no — a *failed* attempt |
| `oom-kill:constraint` | 42 | **yes** |
| `Killed process` | 42 | **yes** |

The 20,621 are a single vitest run whose workers carry `oom_score_adj=-1000`,
so the kernel could not kill anything and spun logging. Zero kills came out of
it. Counting attempt-lines would have manufactured a four-orders-of-magnitude
fake crisis.

**2. The kill phrase is lowercase for memcg.** Kills log as
`Memory cgroup out of memory: Killed process`. A case-sensitive grep for
`Out of memory` **misses every memcg kill**. Use `-i`.

**3. Counting live phantom-busy rows in a past window is a false negative.**
The sweeper *finalizes* an orphan by writing `$.error` containing
`phantom-busy sweeper`, which **erases** the phantom-busy signature. Querying
`time.completed IS NULL AND error IS NULL` over a past window returns 0 and
looks like "OOM does not orphan turns". Search the sweeper's fingerprint
instead — that is what `w2f_swept.py` does, and it is how the 2 real orphans
were found after the naive query said 0.

Also: my own `grep` command line appeared in its own results (systemd logging
the `systemd-run` payload, which contained the search phrase). Small here, but
it is the W2e self-contamination failure repeating in miniature — exclude your
own activity before quoting a count.

## Scripts

All read-only.

| Script | Purpose |
|---|---|
| `w2f_tally.sh` | Kill taxonomy + victim cgroup attribution + unit-restart truth |
| `w2f_swept.py` | Orphan counting by **sweeper fingerprint** (the correct method) |
| `w2f_orphans.py` | Live phantom-busy counting (**kept to show the false negative**) |

## Journal constraint

Retention is **single-boot**. The host rebooted 2026-08-04 22:17, so the
07-30→08-04 history W2e used is gone and cannot be re-examined. Any correlation
work can only reach back to that boot — capture counts into beads as you go
rather than assuming the journal still holds them.

## Relationship to PR #344 / `workstation-le0a`

#344 attaches a 32G **aggregate** slice cap. It does **not** stop a test runner
from executing inside a serve's cgroup, so it does not prevent these events. It
also **couples** the members: with a shared ceiling the kernel picks an OOM
victim across the whole subtree, so a runaway in 4097 can orphan a turn in an
innocent 4098. Correct trade, but it raises the value of `workstation-rdsq.4`.

Verified 2026-08-11 15:40 UTC on **cgroupfs** (never `systemctl show` — it
reports what the unit *asks for*, not what the kernel *enforces*, and the
failure mode is a missing file): the attachment is not live; PR #346 deferred
it until a pool bounce is available.
