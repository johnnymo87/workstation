#!/usr/bin/env python3
"""
Rollout monitoring primitive for the monitoring-deployments skill.

Companion to shepherding-pull-requests/monitor-pr.py, one lifecycle phase
later: that script watches a PR from open to merged; this one watches a
*merged* commit roll out to one or more Kubernetes environments until the
new image is live and healthy. "Merged" is not "deployed" -- a change can
merge green and still fail to reach prod (image build fails, the GitOps
trigger never fires, the new pods crashloop). This script holds the rollout
the way monitor-pr.py holds the PR.

Each invocation polls for up to --budget-seconds (default 60), then returns.
The caller re-invokes in a loop until exit 0/1/2. The 60s cap mirrors
monitor-pr.py and is deliberate: Anthropic prompt-cache TTL is 5 min, so any
single bash call that blocks the model longer than that expires warm cache
and costs full prompt input on the next turn. Capping at 60s keeps the model
in the loop for fix-as-you-go work AND keeps the cache warm. Do NOT raise the
budget to "just wait it out" -- re-invoke instead.

This script is intentionally topology-agnostic: it takes every cluster
context, namespace, and deployment as arguments and hardcodes nothing about
any particular environment. The real values live in the skill's Confluence
INTERNAL.md companion (see SKILL.md), not in this file or this repo.

Exit codes:
  0  All targets rolled out and healthy -- every target deployment's spec
     image is on the merged commit's tag AND all its pods are Running+Ready
     on that tag (no old-revision pods lingering).
  1  Action needed. A new-revision pod is wedged (CrashLoopBackOff, an
     image-pull error, or a restart spike) -- the rollout will not finish on
     its own. Stdout names the pod and reason; investigate (kubectl logs /
     describe) and fix forward or roll back.
  2  Unrecoverable error (gh/kubectl query failed, unknown context, missing
     deployment, bad args, malformed JSON). Surface to the user; do not
     silently retry.
  3  Still rolling -- PR not merged yet, deployment spec not yet bumped to the
     new tag, or pods mid-update. Legitimate idle-wait; re-invoke.
  4  Rolled out AS AN ANCESTOR of a later commit, and healthy. The deployed
     tag is not your commit's tag, but the commit it names provably CONTAINS
     your commit, so your change IS live. This is the merge-queue batching
     case: the queue landed your commit and one or more others in a single
     batch, and the deploy pipeline ran only on the batch head. Terminal and
     successful -- treat like 0, but the distinct code exists so "deployed"
     and "deployed under someone else's tag" are never conflated.

Merge-queue batching (why exit 4 exists):
  On a repo with GitHub's merge queue enabled, the queue batches several PRs
  into one push to the trunk. Your PR merges as commit A; another merges on
  top as commit B minutes later; the deploy pipeline attaches to the BATCH
  HEAD (B) only. Commit A ends up with a full set of CI check-runs and zero
  deploy checks, permanently. Without the detection below, this script would
  print "deploy spec not yet bumped" forever against A while the rollout had
  in fact already succeeded.

  The detection is deliberately conservative and CANNOT produce a false pass:
  we take the tag actually deployed, resolve it to a real commit via the
  GitHub API, and then require `compare/<yours>...<deployed>` to report
  "ahead" or "identical" -- i.e. the deployed commit genuinely contains your
  commit. A newer-looking tag is never assumed to contain you. Anything we
  cannot resolve or cannot prove containment for stays "still rolling"
  (exit 3), which is the safe direction to be wrong in.

Usage in the SKILL.md loop body:
    while true; do
      python monitor-rollout.py --pr 1234 \
        --target UAT:my-uat-ctx:uat-ns:my-service \
        --target PROD:my-prod-ctx:prod-ns:my-service
      case $? in
        0) break ;;                # rolled out & healthy
        1) <investigate per stdout>; ;;   # then re-invoke
        2) <surface to user>; exit ;;
        3) ;;                      # still rolling, re-invoke
        4) break ;;                # live as an ancestor of a batch head
      esac
    done
"""
import argparse
import json
import re
import subprocess
import sys
import time

