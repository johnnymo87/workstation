# ShaDa Corruption Roadmap — kill the nightly nvim write race

**Epic:** `workstation-n0yh` (P1) · **Started:** 2026-08-02 · **Status:** recovery shipped, prevention not started

> **This roadmap exists because the first two fixes were wrong.** Commit
> `b456147` shipped a theory (`E138`, all 26 temp suffixes taken) that was never
> checked against the actual error text — the warnings came straight back.
> Commit `8ff0790` fixed the real symptom but called the cause "unverified
> hypothesis", and that hypothesis was then destroyed by review. The mechanism
> below is the third answer, and the first supported by syscall traces and a
> byte-level walk of the corrupt file.
>
> **Revision 2 (same day, pre-merge).** Adversarial review of *this file* found
> four HIGH defects before it landed: the S0 smoking-gun rule was wrong in both
> the doc and its bead (and wrong *differently* in each), the causal chain's
> middle link was mechanically impossible per nvim's source, the arming command
> printed here did not match the watch actually armed, and the per-step spine
> ordered implementation before design review — the exact defect the
> plugin-loader roadmap's own Revision 2 exists to record. All fixed below.
> Recorded rather than quietly corrected, because "the third answer still had
> four defects" is the most useful datum in this file.

---

## Facts that must survive compaction

Verified against `strace` on this host's binary (NVIM v0.11.7, aarch64), against
nvim's source, or by walking the bytes of the preserved corrupt file. Claims are
labelled **verified** or **inference**. Do not re-derive from memory, and do not
trust a summary — including this one — over a fresh check.

### The observed failure

```
E576: Error while reading ShaDa file: expected positive integer at position 12686
E136: Did not rename .../main.shada.tmp.g because .../main.shada does not look
      like a ShaDa file
```

`~/.local/state/nvim/shada/main.shada` was corrupt at byte 12686 (size 16636).
nvim validates the **existing** target before renaming a new file over it, so
once the target is corrupt the rename is refused **forever**: every start/save
warns, ShaDa silently stops persisting, and each exit strands one more temp
(`shada.c:2861-2867`).

### The mechanism

| # | Fact | Status | How established |
|---|---|---|---|
| 1 | Temps are opened `O_CREAT\|O_EXCL\|O_NOFOLLOW`. Two nvims can **never** share a temp fd. | **verified** | `strace`: `openat(...tmp.a, O_WRONLY\|O_CREAT\|O_EXCL\|O_NOFOLLOW\|O_CLOEXEC, 0600)` |
| 2 | `vim_rename` does `unlinkat(main.shada)` **before** `renameat(tmp → main.shada)`. Every healthy save opens an ENOENT window on the target. | **verified** | `strace` (order below); `fileio.c:2692` `os_remove(to)` before `os_rename` |
| 3 | On read-open failure of `main.shada`, nvim sets `nomerge` and writes **directly** into the real path — no temp, no rename, not atomic. ENOENT is **silent**; other errnos emit `E886`. | **verified** | `shada.c:2711-2727` → `shada.c:2786` (`kFileCreate\|kFileTruncate`). Probe: fresh state dir, `main.shada` absent, **single** write → `openat(main.shada, O_WRONLY\|O_CREAT\|O_TRUNC, 0600)`, no temp created, no message |
| 4 | All 26 temps taken ⇒ `E138` ⇒ **`return FAIL`, nothing is written at all.** A full temp dir does *not* push a writer onto the direct path. | **verified** | `shada.c:2739-2755`. Probe: 26 temps + valid `main.shada`, single write → size unchanged (27500 → 27500) |
| 5 | `pkill -9` does not suppress shada writes — it **triggers** them. Each pane is a TUI client + an `nvim --embed` server; killing the client makes the server see channel EOF and begin a *graceful* exit, which writes shada, before pkill reaches its pid. | **inference**, strongly supported | Socket pairing on `/tmp/nvim-*.sock` (topology, verified) + the corrupt file's header showing a write at `03:00:04` by pid 822121 during the kill storm (artifact, verified). The millisecond ordering itself is not directly observed — S0 is what would observe it |

The syscall order that makes fact 2 concrete:

```
openat(main.shada, O_RDONLY)                                  ← pre-merge read
openat(main.shada.tmp.a, O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW)  ← temps are safe
unlinkat(main.shada)                                          ← ENOENT WINDOW
renameat(main.shada.tmp.a → main.shada)
```

> **Retracted evidence, kept as a warning.** An earlier draft cited "with 26
> temps present and `main.shada` absent, nvim prints `E138` yet still creates
> `main.shada`" as proof of fact 3. That is impossible as a single write (fact
> 4). The probe used `-c 'wshada' -c 'qa'` — **two** writes: the first created
> the file directly while absent, the second hit `E138`. The conclusion was
> right, the evidence was an artifact of a sloppy probe. Use one write per
> probe.

### The corrupt file is proof, not inference

Walking the msgpack of `main.shada.corrupt.20260802T132400Z`:

- **Header:** embedded timestamp `2026-08-01T07:00:04Z` = **Aug 1 03:00:04 EDT**,
  writer **pid 822121**. Exactly the nightly reset hour.
- **Bytes `[0, 12686)`** — writer **B**: marks/registers/jumps/history, search
  history through **Jul 31 14:12**, ending cleanly *on a record boundary*
  (B was SIGKILLed there).
- **Bytes `[12686, 16636)`** — writer **A**, underneath: resumes 9 bytes into a
  cmd-history record header (`\xec` = timestamp low byte, `!` = len 0x21,
  matching its 33-byte payload exactly), then parses cleanly to **exactly EOF**.
  Same section order, same inherited history, **older cutoff (Jul 30 18:01)**.

