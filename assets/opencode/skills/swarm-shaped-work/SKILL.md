---
name: swarm-shaped-work
description: Use when planning a multi-piece task to decide whether to swarm (spawn parallel coordinator + worker sessions) or do the work serially in one session. Covers the heuristic, the topology, and the spin-up sequence.
---

# Swarm-Shaped Work

A "swarm" is a small set of opencode sessions on the same machine that cooperate on one outcome. One session is the **coordinator** (holds shared context, single point of contact for the human); the others are **workers** (each focused on one slice of the work).

This skill answers: when is a task swarm-shaped, what is each role for, and how do you spin one up.

## When To Reach For A Swarm

The strongest signal is **multiple repos with dependencies between them that require timing/coordination**. Concrete shape from real work:

- Backend in repo A, frontend in repo B, proto definitions in repo C, BigQuery views in repo D — each repo has its own build, tests, conventions, and devloop. A change touches all four.
- Dependencies between them: proto defs must land before consumers; backend must deploy before the frontend can pull schema; etc.
- Each slice is too large to comfortably hold in one session alongside the others (separate context windows pay off).

Other signals that often accompany the above:

- The work has clear hand-off points between slices (worker-to-worker notifications matter).
- The total wall-clock time is long enough that parallelism is worth the coordination tax (rule of thumb: > ~1 hour of total work).
- Some slices need human-in-the-loop decisions you'd rather field one at a time through a single point of contact (the coordinator).

## When NOT To Swarm

- **Single-repo, single-subsystem changes.** A bug fix in one codebase, even if it touches multiple files, is usually faster sequentially.
- **You don't have a clear decomposition.** If you can't write down "Worker A does X, Worker B does Y, here are the integration points", you don't have a swarm-shaped task — you have an exploratory task. Do that solo first; swarm later if a shape emerges.
- **The slices race on the same files.** Workers must own disjoint surface area or they'll fight for git locks and you'll spend more time merging than implementing.
- **The coordination overhead exceeds the parallel speedup.** A 4-worker swarm where each worker takes 5 minutes is probably not worth the spin-up + envelope traffic.

## Roles

### Coordinator

The coordinator is the **shared-memory + human-interface** role. Its jobs:

- **Hold shared context.** The Jira ticket, the design doc, the cross-cutting state. Workers don't all need to load the full ticket; they get the slice relevant to them.
- **Single point of contact for the human.** You message the coordinator; it distributes (or aggregates) for the swarm.

The coordinator is **NOT** a chokepoint for worker-to-worker traffic. Workers can swarm-message each other directly when only those two need to know. They loop the coordinator in only when the coordinator's shared-context role actually matters (cross-cutting state, human-facing decisions, integration timing across more than two parties).

### Workers

Each worker owns one slice of the work — typically one repo or one subsystem. Its job:

- Plan and execute that slice, in its own session, with its own context window.
- Notify peers directly when it hits a hand-off point ("BE: my API is deployed; FE: pull schema now").
- Notify the coordinator when shared-context-relevant things happen ("Done with my slice", "Blocked on a decision I need the human to weigh in on").

## Spin-Up Sequence

The mechanism is the existing tools — there's no `swarm spawn` command. You orchestrate it from a single planning session (or from a shell):

### 1. Decompose

Write down (in the planning session, on paper, in a doc — somewhere durable):

- The coordinator's purpose: "hold the design for COPS-1234, field human decisions, broker integration timing".
- For each worker: which dir, what slice, what hand-off points it owns.
- The communication graph: who needs to know what from whom. (E.g. "worker A → worker B at proto-published, worker B → worker C at deploy-complete".)

### 2. Launch the coordinator

```bash
opencode-launch <coordinator-dir> "$(cat <<'PROMPT'
You are the coordinator for COPS-1234. Read the design doc at docs/plans/...
You will spawn workers and broker decisions. Workers will message you via
swarm IPC. The human will reach you via Telegram.

Workers (you'll receive their session ids shortly):
- BE: <repo>
- FE: <repo>
- protos: <repo>
- dbt: <repo>

Plan: ...
PROMPT
)"
```

Capture the coordinator's session id from the output.

### 3. Launch each worker