# --- Constants (justified, not voodoo) -------------------------------------
# Total wall-clock budget per invocation. Capped at the Anthropic prompt-cache
# TTL (5 min) -- a single bash call that blocks the model longer than that
# expires warm cache and costs full prompt input on the next turn. 60s gives
# enough headroom to catch a fast state change without holding the model
# captive. See monitor-pr.py for the same rationale.
DEFAULT_BUDGET_SEC = 60

# Time between polls within a single invocation. 15s yields ~4 samples per 60s
# budget (catches a fast pod flip) without hammering the cluster API.
DEFAULT_INTERVAL_SEC = 15

# Pod label selector template. Defaults to the common "app=<deployment>"
# convention; override with --pod-selector when a deployment labels its pods
# differently (e.g. "app.kubernetes.io/name={deployment}").
DEFAULT_SELECTOR = "app={deployment}"

# Container-status waiting reasons that mean a pod is wedged and the rollout
# will not self-heal. These are surfaced as "action needed" (exit 1) rather
# than "still rolling" (exit 3) so the agent stops idle-polling a dead rollout.
WEDGED_WAITING_REASONS = {
    "CrashLoopBackOff",
    "ImagePullBackOff",
    "ErrImagePull",
    "CreateContainerError",
    "CreateContainerConfigError",
    "InvalidImageName",
}

# Restart count on a NEW-revision pod above which we treat the rollout as
# wedged rather than progressing. A healthy new pod starts cleanly; repeated
# restarts mean a crash that backoff hasn't yet labeled CrashLoopBackOff.
RESTART_SPIKE_THRESHOLD = 3

# Length of the short SHA we match image tags against. GitHub/most CI tag
# images with the 7-char abbreviated commit SHA, often with a build-attempt
# suffix (e.g. "<sha>_0"). We prefix-match to tolerate that suffix.
SHORT_SHA_LEN = 7

# A deployed tag only *might* be a commit SHA. We take its leading hex run
# (so "<sha>_0" and "<sha>-rc1" both yield "<sha>") and require at least
# SHORT_SHA_LEN chars before asking GitHub to resolve it. Anything shorter is
# far too ambiguous to be worth a lookup, and a non-hex tag (a semver release,
# a channel name) is not a commit at all.
HEX_PREFIX_RE = re.compile(r"^[0-9a-f]+")

# `gh api .../compare/<base>...<head>` statuses that prove <head> contains
# <base>. "ahead" is the merge-queue batch-head case; "identical" means the
# same commit. "behind" and "diverged" prove the OPPOSITE and must never be
# accepted -- that is the false-pass this whole mechanism has to avoid.
CONTAINING_COMPARE_STATUSES = {"ahead", "identical"}

# Exit codes -- documented so callers (and SKILL.md) can branch on them.
EXIT_ALL_MET = 0
EXIT_ACTION_NEEDED = 1
EXIT_ERROR = 2
EXIT_STILL_WAITING = 3
EXIT_DEPLOYED_AS_ANCESTOR = 4


class RolloutError(Exception):
    """A target could not be queried (missing deployment, unknown context,
    kubectl failure). Unrecoverable for this run -> EXIT_ERROR."""


# --- Subprocess helper -----------------------------------------------------

def run_cmd(cmd):
    """Run a command (arg list, never shell=True) and return stdout. Raises
    CalledProcessError on non-zero exit -- and also when the binary is missing
    (FileNotFoundError -> CalledProcessError(127, ...)) so callers' existing
    CalledProcessError handling covers a missing gh/kubectl too."""
    try:
        res = subprocess.run(cmd, capture_output=True, text=True)
    except FileNotFoundError as e:
        raise subprocess.CalledProcessError(
            127, cmd, output="", stderr=f"command not found: {cmd[0]} ({e})"
        )
    if res.returncode != 0:
        raise subprocess.CalledProcessError(
            res.returncode, cmd, output=res.stdout, stderr=res.stderr
        )
    return res.stdout.strip()


