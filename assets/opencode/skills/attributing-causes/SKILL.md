---
name: attributing-causes
description: Use when attributing a failure or unexpected state to a cause, especially when a memorable recent event (a deploy, a nightly job, a restart, a merge) is the obvious suspect. Also use when acting on someone else's incident report, or before authorizing a destructive action based on a described state.
---

# Attributing Causes

A memorable event is not evidence. It is a *suspect*.

Deploys, nightly jobs, restarts, merges and reboots are memorable because they
are discrete, timestamped and disruptive. That makes them the first thing
anyone reaches for when something is broken — and it makes them the most
over-convicted causes in any system. The story is plausible, it arrives
pre-formed, and it feels like an explanation.

## The one-line test

**Before blaming X for a state, check whether X could reach that state at all.**

Most false attributions die instantly on this question, because the suspect has
no causal path to the symptom. It is cheaper than any other diagnostic step and
it is almost never run first.

## Why this needs to be a discipline

The failure is not ignorance, it is *sequencing*. The story arrives before the
measurement, and once you hold a plausible cause, subsequent evidence gets
read as confirmation. The expensive part is resisting the story — the evidence
itself is usually seconds away:

| Question | Cost | What it settles |
|---|---|---|
| Does the accused component even reference the subsystem? | one `grep` | Whether a causal path exists |
| Did it touch the files during the window? | one `find -newermt A ! -newermt B` | Whether it acted at all |
| When was the state actually last modified? | one `stat` / `mtime` | Whether the timeline supports the story |
| Does the described state still exist? | one read-only query | Whether you are debugging a ghost |

If the check costs seconds and the conclusion drives an irreversible action,
there is no excuse for skipping it.

## Worked example

A session reported that the 03:00 nightly workspace reset had **killed its
production pods** and **broken its kube context**. Both were plausible: the
reset is disruptive, it runs unattended, and the symptoms appeared "after" it.

Four cheap measurements refuted the whole story:

1. **`grep`** — the reset script contained *zero* references to the subsystem.
   No causal path. This alone was sufficient.
2. **`find -newermt` across the reset window** — it modified nothing in the
   relevant directory.
3. **`stat`** — the config's mtime was *four hours before* the reset. The
   timeline never supported the story.
4. **A read-only query** — the "killed" resources were still running, and had
   survived two such resets.

The real cause was a *different session* mutating shared global state, with a
timestamp hours earlier. The reset was simply the most memorable thing that had
happened in between, so it absorbed the blame.

### What it cost to skip the check

A destructive production action was authorized against resources that a
free read-only query would have shown no longer existed. The inventory in the
report ("four, and growing") had been carried forward from memory rather than
re-measured; the true count was one.

## Rules

1. **Name the causal path before accusing.** "The reset broke my context"
   requires the reset to be able to touch that context. If you cannot state the
   mechanism, you do not have a hypothesis — you have a coincidence.
2. **Distinguish what a thing kills from what it can reach.** A process
   teardown kills *local* processes; it does not reach remote state. "My client
   died" and "the remote resource died" are different claims with different
   blast radii, and conflating them sends investigations to the wrong system.
3. **Re-measure any inherited count, age or inventory before acting on it.**
   Numbers in a report are snapshots that decay silently. Size the problem off
   a fresh query, never a remembered one — especially before a destructive
   action.
4. **Correlation with a memorable event is the weakest possible evidence**,
   precisely because memorable events correlate with *everything*. Timestamp
   proximity is a prompt to measure, not a finding.
5. **State what would falsify you, then go run it.** If you cannot name a cheap
   check that would prove you wrong, you are not investigating.

## When someone hands you a diagnosis

Incident reports arrive with the causal story already attached, usually from
someone closer to the system than you. Treat the *symptom* as data and the
*attribution* as a hypothesis. Re-run the cheap checks even when — especially
when — the reporter sounds certain. Two separate confident attributions in a
single incident were overturned this way, both by measurement rather than
argument.

Being wrong about the cause is normal and cheap. Acting on a wrong cause is
neither.
