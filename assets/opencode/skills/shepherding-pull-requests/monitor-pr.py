#!/usr/bin/env python3
"""
PR monitoring primitive for the shepherding-pull-requests skill.

Each invocation polls for up to --budget-seconds (default 60), then returns.
Claude re-invokes in a loop until exit code 0 or 1. The 60s cap is intentional:
Anthropic prompt-cache TTL is 5 min, and any single bash call that blocks
the model for >5 min expires the warm cache. Capping at 60s keeps the model
in the loop for fix-as-you-go work AND keeps the cache warm.

Exit codes:
  0  All exit conditions met -- PR is landable (CI green, all inline threads
     resolved, and -- if lgtm-bound -- latest non-bot review is APPROVED).
  1  Action needed by Claude. CI failed, unresolved threads, or the latest
     non-bot review is CHANGES_REQUESTED/COMMENTED on a commit older than
     HEAD (re-request needed). Stdout explains the specific action.
  2  Unrecoverable error (could not query GitHub, malformed responses).
  3  Budget elapsed with the PR still in a legitimate idle-wait state
     (CI pending, or lgtm-bound waiting on non-bot APPROVAL). Re-invoke.

Usage in the SKILL.md loop body:
    while true; do
      python monitor-pr.py [PR]
      case $? in
        0) break ;;                # done
        1) <fix per stdout> ;;     # then re-invoke
        2) <surface to user>; exit ;;
        3) ;;                      # idle-wait elapsed, just re-invoke
      esac
    done
"""
import argparse
import json
import re
import subprocess
import sys
import time
from pathlib import Path

# --- Constants (justified, not voodoo) -------------------------------------
# Total wall-clock budget per invocation. Capped at the Anthropic prompt-cache
# TTL (5 min) -- a single bash call that blocks the model longer than that
# expires warm cache and costs full prompt input on the next turn. 60s gives
# enough headroom to catch a fast CI flip without holding the model captive.
DEFAULT_BUDGET_SEC = 60

# Time between polls within a single invocation. 15s is short enough that a
# 60s budget yields ~4 samples (catches fast state changes) and long enough
# that we're not hammering the GitHub API.
DEFAULT_INTERVAL_SEC = 15

# GitHub GraphQL caps page size at 100 for these connections. We page through
# explicitly via endCursor to avoid silently dropping threads on PRs with >100.
PAGE_SIZE = 100

# Path the lgtm daemon's config lives at on machines that run lgtm. Absent on
# devbox/personal hosts; absence means "not lgtm-bound" (consistent with
# SKILL.md "Once, before the loop: determine if this PR is lgtm-bound").
LGTM_CONFIG_PATH = Path.home() / "projects" / "lgtm" / "lgtm.yml"

# Exit codes -- documented so callers (and SKILL.md) can branch on them.
EXIT_ALL_MET = 0
EXIT_ACTION_NEEDED = 1
EXIT_ERROR = 2
EXIT_STILL_WAITING = 3


# --- gh wrappers -----------------------------------------------------------

def run_cmd(cmd):
    """Run a command, returning stdout. On failure, prints to stderr and
    raises CalledProcessError so the caller can decide whether to fall back
    or bail."""
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode != 0:
        raise subprocess.CalledProcessError(
            res.returncode, cmd, output=res.stdout, stderr=res.stderr
        )
    return res.stdout.strip()


def get_pr_info(pr_num=None):
    """Top-level PR metadata via `gh pr view`. Note: `reviews` here is a
    *summary* that does NOT include user.type. We re-fetch reviews via the
    REST API (get_reviews) when we need bot/human disambiguation.

    `author.login` is used by latest_non_bot_review to exclude self-reviews
    -- GitHub auto-creates an empty `state=COMMENTED` review wrapper every
    time the PR author posts an inline reply to a comment thread, and those
    must not be treated as reviewer verdicts."""
    cmd = ["gh", "pr", "view"]
    if pr_num:
        cmd.append(str(pr_num))
    cmd.extend([
        "--json",
        "number,url,state,reviewDecision,headRefName,baseRefName,headRefOid,author",
    ])
    out = run_cmd(cmd)
    return json.loads(out)


