---
name: attributing-causes
description: Use when attributing a failure or unexpected state to a cause, especially when a memorable recent event (a deploy, a nightly job, a restart, a merge) is the obvious suspect. Also use when acting on someone else's incident report, before authorizing a destructive action based on a described state, or before trusting a metric/instrument to attribute with — what entity it measures, whether one sample can answer the question, and whether it is even aimed at a subject the suspect could appear in.
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

## When the cheap checks come back "plausible"

Every instrument in that table is **static**. Each one asks whether a causal
path *could* exist, and each one is decisive only when the answer is *no*.

That makes them powerless in the case where the suspect genuinely touches the
subsystem — which is also the case where you most want help. Worse than
powerless: run all four against a suspect that does have a path, and they
return "yes, yes, yes, yes." You have not been told "keep looking." You have
been handed four counts of confirmation, and the story you arrived with now
feels measured.

**A "plausible" result is not a finding. It is the point at which static
checks are exhausted.** When you reach it, stop reasoning about mechanism and
escalate to a *dynamic* instrument.

### The control run: reproduce at the suspect's parent

The single highest-yield move, and the one almost nobody makes first:

```bash
git worktree add --detach "$(mktemp -d)" <suspect>^   # parent of the accused
# ...run the failing thing there...
```

If the symptom reproduces at the parent, the suspect is acquitted outright —
no mechanism argument required. If it does not, you have a real signal instead
of a plausible one.

This is cheap, decisive, and it terminates the "could X plausibly cause Y?"
spiral that plausibility invites. It also frequently does double duty: the run
that acquits the commit is often the same run that convicts the real cause, by
showing the symptom living somewhere the suspect never reached.

### Stack traces date the tree

A stack trace is not merely a location. It is a **fingerprint of the source as
it existed at the moment it ran**, and it can be diffed against a suspect
commit for free.

If your trace points at `foo.ex:3042` and the accused commit moved that
function to `:3119`, your tree *predates the commit you are blaming* — and the
trace you have been staring at said so the whole time.

```bash
git show <suspect>^:path/to/foo.ex | sed -n '3040,3045p'   # what was there
git show <suspect>:path/to/foo.ex  | sed -n '3117,3122p'   # what is there now
```

Line numbers are evidence. Read them.

## Worked example: when the suspect had no causal path

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

A count of stale production resources was reported, relayed, and inherited
without anyone re-measuring it. A destructive production action was authorized
against that count. The free read-only sweep that would have grounded it ran
*after* the deletes had already executed — and the stand-down, once the sweep
landed, arrived too late to stop them.

The outcome was benign: the deleted resources were genuinely stale and matched
the intended recipe, and the one that did not match was correctly left alone.
The failure was in the process, not the result. That is exactly why it is worth
recording — a near-miss that is honestly described gets learned from, and one
that is inflated gets discounted.

**The sharpened rule: verification must precede authorization, not merely
accompany it.** Once a destructive action has been authorized on an inherited
number, a later correction is racing execution, and it can lose. *A retraction
is not a control.* Treat "I'll double-check while that runs" as equivalent to
not checking at all.

There is a second, quieter lesson in the same episode. The sweep measured the
count correctly — and then *guessed* at why it differed from the report
("cleaned up, or the report was stale"), publishing the guess as a
parenthetical. The real answer was that a peer had deleted two of them fifteen
minutes earlier, which was knowable by asking. Measuring a number and then
inventing the story for why it moved is this same failure one level up, and it
is easy to commit while believing you are being rigorous.

## Worked example: when every cheap check convicts the wrong commit

Four Postgres `40P01 deadlock_detected` failures appeared in one app's ingest
test suite. The obvious suspect was the commit that had just landed *in that
same app, touching that same ingest write path*.

Run the static table against it and every instrument agrees:

| Check | Result |
|---|---|
| Does it reference the subsystem? | **Yes** — same app, same module |
| Did it touch files in the window? | **Yes** — +171/−51 in the very file |
| Does the timeline fit? | **Yes** — landed just before |
| Is the state a ghost? | **No** — failures were real and reproducible |

Four for four. The headline test did not merely fail to exonerate; it
*convicted*. Two days went into reasoning about mechanism from that footing.

