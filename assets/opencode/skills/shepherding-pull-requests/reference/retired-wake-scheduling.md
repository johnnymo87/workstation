# Retired: self-scheduled wakes for PRs

**This describes a mechanism that no longer exists. Do not schedule wakes for a PR.**
`lgtm-shepherd` replaced it: a systemd timer that sweeps open PRs every 10 minutes and either
wakes the authoring session (`needs_reply` / `ci_red` / `conflicted`) or Telegrams the human
(`landable` / `idle`). Its design and rationale live in the lgtm repo:
`docs/plans/2026-08-21-author-side-shepherd-design.md`.

Kept because the cost model is the reusable part: self-scheduled wakes backed off
15m -> 45m -> 2h -> 4h and ran all night, paying a cold turn per check to nearly always learn
nothing had changed. A poll costs roughly a prompt-cache read; a cold wake costs roughly a full
cache write; break-even is around twelve minutes. That arithmetic is why the tight 60-second loop
is still correct while CI is moving, and why neither polling nor self-waking is correct once the
only thing outstanding is a human reviewer.

## Contents

- The watchdog: backoff schedule, exit-code branching, cancel-and-reschedule
- Wake payload requirements
- Mistakes that only applied to self-scheduled wakes

### The watchdog: what to do when the only thing left is waiting

Exit conditions unmet, CI green, nothing to fix, no reviewer yet. Do **not** keep the 60-second loop running for hours. Schedule a wake, end the turn, and let the wake bring you back.

