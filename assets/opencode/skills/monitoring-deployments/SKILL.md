---
name: monitoring-deployments
description: Use when a merged PR's change still needs to reach its Kubernetes environments -- watching a merged commit roll out to UAT/PROD until the new image is live and pods are healthy, or diagnosing a stuck rollout (deploy not bumped, CrashLoopBackOff, ImagePullBackOff, restart spike), or when a merged commit has no deploy check because a merge queue batched it behind a later commit. Work-only; kubectl/AKS-based.
---

# Monitoring Deployments

Merged is not deployed. A PR can merge green and still fail to reach prod: the
image build breaks, the GitOps controller never bumps the deployment, or the
new pods crashloop. This skill is `shepherding-pull-requests` one lifecycle
phase later -- you hold the *rollout* the way that skill holds the PR, until
the merged commit is actually running and healthy, or until there's a real
decision (fix-forward vs roll back) for the user to make.

## When to use

- You merged a change to a repo with continuous deployment to Kubernetes and
  want to confirm it lands in each environment (e.g. UAT then PROD).
- A rollout looks stuck and you need to tell "still progressing" from "wedged."
- Your merge commit has no deploy check at all and you need to tell "the
  pipeline never ran" from "the merge queue batched you behind a later commit"
  (see "Merge queues" below — assume batching first).