What actually settled it was one control run at the suspect's parent, which
reproduced the identical deadlock signature **pre**-suspect. That single run
acquitted the commit and convicted the real cause at once: a config in which
the test database name interpolated an unset partition variable, so *every
worktree on the box shared one database*. Ecto's sandbox isolates within a run
and does nothing across OS processes, so two suites running concurrently
contended on real rows. A longstanding latent defect, nothing recent.

The trace had also been saying so for two days. It pointed at
`socket_client.ex:3042`; the suspect commit had shifted that function to
`:3119` — a 77-line displacement matching the file's growth exactly. The tree
that produced the trace predated the commit under suspicion, and that was
free to check.

### Two failures of sequencing, not of knowledge

Both errors in that investigation are worth naming, because neither was
ignorance:

1. **The correct hypothesis was reached first, then argued away.** A
   shared-box explanation was considered early and discarded on a parsimony
   argument — it seemed like too much coincidence. Parsimony is a tie-breaker
   between hypotheses you cannot test, not a reason to skip a test you can
   run in a minute.
2. **A serial green run was accepted as exoneration of a concurrency
   hypothesis.** If the proposed mechanism is "two things running at once,"
   then one thing running alone cannot falsify it. *Match the control to the
   hypothesis*: a concurrency claim needs a concurrent control.

The first error delayed the answer; the second actively pointed away from it.
Both are sequencing failures, which is this skill's real subject.

## Before you trust a number: what does the instrument measure?

Every rule above assumes your measurements answer the question you are asking.
Most of the expensive attribution failures in this repo did not come from bad
reasoning over good numbers — they came from good reasoning over a number that
described something adjacent. These fail *quietly*, because the output stays
plausible.

**Ask three questions of any number before attributing with it.**

**1. What entity does it describe?** Two numbers in the same row can have
different subjects. A serve-memory sampler read `threads`/`fds`/`rss` from
`/proc/<MainPID>` but `anon`/`swap`/`pagetables` from the **cgroup**, which
spans every child process. That produced a confident headline — "28 GiB
allocated without opening a single thread or fd" — that was true of the *main
process only*. The memory was in child processes the whole time; the conclusion
survived two sessions and sent a third looking at the wrong subsystem. If a
comparison crosses two scopes, it is not a comparison.

**2. Is one sample enough?** A wait-channel read (`/proc/<pid>/wchan`) tells you
where a thread is *right now*. Sampled once on a **healthy** process it returns
`0` or `do_epoll_wait` depending purely on when you looked — four of five
healthy samples are indistinguishable from a hung one caught mid-sleep. The
discriminator was never the value; it was whether the value ever *changes*
across a window. When a quantity oscillates, a snapshot is not weak evidence, it
is misleading evidence.

**3. Is it derived, and from what constant?** A forensics dump reported a CPU
split over a hardcoded `interval=2s` while the real elapsed time was 2.11 s. A
wrong *label* misreports a raw number; a wrong **divisor** silently scales a
derived one, and the result stays plausible — which is exactly what lets it
survive review. Emit measured intervals, not asserted ones.

### The failure mode upstream of all three: a correct instrument, aimed wrong

The three above fail at the point of **measurement**, so a careful check of the
measurement can catch them. There is a worse one that cannot be caught that way.

A serve-monitoring doc listed "port the JS-stack profiler to this host" as a
known gap. The gap was real. The instrument would have been built correctly and
would have produced clean, confident output. It would also have profiled the
**main process**, when the memory under investigation lived in *child*
processes — so it would have answered a real question that was not the one being
asked. Nothing in the doing of it would have felt wrong.

This fails at the point of **aim**, upstream of any check you would think to run
on the result. The only defence is to state what the instrument observes and
confirm the suspect can *appear* there — before building or running it. Catching
this particular case required already knowing the answer, which is why leaving
it listed as an open gap was worse than never documenting it at all.

### Predict the direction of a mismatch, not just its existence

When two scopes measure related things, "these will differ" is unfalsifiable and
will not protect you under time pressure. Predict the **sign**:

> The compacted DB file will land near *old size minus freelist bytes*. Filesystem
> free space will read **lower**, because other writers consume it concurrently
> and the WAL/shm are separate files.

Now a number in the wrong direction is a stop-and-re-measure signal instead of
something to shrug at with the pool down. Writing that prediction down also
tends to expose stale inputs: in this case it surfaced that the freelist count
being relied on was days old and drifting *directionally*, since the database had
been taking writes the entire time. A specific number looks authoritative
precisely *because* it is specific.