For each worker, launch from its own dir with a prompt that includes:

- Its slice of the work.
- The coordinator's session id (so it knows where to escalate).
- Optional: the other workers' session ids if it has a known direct hand-off (e.g. BE → FE for "schema is live").

```bash
opencode-launch <worker-dir> "$(cat <<'PROMPT'
You are the BE worker for COPS-1234. Your slice: implement the GraphQL
endpoints for X.

Coordinator: ses_<coordinator-id>
Other workers: FE=ses_<fe-id>, protos=ses_<protos-id>

When your API is deployed, send `pigeon-send --kind status.update ses_<fe-id> "API live at /v2/foo"` so the FE can proceed.

Plan: ...
PROMPT
)"
```

Capture each worker's session id.

### 4. Tell the coordinator the worker ids

After launches, send the worker ids to the coordinator so it can name them in its mental model:

```bash
pigeon-send ses_<coordinator-id> "Workers spawned:
- BE:     ses_<be-id>
- FE:     ses_<fe-id>
- protos: ses_<protos-id>
- dbt:    ses_<dbt-id>"
```

### 5. Kick off the work

Either:
- Tell the coordinator to begin orchestrating ("the swarm is live; please plan and dispatch initial assignments via `pigeon-send --kind task.assign`"), OR
- Tell each worker to begin its slice directly ("you may now start; report status to the coordinator").

The first style centralizes orchestration; the second parallelizes earlier. Pick based on how much the coordinator needs to gate vs. just observe.

## Communication Patterns

Once the swarm is live, all cross-session messaging goes through `pigeon-send` (or `opencode-send` which auto-routes for `ses_*` targets — see `opencode-send` and `swarm-messaging` skills).

Useful conventions:

- **Coordinator broadcasts assignments**: `pigeon-send --kind task.assign --priority urgent ses_<worker> "..."`.
- **Workers report status to coordinator**: `pigeon-send --kind status.update ses_<coordinator> "Done with <X>; PR at <url>"`.
- **Workers coordinate directly**: `pigeon-send --kind status.update ses_<peer-worker> "API deployed"` — no need to bounce off the coordinator if only the peer needs to know.
- **Threading replies**: `pigeon-send --reply-to <their-msg-id> ...` so receivers can follow conversation chains.
- **Backlog / replay**: receivers can call the `swarm.read` opencode tool to fetch their inbox if they suspect they missed a message.

## Tear-Down

When the work is done:

```bash
# From any shell on the same machine
curl -sf -X DELETE http://127.0.0.1:4096/session/ses_<coordinator-id>
curl -sf -X DELETE http://127.0.0.1:4096/session/ses_<worker-id>
# ... etc

# Or from Telegram
/kill <session-id>
```

Or just let the session reaper expire them after 1 week of inactivity.

Old swarm messages stay in the daemon's `swarm_messages` table. They aren't auto-cleaned yet (see pigeon's `swarm-operations` skill for the manual cleanup query). Stale/queued messages targeting deleted sessions will exhaust their retry budget and terminally `fail` — this is fine.

## Anti-Patterns

- **Spinning up workers without giving them each other's ids.** They can't coordinate directly and end up funneling everything through the coordinator, defeating the parallelism.
- **Using the coordinator as a message broker.** If a message only matters to two workers, send it directly. The coordinator's job is shared context, not packet routing.
- **Spawning more workers than there are decoupled slices.** Two workers fighting over the same code is worse than one worker doing both.
- **Forgetting `--reply-to` in chained conversations.** Without threading, the receiver has to reconstruct context from prose. Cheap to set; expensive to omit.
- **Not telling workers about the coordinator.** Workers that don't know how to escalate will silently get stuck or make decisions that should have been the human's.

## See Also

- [`opencode-launch`](../opencode-launch/SKILL.md) — spawn headless sessions.
- [`opencode-send`](../opencode-send/SKILL.md) — sender CLI (auto-routes through pigeon).
- [`swarm-messaging`](../swarm-messaging/SKILL.md) — sender + receiver protocol; envelope format; kinds; replay via `swarm.read`.
- pigeon repo `swarm-architecture` / `swarm-operations` skills — daemon internals if you need to debug delivery.
