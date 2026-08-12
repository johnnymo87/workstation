---
name: swarm-shaped-work
description: Use when planning a multi-piece task to decide whether to swarm (spawn parallel worker sessions) or do the work serially in one session. Covers the heuristic, the flat coordinator-free topology, and the spin-up sequence.
---

# Swarm-Shaped Work

A "swarm" is a small set of opencode sessions on the same machine that cooperate on one outcome. Every session is a **worker** — each owns one slice of the work.

The topology is **flat**. There is no coordinator session: the role is banned (see the `swarm-messaging` skill for the full argument — in short, a coordinator doubles the message count, and messages are the dominant cost of a swarm). Shared context lives in a **durable artifact** (beads, a plan file), the human is the integration point, and workers talk to each other directly.

This skill answers: when is a task swarm-shaped, and how do you spin one up.

## When To Reach For A Swarm

The strongest signal is **multiple repos with dependencies between them that require timing/coordination**. Concrete shape from real work:

- Backend in repo A, frontend in repo B, proto definitions in repo C, BigQuery views in repo D — each repo has its own build, tests, conventions, and devloop. A change touches all four.
- Dependencies between them: proto defs must land before consumers; backend must deploy before the frontend can pull schema; etc.
- Each slice is too large to comfortably hold in one session alongside the others (separate context windows pay off).

Other signals that often accompany the above:

- The work has clear hand-off points between slices (worker-to-worker notifications matter).
- The total wall-clock time is long enough that parallelism is worth the coordination tax (rule of thumb: > ~1 hour of total work).
- Some slices need human-in-the-loop decisions. The session that needs the decision asks the human directly.

## When NOT To Swarm

- **Single-repo, single-subsystem changes.** A bug fix in one codebase, even if it touches multiple files, is usually faster sequentially.
- **You don't have a clear decomposition.** If you can't write down "Worker A does X, Worker B does Y, here are the integration points", you don't have a swarm-shaped task — you have an exploratory task. Do that solo first; swarm later if a shape emerges.
- **The slices race on the same files.** Workers must own disjoint surface area or they'll fight for git locks and you'll spend more time merging than implementing.
- **The coordination overhead exceeds the parallel speedup.** A 4-worker swarm where each worker takes 5 minutes is probably not worth the spin-up + envelope traffic.
- **You cannot specify the slices up front.** With no coordinator to assign work at runtime, each worker's slice must be fully described in its launch prompt. If you cannot write those prompts, you are not ready to swarm.

## Roles

### The shared artifact (not a session)

What a coordinator used to hold in its context goes in a file instead: the design doc / plan file with the decomposition, the integration order, and the hand-off conditions; plus beads for live state. A document is read on demand, by everyone, for zero messages.

Write it **before** you launch anything, and give every worker its path.

### Workers

Every session is a worker. Each owns one slice — typically one repo or one subsystem. Its job:

- Plan and execute that slice, in its own session, with its own context window.
- Notify peers **directly** when it hits a hand-off point ("BE: my API is deployed; FE: pull schema now").
- Record durable state in beads / the plan file, so peers can **pull** it instead of asking.
- Report its own finished deliverable **to the human, once**. Not to another session for forwarding.
- Ask the human directly when blocked on a decision only a human can make.

## Spin-Up Sequence

The mechanism is the existing tools — there's no `swarm spawn` command. You orchestrate it from a single planning session (or from a shell):

### 1. Decompose into a durable artifact

Write a plan file (`docs/plans/...`) — **not** a session's context — containing:

- For each worker: which dir, what slice, what hand-off points it owns, what "done" means.
- The integration order and the dependency edges ("protos must land before BE").
- The communication graph: who needs to know what from whom. (E.g. "worker A → worker B at proto-published, worker B → worker C at deploy-complete".)

If you can't write this, don't swarm (see "When NOT To Swarm").

### 2. Launch each worker

For each worker, launch from its own dir with a prompt that includes:

- Its slice of the work, and the path to the plan file.
- The other workers' session ids for its known direct hand-offs (e.g. BE → FE for "schema is live"). A worker that doesn't know its peers' ids will route through someone, and that someone becomes an accidental coordinator.
- An explicit statement that there is no coordinator: report to the human, pull peer state rather than asking for it.

**Workers are writable — launch them with `--worktree <slug>`.** A swarm worker
edits code, so it must NOT start in a repo's primary root (in mono that's the
read-only trunk the guard protects). `--worktree <slug>` runs `work <slug>` in
`<worker-dir>` and lands the session in a fresh `.worktrees/<slug>` off the
local trunk, so the worker is isolated and the read-only-main guard is bypassed
by construction. Give each worker a distinct slug (its role/ticket) to avoid
collisions. The worktree is reclaimed automatically once its branch merges (the
nightly `reset-workspace` runs `work --prune-merged`).