## Rules

1. **Name the causal path before accusing.** "The reset broke my context"
   requires the reset to be able to touch that context. If you cannot state the
   mechanism, you do not have a hypothesis — you have a coincidence.
2. **Distinguish what a thing kills from what it can reach.** A process
   teardown kills *local* processes; it does not reach remote state. "My client
   died" and "the remote resource died" are different claims with different
   blast radii, and conflating them sends investigations to the wrong system.
3. **Re-measure any inherited count, age or inventory *before authorizing* an
   action on it — not in parallel with it.** Numbers in a report are snapshots
   that decay silently, and a correction issued after authorization is racing
   execution. Size the problem off a fresh query, never a remembered one. A
   retraction is not a control.
   And when the fresh number disagrees with the report, *measure the
   discrepancy too* — ask who changed it, check the events — rather than
   attaching a plausible story to it. A guessed explanation for a real
   measurement is still a guess.
4. **Correlation with a memorable event is the weakest possible evidence**,
   precisely because memorable events correlate with *everything*. Timestamp
   proximity is a prompt to measure, not a finding.
5. **State what would falsify you, then go run it.** If you cannot name a cheap
   check that would prove you wrong, you are not investigating.
6. **Treat "plausible" as the end of static checking, not as a result.** When
   the cheap checks cannot clear a suspect, stop arguing about mechanism and
   run a control at its parent. A suspect that genuinely touches the subsystem
   is exactly the one static instruments cannot resolve — and exactly the one
   they will appear to confirm.
7. **Match the control to the hypothesis.** A serial run cannot falsify a
   concurrency claim; a single-tenant run cannot falsify a shared-resource
   claim. A green control that could not have gone red proves nothing, and it
   is worse than no control because it feels like evidence.
8. **Read the line numbers.** A stack trace fingerprints the source that
   produced it. If the accused commit moved the code the trace points at, the
   trace is telling you which side of that commit your tree is on.
9. **Say what the instrument observes before you trust what it reports.** Name
   the entity (which process? which cgroup?), whether one sample can answer the
   question, and any constant the number is derived through. Two numbers in one
   row can have different subjects.
10. **Check the aim before the reading.** Confirm the suspect could *appear* in
    what the instrument observes. An instrument built correctly and pointed at
    the wrong subject produces confident output and fails no check you would run
    on the output itself.

## When someone hands you a diagnosis

Incident reports arrive with the causal story already attached, usually from
someone closer to the system than you. Treat the *symptom* as data and the
*attribution* as a hypothesis. Re-run the cheap checks even when — especially
when — the reporter sounds certain. Two separate confident attributions in a
single incident were overturned this way, both by measurement rather than
argument.

### The unmeasured half of a message travels as far as the measured half

This is the part that is easy to miss, because it does not look like a mistake
while you are making it.

A message can be *mostly* measured and still carry an unmeasured aside — a
parenthetical, a "probably", a plausible reason offered for why two numbers
disagree. That aside is transmitted with exactly the same authority as the
evidence around it, and it inherits the credibility the evidence earned.
Downstream, nobody can tell which half was which. In the episode above, the
guessed half is the half that got acted on, and neither the writer nor the
reader noticed — *precisely because it was parenthetical.*

So the discipline does not end when you have measured the thing you set out to
measure. Mark your unmeasured claims **as** unmeasured, in the same breath, or
go measure them. "I don't know why these disagree" is more useful to a reader
than a reasonable-sounding guess, because it does not spend credibility the
guess has not earned.

### Some discrepancies are only resolvable socially

Not every gap closes with a command. When your measurement disagrees with
someone else's, the explanation may live entirely in what another party did and
has not yet said — a delete they ran fifteen minutes ago, a config they
repointed, a service they restarted. No query you can run alone will surface
it.

That makes proactive disclosure load-bearing infrastructure rather than good
manners: in a system with several actors, the norm of volunteering "I changed
this" is often the *only* mechanism by which two inventories can be reconciled
instead of quietly diverging. Say what you changed, unprompted. And when a
number disagrees with a report, consider that the missing measurement may be a
question addressed to a person.

Being wrong about the cause is normal and cheap. Acting on a wrong cause is
neither.