def get_reviews(owner, repo, pr_num):
    """Fetch reviews via the REST API. Unlike `gh pr view --json reviews`,
    this exposes `user.type` ("Bot" vs "User"), which is the ONLY reliable
    way to distinguish bots from humans -- substring matching on login
    misclassifies humans whose name contains 'bot' (e.g. 'abbott') and
    misses bots whose login doesn't ('renovate'). See SKILL.md "Two reviews,
    two roles"."""
    cmd = [
        "gh", "api",
        f"repos/{owner}/{repo}/pulls/{pr_num}/reviews",
        "--paginate",
    ]
    out = run_cmd(cmd)
    # --paginate concatenates multiple JSON arrays. gh emits them as a single
    # array when using --paginate on list endpoints, so a plain json.loads
    # works. Defensive fallback: if it fails, try line-delimited.
    try:
        return json.loads(out)
    except json.JSONDecodeError:
        merged = []
        for line in out.splitlines():
            line = line.strip()
            if line:
                merged.extend(json.loads(line))
        return merged


def parse_repo_from_url(url):
    m = re.match(r"https://github\.com/([^/]+)/([^/]+)/pull/\d+", url)
    if not m:
        raise ValueError(f"Could not parse repo from PR URL: {url}")
    return m.group(1), m.group(2)


# --- Status checks ---------------------------------------------------------

def check_ci(pr_num):
    """Returns (status, message) where status is one of:
      "pass"    -- all checks completed and succeeded (or none configured)
      "pending" -- at least one check still running, none failed yet
      "fail"    -- at least one check failed
    """
    cmd = ["gh", "pr", "checks", str(pr_num), "--json", "name,state,bucket"]
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode != 0:
        # "no checks reported" is a normal "no CI configured" state, not a
        # failure -- treat as pass.
        if "no checks reported" in res.stderr.lower():
            return "pass", "No checks configured"
        # Any other error is a genuine failure to query; surface it.
        return "fail", f"`gh pr checks` errored: {res.stderr.strip()}"

    try:
        checks = json.loads(res.stdout) if res.stdout.strip() else []
    except json.JSONDecodeError as e:
        return "fail", f"Could not parse `gh pr checks` output: {e}"

    if not checks:
        return "pass", "No checks reported"

    pending = []
    failed = []
    for check in checks:
        # `gh pr checks --json` returns state values like "SUCCESS", "FAILURE",
        # "PENDING", "SKIPPED", and bucket values like "pass", "fail", "pending",
        # "skipping", "cancel". Bucket is the post-normalized signal; prefer it.
        bucket = (check.get("bucket") or "").lower()
        state = (check.get("state") or "").upper()
        if bucket == "pending" or state in ("PENDING", "QUEUED", "IN_PROGRESS"):
            pending.append(check["name"])
        elif bucket == "fail" or state in ("FAILURE", "ERROR", "CANCELLED", "TIMED_OUT"):
            failed.append(check["name"])
        # bucket in ("pass", "skipping") and state SUCCESS/SKIPPED/NEUTRAL => OK

    if failed:
        return "fail", f"Failed: {', '.join(failed)}"
    if pending:
        return "pending", f"Pending: {', '.join(pending)}"
    return "pass", f"All {len(checks)} checks passed"


def fetch_review_threads(owner, repo, pr_num):
    """Fetch every reviewThread on the PR, paginating past PAGE_SIZE. Returns
    a list of thread dicts {id, isResolved, first_author, first_author_type,
    first_snippet}. Raises on GraphQL failure -- the skill explicitly relies
    on thread resolution state, so we MUST NOT silently report all-clear."""
    query = """
    query($owner: String!, $name: String!, $number: Int!, $after: String) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) {
          reviewThreads(first: %d, after: $after) {
            pageInfo { hasNextPage endCursor }
            nodes {
              id
              isResolved
              comments(first: 1) {
                nodes {
                  author { login __typename }
                  body
                }
              }
            }
          }
        }
      }
    }
    """ % PAGE_SIZE

    threads = []
    after = None
    while True:
        cmd = [
            "gh", "api", "graphql",
            "-F", f"owner={owner}",
            "-F", f"name={repo}",
            "-F", f"number={pr_num}",
            "-f", f"query={query}",
        ]
        if after is not None:
            cmd.extend(["-F", f"after={after}"])
        else:
            # GraphQL requires `null` for the cursor on first page; gh's -F
            # doesn't have a clean "null" syntax. Omitting the variable means
            # GraphQL uses its declared default ($after: String defaults to
            # null), which is what we want.
            pass

        out = run_cmd(cmd)
        data = json.loads(out)
        if "errors" in data:
            raise RuntimeError(f"GraphQL errors: {data['errors']}")

        page = data["data"]["repository"]["pullRequest"]["reviewThreads"]
        for node in page["nodes"]:
            comments = node["comments"]["nodes"]
            first = comments[0] if comments else None
            author_obj = (first or {}).get("author") or {}
            threads.append({
                "id": node["id"],
                "isResolved": node["isResolved"],
                "first_author": author_obj.get("login", "unknown"),
                # __typename is "Bot" for bot accounts, "User" for humans.
                # GitHub's Bot type covers GitHub Apps (gemini-code-assist,
                # dependabot, etc.); humans are User even if they happen to
                # have "bot" in their login.
                "first_author_type": author_obj.get("__typename", "User"),
                "first_snippet": ((first or {}).get("body") or "")[:120],
            })

        if not page["pageInfo"]["hasNextPage"]:
            break
        after = page["pageInfo"]["endCursor"]

    return threads


