---
name: monitoring-deployments
description: Use when a merged PR's change still needs to reach its Kubernetes environments -- watching a merged commit roll out to UAT/PROD until the new image is live and pods are healthy, or diagnosing a stuck rollout (deploy not bumped, CrashLoopBackOff, ImagePullBackOff, restart spike). Work-only; kubectl/AKS-based.
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

Pass `--merge-sha <sha>` instead of `--pr` to skip merge polling; `--repo
owner/repo` if not in the repo dir; `--pod-selector` if pods aren't labeled
`app=<deployment>`. Run `--help` for the rest.

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

Match the running image tag's short-SHA prefix to the PR's merge commit.

## Related

- **`shepherding-pull-requests`** — the phase before this one (open → merged).
- **`working-with-kubernetes`** — generic kubectl patterns (logs, exec, describe).
- **`escalating-azure-aks-rbac`** — when a write verb returns `Forbidden`.
