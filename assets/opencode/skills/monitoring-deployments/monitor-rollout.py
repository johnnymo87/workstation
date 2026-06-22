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
      esac
    done
"""
import argparse
import json
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

# Exit codes -- documented so callers (and SKILL.md) can branch on them.
EXIT_ALL_MET = 0
EXIT_ACTION_NEEDED = 1
EXIT_ERROR = 2
EXIT_STILL_WAITING = 3


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
    return bool(pod["tag"]) and pod["tag"].startswith(short_sha)


def evaluate_rollout(targets, short_sha, selector_tmpl):
    """One rollout-status pass over all targets. Returns (exit_code, message)
    where exit_code is None to mean 'still rolling, keep polling'."""
    all_done = True
    wedged = []
    waiting = []

    for t in targets:
        label, dep = t["env"], t["deployment"]
        try:
            spec_tag = get_spec_image_tag(t)
            selector = selector_tmpl.format(deployment=dep)
            pods = get_pods(t, selector)
        except RolloutError as e:
            return EXIT_ERROR, str(e)

        spec_ok = bool(spec_tag) and spec_tag.startswith(short_sha)
        print(f"  [{label}] {dep}: spec tag={spec_tag} "
              f"({'on target' if spec_ok else 'NOT on target'})")

        # Wedged detection, scoped to new-revision pods so a pre-existing
        # crashloop on the OLD revision doesn't masquerade as this rollout's
        # failure. An image-pull failure still sets the pod's image to the
        # requested (target) tag, so it is correctly counted as on-target.
        for p in pods:
            is_wedged = on_target(p, short_sha) and (
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
            on_target(p, short_sha) and p["phase"] == "Running" and p["ready"]
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
                        help="owner/repo for --pr (default: gh auto-detects "
                             "from cwd).")
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
    short_sha = merge_sha[:SHORT_SHA_LEN]

    print(f"Target image tag prefix: {short_sha}")
    print(f"Targets ({len(targets)}):")
    for t in targets:
        print(f"  - {t['env']}: {t['deployment']} "
              f"(ctx {t['context']}, ns {t['namespace']})")
    print(f"Budget: {args.budget_seconds}s @ {args.interval}s intervals")

    # Phase 2: watch the rollout.
    iteration = 0
    while True:
        iteration += 1
        print(f"\n--- rollout check {iteration} ---")
        code, msg = evaluate_rollout(targets, short_sha, args.pod_selector)
        if code is not None:
            print(f"\n{msg}")
            sys.exit(code)
        if not sleep_within_budget(deadline, args.interval):
            print(f"\nBudget elapsed; still rolling ({msg}). Re-invoke.")
            sys.exit(EXIT_STILL_WAITING)
        print(f"  ...sleeping {args.interval}s ({msg})")


if __name__ == "__main__":
    main()
