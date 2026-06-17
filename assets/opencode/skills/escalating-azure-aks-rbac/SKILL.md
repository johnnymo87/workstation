---
name: escalating-azure-aks-rbac
description: Use when a kubectl write operation (patch, scale, set env, exec, delete, rollout restart) against a Wonder production AKS cluster fails with a Forbidden / RBAC error, or when you need to self-activate the time-boxed Azure "Kubernetes Service RBAC Writer" role via PIM. Explains the read-vs-write Azure RBAC model and points to the Confluence runbook that holds the exact subscription, cluster, role-definition, and scope IDs (kept out of source control).
---

# Escalating Azure AKS prod RBAC (PIM self-activation)

Wonder production AKS clusters authorize with **Azure RBAC for Kubernetes**. You
get **READ** by default (via an AAD group), but **WRITE** — `kubectl patch`,
`scale`, `set env`, `exec`, `delete`, `rollout restart`, etc. — requires the
**Azure Kubernetes Service RBAC Writer** role. That role is handed out as a
PIM-**eligible** (not active) assignment through a group, so you must
**self-activate** it via PIM for a short, time-boxed window before the write
will succeed. No User Access Administrator / Owner role is involved; PIM
activation is the supported path.

The flow is always: **discover what you're eligible for → activate
(SelfActivate) for a duration → wait for propagation → verify with
`auth can-i` → (optionally) deactivate early.**

## Get the exact commands and IDs from Confluence

The subscription, cluster, resource-group, role-definition, and scope IDs are
environment-specific and **deliberately not stored in this repo**. They live in
one Confluence page, which is the single source of truth:

**Runbook:** [Azure Kubernetes (AKS) prod RBAC self-escalation via PIM](https://wonder.atlassian.net/wiki/spaces/Platform/pages/5386600450) — Confluence space `Platform`, page id `5386600450`.

Two ways to read it:

1. **Companion file (preferred).** This skill ships a fetched copy of the
   runbook as [INTERNAL.md](INTERNAL.md) in this directory, pulled from the
   Confluence page above during `home-manager switch`. Read it for the exact,
   copy-paste-ready commands and IDs.
2. **Fetch it live.** If `INTERNAL.md` is missing or stale, fetch the page
   directly. Use the `using-atlassian` skill:
   ```bash
   nvim --headless out.md -c "FetchConfluencePage 5386600450" -c "write" -c "quit"
   ```
   or re-run `home-manager switch` (requires Atlassian env vars) to refresh the
   companion file.

**Do not** paste the subscription / cluster / role / principal IDs back into
this skill or anywhere else in the workstation repo — that's the whole point of
the Confluence split.

## What you'll do (generic outline)

The runbook spells out each command with real IDs. In generic terms:

1. Point `az` at the **prod** subscription (the default context is often a
   non-prod subscription — this is the #1 gotcha).
2. List your eligible role assignments with `az rest ... roleEligibilityScheduleInstances?...&$filter=asTarget()` and note the `roleEligibilityScheduleId`.
3. Get **your own** user object id (`az ad signed-in-user show --query id -o tsv`) — the activation `principalId` is your user oid, never the group's.
4. PUT a `roleAssignmentScheduleRequests` with `requestType: SelfActivate`,
   your `principalId`, the writer `roleDefinitionId`, the
   `linkedRoleEligibilityScheduleId` from step 2, and an
   `expiration.duration` (e.g. `PT2H`). Success = `status: Provisioned`.
5. Wait ~1–5 min for Azure RBAC to propagate to the AKS authz webhook, then
   poll `kubectl --context <cluster> -n <ns> auth can-i patch deployments`
   until it returns `yes`.
6. Optionally deactivate early with `requestType: SelfDeactivate`; otherwise it
   auto-expires.

Activation is **per-cluster scope** — activating for one cluster does not grant
write on another. Repeat with that cluster's scope.

## Related

- **[working-with-kubernetes](../working-with-kubernetes/SKILL.md)** — generic
  `kubectl` patterns (exec, cp, debugging distroless, kubeconfig). Use it once
  you've activated write access here. A `Forbidden` on a write verb there is the
  signal to come back to this skill.
- **[using-atlassian](../using-atlassian/SKILL.md)** — how to fetch the
  Confluence runbook if the companion `INTERNAL.md` is missing.