**Why the cutover happens exactly at CI-green.** A poll costs roughly a prompt-cache read per minute; a cold wake costs roughly a full cache write. Break-even is around twelve minutes. A wait you expect to measure in a minute or two (CI finishing, a push settling) should be polled through — the cache is warm and re-reading is nearly free. A wait measured in tens of minutes or hours (a human reviewer's queue) should be slept through, because polling it re-pays the read a hundred times to learn nothing.

**Backoff schedule.** Each successive wake for the same PR waits longer, then caps:

| Wake | Delay |
|---|---|
| 1st | 15m |
| 2nd | 45m |
| 3rd | 2h |
| 4th and after | 4h (cap) |

**Before you act on a wake, make sure another one is already queued.** The wake that woke you is spent — it is marked delivered the moment it lands, and nothing redelivers it. So from the instant you begin working, the PR is protected by nothing at all, and a context death or a serve restart mid-fix abandons it silently. That mid-response stall is the *original* failure this watchdog exists to prevent; a watchdog that guards only the idle state and not the working state has fixed the easy half.

So the order on every wake is: **schedule the next wake first, then do the work, then cancel-and-replace when you know the outcome.** A safety net you have to survive the fall to deploy is not a safety net.

**Then run one pass and branch on the exit code:**

```bash
python ~/.config/opencode/skills/shepherding-pull-requests/monitor-pr.py --once <PR>
```

| Exit | Meaning | Action |
|---|---|---|
| `0` | Exit conditions met | The PR is *landable*, which is not the same as landed — confirm with `gh pr view <n> --json state,mergedAt`. Once it is genuinely terminal, **cancel any pending wake** (see below) and report. If it is approved but not yet merged, that is still an open PR: keep the watchdog running until it actually lands. |
| `1` | Action needed | Do step 5 — fix, reply and resolve every thread, push, re-request if the latest non-bot review is non-APPROVED. Then **return to the tight 60-second loop and reset the backoff to step 1.** Your push restarted CI, so something is moving again and the loop is the right instrument; re-enter the watchdog when CI is green and you are idle once more. |
| `2` | Unrecoverable error, **or the PR was closed without merging** | Tell the user — this is not something to retry your way out of. Keep the safety-net wake queued unless the cause is terminal: a closed PR is terminal (cancel), but a `gh` timeout or a rate limit at hour six is not, and cancelling on it converts a transient blip into a silently abandoned PR. |
| `3` | Idle, CI settled — genuinely waiting on a reviewer | Reschedule at the **next** backoff step. |
| `4` | Idle, but CI is still moving | Do **not** back off. Return to the tight 60-second loop; CI churn resolves in minutes, and the warm cache is what pays for watching it. |

**Keep exactly one wake outstanding per PR: cancel before you reschedule.** Rescheduling without cancelling leaves the old wake queued too, and the duplicates compound every cycle until a single PR is waking you on four different timers with four different backoff steps in their payloads, each disagreeing about which step is current. One wake per PR means the most recently scheduled one is always authoritative.

**Handle the wake idempotently: verify, then act or no-op.** A duplicate can still reach you — a peer session may be shepherding the same branch, or a cancel may have raced a delivery. Always re-read current state before acting; never act on what the payload asserts. An agent that trusts the payload instead of checking will re-request a reviewer who already approved, which is exactly the noise the "don't re-request after APPROVED" rule exists to prevent.

**Cancel the wake on any terminal state. This is correctness, not tidiness.** When the PR merges, the branch's worktree becomes a cleanup target — the nightly reset prunes merged worktrees. A wake still queued against that session then fires into a working directory that no longer exists, and **that failure is silent**: the daemon accepts the message, records it as delivered, injects it into the transcript, and the turn then produces nothing at all — no output, no tool call, no error, and nobody is alerted (`pigeon-s9d` in `scheduling-wakes`). You do not find out. Cancel before you consider the PR finished:

```
swarm_scheduled(action: "list")     # match on ref: "pr:<owner>/<repo>#<n>"
swarm_scheduled(action: "cancel", msg_id: "<id>")
```

Match on the `ref` you set when scheduling — that is what makes this unambiguous when several PRs are in flight at once, and it is why the `ref` is worth setting. Cancel *every* match, not just the first. An empty list is a success, not a missed step: the wake that woke you is already delivered and needs no cancelling.

Terminal means merged, closed, or the user explicitly telling you to stop. It does **not** mean "approved", and it does not mean you escalated to the user — reporting that a PR is stuck leaves it your problem until it lands.

**Refresh a PR that is going stale.** The clock that matters is the PR's own `updatedAt`, not how long you have been waiting — read it, don't estimate it:

```bash
gh pr view <n> --json updatedAt -q .updatedAt
```

If that timestamp is roughly 20 hours old and there is **no review at all**, re-request the reviewer to bump it. This applies to lgtm-bound PRs specifically — it exists to beat the dispatcher's staleness cutoff, and on a repo with no such dispatcher it is just an unexplained 20-hour ping at a human. The review funnel drops PRs idle beyond 24 hours, permanently and silently: nothing errors, no component reports unhealthy, the PR simply stops being a candidate and waits forever. A single re-request resets the clock. Skip this once any non-bot review exists — then you are waiting on a verdict, not on discovery.

**Escalate out loud at the cap — but do not stop watching.** The steps are cumulative, so reaching the 4h cap means roughly seven hours of waiting have already passed. At that point post a top-level comment on the PR summarising what is outstanding, and tell the user. Then **keep waking at the 4h cadence.**

The escalation is the *report*, not the stopping. Handing the PR back silently and letting the timer lapse is the abandonment this skill exists to prevent; a reviewer who is simply asleep is the ordinary case, not an error, and a PR opened in the evening will routinely sit longer than seven hours through no fault of anyone. Only a terminal state, or the user telling you to stop, ends the watchdog.

**Make the wake payload self-contained, but carry facts in it rather than procedure.** Per the `scheduling-wakes` skill, the session that receives it may have compacted away everything about why it exists, so it needs the PR URL, repo, branch, worktree path, backoff step, and a timestamp. It does *not* need the branch table — that is on disk at a stable path, and restating it means maintaining it in two places where the copies drift. That is exactly how an earlier draft of this section ended up telling the agent to sleep on exit 1 in the payload while the table said to keep polling.

Name the worktree, but do not let the payload *depend* on it: give the repo root and branch too, so a woken session whose worktree was pruned can still re-establish where it is.

**State the facts as counts with the query that produced them, never as a bare assertion.** "Unresolved threads exist" is unfalsifiable on arrival; `unresolved=0 of 0` plus the command that measured it can be checked in a single call, and — the part that matters — a zero cannot be quietly narrated as a non-zero. This is the difference between a payload the woken session can audit and one it can only obey.

**That applies with more force to any message you send another session**, where the requirement is not a format but a prohibition: **do not assert that work exists unless you ran a command that says so, and quote it.** A wake is a note to yourself and its worst case is wasted effort; a `task.assign` telling a *peer* that a PR has unanswered comments commits someone else to acting on your claim.

This is measured, not hypothetical. A session dispatched seven such messages while querying only `--json number,title,headRefName,state,mergeStateStatus,reviewDecision,autoMergeRequest` — no comments field, no `reviewThreads`, and not one `gh api ... comments` call in the whole session. Two of the seven PRs had never received a single review comment. It went undetected because it was right five times out of seven **by base rate** — most reviewed PRs do have comments — so it read as a working feature rather than an unfetched guess. All seven had zero unresolved threads, so even the "correct" dispatches asked for work already discharged. See `swarm-messaging` §"Never assert a checkable fact you did not fetch".

```
swarm_schedule(
  after: "15m",
  ref: "pr:<owner>/<repo>#<n>",
  expires_in: "24h",
  message: "Resume shepherding <owner>/<repo>#<n> — <url>.
            Worktree <abs path> (if pruned: repo root <repo path>, branch <branch>).
            Follow the `shepherding-pull-requests` skill, section 'The watchdog';
            start by running monitor-pr.py --once <n> and branch on the exit code.
            Backoff step 1 of 4 (next step: 45m).
            State when scheduled (<timestamp>, verify before trusting):
            CI green; reviewThreads unresolved=0 of 0; reviews=0; lgtm-bound <auto value>.
            Premise check: gh pr view <n> --json state,reviewDecision,statusCheckRollup"
)
```

Set `expires_in` generously. A wake defaults to expiring six hours after its delivery time, and a serve that is wedged for longer than that drops it with nothing left queued — the cap cadence alone can exceed the default.


## Mistakes that only applied to self-scheduled wakes

- **Ending the turn without scheduling a wake.** *(Retired. Ending the turn with an explicit state report is now correct: `lgtm-shepherd` watches the PR and tells the user if it stalls. The failure to avoid is no longer stopping — it is stopping **silently**, or implying something will resume the work automatically when only a notification is coming.)* Stopping used to be legitimate only if something would bring you back. Nothing runs between your turns — no timer, no hook, no notification. An unscheduled stop is indistinguishable from abandoning the PR, and it is the failure this skill exists to prevent, reached by a more comfortable route.
- **Leaving a wake scheduled after the PR lands.** The merged branch's worktree gets pruned, and the orphaned wake fires into a directory that no longer exists — where it is accepted, marked delivered, and then does nothing at all, silently. Cancel on every terminal state.
- **Doing the work with nothing queued behind you.** The wake that woke you is already spent. If you start fixing threads without having scheduled the next wake first, a context death mid-fix abandons the PR exactly as if there had been no watchdog — which is the failure the watchdog was built for. Schedule, then act, then cancel-and-replace.
- **Re-invoking `--once` in a loop.** That is the 60-second poll with extra ceremony and a cold cache on every pass — strictly worse than either real option. If you are awake and still idle, reschedule and stop. If you expect an answer within a minute or two, use the normal loop.
