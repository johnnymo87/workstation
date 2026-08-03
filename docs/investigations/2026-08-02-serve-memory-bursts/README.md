# Serve memory bursts — raw data for step 3

Backing evidence for **step 3** of
`docs/plans/2026-08-01-cloudbox-serve-reliability-roadmap.md`
(bead `workstation-9b3o`). The conclusions live in the roadmap; this directory
exists so they can be re-derived or disputed.

## Files

| File | What |
|---|---|
| `sample.sh` | The sampler, exactly as run. Read-only. |
| `samples.tsv.gz` | 3 928 ticks × 4 serves, 2026-08-01 21:34 → 08-02 15:00, every 15 s. |

## How it was run

Not nix-managed — this is throwaway investigation tooling, deliberately kept out
of the system config. It ran from a **transient** `systemd --user` timer so it
would outlive the session that started it:

```sh
export XDG_RUNTIME_DIR=/run/user/$(id -u)
systemd-run --user --unit=s3-sampler --collect \
  --on-active=5s --on-unit-active=15s --timer-property=AccuracySec=1s \
  --setenv=PATH="/run/current-system/sw/bin:/usr/bin:/bin" \
  /home/dev/s3-sampling/sample.sh
```

It survived the 03:01 nightly reset and the 10:25 deploy. It would **not**
survive a reboot, and the hardcoded `sqlite3` store path will rot on the next
`nixpkgs` bump — fix that path before re-running rather than trusting it.

## Columns

`ts port serve_id pid boot mem_bytes rss_kb threads fds inotify_fds
inotify_watches notify_debounce assign_total assign_active_1h assign_active_10m
anon file slab pagetables swap mem_high active_file`

`mem_bytes` is the cgroup's `memory.current`, so it **includes page cache** —
that distinction is load-bearing here and is why `anon`/`file` are sampled
separately. `assign_*` come from pigeon's `session_assignment` table, which
includes dormant sessions.

## Reading it

```sh
zcat samples.tsv.gz | awk -F'\t' 'NR==1||$2==4096' | less
```

The band episode is port 4096, epoch `1785683800`–`1785685000`
(08-02 11:18–11:36). The two `memory.current == 7516192768` pins with
`swap` at 1.49 G and 6.22 G are the point of the whole exercise: the cgroup
relieves cap pressure through zram instead of dying, which is what
`workstation-h1y6` has to design around.

## Caveat on the correlations

`threads`, `fds` and the watcher counts all rise together when a session opens a
project tree, so the roadmap's positive claim ("memory tracks open trees") is
co-movement, not isolated causation. The load-bearing result is the **negative**
one: `assign_total` and `assign_active_*` do not predict memory at all
(*r* between −0.18 and 0.39), which kills the mega-session hypothesis.