# --- Parsing helpers -------------------------------------------------------

def parse_target(spec):
    """Parse ENV:CONTEXT:NAMESPACE:DEPLOYMENT into a dict. k8s context names,
    namespaces, and resource names never contain ':', so a plain split is
    unambiguous."""
    parts = spec.split(":")
    if len(parts) != 4 or not all(p.strip() for p in parts):
        raise ValueError(
            f"--target must be ENV:CONTEXT:NAMESPACE:DEPLOYMENT (4 non-empty "
            f"colon-separated fields); got {spec!r}"
        )
    env, context, namespace, deployment = (p.strip() for p in parts)
    return {
        "env": env,
        "context": context,
        "namespace": namespace,
        "deployment": deployment,
    }


def image_tag(image):
    """Extract the tag from a container image reference. Handles a registry
    host:port prefix (host:port/path:tag) by isolating the final path segment
    before splitting on ':', and digest pins (name@sha256:...) by returning
    None -- a digest has no SHA-based tag to prefix-match.

    Examples:
      registry.example.com/team/svc:abc1234_0 -> "abc1234_0"
      localhost:5000/svc:abc1234              -> "abc1234"
      registry/svc@sha256:deadbeef            -> None
    """
    if not image:
        return None
    last = image.rsplit("/", 1)[-1]  # drop registry host[:port]/path/...
    if "@" in last:                  # digest pin
        last = last.split("@", 1)[0]
    if ":" not in last:
        return None
    return last.split(":", 1)[1]


# --- gh (PR merge) ---------------------------------------------------------

def get_merge_state(pr, repo):
    """Return (state, merge_sha) for a PR via `gh pr view`. merge_sha is None
    until the PR is MERGED. Exits EXIT_ERROR on query failure -- a broken gh
    call must not be mistaken for 'not merged yet'."""
    cmd = ["gh", "pr", "view", str(pr), "--json", "state,mergeCommit"]
    if repo:
        cmd += ["--repo", repo]
    try:
        out = run_cmd(cmd)
    except subprocess.CalledProcessError as e:
        print(f"gh pr view failed: {(e.stderr or '').strip()}", file=sys.stderr)
        sys.exit(EXIT_ERROR)
    try:
        data = json.loads(out)
    except json.JSONDecodeError as e:
        print(f"Could not parse `gh pr view` output: {e}", file=sys.stderr)
        sys.exit(EXIT_ERROR)
    commit = data.get("mergeCommit") or {}
    return data.get("state"), commit.get("oid")


# --- gh (merge-queue batch-head containment) -------------------------------

def resolve_repo(repo_arg):
    """Return "owner/repo" for the API calls below. Uses --repo when given,
    else asks gh to infer it from the cwd. Returns None (rather than exiting)
    when neither works: containment detection is an ENHANCEMENT, and losing it
    must degrade to plain "still rolling", never to a hard failure."""
    if repo_arg:
        return repo_arg
    try:
        out = run_cmd(["gh", "repo", "view", "--json", "nameWithOwner"])
        return json.loads(out).get("nameWithOwner")
    except (subprocess.CalledProcessError, json.JSONDecodeError):
        return None


def tag_sha_candidate(tag):
    """Leading hex run of a tag, if it is long enough to be a commit SHA.
    "abc1234f_0" -> "abc1234f"; "v1.2.3" -> None; "12345" -> None (too short)."""
    if not tag:
        return None
    m = HEX_PREFIX_RE.match(tag.lower())
    if not m or len(m.group(0)) < SHORT_SHA_LEN:
        return None
    return m.group(0)


def resolve_commit(repo, rev):
    """Full SHA for a rev (short SHA) in repo, or None if GitHub cannot
    resolve it -- unknown, ambiguous prefix, or simply not a commit. None
    means "we learned nothing", which keeps the caller in the safe branch."""
    try:
        out = run_cmd(["gh", "api", f"repos/{repo}/commits/{rev}", "--jq", ".sha"])
    except subprocess.CalledProcessError:
        return None
    out = out.strip()
    return out or None


