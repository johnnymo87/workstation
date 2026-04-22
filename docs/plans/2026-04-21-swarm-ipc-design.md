# Swarm IPC Design — Pigeon-Hosted Session-to-Session Messaging

**Date:** 2026-04-21
**Status:** Approved (user + ChatGPT brain trust); ready to implement
**Outcome of:** brainstorm + ChatGPT consult on whether `opencode-send` over `prompt_async` is the right primitive for swarm-member coordination
**Implementation plan:** `docs/plans/2026-04-21-swarm-ipc-plan.md`

---

## Goal

Enable durable, replayable, broadcast-capable message routing between
peer OpenCode sessions ("swarm members") on the same machine, while
preserving today's `opencode-send` UX and avoiding the multi-Instance
`prompt_async` race we hit in COPS-6107.

## Background

Today's swarm IPC is `opencode-send`: a bash wrapper that POSTs each
message directly to `opencode serve`'s `/session/<id>/prompt_async`
HTTP route. This re-uses a route designed for human input as an
inter-agent message bus. Three concrete problems:

1. **Race**: concurrent posts to the same session id from different
   `x-opencode-directory` headers bypass OpenCode's per-session busy
   guard, run parallel LLM turns, and produce 400 "assistant message
   prefill" from Claude Opus 4.7 on Vertex.
2. **No replay / no broadcast / no acks**: a session that comes
   online late can't read missed messages; the coordinator must
   enumerate workers; senders never know if delivery succeeded.
3. **Wrong altitude**: the channel is the LLM input stream, so all
   inter-agent traffic mixes with human prompts in the transcript
   with no way to distinguish, correlate, or thread.