def detect_lgtm_bound(owner, repo):
    """Read ~/projects/lgtm/lgtm.yml and check whether owner/repo is listed.
    Matches lines like "  owner/repo:" (two-space indent + repo key + colon)
    per SKILL.md "Once, before the loop". Returns False if the file is
    absent (consistent with the skill: devbox/personal hosts treat all PRs
    as not lgtm-bound)."""
    if not LGTM_CONFIG_PATH.is_file():
        return False
    needle = re.compile(rf"^  {re.escape(owner)}/{re.escape(repo)}:\s*$")
    with open(LGTM_CONFIG_PATH) as f:
        for line in f:
            if needle.match(line.rstrip("\n")):
                return True
    return False


# --- Review classification -------------------------------------------------

def latest_non_bot_review(reviews, author_login=None):
    """From the REST /reviews payload, return the most recent review per
    non-bot, non-author reviewer. Bots are identified by `user.type == "Bot"`
    (the only correct test; see get_reviews docstring). Returns a dict
    {login: {state, submitted_at}} containing only third-party humans (or
    lgtm-dispatched sessions, which run under real human PATs and look
    identical to humans here -- that's intentional per SKILL.md "Two
    reviews, two roles").

    Only non-PENDING review states are considered: a reviewer hitting
    "Approve" or "Request changes" generates a non-PENDING review. PENDING
    states are drafts the reviewer hasn't submitted yet -- ignore them.

    Self-reviews (login == author_login) are skipped: GitHub auto-creates
    an empty `state=COMMENTED` review wrapper every time the PR author
    posts a threaded inline reply, and the API surfaces those as
    indistinguishable from a real review verdict. The author cannot
    meaningfully gate their own PR (GitHub refuses APPROVE/REQUEST_CHANGES
    from the author outright), so dropping every self-review here is safe
    and prevents false-positive blocked-on-review states. Pass
    `author_login=None` to disable filtering (e.g. for unit tests)."""
    latest = {}  # login -> review dict
    for r in reviews:
        user = r.get("user") or {}
        if user.get("type") == "Bot":
            continue
        if r.get("state") == "PENDING":
            continue
        login = user.get("login")
        if not login:
            continue
        # Skip self-reviews -- see docstring above.
        if author_login is not None and login == author_login:
            continue
        # Reviews are returned in chronological order; keep the latest.
        prev = latest.get(login)
        if prev is None or r["submitted_at"] > prev["submitted_at"]:
            latest[login] = {
                "state": r["state"],
                "submitted_at": r["submitted_at"],
                "commit_id": r.get("commit_id"),
            }
    return latest


# --- Main loop -------------------------------------------------------------

