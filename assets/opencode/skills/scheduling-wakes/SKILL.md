---
name: scheduling-wakes
description: Use when you are about to end a turn with something still owed to the future and would need swarm_schedule to return to it — "check the deploy after the 09:00 run", "revisit once CI finishes", "the rate limit clears in 4h", "verify this tomorrow". Also use when a scheduled wake arrives (an envelope carrying scheduled_for or delivered_late_ms) and you need to know what it can and cannot be trusted to mean, when your work is gated on someone else's item, or when a claim in an already-queued payload turns out to be wrong.
---

# Scheduling Wakes

You cannot remember to do something later. When your turn ends, nothing runs
until someone prompts you again. A wake is the only mechanism that brings you
back on your own initiative.

`swarm_schedule` delivers a message to a session at a future time. `to`
defaults to the calling session, so the dominant case — waking *yourself* —
needs no target.

## The imperative

**If you are ending a turn on a future checkpoint, schedule the wake before you
stop.**

"I'll check the prod cron after the 09:00 run" is not a plan unless a wake
exists. Writing the intention in a summary, a bead, or a commit message does
not schedule anything. Neither does the user remembering. If the next step is
blocked only by the passage of time, that is precisely what this is for.

```
swarm_schedule(after: "13h", ref: "bd:pigeon-4yz",
  message: "Resume pigeon-4yz: run bd show pigeon-4yz, then verify the 09:00 cron in ~/projects/foo.")
```

Delivery is durable, not a timer. The row lives in the daemon's SQLite and is
polled, so it survives daemon restarts, the nightly 03:00 reset, and reboots.
Measured, not hoped for: a wake scheduled at 21:30 was delivered at 09:00 the
next morning, 119ms late, by a daemon process that had been restarted at 03:00
— a different process than the one that accepted it.

## Arguments worth knowing

- **Prefer `after`** (`"30s"`, `"30m"`, `"13h"`, `"2d"`) — unambiguous, no
  timezone reasoning. `at` requires a *full* RFC3339 timestamp with an offset
  (`"2026-08-02T09:00:00-04:00"` or a `Z`); a bare `"09:00"` is rejected. The
  time must be in the future and within 30 days.
- **Expiry defaults to 6h** after the delivery time; override with
  `expires_in`. A wake that cannot be delivered inside its window expires
  rather than surfacing at some arbitrary later hour, when it may be worse than
  useless.
- **`ref`** is a durable pointer rendered as an envelope attribute — use the
  beads id (`bd:pigeon-4yz`).
- `swarm_scheduled(action: "list")` shows pending (queued) wakes plus terminal
  ones — failed, expired, cancelled — from the **last 24h**. A successfully
  delivered wake does not appear. So within 24h, absence means the wake was
  handed off to your serve, which is delivery in every case except the silent
  directory-deleted failure described below. Past 24h absence is ambiguous:
  search your transcript for the `msg_id` instead.

## Write the payload for a reader with amnesia

Payloads under 40 characters are rejected, but that floor only catches the
worst case. The real rule: **the session that receives the wake may have
compacted away everything about why it was scheduled.** Write for a stranger
who happens to have your tools.

| Write this | Not this |
|---|---|
| "Resume pigeon-c68: run `bd show pigeon-c68`, continue W4 in `.worktrees/wake-w4`." | "continue what you were doing" |
| "PR #35 should be merged by now — check `gh pr view 35`, then start W5 (`bd show pigeon-4yz`)." | "Check on that PR from yesterday and continue the follow-up work we discussed." |

Name a durable pointer: a beads id, a PR number, a file path, a command to run.

Note the second "don't": at 77 characters it clears the length floor easily.
Length is not the rule — a reader with no memory of you is.

## On receipt

- **Check the wall clock yourself.** `delivered_late_ms` measures *delivery*,
  not *processing*. A wake handed off on time but queued behind a two-hour
  blocking turn shows `delivered_late_ms≈0` while actually being read two hours
  late. Compare `scheduled_for` against `date` before acting on anything
  time-sensitive.