```bash
opencode-launch --worktree be-proj-1234 <worker-dir> "$(cat <<'PROMPT'
You are the BE worker for PROJ-1234. Your slice: implement the GraphQL
endpoints for X. You are in a fresh worktree off trunk — commit here and open
a PR from this branch when done.

There is NO coordinator in this swarm. Report your finished slice to the human
directly, once. Do not send progress updates to anyone. To learn what a peer is
doing, read its beads/PR rather than asking it.

Peers: FE=ses_<fe-id>, protos=ses_<protos-id>

When your API is deployed, use the `swarm_send` tool (to=ses_<fe-id>, kind=status.update, message="API live at /v2/foo") so the FE can proceed.

Plan: docs/plans/...
PROMPT
)"
```

Capture each worker's session id.

### 3. Distribute the roster

Every worker needs every other worker's id. Ids only exist after launch, so this is one message per worker — the last unavoidable broadcast:

```
Swarm roster (no coordinator — report to the human, message peers directly):
- BE:     ses_<be-id>
- FE:     ses_<fe-id>
- protos: ses_<protos-id>
- dbt:    ses_<dbt-id>
```

Fold the "begin now" instruction into this same message rather than sending a second one.

### 4. Kick off

Each worker starts its slice immediately. It reports to the human when its slice is done, and messages a peer only at a hand-off point.

## Communication Patterns

Once the swarm is live, all cross-session messaging goes through the `swarm_send` tool (see the `swarm-messaging` skill for the full protocol). `from` is filled in automatically from the calling session.

Useful conventions (all are `swarm_send` calls):

- **Hand-off, worker to worker**: `to=ses_<peer-worker>, kind=status.update, message="API deployed at /v2/foo"` — sent only when the peer's next action depends on it.
- **Deliverable, worker to human**: report your own slice yourself, once, when it's done. No session forwards for another.
- **Blocked on a human decision**: ask the human directly.
- **Wondering how a peer is doing**: don't send anything. Read its beads, branch, PR, or session transcript.
- **Threading replies**: set `reply_to=<their-msg-id>` so receivers can follow conversation chains.
- **Discovery**: don't have a peer's id? Call `swarm_list`.
- **Backlog / replay**: receivers can call `swarm_read` to fetch their inbox if they suspect they missed a message.

Everything else — acks, "starting now", progress percentages, status round-ups — is banned by the message-economy rules in `swarm-messaging`.

## Tear-Down

When the work is done:

```bash
# From any shell on the same machine (via front door, no creds needed)
curl -sf -X DELETE http://127.0.0.1:4700/session/ses_<worker-id>
# ... etc (or against raw port :4096 with -u "opencode:$(cat /run/secrets/opencode_server_password)")

# Or from Telegram
/kill <session-id>
```

Or just let the session reaper expire them after 1 week of inactivity.

Old swarm messages stay in the daemon's `swarm_messages` table. They aren't auto-cleaned yet (see pigeon's `swarm-operations` skill for the manual cleanup query). Stale/queued messages targeting deleted sessions will exhaust their retry budget and terminally `fail` — this is fine.

## Anti-Patterns

- **Appointing a coordinator.** Banned. It doubles message count, and messages are the cost. See `swarm-messaging`.
- **Growing one by accident.** A worker that everyone reports to, or that everyone asks for status, has become a coordinator whether or not you called it one. Warning signs: one session's transcript is mostly `swarm_send` calls; the human hears findings second-hand; a worker asks a peer "how's it going?" instead of reading its beads.
- **Spinning up workers without giving them each other's ids.** They can't coordinate directly and will funnel everything through whoever they do know, manufacturing a coordinator.
- **Spawning more workers than there are decoupled slices.** Two workers fighting over the same code is worse than one worker doing both.
- **Forgetting `--reply-to` in chained conversations.** Without threading, the receiver has to reconstruct context from prose. Cheap to set; expensive to omit.
- **Not telling workers how to escalate.** Workers that don't know they should ask the human directly will silently get stuck, or make decisions that should have been the human's.

## See Also

- [`opencode-launch`](../opencode-launch/SKILL.md) — spawn headless sessions.
- [`swarm-messaging`](../swarm-messaging/SKILL.md) — message economy, the coordinator ban, sender + receiver protocol; the `swarm_send`/`swarm_read`/`swarm_list` tools; envelope format; kinds; replay.
- pigeon repo `swarm-architecture` / `swarm-operations` skills — daemon internals if you need to debug delivery.