def compare_status(repo, base, head):
    """`gh api repos/<repo>/compare/<base>...<head> --jq .status`, or None on
    failure. "ahead" means head is ahead of base, i.e. head CONTAINS base."""
    try:
        out = run_cmd([
            "gh", "api", f"repos/{repo}/compare/{base}...{head}", "--jq", ".status",
        ])
    except subprocess.CalledProcessError:
        return None
    return out.strip() or None


def classify_deployed_tag(repo, merge_sha, deployed_tag, cache):
    """Decide whether a deployed tag that does NOT match our commit is
    nonetheless a commit that CONTAINS our commit (the merge-queue batch-head
    case). Returns a dict:

      {"kind": "contained",  "sha": <full sha>, "status": <compare status>}
      {"kind": "unrelated",  "sha": <full sha>, "status": <compare status>}
      {"kind": "unknown",    "reason": <why we could not tell>}

    Only "contained" may be treated as a successful rollout, and only because
    containment was PROVEN by the compare endpoint -- never inferred from a
    tag looking newer. Results are memoised per deployed tag so a polling loop
    costs at most two API calls per distinct tag it sees."""
    if deployed_tag in cache:
        return cache[deployed_tag]

    result = None
    if not repo:
        result = {"kind": "unknown",
                  "reason": "could not determine owner/repo (pass --repo)"}
    else:
        candidate = tag_sha_candidate(deployed_tag)
        if candidate is None:
            result = {"kind": "unknown",
                      "reason": f"deployed tag {deployed_tag!r} is not a commit SHA"}
        else:
            deployed_sha = resolve_commit(repo, candidate)
            if deployed_sha is None:
                result = {"kind": "unknown",
                          "reason": f"{candidate} does not resolve to a commit "
                                    f"in {repo}"}
            else:
                status = compare_status(repo, merge_sha, deployed_sha)
                if status is None:
                    result = {"kind": "unknown",
                              "reason": f"could not compare {merge_sha[:SHORT_SHA_LEN]}"
                                        f"...{deployed_sha[:SHORT_SHA_LEN]}"}
                elif status in CONTAINING_COMPARE_STATUSES:
                    result = {"kind": "contained", "sha": deployed_sha,
                              "status": status}
                else:
                    result = {"kind": "unrelated", "sha": deployed_sha,
                              "status": status}

    cache[deployed_tag] = result
    return result


# --- kubectl (rollout) -----------------------------------------------------

def get_spec_image_tag(target):
    """Tag of the deployment's first container image, per its current spec.
    This is the 'has the GitOps controller bumped the deployment yet?' signal.
    Raises RolloutError if the deployment can't be read."""
    cmd = [
        "kubectl", "--context", target["context"], "-n", target["namespace"],
        "get", "deploy", target["deployment"],
        "-o", "jsonpath={.spec.template.spec.containers[0].image}",
    ]
    try:
        out = run_cmd(cmd)
    except subprocess.CalledProcessError as e:
        raise RolloutError(
            f"kubectl get deploy {target['deployment']} "
            f"(ctx {target['context']}, ns {target['namespace']}) failed: "
            f"{(e.stderr or '').strip()}"
        )
    if not out:
        raise RolloutError(
            f"deployment {target['deployment']} (ctx {target['context']}, "
            f"ns {target['namespace']}) has no container image in its spec"
        )
    return image_tag(out)


