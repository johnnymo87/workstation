# Common mistakes while shepherding a PR

Moved out of `SKILL.md` for length; it still binds. `§"..."` references point to sections of
`SKILL.md`.

- **Mistaking Gemini's review for the gating review.** Gemini fires early and looks like a reviewer has shown up, which makes it tempting to declare done as soon as its threads are resolved. On lgtm-bound repos, the gating review is the lgtm-dispatched one (`type: "User"`), which arrives ~10 min *after* CI goes green and is what you're actually waiting for. Address Gemini's threads, but don't exit on Gemini's signal.
- **Re-requesting review from a bot login.** Bots aren't on the lgtm reawaken loop; the request is wasted. Filter on `user.type != "Bot"` before re-requesting.
- **Poking a bot with its trigger comment.** `/gemini review` and `@claude review` are the same mistake as re-requesting them, wearing a different hat — and they *work*, so unlike a wasted API call they produce real noise on the PR. Measured 2026-09-02 on `mono#4476`.
- **Re-requesting lgtm where tier 0b can already see you.** Where `reviewDecision` is `REVIEW_REQUIRED` *and you pushed*, lgtm re-reviews a settled head itself; reaching that state is the useful action and the re-request just races the sweep.
- **Not re-requesting lgtm after answering its threads without a push.** The quieter inverse: "never re-request the pool" remembered as a rule rather than as its reason. A reply does not move the head, and nothing else reawakens lgtm; the PR sits at `COMMENTED` until someone presses the button. See [lgtm-review-mechanics.md](lgtm-review-mechanics.md).
- **NOT re-requesting lgtm where tier 0b cannot see you.** The mirror image, and the more expensive one: on a repo whose base branch has no review-required rule, `reviewDecision` is empty after lgtm's `COMMENTED` review (or `CHANGES_REQUESTED` after its `REQUEST_CHANGES`), tier 0b refuses forever, and "never re-request lgtm" waits indefinitely. `salmon-of-knowledge#208`, 2026-09-04. Check the field; if it is not `REVIEW_REQUIRED`, re-request once. When `monitor-pr.py` says to re-request, it is right.
- **Running `gh pr merge`.** Not yours. See §"Merging stays with the human" — and note that branch protection refusing your merge is not evidence you were allowed to try.
- **Ending the turn on a PR with nobody pending on it.** Green plus every thread resolved plus zero requested reviewers is a stalled PR that looks finished. See §"The stalled-but-healthy trap".
- **Telling the user "a daemon will pick this up" when it will only wake you.** The shepherd routes `needs_reply` / `ci_red` / `conflicted` back to *this session* and only Telegrams the human for `landable` / `idle`. Saying the wrong one leaves the user either ignoring a PR they now own or waiting on a handoff that is coming to you.
- **Re-requesting review after an APPROVED.** If the latest non-bot review is already `APPROVED`, don't re-request when you push fixes for leftover inline threads. The reviewer signed off; pinging them again to re-confirm is noise. Re-request only when the latest non-bot review is `CHANGES_REQUESTED` or `COMMENTED`.
- **Re-requesting from the wrong login.** lgtm's reviewer pool rotates, but on re-review it pins to the prior reviewer. Always use the exact login from the most recent non-bot review, not a hardcoded default.
- **Using `sleep 300` while polling.** A 5-minute idle gap can expire Anthropic's prompt cache and force the next turn to re-send the full prompt. Use `sleep 60` for monitoring loops. (This is an argument against *medium* sleeps specifically. Once you've decided to wait tens of minutes, the cache is lost either way and ending the turn is strictly cheaper than continuing to poll.)
- **Treating a wake payload as trustworthy state.** It records what was true when it was scheduled, possibly hours ago. Re-read CI, reviews, and threads before acting on any of it.
- **Bundling sleep with the follow-up `gh` calls in one bash invocation.** Long chained one-liners that include `sleep` are a known hang risk in this environment (see AGENTS.md). Run `sleep 60` as its own tool call, then run the checks.
- **Replying to inline comments without resolving them.** GitHub tracks thread resolution separately from the reply chain. A thread with five replies and no resolve still reads as unresolved in the diff UI. After every reply, call `resolveReviewThread`. See `reviewing-github-prs` §"Resolving review threads".
- **Cherry-picking the easy comments.** Addressing the agreeable comments and quietly dropping the hard or controversial ones leaves threads looking abandoned and isn't actually finishing the review. Every thread gets accept / push back / escalate — see `receiving-code-review` §"Address Every Item". Use the unresolved-threads filter query (in `reviewing-github-prs`) before claiming exit conditions met.
- **Trusting a command's output instead of checking the resulting state.** `git push -q ... | tail -3` has swallowed a *failed* push and printed a success-looking line. Measured 2026-08-09 on #4179: the branch was already checked out in another worktree, so `git checkout -b <branch> origin/<branch>` failed with `fatal: a branch named '...' already exists`; the commit then landed on a **detached HEAD**, and `git push origin <branch>` had no local branch of that name to push. The `-q`-plus-`tail` pipeline hid all of it. The reply-and-resolve round that followed would have cited a commit that was never on the remote.

  **Verify the resulting state, not the command's exit.** The same discipline catches a queued-vs-passed CI check, a re-review request sent to a login that 404s, and a "resolved" thread count taken from the REST comments endpoint instead of `reviewThreads.isResolved`.

  After any push you intend to cite, compare the three values that must agree:

  ```bash
  git rev-parse HEAD                                               # what you built
  git fetch -q origin "$BRANCH" && git rev-parse "origin/$BRANCH"  # what the remote has
  gh pr view "$PR" --json headRefOid -q .headRefOid                # what the PR will merge
  ```

  If they disagree, push explicitly from the detached HEAD rather than re-running the same command —
  and drop `-q` / `| tail` so failures are visible:

  ```bash
  git push origin HEAD:refs/heads/<branch>
  ```
