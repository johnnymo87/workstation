# lgtm review mechanics

Detail for the two conditional branches in `SKILL.md`: whether a PR is lgtm-bound, and when
lgtm's dispatched reviewer must be re-requested. Both have been got wrong in *both* directions,
which is why the reasoning is preserved rather than compressed to a rule.

## Contents

- Determining whether a PR is lgtm-bound, and the config-shape trap
- The failure asymmetry that decides which way to fail when unsure
- Re-requesting review: who to re-request and who to leave alone
- When lgtm comes back on its own, and when it structurally cannot
- Why `reviewDecision` behaves the way it does, with measured values
- Never use a bot trigger comment

### Once, before the loop: determine if this PR is lgtm-bound

`~/projects/lgtm` runs an AI review daemon on a configured set of repos. If this PR is in scope, you MUST wait for a non-bot reviewer (lgtm dispatches under a real human GitHub identity) to APPROVE before exiting -- CI green + comments resolved is necessary but not sufficient. lgtm typically dispatches within ~10 min of CI going green.

**Two conditions, and repo presence is only the first.** A PR is lgtm-bound iff the repo is listed AND the PR's **author** is admitted. The effective allowlist is `authors ∪ reviewers ∪ repos[R].authors` (plus `onRequestAuthors`, which is admitted only when an lgtm reviewer is explicitly requested). **`reviewers` is in that union** — lgtm treats its reviewer pool as implicitly-trusted authors, since they are already trusted enough to review as. Source of truth is `filterByAuthors` in `lgtm/src/discover.ts`; `monitor-pr.py` implements it, including the back-compat rule that no author config at all means no filtering.

```bash
REPO=<owner>/<repo>; AUTHOR=$(gh pr view <n> --json author --jq .author.login)
grep -qE "^  ${REPO}:" ~/projects/lgtm/lgtm.yml || echo "NOT lgtm-bound (repo not listed)"
# Author admitted? Any of authors / reviewers / repo authors / onRequestAuthors.
# Crude; prefer monitor-pr.py, which parses the sections properly.
grep -qE "^  - ${AUTHOR}$|^      - ${AUTHOR}$" ~/projects/lgtm/lgtm.yml \
  || echo "NOT lgtm-bound (author in no allowlist)"
```

If `~/projects/lgtm/lgtm.yml` doesn't exist on this machine (e.g. devbox), treat the PR as **not lgtm-bound**.

> ⚠ **DO NOT INFER LGTM-BOUNDNESS FROM CONFIG SHAPE — READ `discover.ts`, OR JUST WAIT LONGER.** This warning exists because the author of this very section got it wrong in the expensive direction and nearly shipped the error.
>
> The reasoning went: *"my login appears in `lgtm.yml` only under `reviewers:`, never in an author list, and lgtm is my own daemon so it won't review my own PRs — therefore this PR can never be dispatched and polling is futile."* Structurally plausible, internally consistent, and **false**. `reviewers` is part of the author union, and the daemon dispatched **7 minutes after polling stopped**. The correct action had been to keep waiting; the "finding" was a false positive produced by reading config layout instead of the dispatch code.
>
> **Recognising this trap is not the same as avoiding it** — it reads as familiar, and the familiarity is easy to mistake for having checked. Get the value rather than matching the shape: run `monitor-pr.py`, which prints the detection, or read `filterByAuthors`.
>
> **The generalisable trap: a config file tells you what is configured, not what the program does with it.** `reviewers:` and `authors:` look like disjoint roles and are unioned one function call away. If you need to know whether a daemon will act, read the code that decides, or observe it — do not derive it from key names.
>
> **What survives, and is why the author check is still here:** for an author in *none* of those lists, repo-presence alone is genuinely wrong, and the failure is asymmetric —
>
> | filter wrong | consequence | cost |
> |---|---|---|
> | `paths:` | gate opens for other PRs; you over-wait on this one | **bounded** — user short-circuits |
> | **`authors:`** | gate **never** opens for this author | **unbounded** — waits for an approval that cannot arrive |
>
> A safety argument that holds for a bounded delay and gets silently reused for an unbounded one is its own defect class — which is why the check is worth having even though the case that prompted it turned out not to be an instance.
>
> **Fail toward lgtm-bound (keep waiting) when unsure.** Over-waiting is visible and interruptible; a wrong early exit looks like a decision and silently drops the PR. Note this is the opposite of what an earlier draft of this section said.

Cache the answer in a shell var (e.g. `LGTM_BOUND=yes`) for the loop.


### Re-requesting review

**Re-request real people, and lgtm only where its sweep cannot reach you.** Bots come back on their own and chasing one is wasted motion; lgtm comes back on its own *under a precondition*, and that precondition is checkable in one call.

| Reviewer | Re-request after you push fixes? | Why |
|---|---|---|
| A human colleague whose latest review is `COMMENTED` / `CHANGES_REQUESTED` | **Yes** | Nothing else re-notifies them. Answering a thread does not; a `COMMENTED` review means they are *not* satisfied and they will not know you are ready again. |
| Anyone whose latest review is `APPROVED` | **No** | They signed off. Approval survives later pushes for inline-only fixes. |
| A review bot (`user.type: "Bot"` — Gemini, claude, dependabot) | **No** | They review when the PR opens and have nothing to add on a second pass. |
| **lgtm's dispatched reviewer** (`user.type: "User"`, a pool identity under a real human PAT) | **Depends on whether the head moved, and on `reviewDecision`** — see below | lgtm re-reviews by itself only when **the head has moved** past the one it reviewed *and* GitHub reports `REVIEW_REQUIRED`. If you answered its threads **without pushing**, or the repo never reports `REVIEW_REQUIRED`, re-request once. |