def get_pods(target, selector):
    """Return a list of pod dicts {name, phase, ready, restarts, tag,
    waiting_reason} for the deployment's pods. Raises RolloutError on query
    failure. Uses the first container per pod (matches the single-container
    app-deployment assumption)."""
    cmd = [
        "kubectl", "--context", target["context"], "-n", target["namespace"],
        "get", "pods", "-l", selector, "-o", "json",
    ]
    try:
        out = run_cmd(cmd)
    except subprocess.CalledProcessError as e:
        raise RolloutError(
            f"kubectl get pods -l {selector} (ctx {target['context']}, "
            f"ns {target['namespace']}) failed: {(e.stderr or '').strip()}"
        )
    try:
        data = json.loads(out) if out else {"items": []}
    except json.JSONDecodeError as e:
        raise RolloutError(f"could not parse `kubectl get pods` JSON: {e}")

    pods = []
    for item in data.get("items", []):
        status = item.get("status", {}) or {}
        cstatuses = status.get("containerStatuses") or []
        ready = False
        restarts = 0
        tag = None
        waiting_reason = None
        if cstatuses:
            c0 = cstatuses[0]
            ready = bool(c0.get("ready", False))
            restarts = c0.get("restartCount", 0)
            tag = image_tag(c0.get("image", ""))
            waiting = (c0.get("state", {}) or {}).get("waiting")
            if waiting:
                waiting_reason = waiting.get("reason")
        pods.append({
            "name": (item.get("metadata", {}) or {}).get("name", "<unknown>"),
            "phase": status.get("phase"),
            "ready": ready,
            "restarts": restarts,
            "tag": tag,
            "waiting_reason": waiting_reason,
        })
    return pods


# --- Evaluation ------------------------------------------------------------

def on_target(pod, short_sha):
    return bool(pod["tag"]) and pod["tag"].lower().startswith(short_sha)