We brainstormed several alternatives (build a new queue+tool from
scratch; cherry-pick upstream agent-teams PRs; just patch the race
and live with the limits; do nothing). We checked the upstream PRs
on `anomalyco/opencode` — three competing agent-teams designs
(#12730/#12731/#12732, #15205, #20152), all 2-4 months stale with no
maintainer movement despite community pressure. Waiting is not
credible.

We then noticed pigeon (`~/projects/pigeon`) already implements ~70%
of what a swarm-IPC bus needs: durable SQLite storage, an outbox
sender with retry/backoff/dedupe, an OpenCode plugin that runs
in-process per session, multi-machine routing via Cloudflare D1.
Pigeon's mission today is "Telegram ↔ opencode"; extending it to
"opencode ↔ opencode" is a natural reuse.

A fresh ChatGPT consult (`docs/plans/research/2026-04-21-swarm-ipc-design-answer.md`)
endorsed extending pigeon, with several refinements: keep swarm as a
first-class subsystem with its own schema (don't bolt onto Telegram
tables), use a compact XML envelope for in-transcript routing fields,
mix push + pull rather than push-everything, ship a defense-in-depth
route-rebind patch in `opencode-patched` after the IPC ships.

## Architecture

### Data flow (steady state)

```
sender opencode session                 receiver opencode session
        |                                       |
        | pigeon-send <to_id> <payload>         |
        v                                       |
  bash wrapper                                  |
        |                                       |
        | POST http://127.0.0.1:4731/swarm/send |
        v                                       |
  pigeon daemon (HTTP)                          |
        |                                       |
        | INSERT swarm_messages + swarm_outbox  |
        v                                       |
  daemon SQLite (better-sqlite3)                |
        ^                                       |
        |                                       |
        | per-session arbiter pulls one         |
        | message at a time for target id       |
        |                                       |
        | POST /session/<to>/prompt_async       |
        | Header: x-opencode-directory =        |
        |   <session.directory> (canonical,     |
        |   resolved daemon-side, NOT sender)   |
        | Body:  {"parts":[{"type":"text",      |
        |   "text":"<swarm_message ...>...      |
        |   </swarm_message>"}]}                |
        +--------------------------------------->|
                                                v
                                       opencode serve
                                                |
                                                | injected as user message
                                                v
                                       receiving agent reads
                                       <swarm_message> envelope,
                                       parses routing fields,
                                       reasons over payload,
                                       optionally calls
                                       swarm.read for backlog.
```

### Components (new + existing)

**New (in `~/projects/pigeon`):**

- `packages/daemon/src/storage/swarm-schema.ts` — DDL for `swarm_messages`,
  `swarm_subscriptions`. Separate file from existing schema because
  swarm is a first-class subsystem (per ChatGPT refinement #1).
- `packages/daemon/src/storage/swarm-repo.ts` — repository functions:
  `insert`, `getReady(target_session, since=NULL)`, `markHandedOff`,
  `markFailed`, `getBacklog(session, since)`, `cleanup`.
- `packages/daemon/src/swarm/arbiter.ts` — per-target serialized
  delivery worker. Owns ALL prompt-injection traffic for any session
  (Telegram + swarm), so no two writers race for the same target.
  Background loop reads ready messages, delivers via opencode-client,
  marks state.
- `packages/daemon/src/swarm/envelope.ts` — XML envelope serializer
  / parser. Renders the wire format the receiver sees.
- `packages/daemon/src/swarm/registry.ts` — canonical
  `session_id → directory` resolver. Hits opencode serve's
  `GET /session/:id` once and caches; never trusts caller-supplied
  directory (per ChatGPT precondition).
- New routes in `packages/daemon/src/app.ts`:
  - `POST /swarm/send` — accept `{to, from, payload, msg_id, kind, priority, reply_to}`,
    return `{accepted: true, msg_id}` (HTTP 202).
  - `GET /swarm/inbox?session=<id>&since=<msg_id>` — return
    delivered messages targeting `<session>` since cursor.
  - (Optional v0.5) `POST /swarm/broadcast` — fan-out to channel
    members (static membership in config for MVP).

**New (in `~/projects/workstation/users/dev/home.base.nix`):**

- `pigeon-send` bash wrapper (~80 lines, mirrors `opencode-send`'s
  CLI shape). POSTs to `http://127.0.0.1:4731/swarm/send`. Has
  `--list`, `--cwd`, message-from-stdin support. Returns when 202.
- Modified `opencode-send`: when target is detected as a session
  (matches `^ses_`), default to going through pigeon
  (`/swarm/send`) instead of directly to `prompt_async`. Override
  with `--direct` to bypass and hit opencode serve directly (legacy
  fallback). Keep the flock for `--direct`.

**New (in `~/projects/workstation/assets/opencode/skills/`):**

- `assets/opencode/skills/swarm-messaging/SKILL.md` — agent-facing
  skill explaining the `<swarm_message>` envelope, when senders
  should use `pigeon-send`, when receivers should call `swarm.read`.

**New (in pigeon):**

- `packages/opencode-plugin/src/swarm-tool.ts` — registers a
  `swarm.read` tool with opencode that returns backlog messages
  for the receiver's own session id since a cursor (defaults to
  the cursor of the last `swarm.read` call).

**Defense-in-depth (in `~/projects/opencode-patched`):**

- `patches/prefill-fix.patch` — the route-rebind patch we already
  designed (`docs/plans/2026-04-21-opencode-prefill-fix-design.md`).
  Ship AFTER the swarm IPC is in place. This protects the few cases
  where a human might still hit `prompt_async` directly with a wrong
  cwd. Not the primary fix.

### Wire format: `<swarm_message>` envelope

```xml
<swarm_message
  v="1"
  kind="task.assign"
  from="ses_24e8ff295ffeyV8o35YuK63g2u"
  to="ses_abcd1234"
  channel="workers"
  msg_id="msg_01h..."
  reply_to="msg_01g..."
  priority="normal">
Please run the frontend regression suite in the COPS-6107 worktree
and report only failures that reproduce twice.
</swarm_message>
```

**Field semantics:**

| Field | Required | Notes |
|---|---|---|
| `v` | yes | envelope version, "1" for MVP |
| `kind` | yes | `task.assign` / `status.update` / `clarification.request` / `clarification.reply` / `artifact.handoff` / `chat` — receivers don't have to special-case but it helps logging |
| `from` | yes | sender session id |
| `to` | one of | direct-send target session id |
| `channel` | one of | broadcast channel name (static membership for MVP) |
| `msg_id` | yes | ULID, generated by daemon, idempotency key |
| `reply_to` | no | another `msg_id`, for threading |
| `priority` | no | `urgent` / `normal` / `low`; default `normal` |

The XML body is the entire user-message text injected via
`prompt_async`. Receivers learn to recognize the envelope (via the
`swarm-messaging` SKILL) and parse it before reasoning. Anthropic's
prompt guidance favors structured tags over prose markers, so this
shape is explicitly chosen for LLM legibility.

**Bookkeeping (NOT in transcript):** delivery state, retry counts,
attempts, ack timestamps, idempotency-replay hits. Stay in pigeon
SQLite.

### Push vs pull

ChatGPT explicitly recommended a push-with-nudge mix, NOT
push-everything. MVP uses a simpler split:

- `priority="urgent"` → daemon delivers via `prompt_async` immediately
- `priority="normal"` (default) → daemon delivers via `prompt_async`
  too, BUT future enhancement: daemon can batch and emit a single
  "you have N new messages, call swarm.read" nudge instead of N
  injections
- `priority="low"` → daemon stores only; receiver must call
  `swarm.read` to see it

For day-1 MVP, treat normal+urgent the same (both inject). Add the
nudge-batching later if interruption noise is a problem.

**`swarm.read` tool** is the replay mechanism: a receiving agent can
ask "what swarm messages have arrived for me since cursor X?" and
get the backlog. Required for true replay, optional for normal flow.

### Per-target arbiter

The single most important architectural property: **for any given
target session id, exactly ONE in-flight `prompt_async` request at
a time, regardless of source (swarm vs Telegram).**

Implementation: a worker in
`packages/daemon/src/swarm/arbiter.ts` polls the outbox / delivery
queue every ~500ms (faster than the existing 5s OutboxSender for
swarm because swarm traffic is more interactive). For each target
session id with ready work, it picks the oldest unprocessed message
and dispatches to opencode-client.sendPrompt. It marks `handed_off`
on 2xx, `retry` with backoff on 5xx, `failed` on terminal.

The arbiter must own ALL prompt-injection paths to a session — it's
not enough for swarm to be serialized internally if Telegram traffic
hits the same session through a different code path. So either:
- swarm and Telegram share the arbiter (preferred), or
- swarm has its own arbiter and Telegram's already-serial path
  separately serializes.

For MVP, swarm gets its own arbiter (Telegram traffic is rare for
swarm-member sessions; we accept the risk and add unification
later).

### Canonical directory resolution

Sender does NOT supply `x-opencode-directory`. Daemon resolves it
itself by hitting opencode-serve once per session (cache the result):

```
GET http://127.0.0.1:4096/session/<id>
→ {"id":"ses_...", "directory":"/home/dev/projects/mono", ...}
```

Cache `(session_id, directory)` in memory with a 5-minute TTL. On
miss, refetch. This ensures the `Instance.directory` keying always
matches the session's own directory, so the busy guard works
correctly.

## Error handling

| Case | Behavior |
|---|---|
| Sender posts to nonexistent session | 404 from `POST /swarm/send` (after registry lookup fails) |
| Daemon down | sender wrapper returns nonzero, prints clear error |
| opencode serve down | arbiter sees ECONNREFUSED, marks retry; backs off; gives up after 10 attempts or 15 min |
| Duplicate `msg_id` | `INSERT … ON CONFLICT DO NOTHING`; arbiter skips dups |
| Receiver session deleted mid-flight | arbiter sees 404, marks failed |
| `prompt_async` returns 5xx | retry with backoff |
| `prompt_async` returns 2xx but session never sees the text | not detectable in MVP; we trust 2xx as "handed off". Future: receipt ack via plugin hook |
| Two daemons running | not supported in MVP; documented "single daemon per machine" |

## Testing strategy

Tests live alongside existing pigeon tests in
`packages/daemon/test/`. New test files:

- `swarm-repo.test.ts` — repository functions, idempotency, ordering,
  cursor-based reads.
- `arbiter.test.ts` — per-target serialization, retry/backoff,
  terminal failure, no-cross-talk between targets.
- `envelope.test.ts` — XML serialization round-trip; rejects malformed
  input; preserves payload exactly.
- `registry.test.ts` — fetches+caches; refetches on TTL expiry; 404s.
- `swarm-routes.integration.test.ts` — exercises `POST /swarm/send` +
  `GET /swarm/inbox` end-to-end against a fake opencode serve and a
  real SQLite db; asserts at-most-one in-flight per target by firing
  4 concurrent sends to the same target with different sender cwds
  and confirming exactly 4 sequential `prompt_async` calls (NOT 4
  parallel).

In `~/projects/workstation`:
- `pigeon-send` is a bash wrapper; we test it like other wrappers
  (smoke test in `tests/` if any exist; otherwise document manual
  smoke test).

In `~/projects/opencode-patched`:
- The route-rebind patch ships its own Bun test
  (`packages/opencode/test/server/session-directory-rebind.test.ts`)
  per the prefill design doc.

## Out of scope (NOT in MVP)

- Cross-machine swarm routing (works for free later if we wire D1)
- Receipt acks beyond `handed_off` (no `received` / `seen` levels)
- Dynamic subscription management (channel membership is config-only)
- Exactly-once delivery (we have at-least-once + idempotency by `msg_id`)
- Rich attachments (file paths in payload only; no R2 round-trip)
- Thread tree visualization
- Pub/sub ACLs (any session can send to any other)
- Nudge-batching for normal-priority traffic (push-everything for now)
- Unified Telegram + swarm arbiter (separate arbiters for now)

## Migration path to upstream agent-teams

If `anomalyco/opencode` eventually merges one of #12730 / #15205 /
#20152 (or something similar), the migration plan:

- Our external API surface is `swarm.send(to, payload)` /
  `swarm.broadcast(channel, payload)` / `swarm.read(since?)`. None of
  these are tied to pigeon — they're a generic message bus.
- The internal adapter today is "pigeon → prompt_async". Tomorrow it
  could be "pigeon → upstream team-message API" (or even just "the
  upstream API directly", with pigeon as a passthrough).
- ChatGPT's note: don't model as "team lead / teammate" — model as
  "general message bus with channels". This MVP follows that advice.
- The biggest risk is topology mismatch: upstream PRs lean toward
  "lead spawns teammates" (#15205, #20152); our model is peer-equal.
  If upstream's API can't represent peer-equal topologies, we keep
  pigeon. If it can, we adapt.

## Day-1 MVP scope (what we'll actually build first)

Per ChatGPT's guidance, smallest shippable cut:

1. `swarm_messages` SQLite table (one table only, no separate outbox
   for MVP — combine into `swarm_messages` with `state` column).
2. `POST /swarm/send` endpoint.
3. `GET /swarm/inbox` endpoint.
4. Per-target arbiter loop (swarm-only, Telegram unchanged).
5. Canonical session→directory registry (in-memory, 5-min TTL).
6. XML envelope serializer.
7. `pigeon-send` bash wrapper.
8. `opencode-send` modified to default to pigeon path for `ses_*` ids.
9. `swarm-messaging` skill doc for agents.
10. `swarm.read` opencode tool (registered via plugin).

Two ack levels: `accepted` (persisted in SQLite, returned in the
`POST /swarm/send` response) and `handed_off` (arbiter delivered to
`prompt_async` with 2xx).

After MVP ships and works for COPS-6107: ship the route-rebind patch
in `opencode-patched` as defense-in-depth.