**When NOT to use:** non-k8s deploy targets (Lambda, serverless, static
hosting); pre-merge work (that's `shepherding-pull-requests`).

## Targets live in INTERNAL.md, not here

The cluster contexts, namespaces, deployments, image registry, and tag
convention are environment-specific and **deliberately kept out of this repo**.
They live in this skill's Confluence-fetched companion:

- **[INTERNAL.md](INTERNAL.md)** — fetched during `home-manager switch` (same
  mechanism as `working-with-kubernetes` / `escalating-azure-aks-rbac`). It
  lists each `ENV:CONTEXT:NAMESPACE:DEPLOYMENT` target and notes the image tag
  convention. Read it to get the exact `--target` values below.

If `INTERNAL.md` is absent (not yet fetched, or the page doesn't exist), the
tooling still works — supply `--target` values directly. Never paste real
cluster/namespace/registry names back into this SKILL.md or the script.

## Tooling: monitor-rollout.py

A companion script polls the rollout and prints the next action. It mirrors
`shepherding-pull-requests/monitor-pr.py`: each invocation has a ~60s
wall-clock budget (Anthropic prompt-cache TTL is 5 min; a longer blocking call
expires warm cache), so **you re-invoke it in a loop** — the script owns the
within-60s pacing, you own the loop and the fix step.

```bash
python ~/.config/opencode/skills/monitoring-deployments/monitor-rollout.py \
  --pr <PR> \
  --target <ENV:CTX:NS:DEPLOY> [--target ...]
```

It waits for the PR to merge, derives the image tag from the merge commit's
short SHA (prefix match, tolerant of a `_N` build-attempt suffix), then watches
each target's deployment spec image and pod health.

| Exit code | Meaning | What to do |
|---|---|---|
| `0` | All targets on the new tag, pods Running+Ready | Done. |
| `1` | A new-revision pod is wedged (CrashLoopBackOff / image-pull error / restart spike) | Read stdout, investigate (step below), then re-invoke or escalate. |
| `2` | Unrecoverable (gh/kubectl failed, unknown context, missing deployment) | Surface to user; don't silently retry. |
| `3` | Still rolling (merge pending, spec not bumped, pods updating) | Re-invoke immediately. |
| `4` | Deployed **as an ancestor** of a later commit, pods healthy (merge-queue batch — see below) | Done. Record the batch head as the deployed SHA, not yours. |

Pass `--merge-sha <sha>` instead of `--pr` to skip merge polling; `--repo
owner/repo` if not in the repo dir; `--pod-selector` if pods aren't labeled
`app=<deployment>`. Run `--help` for the rest.

## Merge queues: the deploy runs on the batch head, not on your commit

**This is the single most expensive misread in this skill.** If the repo has
GitHub's merge queue enabled, the queue **batches** several PRs into one push
to the trunk. Your PR merges as commit A; another PR merges on top as commit B
minutes later, in the same batch; the deploy pipeline attaches to the **batch
head** (B) only. Commit A ends up with a full set of CI check-runs and *zero*
deploy checks — permanently. Nothing is broken.

Two ways this bites:

- **The monitor never converges.** `--merge-sha A` prints "deploy spec not yet
  bumped" forever, because the deployed image tag is derived from B. A
  *successful* rollout looks like a wedged one.
- **"No deploy check on my merge commit" reads as "the pipeline never
  triggered."** It didn't trigger *on A*, and never will. Investigating that as
  a pipeline failure is a bogus investigation.

**Diagnostic heuristic:** on an unbatched merge the deploy check appears within
*seconds* of the merge (calibrate once on your own unbatched merge and remember
the number). So more than a couple of minutes of silence on your merge commit
means *look for a batch head*, not *the pipeline is broken*.

### Procedure (also what the script automates)

```bash
# 1. Newest trunk commit at or above your merge commit -- the batch head.
gh api repos/<owner>/<repo>/commits --jq '.[0:5][] | "\(.sha[0:7]) \(.commit.message | split("\n")[0])"'

# 2. Prove containment. Expect "ahead" (or "identical"). Anything else --
#    "behind", "diverged" -- means that commit does NOT contain yours; stop.
gh api repos/<owner>/<repo>/compare/<yours>...<batchhead> --jq .status

# 3. Re-run the monitor against the batch head.
python monitor-rollout.py --merge-sha <BATCH HEAD> --target <ENV:CTX:NS:DEPLOY>
```

### What the script does automatically

When the deployed tag isn't yours, `monitor-rollout.py` resolves that tag to a
real commit and runs the same `compare` check. If — and only if — GitHub
reports the deployed commit is `ahead`/`identical` relative to yours, it judges
pod health against the batch head's tag and exits **`4`** with "your commit IS
deployed, as an ancestor of `<batch head>`".

It cannot false-pass: a newer-looking tag is never *assumed* to contain you.
Any tag it can't resolve, or can't prove containment for, stays exit `3` (still
rolling). Disable the whole mechanism with `--no-batch-head-detect`, and pass
`--repo <owner>/<repo>` when running outside the repo dir (without it the
containment check can't run and you silently get exit `3` forever — the script
warns on stderr when this happens).

Exit `4` is deliberately not `0`: the tag in the registry and in the cluster is
the batch head's, not yours. Report it that way.

## The fix step (yours, not the script's)

On exit `1` the script tells you *which* pod and *why*; deciding what to do is
yours:

- **CrashLoopBackOff / restart spike** → `kubectl --context <c> -n <ns> logs <pod>`
  (add `--previous`) to find the crash. App bug introduced by the change → fix
  forward or roll back; surface the choice to the user.
- **ImagePullBackOff / ErrImagePull** → the tag isn't in the registry. Usually
  the image-build CI hasn't finished or failed — check that before assuming a
  deploy problem.
- **Forbidden on a write you attempt** (rollback, restart) → see
  `escalating-azure-aks-rbac`.

A wedged rollout will not self-heal. Don't idle-poll it — act or escalate.

## Manual fallback (script not deployed)

```bash
# Did the GitOps controller bump the deployment to the new tag?
kubectl --context <c> -n <ns> get deploy <d> \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
# Are the new pods healthy?
kubectl --context <c> -n <ns> get pods -l app=<d>
kubectl --context <c> -n <ns> rollout status deploy/<d> --timeout=0
```

Match the running image tag's short-SHA prefix to the PR's merge commit — or,
on a merge-queue repo, to the batch head that contains it (verify with
`gh api repos/<owner>/<repo>/compare/<yours>...<deployed> --jq .status` →
`ahead`).

## Related

- **`shepherding-pull-requests`** — the phase before this one (open → merged).
- **`working-with-kubernetes`** — generic kubectl patterns (logs, exec, describe).
- **`escalating-azure-aks-rbac`** — when a write verb returns `Forbidden`.