- **A wake may arrive twice.** Delivery is at-least-once: the row is only
  marked handed-off after a 2xx, so a crash mid-delivery re-delivers rather
  than drops. At-most-once is not achievable over `prompt_async`. Make the
  action idempotent, or check whether you already did it.
- **Your working directory may be gone.** Session id stable ≠ session
  *environment* stable. The nightly reset runs `work --prune-merged`, which
  removes worktrees that are merged and clean — precisely the state of "PR
  merged, wake me at 09:15 to verify the deploy". Never write a payload that
  depends on the worktree still existing; reference the repo root and the
  branch/PR instead.

  **Today this failure is silent** (`pigeon-s9d`). A wake into a session whose
  directory was deleted is accepted by the daemon, recorded as delivered, and
  injected into the transcript — and then the turn produces nothing at all: no
  output, no tool call, no error, forever. Nobody is alerted. If you scheduled
  a wake and it never seems to have happened, check whether its directory
  survived.

## Restraint

A wake interrupts a future session that has no context for it, so the message
economy in `swarm-messaging` applies more sharply here, not less.

Schedule one when a specific action is genuinely blocked on the passage of
time: a deploy to verify, a nightly job to check, a rate limit to clear. Not to
"check in", not to review your own progress, and never on a recurring cadence.
A wake you would not bother to write a paragraph for is a wake nobody needed.

If the checkpoint gets handled early, cancel it —
`swarm_scheduled(action: "cancel", msg_id: "...")`. Only the original sender
can cancel, and only while it is still queued. An uncancelled wake for work
already done is exactly the pointless interruption this section is about.

## A wake on the dependent does not cover the dependency

**Coverage is a property of the chain, not of the item.** If your work is gated
on someone else's, a trigger on *yours* is worth nothing while *theirs* has
none — your wake fires, finds the gate still shut, and reschedules itself
forever.

The nasty part is the asymmetry. You can audit every item you own, find them all
triggered, and still be blocking someone — because the gap is in *your* bead
while the symptom appears on *theirs*. Neither party can see it from their own
list, and no `bd` query surfaces it: it lives on the dependency edge. In practice
it took two sessions comparing notes to notice.

So when you gate an item on work you do not own:

- Check the **dependency** has its own trigger, not just yours.
- If it does not, the fix belongs on **their** item — a due date, or a word to
  the owner. Tightening the wake on your own item just wakes you to discover
  it is still blocked.
- Write the expectation into your payload ("expect this landed or scheduled by
  now"), so a surprise reads as a signal rather than as normal.

## A queued payload cannot be edited — cancel and reschedule

There is no amend. If a claim in a scheduled message turns out to be wrong, the
only fix is `swarm_scheduled(action: "cancel", msg_id: ...)` followed by a fresh
`swarm_schedule`. Verify the new one is queued and the old one shows
`cancelled`.

**Invert the claim; do not merely delete it.** A payload that silently drops a
retracted inference leaves the underlying *fact* sitting there for the reader to
re-derive the same wrong conclusion from. The retraction has to be reachable
from the fact. If a payload said "this is urgent" and urgency was wrong, the
replacement says **"there is no time pressure, and an earlier version of this
wake said otherwise"** — not nothing.

This matters more for wakes than for ordinary messages, because the recipient
has no context to check the claim against and no sender to ask. A wake payload
is read as settled fact by definition. Be especially wary of forwarding a
conclusion you received pre-reasoned from someone closer to the data: that is
exactly when re-deriving feels redundant, and a wake is the worst place to
launder an unchecked inference into the future.

## Related

- `swarm-messaging` — the envelope, kinds, priority, and the message economy a
  wake is a special case of.
- `resetting-workspace` (workstation repo-local) — what the nightly 03:00 reset
  does to sessions and worktrees, which is what a wake has to survive.
- `attributing-causes` — for the inference-forwarding hazard above: what an
  instrument actually measures, and confirming a conclusion is aimed at the
  question you are asking before you carry it forward.