Two complete streams, one inode, different recency cutoffs. Only the direct-write
path (fact 3) can produce that; `O_EXCL` temps and atomic renames cannot.

### The causal chain — and its one unresolved fork

Two writers reached the direct path concurrently on Aug 1 at 03:00:04. Per fact
4, a full temp dir cannot be what put them there, so it happened one of two ways:

- **(a) At least one temp letter was free.** A healthy saver C unlinked
  `main.shada` (fact 2); A and B both did their pre-merge read-open inside C's
  ENOENT window; both fell to `nomerge`; both direct-opened the real path, the
  second truncating over the first.
- **(b) `main.shada` was already absent** entering 03:00, so every exiting
  server direct-wrote and two of them spliced.

**Which one is unresolved** — the temps that would have settled it were reaped
during remediation. It does not change the prevention: both variants are
disarmed by removing concurrent writers (S2), and **both are reachable with a
completely clean temp directory**, so "the race re-arms every night" holds
regardless of temp hygiene.

The stranded temps (Apr 26 – May 4) are earlier debris of the same nightly
storm, not a link in this chain.

### Ruled out (do not revisit without new evidence)

- **Shared temp fd** — `O_EXCL` (fact 1).
- **Full temp dir causing a direct write** — `E138` returns FAIL (fact 4).
- **Crash exposing an unsynced rename** — no reboot since May 11; `uptime` 82d.
  The splice is not zeros, it is a second valid stream.
- **Disk full** — 57% used, 163G free (weak: not verified for Aug 1 03:00).
- **Weak pre-rename validation as the corruptor** — the merge-read is a full
  parse. It is the victim (it strands temps), not the culprit.

### Artifacts

| Thing | Where | Durability |
|---|---|---|
| Corrupt file (only evidence of the splice) | `~/.local/state/nvim/shada/main.shada.corrupt.20260802T132400Z` | Kept; Step 3.5 never deletes quarantines |
| S0 watch log | `~/.local/state/shada-watch.log` | Until manually removed |
| S0 unfiltered control capture | `~/.local/state/shada-watch.log.control` | Until manually removed |
| msgpack walker | pasted into epic bead `workstation-n0yh` | Durable (was `/tmp/opencode/walk.py`, ephemeral) |
| Recovery code | `pkgs/reset-workspace/default.nix`, search `Step 3.5` | Shipped `8ff0790`, deployed |

### Already shipped — recovery only, NOT prevention

- `b456147` — **wrong theory**, swept temps. Warnings returned.
- `8ff0790` — Step 3.5: quarantine an unparseable `main.shada`, promote the
  newest parseable temp, reap the rest. Self-heals within one night. **The race
  re-arms every night regardless.**

One landmine already caught in that code: a parse probe using `-i <file>` makes
nvim **write** that shada on exit, mutating the file it inspects and stranding
new temps. A sandbox test caught the probe promoting its own byproduct. Hence
`-i NONE -c 'rshada <file>'`.

### Scope

cloudbox is where this fired, but devbox and macOS run the same nvim config and
the same `nvims` pool shape. S2 is cloudbox-first; the hazard is not
cloudbox-only. S2 also only covers the *nightly* storm — ordinary daytime
multi-pane quits carry the same (much smaller) race, which only S3 truly fixes.

---

## Per-step spine

Every step runs this sequence. No step is done until its last box is ticked.

1. **Compact** — persist context first (`preparing-for-compaction`).
2. **Oracle consult** (`oracle-fable`) — *optional*, when the design is genuinely
   open. Skip when the change is mechanical.
3. **Adversarial review of the DESIGN** (`adversarial-reviewer-fable`) —
   **mandatory, before any code is written.** Not before merge: before code.
   Every failure in this family has been wrong-approach, not typo, and the
   plugin-loader roadmap records this exact ordering defect as HIGH
   (`2026-08-01-plugin-loader-hardening-roadmap.md`, Revision 2). This document
   had it too, in its first draft.
4. **SDD** — subagent-driven development, *if applicable* (multi-task steps).
   Single mechanical edits go direct.
5. **PR** — *if applicable*. Repo norm is PRs; the two fixes above went direct to
   `main` and bypassed a required check, which Jonathan waived once.
6. **Update this roadmap** — status, new facts, new beads for discovered work.

---

## Steps

### S0 — Arm the inotify watch · `workstation-t032` · **P0** · ARMED 2026-08-02 17:56 EDT

Read-only observation of the 03:00 reset. **Already armed and verified against a
live control write.** Exit: verdict recorded in the bead, bead closed, watch
stopped (`systemctl --user stop shada-watch`).

Re-arm (verbatim — this is what is actually running; the earlier draft of this
doc printed a different, unfiltered command that logged to the journal):

```bash
export XDG_RUNTIME_DIR=/run/user/$(id -u)
IW=$(readlink -f ~/.cache/shada-watch-inotify)/bin/inotifywait
systemctl --user stop shada-watch; systemctl --user reset-failed shada-watch
systemd-run --user --unit=shada-watch --collect --setenv=PATH="$PATH" \
  bash -c "exec $IW -m --timefmt '%F %T' --format '%T %e %w%f' \
    -e create,delete,modify,moved_to,moved_from,close_write \
    ~/.local/state/nvim/shada >> ~/.local/state/shada-watch.log 2>&1"
```

`systemd-run` (not `setsid nohup`) so it survives a restart of the opencode serve
unit it was launched from — AGENTS.md, *Backgrounding Long-Running Processes*.
The binary is GC-root pinned at `~/.cache/shada-watch-inotify`.

**Before interpreting anything, check the watch was alive across 03:00:**
`systemctl --user is-active shada-watch` **and** a log mtime past 03:00. The unit
is `--collect`, so if it died it left no failed unit — a dead watch produces a
short, clean-looking log that reads exactly like "no race tonight". inotify also
watches *inodes*: if anything ever replaces the shada **directory**, the watch
goes silently deaf (nothing does today; verify anyway).