def evaluate_rollout(targets, short_sha, selector_tmpl,
                     merge_sha=None, repo=None, containment_cache=None):
    """One rollout-status pass over all targets. Returns (exit_code, message)
    where exit_code is None to mean 'still rolling, keep polling'.

    When a target's deployed tag is not ours, we ask whether it names a commit
    that CONTAINS ours (merge-queue batch head) before concluding anything --
    see classify_deployed_tag. Only proven containment counts; everything else
    keeps the target in the 'still rolling' bucket."""
    if containment_cache is None:
        containment_cache = {}
    all_done = True
    wedged = []
    waiting = []
    batched = []

    for t in targets:
        label, dep = t["env"], t["deployment"]
        try:
            spec_tag = get_spec_image_tag(t)
            selector = selector_tmpl.format(deployment=dep)
            pods = get_pods(t, selector)
        except RolloutError as e:
            return EXIT_ERROR, str(e)

        # The SHA prefix this target's pods are judged against. Normally ours;
        # it becomes the batch head's only after containment is proven.
        effective_sha = short_sha
        spec_ok = bool(spec_tag) and spec_tag.lower().startswith(short_sha)

        if not spec_ok and spec_tag and merge_sha:
            cls = classify_deployed_tag(repo, merge_sha, spec_tag,
                                        containment_cache)
            if cls["kind"] == "contained":
                effective_sha = cls["sha"][:SHORT_SHA_LEN]
                spec_ok = True
                batched.append(
                    f"[{label}] {dep}: deployed as {cls['sha'][:SHORT_SHA_LEN]}, "
                    f"which contains {short_sha} (compare status "
                    f"{cls['status']})"
                )
                print(f"  [{label}] {dep}: deployed tag {spec_tag} resolves to "
                      f"{cls['sha'][:SHORT_SHA_LEN]}, which CONTAINS our commit "
                      f"{short_sha} -- merge-queue batch head; judging pods "
                      f"against {effective_sha}")
            elif cls["kind"] == "unrelated":
                print(f"  [{label}] {dep}: deployed tag {spec_tag} resolves to "
                      f"{cls['sha'][:SHORT_SHA_LEN]}, which does NOT contain "
                      f"our commit (compare status {cls['status']})")
            else:
                print(f"  [{label}] {dep}: deployed tag {spec_tag} not proven "
                      f"to contain our commit ({cls['reason']})")

        print(f"  [{label}] {dep}: spec tag={spec_tag} "
              f"({'on target' if spec_ok else 'NOT on target'})")

        # Wedged detection, scoped to new-revision pods so a pre-existing
        # crashloop on the OLD revision doesn't masquerade as this rollout's
        # failure. An image-pull failure still sets the pod's image to the
        # requested (target) tag, so it is correctly counted as on-target.
        for p in pods:
            is_wedged = on_target(p, effective_sha) and (
                p["waiting_reason"] in WEDGED_WAITING_REASONS
                or p["restarts"] >= RESTART_SPIKE_THRESHOLD
            )
            mark = ""
            if is_wedged:
                reason = p["waiting_reason"] or f"{p['restarts']} restarts"
                wedged.append(f"[{label}] {p['name']}: {reason} (tag={p['tag']})")
                mark = f"   <-- WEDGED ({reason})"
            print(f"      pod {p['name']}: phase={p['phase']} "
                  f"ready={p['ready']} restarts={p['restarts']} "
                  f"tag={p['tag']}{mark}")

        if not spec_ok:
            all_done = False
            waiting.append(f"[{label}] {dep}: deploy spec not yet bumped")
            continue
        if not pods:
            all_done = False
            waiting.append(f"[{label}] {dep}: no pods yet")
            continue

        # Fully rolled out only when EVERY pod under the selector is on the
        # target tag and Running+Ready -- old-revision pods still terminating
        # keep this False, which is correct (rollout isn't done until they go).
        healthy = all(
            on_target(p, effective_sha) and p["phase"] == "Running" and p["ready"]
            for p in pods
        )
        if healthy:
            print(f"      => {label}/{dep} rolled out & healthy")
        else:
            all_done = False
            waiting.append(f"[{label}] {dep}: pods updating")

    # Precedence: a wedged pod is actionable even if other targets are still
    # legitimately rolling -- surface it so the agent stops idle-polling.
    if wedged:
        return EXIT_ACTION_NEEDED, (
            "Wedged pod(s) -- rollout will not self-complete:\n  - "
            + "\n  - ".join(wedged)
        )
    if all_done and batched:
        # Terminal success, but NOT under our own tag: report it distinctly so
        # nobody records "deployed as <our sha>" when the registry and the
        # cluster only ever saw the batch head's tag.
        return EXIT_DEPLOYED_AS_ANCESTOR, (
            "Your commit IS deployed, as an ancestor of a later commit "
            "(merge-queue batch head). All targets healthy:\n  - "
            + "\n  - ".join(batched)
        )
    if all_done:
        return EXIT_ALL_MET, "All targets rolled out and healthy."
    return None, "; ".join(waiting) or "still rolling"


# --- Budget helpers --------------------------------------------------------

def sleep_within_budget(deadline, interval):
    """Sleep one interval if at least that much budget remains. Returns True
    if it slept, False if the budget is spent (caller should return idle)."""
    remaining = deadline - time.monotonic()
    if remaining <= interval:
        return False
    time.sleep(interval)
    return True


# --- Main ------------------------------------------------------------------