def evaluate_iteration(pr_num, owner, repo, lgtm_bound):
    """Run one polling iteration. Returns a dict with the per-iteration
    findings AND a recommended exit code (or None to keep polling)."""
    pr = get_pr_info(pr_num)
    head_sha = pr.get("headRefOid")
    author_login = (pr.get("author") or {}).get("login")

    ci_status, ci_msg = check_ci(pr_num)
    try:
        threads = fetch_review_threads(owner, repo, pr_num)
    except Exception as e:
        # The skill exits on inline-threads-resolved -- we cannot fudge this.
        # If GraphQL is broken, bail with a clear error so Claude knows to
        # check manually rather than thinking all threads are clear.
        return {
            "exit_code": EXIT_ERROR,
            "message": f"GraphQL fetch failed; cannot verify thread state: {e}",
        }
    unresolved = [t for t in threads if not t["isResolved"]]

    reviews = get_reviews(owner, repo, pr_num)
    non_bot_latest = latest_non_bot_review(reviews, author_login=author_login)

    # Print iteration status
    print(f"  CI:        {ci_status:<8} ({ci_msg})")
    print(f"  Threads:   {len(unresolved)} unresolved / {len(threads)} total")
    for t in unresolved[:5]:
        kind = "bot" if t["first_author_type"] == "Bot" else "user"
        print(f"             - {kind} @{t['first_author']}: {t['first_snippet'][:80]!r}")
    if len(unresolved) > 5:
        print(f"             ... and {len(unresolved) - 5} more")

    if non_bot_latest:
        print("  Reviews:   latest non-bot per reviewer:")
        for login, info in non_bot_latest.items():
            marker = "(on HEAD)" if info["commit_id"] == head_sha else "(stale commit)"
            print(f"             - @{login}: {info['state']} {marker}")
    else:
        print("  Reviews:   no non-bot reviews yet")

    # Action-needed conditions: things Claude must address before the loop
    # can continue. Exit and let Claude work.
    if ci_status == "fail":
        return {
            "exit_code": EXIT_ACTION_NEEDED,
            "message": (
                f"CI failed ({ci_msg}). Investigate logs (gh run view / az pipelines) "
                f"and push fixes."
            ),
        }
    if unresolved:
        # Distinguish "your own unaddressed bot/human threads" -- skill says
        # every thread root gets a reply + resolve regardless of bot/human.
        return {
            "exit_code": EXIT_ACTION_NEEDED,
            "message": (
                f"{len(unresolved)} unresolved inline thread(s). "
                f"Address each (reply + resolveReviewThread) per the "
                f"reviewing-github-prs and receiving-code-review skills."
            ),
        }

    # CI green + threads clean. Now reason about review verdicts.
    #
    # The exit gate has two halves, both of which must be satisfied:
    #
    # (a) NEGATIVE GATE: no non-bot reviewer has an OUTSTANDING request for
    #     changes. "Outstanding" means their latest review is
    #     CHANGES_REQUESTED or COMMENTED. This gate blocks exit regardless
    #     of lgtm-boundness -- if a human asked for changes, you don't ship
    #     over them just because another reviewer approved or because the
    #     repo isn't on lgtm. The flowchart's "Anything to fix?" branch
    #     implicitly covers this; SKILL.md §"Exit condition" line 223 is
    #     loosely worded ("the most recent review from a non-bot reviewer")
    #     but the practical contract is "no outstanding CHANGES_REQUESTED."
    #
    # (b) POSITIVE GATE (lgtm-bound only): at least one non-bot reviewer's
    #     latest review is APPROVED. "Approval is durable" -- a stale
    #     APPROVED on an older commit still counts for inline-only fixes,
    #     per SKILL.md §"Approval is durable".
    #
    # The interaction we have to get right (per the user audit prompt):
    # APPROVED + inline suggestions in the same review. GitHub stores the
    # approval as state=APPROVED and the suggestions as separate review
    # threads. Those threads gate exit via the unresolved-threads check
    # ABOVE, so an "approving review with open suggestions" correctly does
    # not let us out -- the threads do the work.
    outstanding_non_approved = [
        (login, info) for login, info in non_bot_latest.items()
        if info["state"] != "APPROVED"
    ]
    any_approval = any(info["state"] == "APPROVED" for info in non_bot_latest.values())

    if outstanding_non_approved:
        # Split by "have they seen current HEAD?" Reviewers who haven't seen
        # HEAD need a re-request (their non-APPROVED is stale). Reviewers
        # who HAVE seen HEAD and still said non-APPROVED are the
        # authoritative "blocked" signal -- we wait for them to update.
        needs_rerequest = [
            (login, info) for login, info in outstanding_non_approved
            if info["commit_id"] != head_sha
        ]
        blocked_on_head = [
            (login, info) for login, info in outstanding_non_approved
            if info["commit_id"] == head_sha
        ]

        if needs_rerequest:
            logins = [login for login, _ in needs_rerequest]
            return {
                "exit_code": EXIT_ACTION_NEEDED,
                "message": (
                    "Stale non-APPROVED review(s) from "
                    f"{', '.join('@' + l for l in logins)} predate current "
                    f"HEAD. Re-request review:\n"
                    + "\n".join(
                        f"  gh api -X POST repos/{owner}/{repo}/pulls/{pr_num}"
                        f"/requested_reviewers -f 'reviewers[]={l}'"
                        for l in logins
                    )
                ),
            }

        # Everyone outstanding has seen HEAD. We're legitimately waiting on
        # them. Idle-poll regardless of lgtm-boundness or other approvals --
        # an open CHANGES_REQUESTED blocks merge.
        states = ", ".join(
            f"@{l}: {i['state']}" for l, i in blocked_on_head
        )
        return {
            "exit_code": None,
            "message": f"waiting on non-bot reviewer(s) post-HEAD review ({states})",
        }

    # No outstanding non-APPROVED reviews. Check the positive gate for
    # lgtm-bound repos.
    if lgtm_bound and not any_approval:
        # Waiting on lgtm dispatch (typically ~10 min after CI green).
        return {"exit_code": None, "message": "lgtm-bound: waiting on non-bot APPROVAL"}

    # CI still resolving -- idle-poll.
    if ci_status == "pending":
        return {"exit_code": None, "message": f"CI still running: {ci_msg}"}

    # All gates pass.
    return {"exit_code": EXIT_ALL_MET, "message": "All exit conditions met"}