**Negative control — signature of a HEALTHY save (captured live):**

```
CREATE      main.shada.tmp.a
MODIFY      main.shada.tmp.a   (xN)
DELETE      main.shada          ← the unlink window; happens on EVERY healthy save
MOVED_FROM  main.shada.tmp.a
MOVED_TO    main.shada
CLOSE_WRITE main.shada
```

**The discriminator.** The healthy path never emits `CREATE` or `MODIFY` on the
name `main.shada` — writes land under a temp name, and the rename surfaces as
`MOVED_TO`. Therefore:

> **Any `CREATE` or `MODIFY` event on `main.shada` itself = a writer that opened
> the real path directly.**

Do **not** qualify that with "preceded/followed by MOVED_TO" — earlier drafts of
this doc and of bead `t032` each did, differently, and both filters are wrong:
healthy saves sprinkle `MOVED_TO main.shada` through the log at unbounded
distance either side, so "not preceded" discards the real gun and "not followed"
masks it.

**Known benign producers of that same signature — exclude before concluding:**

| Source | Signature | How to tell |
|---|---|---|
| Step 3.5 promotion — **as shipped in `8ff0790`, i.e. what is running during the first watched night** | `CREATE main.shada` + `MODIFY` + `CLOSE_WRITE` — **identical to the gun, and it fires at 03:00** | Only runs when `main.shada` was corrupt; preceded by `MOVED_FROM main.shada` → `MOVED_TO main.shada.corrupt.*` |
| Step 3.5 promotion — **after S1 (#261)** | `CREATE main.shada.promote.<pid>` + `MODIFY` + `MOVED_FROM main.shada.promote.*` → `MOVED_TO main.shada`. **No `CREATE`/`MODIFY` on `main.shada` at all** | S1 made promotion atomic (temp + rename) for durability reasons, which as a side effect retires the worst false positive above: from now on the repair is indistinguishable from a healthy save, and the discriminator is clean |
| Step 3.5 quarantine `mv` | `MOVED_FROM main.shada` + `MOVED_TO main.shada.corrupt.*` | — |
| Step 3.5 reap | `DELETE main.shada.tmp.*` | — |
| First write to a fresh/absent shada | `CREATE main.shada` (single writer, benign) | No second writer overlapping |

Two or more direct writers **overlapping in time** is the finding. A single one
is a curiosity.

**Quantified control, 17:56–18:31 on the arming night** (ordinary interactive
use, no reset): **103** `CREATE`/`MODIFY` events in the shada dir, of which
**0** were on `main.shada` itself — every one landed on a `main.shada.tmp.*`
name. So the discriminator's false-positive rate against normal traffic is zero
over ~35 minutes, and the signature is genuinely rare rather than merely
undocumented. If tomorrow's readout shows even one, that is signal.

### S0 verdict — read out 2026-08-03 09:00

**No direct writers.** Zero `CREATE`/`MODIFY` on the name `main.shada` across the
whole 11.3h watch (326 events, 17:56 Aug 2 → 05:16 Aug 3), reset included. The
race did not fire. Liveness was confirmed *first* (unit active, same
`ExecMainPID` as at arming, log mtime past 03:00), so this is not the dead-watch
false quiet the `--collect` trap produces.

**The storm, on the other hand, is now observed rather than inferred** — 19
events in one second, three writers, three unlink windows:

```
 1  CREATE tmp.a          writer A opens its temp
 2  CREATE tmp.b          writer B starts while A is still writing
 3  MODIFY tmp.a
 4  DELETE main.shada     <- A's vim_rename unlink: ENOENT WINDOW OPEN
 5  MOVED_FROM tmp.a
 6  MOVED_TO main.shada   <- A renames; window closes
 7  MODIFY tmp.b
 8  DELETE main.shada     <- B's unlink: window 2
 9  MOVED_FROM tmp.b
10  MOVED_TO main.shada   <- B renames
11  CREATE tmp.a          writer C
12  MODIFY tmp.a  (x2)
14  DELETE main.shada     <- C's unlink: window 3
15  MOVED_FROM tmp.a
16  MOVED_TO main.shada   <- C renames
17  CLOSE_WRITE main.shada (x3)
```

This upgrades **causal-chain point 4** from inference to observation: `pkill -9`
does provoke graceful ShaDa writes from the embedded servers, and they overlap.
Three windows opened; no writer's merge-read happened to land inside one. That
is ordering luck, not safety — B had already created its temp (event 2) before
A's unlink (event 4), so B's read preceded the window. The 2026-08-01 corrupt
file's header is stamped `03:00:04`: the same second of the same nightly burst,
different dice.

**Second finding, unprompted: the burst destroys history every night even when
nothing corrupts.** Three renames onto one path means the survivor is writer C
alone. B created its temp before A's rename, so B cannot have read A's merged
result — A's session history is silently discarded. Last-writer-wins, nightly.
This is an independent argument for S2, and the same serialization fixes it:
serialized exits make each writer read its predecessor's result instead of
racing it.

**Watch left armed** (deviation from the plan, which said stop it): S2's exit
criterion needs an observed night anyway, and extra nights are free pre-S2
baseline. Boundary for future readouts: the pre-S2 window ends at log line 326
(05:16:28 Aug 3).

**If the log is clean, S2 still proceeds.** The mechanism is strace-proven
independently of S0; the race is probabilistic and its window is milliseconds, so
one quiet night is not evidence of absence. S0 exists to characterise the storm
(how many writers, what Step 3.5 does, whether temps strand), **not** to decide
whether the race exists. Do not re-gate S2 on a second night.

Spine: no oracle, no SDD, no PR. Review the *interpretation* before acting on it.

### S1 — Fix four defects in the Step 3.5 probe · `workstation-wro4` · P1

All four make the repair **fail open** — declare a bad file healthy, or install
an unvalidated one. All in code shipped by `8ff0790`. Review confirmed the list
is complete (no fifth defect found).

| # | Defect | Site | Fix |
|---|---|---|---|
| 1 | Greps only `E576`; nvim's reader also emits `E575` and `E886` | `default.nix:778`; classes at `shada.c:119,127` | widen to `E57[56]\|E886` |
| 2 | `timeout 30` **inverts to healthy** — a hung probe yields empty output → no match → "parses". Same for the absent-nvim fallback. | `default.nix:777-778` | fail closed |
| 3 | Promotion `cp`s straight onto the live path — a reset dying mid-copy manufactures the exact corruption this code exists to fix | `default.nix:793` | copy to a temp name, then `mv` |
| 4 | "Newest parseable temp" can install months-stale history over fresher quarantined data (Aug 2 only worked because fresh temps existed) | `default.nix:786-792` | log the age gap; consider refusing a temp older than the quarantine |

Also: a truncated-but-record-aligned file parses clean, so promotion can silently
lose history after the cut. Acceptable, but log the size delta.

Test with the sandbox pattern that already caught a real bug: `sed` the Step 3.5
block out of the built script, run it against a seeded dir with `XDG_STATE_HOME`
overridden. Static greps live in `pkgs/reset-workspace/test.sh`.

**Exit:** four defects fixed, sandbox test covers each fail-closed path, static
tests updated, PR merged, deployed via home-manager, verified in the built script.

Spine: no oracle (mechanical), design review still mandatory but can be brief,
SDD optional, PR yes.

**DONE — `#261`, deployed.** Two deviations from the table above, both because
the prescription was wrong:

- **Fix #1 (widen the grep) was rejected.** Which read-error classes cause the
  *refusal* is a guess about upstream's taxonomy, and a wrong guess quarantines
  healthy files nightly. The probe now asks nvim the question that matters —
  write to a scratch **copy**, look for the refusal — which is exact and
  survives upstream renumbering. Match the **phrase** `does not look like a
  ShaDa file`, never bare `E136`: five messages share that code and one of them
  (*"errors during writing it"*) fires on a **healthy** file when the disk is
  full, which would quarantine good history.
- **Fix #2 ("fail closed") was rejected as stated.** "Cannot tell" is not
  "corrupt". Wrongly-healthy is visible and recoverable; wrongly-corrupt
  silently moves live history aside and installs a stale temp over it, every
  night. Verdict is three-state; `unknown` does nothing, loudly, and keeps the
  temps.

**Fifth defect, missed by the review that produced the table:** the reap was
unconditional. On false-healthy, failed quarantine, or failed promotion it
deleted all 26 promotion candidates — converting a transient probe failure into
permanent history loss. Now gated on verdict + repair success.

Review also caught two bugs in the *fix's own design* before any code: the bare
`E136` false-positive above, and a first sketch that re-shipped the exact
pipeline inversion it was replacing (`nvim | grep -q` yields **grep's** status,
so a hung nvim reads as healthy). Exit status is now read before grepping;
measured, nvim exits 0 on both verdicts and `timeout` gives 124.

Discrimination check — the same input against the old build, which is what makes
the new tests meaningful rather than vacuous:

```
OLD code, nvim absent, corrupt master + one good temp:
  survivors: main.shada                      <- good temp deleted, corrupt master kept
NEW code, same input:
  survivors: main.shada main.shada.tmp.a     <- both preserved
```

### S2 — Serialized graceful nvim exits · `workstation-zv0l` · P1 · gated on S0

The actual prevention. Replace `pkill -9 -u dev -x nvim` with a walk of
`/tmp/nvim-*.sock` driving graceful exits **one at a time**, SIGKILLing only
stragglers after a bounded wait. Serial exits ⇒ at most one shada writer ⇒ no
concurrent direct writers ⇒ the race is gone at its source.

Hazards to design against: a modal/hung nvim stalling the reset; stale sockets
hanging the connect; added latency to a nightly job that also restarts the serve
pool; and the existing cgroup re-exec dance (reset-workspace can kill its own
ancestors — a graceful loop touching the launching pane needs the same care).

Complementary alternative reviewed: per-pane shada via `-i` keyed on
`$TMUX_PANE` in `pkgs/nvims`. 18 writers on one file is inherently racy either
way — but it costs shared history across panes, a real UX loss. Discuss before
choosing; not mutually exclusive.

**Exit:** reset completes with no SIGKILL of a live nvim on the happy path,
measured latency recorded, a night observed with the watch re-armed showing no
overlapping direct writers.

#### Design, as measured 2026-08-03 (supersedes the sketch above)

Every number here was measured on this host, not assumed. The sketch above said
"walk `/tmp/nvim-*.sock`"; **that is wrong** and the design changed.

| # | Measurement | Consequence |
|---|---|---|
| 1 | 10 panes = 20 nvim procs; the pane socket is bound by the **embed child**, not the client | the socket reaches the shada owner, but so does its pid |
| 2 | 27 `/tmp/nvim-*.sock` files, **10 listeners** → 17 orphans | SIGKILL residue; a glob walks mostly garbage |
| 3 | RPC `:qa!` on a realistic pane: embed dead 14ms, client 17ms, pane closed, socket unlinked, shada written | graceful exit works and is cheap |
| 4 | **SIGTERM to the embed pid does the same**: embed 56ms, client 60ms, pane closed, socket unlinked, shada written | pid alone is a sufficient handle |
| 5 | **Merge-at-write**: B started on an empty shada; A then wrote `MARKER_A`; SIGTERM B → **both markers** present | serialized exits *accumulate*; the nightly loss is caused by concurrency, not inherent |
| 6 | A *successful* `:qa!` returns **rc=2** (`ch 3 was closed by the peer`); a stale socket returns **rc=2** (`E247`) | the RPC exit code cannot distinguish success from no-op |
| 7 | A socket that accepts but never answers blocks forever (still hung at an 8s bound); `timeout 3` cuts it, rc=124 | the RPC path *requires* a timeout |
| 8 | `&swapfile` is **0** in this config; 0 swap files after either exit path | the swap argument for preferring `:qa!` does not apply here |
| 9 | `VimLeavePre` runs on **both** `:qa!` and SIGTERM | SIGTERM is a clean exit, not a truncated one |
| 10 | A `/tmp` glob **misses** writers: a default-address nvim listens on `/tmp/nvim.dev/<x>/nvim.<pid>.0` | socket enumeration is unsound |
| 11 | `kill -0` reports a **zombie** as ALIVE; SIGKILL returns 0 and it stays `Z` | a naive pid-gone oracle burns the full timeout and logs a false WARN per zombie |
| 12 | A pid appeared in one enumeration and was gone before the next | the process set is a moving target; signals must tolerate vanishing pids |
| 13 | Classifier from one `/proc` snapshot: writers == exactly the 10 embed pids, clients == the 10 parents; a bare `nvim --headless` classifies as a writer | pid classification is sound where the glob is not |

**Therefore: SIGTERM by pid, no sockets, no RPC.** Measurements 4/8/9 make the RPC
path behaviourally equivalent here, while 6/7/10 make it strictly more fragile
(useless rc, mandatory timeout, misses writers). An advisor recommended a dual
RPC-then-SIGTERM path; the simpler one is chosen deliberately, and the reason is
recorded so a future reader does not "restore" the RPC path thinking it was an
oversight. Adversarial review agreed and added the mechanism: nvim delivers
SIGTERM on the **same main loop** that services RPC, so a wedged nvim blocks both
identically — RPC buys zero coverage of the hung class it appears to address.

**Writer** := any nvim that owns shada state = every nvim **except a UI client**,
where a UI client is an nvim having an nvim child whose cmdline contains
`--embed`. Defined by exclusion so `--headless` and `-es` are caught (a
`--embed`-only grep would miss them, measurement 13).

The walk, replacing `pkill -9 -u dev -x nvim`:

1. **Pre-walk verdict, and quarantine if corrupt.** Not just logged — *acted on*.
   If `main.shada` is already corrupt entering 03:00, every serialized writer
   fails its rename (`E136`), strands a temp holding only its own history, and
   the post-walk repair promotes the newest = **one pane's** history. Quarantining
   first means writer 1 direct-writes into the gap (safe, it is alone) and
   writers 2..10 merge onto it — full accumulation instead of one pane.
2. `cp -a main.shada main.shada.pre-reset` (guarded by `[ -f ]`). Quarantine
   preserves a *corrupt* file; this preserves a *good* one.
3. Snapshot `/proc` once; classify writers; capture `starttime` (stat field 22)
   per pid. Order deepest-nvim-nesting first, so a nested `:terminal` nvim exits
   before the host that would otherwise take it down as collateral — an
   unserialized write outside the loop.
4. Defer a writer that is an ancestor of the script to last, logging loudly.
5. Per writer, strictly serially: re-verify `comm` + `starttime` (pid reuse), then
   `kill -TERM` → poll to 3s → `kill -9` → poll to 1s → WARN if unkillable.
   **Advance only when the pid is gone or `Z`.** That is the invariant.
6. Three bounded rounds, re-snapshotting, to absorb respawns and collateral.
7. Final sweep: SIGKILL remaining **writers first** (SIGKILL is the only signal
   that suppresses the write), *then* `pkill -9` the clients. Never the reverse:
   killing the low-pid client first is exactly what triggers the burst.
8. Reap orphan sockets, skipping any with a live listener.

**Straggler SIGKILL is deliberate** — a straggler is by definition unbounded in
when its write lands, so it can overlap the *next* pane's window. One pane's
history is worth less than the file's integrity, and "it is alone by then" is
false because the walk continues after it.

#### A pre-existing blind spot this change makes reachable

Step 3.5 sets `shada_reap_ok=1`, then branches on `[ -e ] && [ ! -f ]` /
`elif [ -f ]` — with **no branch for `main.shada` absent entirely**. So when the
file is missing, `reap_ok` stays 1 and the reap **deletes every temp**. Verified
by reading the shipped code, not inferred.

A straggler SIGKILLed between its `unlink` and its `rename` leaves exactly that
state, with its temp holding all the accumulated history. So S2 must also teach
Step 3.5 to **promote, not reap, when main is missing and temps exist**, and to
log loudly when a straggler kill leaves no `main.shada`. Reachable today too (the
`pkill -9` storm can leave main absent — roadmap variant (b)); S2 makes it
likelier, so S2 owns the fix.

#### Rejected: per-pane shada

`-i` keyed on `$TMUX_PANE` removes the shared-file race but forfeits cross-pane
history permanently. Measurement 5 shows serialization *recovers* that history
instead, so per-pane shada trades away the thing the fix restores. Kept as
break-glass only.

#### First-night readout, 2026-08-04 — verified, and incomplete

Deployment was confirmed *before* the log was read (the profile binary contains
the walk; the old `pkill` is absent), and watch liveness *before* reading absence
as success (active, same `ExecMainPID` 225669, log mtime 03:00:06). So this is a
real observation, not the dead-instrument false quiet the `--collect` unit can
manufacture.

Splitting the 03:00 window by phase is what makes the result legible:

| phase | temps | **max concurrent** | unlink windows | overlapping |
|---|---|---|---|---|
| pre-walk — Step 1.5 lgtm teardown | 8 | **3** | 8 | 0 |
| the walk — Step 3 | 7 | **1** | 7 | 0 |

**The walk does exactly what it was designed to do.** Max concurrent = 1 is the
invariant, verified in production, one round, ~1 second, `7 exited gracefully, 0
SIGKILLed, 0 unkillable` — so the "no SIGKILL of a live nvim on the happy path"
clause is met. Accumulation holds too: `main.shada` grew 44138 → 44486 bytes
across the reset instead of collapsing to one pane's worth, with a healthy
verdict, no new quarantine, and zero stranded temps.

**But the night is not clean.** Three concurrent writers appear at 03:00:03, two
seconds *before* the walk, from Step 1.5 (`default.nix:419-422`):
`tmux kill-session -t '=lgtm'` tears down every lgtm pane at once, each pane's
client dies, and each embed server graceful-writes. That is the identical
mechanism to the old `pkill -9` — killing the client is what triggers the
server's write — with a different trigger, in a step S2 never touched.

Zero overlapping windows in that burst, so nothing corrupted. **That is ordering
luck, not safety**, the same way the clean S0 night was. The property that
matters is max-concurrent == 1, and Step 1.5 violates it. Tracked as `n0yh.1`.

Generalisable lesson: "we fixed the thing that kills nvims" was too narrow a
frame. Anything that tears down a pane triggers a shada write, so the invariant
has to hold across the *whole* reset, not just the step that was rewritten.

#### Landmine noted, not fixed

A deadly-signal exit sets `v:dying=1`, and well-behaved persistence plugins skip
their save when it is set. This config has no such plugin (the only
`VimLeavePre` consumer is a tabby timer cleanup), so SIGTERM loses nothing
today — but adding an auto-session plugin would silently change that, which is
why the script carries a comment saying so.

Spine: **oracle consult yes** (design is open), **design review before code**,
SDD yes, PR yes.

### S2b — The lgtm teardown · `workstation-n0yh.1` · P1 · done 2026-08-04

The teardown moved out of the interactive head (old Step 1.5) into the
destructive tail as **Step 3.4**, after the walk and its sweep, where no nvim is
left alive for `kill-session` to make write. Three findings decided the shape:

**The manifest-leak worry was unfounded.** The allowlist is built from `'=main'`
panes only (`default.nix:437,443`), so lgtm panes are out of scope whether alive
or dead. Delaying the teardown cannot leak them into the recommendation
manifest; the capture loops filter on that allowlist before doing anything.

**The alternative — serializing lgtm's nvims in place at Step 1.5 — is worse,
and not for cost reasons.** It would run writer exits *before* the pre-walk
corruption guard, so a main.shada that was already corrupt on entry would make
every one of those exits fail its rename and strand a one-pane temp, which
Step 3.5 would then promote. That is precisely the failure the guard exists to
prevent. Hoisting the guard instead would put a destructive quarantine ahead of
the `[y/N]` prompt.

**A log-only guard would have been too weak, because of a scheduled collision.**
`lgtm-run.timer` is `OnCalendar=*:0/10`, so it fires at 03:00:00 — the same
second the reset starts. Measured on 2026-08-04: `lgtm-run` began at
**03:00:03.461**, 113 ms *before* the teardown logged at 03:00:03.574, and it
dispatches fresh nvims into the lgtm session. Moving the teardown later widens
the window in which such an nvim can appear, so Step 3.4 **drains** any writer
that arrives after the sweep, one at a time, before calling `kill-session`.
Merely logging the count would have observed the burst instead of preventing it.

Behaviour change, deliberate: the teardown is now behind the confirmation gate,
so **aborting at `[y/N]` leaves the lgtm session alive**. It used to be destroyed
before the user answered — a destructive act ahead of consent. The manual
substitute is one command.

Cost paid to learn something: `test-nvim-walk.sh` *executes* the region it
extracts and stubs only `pgrep`/`pkill`. Step 3.4 was first placed inside that
region, so running the harness drove the **real** tmux server and killed the
live lgtm session and its two nvims. The extraction now stops at the Step 3.4
marker and a new guard rejects any `tmux` command in the extracted body — the
same shape as the existing guard that keeps the real `/tmp` socket reap out of
the lab. Generalisable: an extraction harness is only as safe as its least
stubbed command, and its boundary is load-bearing test infrastructure.

#### First-night readout, 2026-08-05 — the invariant held, but it was a null test

Both traps passed before anything was read: the deployed binary is the fixed one
(client sweep 976 < drain 1010 < `kill-session` 1030), and the watch was alive
through the window (same `ExecMainPID` 225669, log mtime 03:00:06, 93 events).

Measured across the whole 02:59–03:02 window: **9 temps, max concurrent = 1**,
none stranded, `9 exited gracefully, 0 SIGKILLed, 0 unkillable`, pre-walk verdict
healthy. Independent corroboration that nothing overlapped: every temp was
`main.shada.tmp.a`. nvim picks the first *free* letter, so `.b`/`.c` never
appearing means no writer ever coexisted with another.

**But S2b was not exercised.** There was no lgtm session at 03:00: no "tearing
down" line, zero occurrences of `lgtm` anywhere in the reset's journal, and
`lgtm-run` logged "Nothing to review. Done." at 02:50 and 03:00, so it dispatched
nothing and created no session. With no session to tear down, the *old* code
would have produced an equally clean night. The result re-confirms the S2 walk
and says nothing about the S2b change.

This is the failure mode the roadmap keeps warning about, in a new costume: a
memorable change plus a clean measurement invites the conclusion that the change
caused the cleanliness. The check that catches it is asking whether the change
could have influenced the measurement *at all* — here, whether the code path
even ran.

#### The evidence production could not supply — `test-lgtm-teardown.sh`

Since an lgtm session at 03:00 cannot be scheduled (present 08-04, absent 08-05),
the claim is pinned in a lab instead. The harness extracts the **real** Step 3.4
and runs it against a tmux session literally named `lgtm` on a **private tmux
server** (`tmux -L`), so the extracted code is unmodified yet cannot reach the
user's sessions — the isolation the walk harness lacked when it killed the live
lgtm session.

Two lab findings shaped it. A fresh state dir makes nvim write `main.shada`
*directly*, with no temp, so every measurement would have read zero; the lab now
seeds a real file first, as production always has. And three fast lab nvims often
serialize by luck, so "the old ordering bursts" is too flaky to assert. The
deterministic form of the same claim is used instead: **how many ShaDa writes
does the teardown itself cause?** The `tmux` stub marks the watch log at the
instant `kill-session` is invoked, and writes after that mark are attributable to
the teardown.

| ordering | writes caused by the teardown | max concurrent |
|---|---|---|
| old (teardown before the walk) | **3** | 1 |
| new (Step 3.4, drain first) | **0** | 1 |

The drain reported all three as late writers and every history survived, so this
also exercises the `lgtm-run`-collision path — the one the adversarial review
insisted on and the one production has never hit.

### S4 — The reset verifies its own invariant · `workstation-y3fq` · P1 · done 2026-08-09

Every verification in this epic came from one `inotifywait` started by hand on
2026-08-02 and living in `/run/user/1000/systemd/transient/`. It survived only
because the host had not rebooted in seven days. On the next reboot it would have
vanished, and **its absence looks exactly like a clean night** — an empty log is
what success is supposed to look like.

The obvious fix — declare it as a real unit — was investigated and **rejected on
evidence**. `inotifywait -m` goes deaf when its watched directory is replaced:
measured 2026-08-09 on the same binary the watch runs, the process **stays alive
and healthy-looking**, prints `DELETE_SELF`, never re-watches, and never sees
another event. `Restart=`, `is-active` and the unit's main-pid all keep passing.
That is an instrument which cannot be calibrated, shipped into an epic whose
entire history is instruments lying.

So the reset measures itself instead, and the measurement **has a positive
control**: the walk already counts how many writers it exited, and every graceful
exit must produce at least one temp. Writers exited plus zero observed events
therefore means the instrument is dead, and the report says so loudly instead of
reporting a reassuring `max 1`. A standalone daemon can never do this — on an
idle day it has no expected event count to compare against.

Three placement constraints, each of which was nearly got wrong:

- It starts **inside the destructive tail**, after the setsid/scope re-exec. Any
  earlier and a manual run launched from a serve cgroup loses its watcher to the
  pool restart mid-reset and under-reports its own concurrency — a false PASS.
- It reports **after the socket reap**, which is outside the region
  `test-lgtm-teardown.sh` extracts and executes; inside it, that harness dies on
  an unbound `nvim_exited`. The boundary is now pinned by a guard in the harness.
- It hooks the **existing** `cleanup_trap` rather than installing its own EXIT
  trap. Bash keeps only the last trap per signal, so a second one would have
  silently disabled the sentinel's failure reporting.

A host-scope premise was also wrong and worth recording: this was scoped
"cloudbox only, where the nightly reset runs". **Devbox runs the identical
nightly reset** (`hosts/devbox/configuration.nix`). Living in the shared package
covers both hosts; a cloudbox-only daemon would have left devbox armed with the
same storm mechanism and no instrumentation at all.

`test-shada-report.sh` calibrates the counter against event streams whose answer
is known by construction — a 3-writer burst reads 3 and is flagged BROKEN, the
same six events interleaved read 1, writers-with-no-events reads UNKNOWN, and a
genuinely quiet run does not cry wolf. It deliberately does **not** race real
nvims: that was measured and rejected, because three lab nvims serialize by luck
more often than not, so a race-based test would be flaky in the direction that
matters — passing when it should fail.

#### Baseline the retired watch leaves behind

Final aggregate from `~/.local/state/shada-watch.log` before retirement, the only
record of the corruption era:

| night | temps | max concurrent | |
|---|---|---|---|
| 2026-08-03 | 3 | **2** | pre-S2 |
| 2026-08-04 | 15 | **3** | S2 walk clean; the lgtm teardown burst |
| 2026-08-05 | 9 | 1 | |
| 2026-08-06 | 15 | 1 | |
| 2026-08-07 | 12 | 1 | |
| 2026-08-08 | 9 | 1 | |
| 2026-08-09 | 8 | 1 | |

Five consecutive clean nights, 8–15 writers each. **Caveat that must travel with
this table:** none of those nights exercised the S2b teardown — no lgtm session
existed at 03:00 on any of them — so the improvement from 08-04 to 08-05 belongs
to the walk, not to S2b. S2b's evidence is the lab, not this table.

#### First in-band readout, 2026-08-10 - and the blind spot it exposed

The self-report worked on its first night: `max concurrent shada writers: 1
(invariant holds; 7 temp(s), 7 writer(s) exited)`, with the positive control
satisfied (writers exited *and* events observed, so not `unknown`).

The one-night overlap with the retiring external watch is what made this readout
worth doing. The two instruments agreed exactly on the walk window - 7 temps, max
1 - **but the old watch saw an 8th temp at 03:00:57**, 53 seconds after the
in-band report had closed, during the prune/restart steps.

That is not a wiring bug; it is a scope bug in the measurement. The claim being
made is "max concurrent == 1 across the **whole** reset", and Steps 4-6 were
outside the window. A measurement that stops before the run does cannot
substantiate a claim about the run. The report now runs at the very end, just
before `FINISHED=1`, so the prune, the pool restart and the session launch are
all inside it.

Had the old watch been retired on schedule - as the plan said - this gap would
have shipped invisibly, and the nightly line would have kept saying "invariant
holds" about two thirds of the reset. Keeping the outgoing instrument alive for
one night of overlap is what caught it.

### S3 — Upstream report to neovim · `workstation-z9i3` · P3 · optional, last

Two upstream defects: the unnecessary `os_remove(to)` before `os_rename`
(`fileio.c:2692` — rename(2) is already atomic on Linux), and the `nomerge`
fallback (`shada.c:2711-2727`) that converts a transient open failure into a
non-atomic overwrite of the real path.

**Be precise or lose the maintainer on the first read:** only the **ENOENT** case
is silent; other errnos do emit `E886`. ENOENT is exactly the window case, so the
mechanism stands — but do not claim "no message" generally.

Needs a minimal reproducer outside our setup (two headless nvims exiting
simultaneously against one shada path, in a loop). Re-verify line numbers against
master; check for an existing issue first.

---

## Status log

| Date | Event |
|---|---|
| 2026-08-01 03:00:04 | Corruption written (header timestamp, pid 822121). Variant (a) vs (b) unresolved — see causal chain |
| 2026-08-02 ~13:24 | Corrupt file quarantined, parseable temp promoted, warnings gone |
| 2026-08-02 | `8ff0790` deployed — recovery only |
| 2026-08-02 | Review killed the racing-temps hypothesis; direct-write mechanism verified |
| 2026-08-02 17:56 | S0 watch armed and control-verified |
| 2026-08-02 | Revision 2: review of this doc found 4 HIGH defects pre-merge; fixed |
| 2026-08-02 22:29 | **S1 done** — `#261` merged and deployed. Probe replaced with a write-path oracle; three-state verdict; reap gated. Review found a 5th defect (unconditional reap) and 2 bugs in the fix's own design |
| 2026-08-02 22:4x | S1 side effect: promotion is now atomic, so Step 3.5 no longer produces the S0 smoking-gun signature — the 03:00 false positive is retired |
| 2026-08-03 03:00:04 | First reset under the S1 code. Step 3.5 silent = healthy verdict, nothing to reap (verified against the log and the directory) |
| 2026-08-04 03:00 | **S2 verified, and incomplete.** Walk invariant holds in production: **max concurrent writers = 1** across 7 writers, "7 exited gracefully, 0 SIGKILLed". History accumulated (44138 → 44486 bytes). But a **3-writer burst at 03:00:03**, two seconds earlier, from Step 1.5's `tmux kill-session -t =lgtm` — same mechanism, outside S2's scope. `zv0l` closed, **`n0yh.1` (S2b) opened** |
| 2026-08-04 11:00 | **S2b fixed.** lgtm teardown moved from the interactive head to **Step 3.4** in the destructive tail, after the walk + sweep. Manifest-leak worry disproved (allowlist is `=main`-only). Added a **serialized drain** before it, because `lgtm-run.timer` (`*:0/10`) fires at 03:00:00 and dispatches fresh nvims mid-reset — measured starting 03:00:03.461, 113ms before the teardown. Abort now leaves lgtm alive (destruction moved behind the `[y/N]` gate). Harness bug found the hard way: it executed the extracted Step 3.4 against the **real** tmux server and killed the live lgtm session; extraction boundary + a no-`tmux` guard added. 156 static assertions, walk harness green. Awaiting the 03:00 readout |
| 2026-08-05 03:00 | **S2b readout: clean, but a NULL TEST.** Whole-window max concurrent = **1** (9 temps, all `.tmp.a`, 9/9 graceful) — but **no lgtm session existed** at 03:00 (`lgtm-run`: "Nothing to review"), so the teardown never ran and the old code would have looked identical. Re-confirms S2, proves nothing about S2b. Evidence supplied instead by a new lab harness `test-lgtm-teardown.sh` (real Step 3.4, private `tmux -L` server): teardown causes **3 writes old vs 0 new**, drain exercised, histories accumulated. `n0yh.1` closed |
| 2026-08-09 22:40 | **S4: the instrument moves in-band.** The hand-started inotify watch was one reboot from vanishing, and a declared daemon was rejected on evidence — `inotifywait -m` goes **deaf on dir replace while staying alive and healthy-looking**, so no `Restart=`/liveness check can catch it. The reset now measures its own max-concurrent every night on **both hosts** (devbox runs the same reset — the cloudbox-only premise was wrong), with the walk's exit count as a positive control so a dead instrument reports UNKNOWN instead of `max 1`. Calibrated by `test-shada-report.sh`. Transient watch retired, 5-night baseline preserved above |
| 2026-08-10 03:20 | **First in-band readout + measurement-window fix.** Report worked: max concurrent 1 (7 temps, 7 writers). Cross-check against the retiring watch agreed on the walk window but revealed an 8th write at **03:00:57**, past the report's close - Steps 4-6 were unmeasured. Report moved to end-of-run; a guard now pins it past the pool restart. Old watch **not** retired: it earned another night. Also fixed a latent flake in test-lgtm-teardown.sh (killing the lab tmux server's only session races its shutdown) |
| 2026-08-03 16:34 | **S2 shipped** — `#268` merged and deployed (`.#cloudbox`; `~/.nix-profile/bin/reset-workspace` verified to contain the walk). SIGTERM by pid, not the planned socket walk — measurement killed that plan. Discovered **merge-at-write**, so S2 also *restores* the history the burst destroyed. Test suite 133 → 150, plus a behavioural test that runs the extracted walk. **Verification still owed: one observed night** |
| 2026-08-03 09:00 | **S0 read out, `t032` closed.** No direct writers (0 `CREATE`/`MODIFY` on `main.shada` in 326 events). Storm confirmed: **3 concurrent writers, 3 unlink windows in one second**. S2 proceeds per the pre-registered rule |