```bash
gh pr edit <n> --repo <owner>/<repo> --add-reviewer <login>
```

#### When lgtm comes back on its own, and when it cannot

Until 2026-09-02 the author *did* have to re-request lgtm, and this section said so. The reason was a structural gap, not a policy: once lgtm posted a review, that PR became invisible to every discovery lane it had. Tier 2 skips anything already dispatched, and tier 0 was populated entirely by `gh search prs user-review-requested:<pool login>` — and posting a review is precisely what *clears* a review request. So the "head changed, always re-review" branch was unreachable for every PR lgtm had ever looked at, and a human re-requesting by hand was the only way back in.

Observed on `mono#4476`: lgtm reviewed one commit at 05:17Z, the author pushed at 08:47Z, and for the next nine hours every cycle logged the PR in scope and then dropped it.

**Tier 0b closes that — on some repos.** lgtm re-reviews a dispatched PR once the head has moved past the one it reviewed *and* threads are clear *and* CI is green *and* GitHub reports `reviewDecision == "REVIEW_REQUIRED"`. Reaching that state is the useful thing you can do for lgtm. **But the fourth condition is not something you can reach; it is a property of the repo.** Check it:

```bash
gh pr view <n> --repo <owner>/<repo> --json reviewDecision -q .reviewDecision
```

- **`REVIEW_REQUIRED` and you pushed** — tier 0b can see you. Do not re-request lgtm. If it has not come back and the other three conditions hold, that is a bug in lgtm worth reporting, not a re-request worth sending.
- **Empty (GitHub's null) or `CHANGES_REQUESTED`** — tier 0b **cannot** see you, and it never will on this PR. Re-request lgtm's login once (the exact login from its most recent review) and stop. This is not the retired chase-the-bot habit coming back; it is the one case the sweep is structurally unable to reach, and the re-request is the only way back in.
- **You answered its threads without pushing** — tier 0b cannot see you either, whatever `reviewDecision` says. Its first gate is "the head moved past the one lgtm reviewed" (`settledRereview.ts`, refusal `head-already-reviewed`), and resolving a thread does not move the head. lgtm has exactly two reawaken inputs for a dispatched PR: a new head, or a review re-request newer than its last review (`discover.ts`, reasons `head-changed` / `review-rerequested`). There is no threads-resolved trigger. So when a pool reviewer left `COMMENTED` on informational threads and the right answer was a reply rather than a code change, re-request that login **once** — it is the designed signal for "I answered; look again", not a nag. The maven-renovate lane does this by construction (`lane-request-review.sh`, once per head), and on 2026-09-14 that was what turned two `COMMENTED` reviews into approvals on `mono#4580` and `#4582`; the same day a session that had internalised "never re-request the pool" flagged it as a violation. It was not.

The line that separates the two, in one sentence: **a push is a signal lgtm already receives; a reply is not.**

Why the field behaves that way: `reviewDecision` is only ever `REVIEW_REQUIRED` when the PR's *base branch* carries a review-required protection rule. Without one, GitHub reports the latest *decisive* review and null when there is none — and a `COMMENTED` review is not a decision. lgtm posts `COMMENTED` when it wants changes without blocking, so on such a repo its own review both clears the review request and nulls the field, and tier 0b's gate refuses forever. Measured on `food-truck/salmon-of-knowledge`, 2026-09-04:

| PR | latest non-bot review | pending requests | `reviewDecision` |
|---|---|---|---|
| #194 | COMMENTED | 0 | *(null)* |
| #193 | CHANGES_REQUESTED | 0 | CHANGES_REQUESTED |
| #191 | APPROVED | 0 | APPROVED |
| #38 | none | 0 | *(null)* |

`salmon-of-knowledge#208` is the incident this paragraph exists for: CI green, all eight threads resolved, settled head — the exact state tier 0b is for — and an agent following the previous wording of this section waited on a lane that had never once fired on that repo (12 tier-0b firings in the surrounding week, every one on `mono`, `culinary-operations-server` or `internal-frontends`; zero on `salmon-of-knowledge` or `k8s-gitops`, which have **no** open PR reporting `REVIEW_REQUIRED`). What rescued it was tier 0, three minutes after a human re-requested by hand. That is the "stalled-but-healthy trap" below, reached by following this skill.

**`monitor-pr.py` is the tiebreaker when the prose and the script disagree.** On #208 it said `Stale non-APPROVED review(s) from @jamesvec predate current HEAD. Re-request review:` — and it was right. The script keys on "has this reviewer seen the current head", which is the question that actually matters, and it does not carry the `REVIEW_REQUIRED` assumption this section used to. If it tells you to re-request, do it.

The lgtm-side fix (admit a null decision after positively confirming no approval, and admit `CHANGES_REQUESTED` once the head has settled) is in the lgtm repo — see the `settledRereview.ts` header. Once that is deployed the precondition above relaxes, but a single re-request on a settled head stays harmless either way: tier 0 and tier 0b de-duplicate against each other, so the worst case is a race the sweep wins.

#### Never use a bot's trigger comment either

Do not post `/gemini review`, `@claude review`, or any equivalent. A session did exactly this on `mono#4476` on 2026-09-02, four minutes after being woken, because the wake payload it was reading told it to "use the bot's documented re-trigger comment" if a review request didn't take. That instruction was wrong and has been removed. The rule is the same for both mechanisms: **leave automated reviewers alone.**

Note that a bot review you did *not* ask for is still real feedback. Address its threads on the merits like any other review; just don't summon it again.