def main():
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "pr_num", nargs="?", type=int,
        help="PR number. Auto-detected from current branch if omitted.",
    )
    parser.add_argument(
        "--lgtm-bound", choices=["auto", "yes", "no"], default="auto",
        help="Override lgtm-boundness detection. 'auto' (default) reads "
             "~/projects/lgtm/lgtm.yml.",
    )
    parser.add_argument(
        "--budget-seconds", type=int, default=DEFAULT_BUDGET_SEC,
        help=f"Max wall-clock budget for this invocation in seconds "
             f"(default: {DEFAULT_BUDGET_SEC}). Capped at 5 min by the "
             f"Anthropic prompt-cache TTL; the skill expects you to re-invoke "
             f"in a loop rather than raise this.",
    )
    parser.add_argument(
        "--interval", type=int, default=DEFAULT_INTERVAL_SEC,
        help=f"Seconds between polls within a single invocation "
             f"(default: {DEFAULT_INTERVAL_SEC}).",
    )
    args = parser.parse_args()

    try:
        pr = get_pr_info(args.pr_num)
    except (subprocess.CalledProcessError, ValueError, json.JSONDecodeError) as e:
        print(f"Error fetching PR info: {e}", file=sys.stderr)
        sys.exit(EXIT_ERROR)

    pr_num = pr["number"]
    owner, repo = parse_repo_from_url(pr["url"])

    if args.lgtm_bound == "yes":
        lgtm_bound = True
    elif args.lgtm_bound == "no":
        lgtm_bound = False
    else:
        lgtm_bound = detect_lgtm_bound(owner, repo)

    print(f"Monitoring PR #{pr_num}: {pr['url']}")
    print(f"  {pr['baseRefName']} <- {pr['headRefName']}")
    print(f"  lgtm-bound: {lgtm_bound}")
    print(f"  budget: {args.budget_seconds}s @ {args.interval}s intervals")

    deadline = time.monotonic() + args.budget_seconds
    iteration = 0
    last_message = "no observations yet"

    while True:
        iteration += 1
        print(f"\n--- iteration {iteration} ---")
        result = evaluate_iteration(pr_num, owner, repo, lgtm_bound)
        last_message = result["message"]

        if result["exit_code"] is not None:
            # Definitive verdict (done, action needed, or error). Return now.
            print(f"\n{result['message']}")
            sys.exit(result["exit_code"])

        # Idle-wait state. Sleep an interval, but only if we have budget left
        # for at least one more meaningful sample (a poll-then-immediately-exit
        # is wasted work).
        remaining = deadline - time.monotonic()
        if remaining <= args.interval:
            print(f"\nBudget elapsed (~{args.budget_seconds}s); still idle: "
                  f"{last_message}")
            print("Re-invoke this script to keep polling.")
            sys.exit(EXIT_STILL_WAITING)

        print(f"  ...idle; sleeping {args.interval}s ({last_message})")
        time.sleep(args.interval)


if __name__ == "__main__":
    main()
