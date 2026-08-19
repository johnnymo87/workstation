# PR Watchdog: replacing the long poll with self-scheduled wakes

**Date:** 2026-08-19
**Status:** approved, not yet implemented
**Scope:** `assets/opencode/skills/shepherding-pull-requests/` (SKILL.md + `monitor-pr.py`). No changes to the review daemon, no changes to the message bus.

## Problem

PRs languish in partially-complete states. A review lands, some inline threads get
answered, work stops, and nobody comes back. The authoring session was supposed to
shepherd the PR until it landed, but it stalled part-way through responding —
context death, a serve restart mid-turn, or the model deciding it was finished.

There is a second, smaller problem stacked on top: the shepherding loop polls every
60 seconds for the entire life of the PR, including the long, unpredictable wait for
a human review that may be hours away.

## What exists today

The `shepherding-pull-requests` skill runs a monitoring loop. `monitor-pr.py` bundles
roughly 60 seconds of polling into a single bash call and returns an exit code telling
the agent what to do next: `0` done, `1` action needed, `2` unrecoverable, `3` budget
elapsed while idle.

The 60-second budget is deliberate and load-bearing. The prompt cache TTL is five
minutes, so a poll turn every minute keeps the cache warm and costs roughly a cache
*read* of the context. A wake after more than five minutes idle costs a cache *write*.
Taking read ≈ 0.1× and write ≈ 1.25× of context size, **the break-even is roughly
twelve minutes of polling per wake.** Any redesign has to beat that loop, not a
strawman.

## Goals

1. Stop the polling burn across the long wait, without losing the PR.
2. Re-engage a PR whose shepherd stalled part-way through responding to a review.

## Non-goals

- Notifying on CI transitions after the session has gone to sleep.
- Anything that requires changes to the review daemon or the message bus.
- Covering repositories outside the review daemon's scope differently from those
  inside it. The design is identical for both, which is a feature.

## Design

### State machine

The existing 60-second loop is unchanged up to CI-green. It is the right tool for a
short, bounded wait, and it is cache-warm. At CI-green the loop hands off to the
watchdog rather than continuing to poll.

| State at CI-green | Action |
|---|---|
| Exit conditions already met | Done. Nothing scheduled, nothing to cancel. |
| Inline threads outstanding | Reply, resolve, push, re-request if warranted — then hand off. |
| Waiting on a review | Schedule a wake and **end the turn**. |

### Backoff

15m → 45m → 2h → 4h, then cap at 4h.

The first step is sized to the observed CI-green-to-review-landed window, so the
common case is a single wake.

### Wake handler

The handler must be idempotent — verify, act, or no-op — because two wakes can
arrive for the same PR and because a future phase may add an event ping alongside
the timer.

1. Run `monitor-pr.py --once`.
2. Exit `0` → **cancel any pending wake**, report, done.
3. Exit `1` → fix, push, re-request if warranted, reschedule at the current backoff step.
4. Exit `3` → reschedule at the next backoff step.
5. Exit `2` → surface to the user; do not silently reschedule.

### Cancel-on-terminal is mandatory

Not hygiene — a correctness requirement. Without it: the PR merges, the nightly
reset prunes the now-merged worktree, and the orphaned wake fires into a working
directory that no longer exists.

**Correction (found in adversarial review):** an earlier draft of this section said
the bus refuses delivery, burns its retry budget, and marks the message failed.
That is wrong, and wrong in the more dangerous direction. Per `scheduling-wakes`
(`pigeon-s9d`), a wake into a session whose directory was deleted is *accepted* by
the daemon, recorded as delivered, and injected into the transcript — and then the
turn produces nothing at all: no output, no tool call, no error, and no alert.

The conclusion survives and gets stronger. A loud failure would at least be
diagnosable; this one is invisible, and this design would otherwise trigger it on
*every successful PR*.

### Stale refresh

If a wake finds no review at all and the PR has not been updated in roughly 20
hours, take an action that bumps `updatedAt` — re-requesting the reviewer is the
cheapest one that also re-enters the daemon's re-review lane.

Rationale: the daemon's discovery funnel drops PRs whose `updatedAt` is older than
24 hours. A PR that goes quiet for a day is dropped from the funnel permanently and
will never be reviewed, while every individual component reports healthy. The
watchdog would then wake forever against a PR that structurally cannot progress.

This action pings a human, so it is deliberately rate-limited to the stale case and
skipped when an approval already exists.

### Give up

After reaching the 4h cap with no state change, post a top-level status comment on
the PR and hand back to the user. Waking forever is not shepherding.