def parse_args(argv=None):
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    src = parser.add_argument_group("merged commit source (one required)")
    src.add_argument("--pr", type=int,
                     help="PR number; poll until MERGED, then use its merge "
                          "commit SHA.")
    src.add_argument("--merge-sha",
                     help="Merge commit SHA directly (skip PR polling).")
    parser.add_argument("--repo",
                        help="owner/repo for --pr and for merge-queue "
                             "batch-head containment checks (default: gh "
                             "auto-detects from cwd).")
    parser.add_argument(
        "--no-batch-head-detect", action="store_true",
        help="Disable merge-queue batch-head detection: never accept a "
             "deployed tag other than our own, even when the commit it names "
             "provably contains ours. Exit 4 then becomes unreachable.",
    )
    parser.add_argument(
        "--target", action="append", default=[], metavar="ENV:CTX:NS:DEPLOY",
        help="Rollout target as ENV:CONTEXT:NAMESPACE:DEPLOYMENT. Repeatable "
             "(one per env+deployment pair). Required at least once.",
    )
    parser.add_argument(
        "--pod-selector", default=DEFAULT_SELECTOR,
        help=f"Pod label selector template; '{{deployment}}' is substituted "
             f"(default: {DEFAULT_SELECTOR!r}).",
    )
    parser.add_argument(
        "--budget-seconds", type=int, default=DEFAULT_BUDGET_SEC,
        help=f"Max wall-clock budget per invocation (default: "
             f"{DEFAULT_BUDGET_SEC}). Capped by the Anthropic prompt-cache TTL; "
             f"re-invoke in a loop rather than raising this.",
    )
    parser.add_argument(
        "--interval", type=int, default=DEFAULT_INTERVAL_SEC,
        help=f"Seconds between polls within one invocation (default: "
             f"{DEFAULT_INTERVAL_SEC}).",
    )
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)

    if not args.pr and not args.merge_sha:
        print("error: one of --pr or --merge-sha is required", file=sys.stderr)
        sys.exit(EXIT_ERROR)
    if not args.target:
        print("error: at least one --target is required", file=sys.stderr)
        sys.exit(EXIT_ERROR)
    try:
        targets = [parse_target(t) for t in args.target]
    except ValueError as e:
        print(f"error: {e}", file=sys.stderr)
        sys.exit(EXIT_ERROR)

    deadline = time.monotonic() + args.budget_seconds

    # Phase 1: resolve the merged commit SHA.
    merge_sha = args.merge_sha
    if merge_sha is None:
        print(f"Polling PR #{args.pr} for merge...")
        while True:
            state, sha = get_merge_state(args.pr, args.repo)
            if state == "MERGED" and sha:
                merge_sha = sha
                print(f"PR #{args.pr} merged at {sha}")
                break
            print(f"  PR #{args.pr}: state={state}, not merged yet")
            if not sleep_within_budget(deadline, args.interval):
                print("\nBudget elapsed; PR not merged yet. Re-invoke.")
                sys.exit(EXIT_STILL_WAITING)

    if len(merge_sha) < SHORT_SHA_LEN:
        print(f"error: merge SHA {merge_sha!r} shorter than {SHORT_SHA_LEN} "
              f"chars", file=sys.stderr)
        sys.exit(EXIT_ERROR)
    merge_sha = merge_sha.lower()
    short_sha = merge_sha[:SHORT_SHA_LEN]

    # owner/repo for the containment checks. Resolved once per invocation; a
    # failure here only disables batch-head detection (the checks then report
    # "unknown"), it is never fatal.
    repo = None
    if not args.no_batch_head_detect:
        repo = resolve_repo(args.repo)
        if repo is None:
            print("warning: could not determine owner/repo; merge-queue "
                  "batch-head detection disabled (pass --repo to enable)",
                  file=sys.stderr)

    print(f"Target image tag prefix: {short_sha}")
    print(f"Targets ({len(targets)}):")
    for t in targets:
        print(f"  - {t['env']}: {t['deployment']} "
              f"(ctx {t['context']}, ns {t['namespace']})")
    print(f"Budget: {args.budget_seconds}s @ {args.interval}s intervals")

    # Phase 2: watch the rollout. The containment cache lives across iterations
    # of this invocation so a repeated deployed tag costs no extra API calls.
    containment_cache = {}
    iteration = 0
    while True:
        iteration += 1
        print(f"\n--- rollout check {iteration} ---")
        code, msg = evaluate_rollout(
            targets, short_sha, args.pod_selector,
            merge_sha=None if args.no_batch_head_detect else merge_sha,
            repo=repo, containment_cache=containment_cache,
        )
        if code is not None:
            print(f"\n{msg}")
            sys.exit(code)
        if not sleep_within_budget(deadline, args.interval):
            print(f"\nBudget elapsed; still rolling ({msg}). Re-invoke.")
            sys.exit(EXIT_STILL_WAITING)
        print(f"  ...sleeping {args.interval}s ({msg})")


if __name__ == "__main__":
    main()