### Wake payload

Self-contained, per the `scheduling-wakes` skill: PR URL, repository, branch,
worktree path, current backoff step, and the instruction to run `monitor-pr.py --once`.
The session that receives the wake may have compacted away every reason it exists.

### Tooling change

`monitor-pr.py` gains `--once`: a single pass, no internal sleep, same exit-code
contract. The existing budgeted-loop behaviour is unchanged and remains the default.

## Rejected alternatives

These were explored in depth and rejected on evidence. Recorded here so the same
ground is not re-covered.

### Session id in the PR body, pinged by the review daemon

The idea: embed `OPENCODE_SESSION_ID` in the PR description as an HTML comment; the
daemon parses it and pushes a message to that session when something happens.

Rejected because **the ping fires upstream of the failure it was meant to fix.** The
stall happens *after* the review lands, mid-response. A notification at review-arrival
cannot re-engage a session that dies while replying to the third of five threads.

Supporting findings, each verified in source:

- **Three independent prompt templates**, not one — a fresh-review template, a
  re-review template, and an assist template, sharing nothing. An instruction added
  to one is missed by the others. The re-review lane is where the terminal APPROVE
  lands, so a ping added only to the fresh-review template would miss the single
  event the sleeping author is waiting for.
- **The daemon's own instructions tell the reviewer to ask the author to rewrite the
  PR description.** The author complies with `gh pr edit --body` and destroys the
  marker. The daemon manufactures the marker-loss event; the body is the wrong channel.
- **The daemon's prompt states that sessions forget final acts**, verbatim: writing
  the terminal marker is mandatory, and if forgotten "the daemon eventually flags this
  run as lost." There is daemon-side lost-run detection built precisely because misses
  happen, and it explicitly will not re-dispatch — it alerts a human. A ping performed
  as a session's last act inherits that miss rate, and the miss is invisible: the send
  returns 202 regardless, and the delivery-failure bounce is addressed back to a
  dormant session.
- **A cost inversion.** The daemon runs on a 10-minute timer, so every event is
  quantized into 10-minute buckets. Against a 12-minute polling break-even, a single
  ping costs about what polling the whole interval would have cost, and arrives later
  than polling would have noticed it.

### Making the daemon a general PR event notifier (CI red/green + review)

Rejected. Its discovery funnel drops PRs *before* fetching CI status when the author
is not allowlisted, drops PRs whose latest non-bot verdict is APPROVED **or
CHANGES_REQUESTED**, and fails closed on API error. The events most worth notifying
about are precisely the ones that remove the PR from its view. Delivering them would
require a new discovery lane rather than a hook in the existing one.

### Deduplicating pings via a deterministic message id

Rejected. The bus deduplicates on `msg_id` as a primary key with conflict-ignore
semantics, which dedupes on *attempt*, not on *delivery*. A send that fails while the
serve pool is bouncing leaves a failed row that silently swallows every later retry of
the same id for seven days, and the send endpoint returns 202 either way, so the
sender cannot detect it.

## Corrected assumption worth recording

An earlier round of this design assumed the nightly reset destroys sessions, and
concluded that waking a long-idle session was unreliable. **That is false.** The reset
performs no database deletes at all; sessions accumulate indefinitely. The message bus
re-places a pre-restart session onto a fresh healthy serve, and all serves share one
database. Measured: 250 of 367 delivered messages went to sessions created on an
earlier calendar day, 239 of them verified, with a maximum observed gap of 70 days
across roughly 70 nightly resets.

Waking a long-idle session is a routine, proven operation. The real hazard is not a
dead session but a **deleted working directory**, which is why cancel-on-terminal is
mandatory above.

## Risks

| Risk | Mitigation |
|---|---|
| Wake fires into a pruned worktree | Cancel-on-terminal; give-up path posts and stops |
| Two wakes for one PR | Handler is verify-act-or-no-op |
| PR dropped from the review funnel at 24h | Stale refresh at ~20h |
| Watchdog wakes forever | 4h cap, then post status and hand back |
| Stale refresh spams a human reviewer | Only in the stale case, skipped once approved |

## Deferred: Phase 2

An event ping remains available as a latency optimisation if the watchdog's wake
granularity proves annoying in practice. It is not worth building until then, and if
built it requires all three prompt templates, an append-only channel rather than the
PR body, a receiver-side ownership check, and idempotent wakes. The watchdog must
remain fully robust regardless, because the ping's miss rate is non-zero and its
misses are silent.
