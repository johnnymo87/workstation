# How should we route messages between members of an OpenCode "swarm" (multiple peer sessions in one or more `opencode serve` processes)?

## Keywords

opencode, agent teams, swarm, multi-agent, IPC, message bus, pub/sub,
SQLite outbox, durable delivery, Hono, Effect-TS, Anthropic Claude prefill
race, prompt_async, opencode-send, pigeon, Telegram daemon

## TL;DR for the researcher

We're running a 5-session swarm of OpenCode (`anomalyco/opencode` v1.14.19,
Bun-based TS, Hono HTTP server) on one box. Sessions talk to each other
today via a bash wrapper called `opencode-send` that POSTs to
`/session/<id>/prompt_async`. This wrapper is a stopgap and we've hit
serious bugs (a multi-`Instance` race that produces 400 "assistant
message prefill" from Claude Opus 4.7 on Vertex). Patching the race fixes
a symptom but the underlying abstraction (RPC over the LLM input stream)
is wrong. We need help deciding **what to build instead**, given:

1. Upstream OpenCode has 3+ competing "agent teams" PRs, all stalled
   2-4 months without maintainer review.
2. We already operate a Telegram-routing daemon called **pigeon**
   (TypeScript, SQLite outbox, OpenCode plugin, retry/backoff/dedupe
   already implemented).
3. We want pub/sub + replay + delivery acks, not fire-and-forget.

We've narrowed the design space to a small number of options and want
ChatGPT's view on which one is the right bet, plus things we've missed.

## The situation

### What we have today

We work in a 5-session swarm:

- 1 coordinator session (in `~/projects/mono`)
- 4 worker sessions, each in its own git worktree
  (`~/projects/mono/.worktrees/COPS-6107`,
  `~/projects/protos/.worktrees/COPS-6107`,
  `~/projects/internal-frontends/.worktrees/COPS-6107`,
  `~/projects/data_recipe/.worktrees/COPS-6107`)

All 5 sessions run inside ONE `opencode serve` process on a single
NixOS box (port 4096, loopback only).

Sessions are effectively peers — the "coordinator" is just our
convention; OpenCode itself only models them as independent sessions
that happen to share a server.

Each session corresponds to an `Instance` in OpenCode's model. An
`Instance` is keyed by **directory** — so the coordinator's Instance
context has `directory = ~/projects/mono`, etc. (Important later:
session-scoped state in OpenCode is cached per-Instance, not
per-session.)

### How sessions talk to each other today

Wrapper: `opencode-send` (bash + curl + jq, ~280 lines). Source is in
`workstation/users/dev/home.base.nix` lines 748-1039. Behavior:

```bash
opencode-send <session-id> "<message>"
   # POST http://127.0.0.1:4096/session/<id>/prompt_async
   #   Header: x-opencode-directory: $PWD
   #   Body:   {"parts":[{"type":"text","text":"<msg>"}]}
```

It's a thin shim over OpenCode's HTTP route. The receiving session sees
the message as if a human typed a prompt — it appears in its transcript,
triggers a new agent turn, and the agent decides what to do.

Returns 204 immediately (fire-and-forget). No ack, no inbox, no replay.

There's a `--list` mode (lists local sessions) and a recently-added
`--cwd DIR` flag and a per-session `flock` (mitigation for a race —
see "what we tried that didn't work").

### What kinds of messages flow

User reports: **"mix of all three"** —
- Task assignments + status updates ("done", "blocked", "need clarification")
- Long-running collaborative dialogue (workers asking the coordinator
  for clarification, coordinator pushing back on a worker's proposal)
- Artifact handoff (file paths, PR URLs, diffs)

So the channel needs to support varied message shapes.

### What delivery semantics we need

User said hard requirement: **pub/sub with replay**. Specifically:
- A session that comes online late should be able to read messages it
  missed.
- The coordinator should be able to broadcast to all workers without
  enumerating them.
- We want delivery acks ("message was queued" at minimum, "session
  received it" ideally) — fire-and-forget is causing real
  "did you get my last message?" friction.

## The bug that started this

Concurrent `prompt_async` requests to the **same session id** from
DIFFERENT `x-opencode-directory` headers bypass OpenCode's per-session
busy guard and run parallel LLM turns. The 3rd-onward turn produces
HTTP 400 from Anthropic Vertex:

```
This model does not support assistant message prefill.
The conversation must end with a user message.
```

(Confirmed real Anthropic restriction on Opus 4.7, Opus 4.6, Sonnet
4.6.)

### Why it happens (verified)

1. The Hono middleware at
   `packages/opencode/src/server/routes/instance/middleware.ts` (in the
   v1.14.19 tag) selects an `Instance` from the
   `x-opencode-directory` header (or `?directory=`) on EVERY request:
   ```ts
   const raw = c.req.query("directory") || c.req.header("x-opencode-directory") || process.cwd()
   const directory = AppFileSystem.resolve(decodeURIComponent(raw))
   return WorkspaceContext.provide({
     workspaceID,
     async fn() {
       return Instance.provide({
         directory,
         init: () => AppRuntime.runPromise(InstanceBootstrap),
         async fn() { return next() },
       })
     },
   })
   ```

2. `Instance.provide` caches per-directory:
   ```ts
   const cache = new Map<string, Promise<InstanceContext>>()
   provide({ directory, fn }) {
     const key = AppFileSystem.resolve(directory)
     let existing = cache.get(key)  // distinct directory => distinct Instance
     ...
   }
   ```

3. Session-scoped state — including the busy/runners map — lives in
   `SessionRunState` which is created via `InstanceState.make()`, keyed
   by the current `Instance.directory` via
   `ScopedCache.get(self.cache, yield* directory)` in
   `packages/opencode/src/effect/instance-state.ts` line ~65.

4. Result: two `prompt_async` requests to session `S` from directory A
   and directory B see two DIFFERENT empty `runners` maps for `S`,
   both pass the busy guard, both kick off parallel LLM turns. Their
   message writes to the (single, shared) SQLite session interleave;
   by the time the 3rd or 4th turn assembles its message array, the
   final message is `assistant`, and Vertex Opus rejects it.

### What we tried that didn't work (or worked partially)

1. **Wrapper-level `flock` on `/tmp/opencode-send-<session>.lock`.**
   Already shipped in `opencode-send`. Serializes wrapper invocations
   targeting the same session id. Mitigates the race for synchronous
   bursts, but is **insufficient on its own** — once parallel
   `Instance` loops exist, leftover loops keep iterating against
   incoming user messages with their own cwd until they naturally
   drain. The flock prevents NEW races but doesn't kill EXISTING
   parallel loops.

2. **Protocol broadcast: "always pass `--cwd <target's-own-dir>`".**
   We sent every swarm member a system message changing the
   convention. Now every send to session `S` uses
   `--cwd <session-S's-own-directory>`. This collapses all
   header-derived directories to the SAME value, which means all
   `prompt_async` requests for `S` end up in the SAME Instance, and
   the busy guard works again. **This is the durable mitigation.**
   Confirmed zero errors since broadcast.

3. **Drafted an upstream-style patch** that wraps every `:sessionID/*`
   route in a "lookup the session row, re-enter
   `Instance.provide({directory: session.directory})`" middleware,
   bypassing the caller-supplied header. ChatGPT brainstorming
   session 1 produced a PR-ready sketch
   (`docs/plans/research/2026-04-21-opencode-prefill-patch-sketch-answer.md`).
   We have NOT shipped this patch yet because we're now reconsidering
   whether `prompt_async` should even be the swarm IPC channel.

## Verified state of upstream agent-teams work

We checked `anomalyco/opencode` (this is the actual upstream we patch
against; `sst/opencode` is a different unrelated project — please don't
confuse them). Today (2026-04-21):

| PR | Approach | Status | Last code update |
|---|---|---|---|
| **#12730/12731/12732** (`ugoenyioha`) | "Team namespace" + messaging + recovery + events; file-based per design #12711 | OPEN, not draft, **2,595 commits behind dev** | 2026-02-10 |
| **#15205** (DB-based) | Drizzle/SQLite, 3 new tables (`team`, `team_task`, `team_message`), synthetic-user-message injection in prompt loop, TUI integration | OPEN, not draft, **2 months stale** | 2026-02-26 |
| **#20152** (lightweight `team` tool) | Ephemeral parallel sub-agent spawner (parent→children, NOT peer messaging) | OPEN, not draft, ~3 weeks stale | 2026-03-30 |

Issues #12711 (design), #12661 (feature request), #19999 (#20152's
issue) all OPEN. No maintainer activity on any of these despite
community pressure ("bump", "no chance to merge?", "why hasn't this
merged yet?").

`Kit Langton` (anomaly engineer) is committing actively to `dev`
branch (5 commits today), but on unrelated features. The PR backlog
includes other simple bugfixes that have sat for months with PRs
already submitted (e.g. #17982 for a different prefill bug has
PRs #17010 and #17149 sitting unreviewed).

**Our specific bug (multi-Instance prompt_async race) is genuinely
undocumented upstream.** We searched and found no related issue.
Closest is #17982 which is a different prefill bug (single-session,
finish=stop loop continuation) — different root cause, same Anthropic
error message.

We're not optimistic that filing an issue or PR for our bug will get
attention from maintainers in any reasonable timeframe.

## The pigeon angle (this is the new thought)

We already operate a related system at `~/projects/pigeon`:

```
Telegram → Worker (Cloudflare) → D1 (Cloudflare SQLite) ← Daemon (5s polling) → opencode plugin → opencode serve
```

The daemon is local TypeScript on the same box as opencode. It runs as
a systemd service. Schema (`packages/daemon/src/storage/schema.ts`)
has these SQLite tables:

```sql
sessions          -- registered opencode sessions
session_tokens    -- auth/reply tokens per session
reply_tokens      -- short-lived reply correlation
inbox             -- messages from Telegram before delivery
pending_questions -- unresolved /question prompts
outbox            -- DURABLE delivery to Telegram with retry/dedupe
```

Pigeon already handles:

- Durable delivery with retries, exponential backoff, dedupe by
  `notificationId`
- Acks (HTTP 202 from daemon)
- An OpenCode plugin (`packages/opencode-plugin/`) that runs
  in-process with each opencode session, knows how to inject
  `prompt_async` messages, captures attachments, handles questions,
  routes events back
- Multi-question wizard (sequential prompts in one Telegram message
  edited in-place)
- Cross-machine routing (D1 routes between Cloudflare worker and
  multiple devboxes)
- Rate-limit retry handling, message splitting at 4096 char limits
- Session reaper (cleans dead sessions)

In other words, pigeon is **already a durable, retrying, multi-machine
message router with an opencode-plugin integration on the receiving
side.** The only thing it doesn't do today is route messages from one
opencode session to another — it routes Telegram → opencode and back.

## Design options on the table

We've enumerated 4 options and want ChatGPT's read on which is best
plus what we're missing. (Earlier brainstorm options A-E are
collapsed/superseded. F1, F3, F4 are independent variations; G is
the new pigeon-based option.)

### F1 — Ship the small upstream-style prefill-fix patch only

- Apply the route-rebind middleware to every `:sessionID/*` route in
  our `opencode-patched` fork
- Rebuild, ship via existing CI
- Keep using `opencode-send` as today
- Defer the "right" IPC redesign to "someday when upstream agent-teams
  lands"

Pros:
- Smallest change. ~50 line patch + ~400 lines test.
- Eliminates the race architecturally.
- No new long-term commitments.

Cons:
- Doesn't solve "pub/sub with replay" (user's hard requirement).
- Still treats LLM input stream as RPC channel — wrong abstraction.
- No structured payloads, no message types, no correlation IDs.
- Transcript pollution remains.
- We carry a fork patch.

### F3 — Build a separate queue-based mailbox tool from scratch

- New small tool, `mailbox.send(channel, payload)` and
  `mailbox.read(channel, since?)`, registered as an OpenCode tool
  the agent can call
- Backed by a SQLite file in `~/.local/share/opencode/swarm/inbox.db`
- Pull-style for replay; small daemon could "nudge" via
  `prompt_async` for urgent push
- All custom code; no opencode internals touched

Pros:
- Decouples IPC from `prompt_async` — race vanishes.
- Replay + persistence built in.
- Independent of upstream agent-teams timeline.

Cons:
- Reinvents pigeon's outbox + retry + dedupe.
- Local-only unless we add networking ourselves.
- Built specifically for this use case; throwaway when upstream lands.

### F4 — Do nothing structural; just keep the protocol mitigation

- Trust the "always `--cwd <target's-own-dir>`" convention.
- Ship the prefill patch eventually but not urgently.
- Live with the limits: no replay, no broadcast, no acks.

Pros: Zero engineering.

Cons: Discipline-dependent. One forgotten `--cwd` re-triggers the
race. No replay or broadcast forever.

### G — Extend pigeon with swarm-IPC routing

The big one. Sketch:

- New daemon endpoints:
  - `POST /swarm/send` — `{from_session, to_session, payload, idempotency_key}` →
    insert into existing `outbox` table targeting "opencode session X" instead of Telegram.
  - `POST /swarm/broadcast` — `{from_session, channel, payload, idempotency_key}` →
    fan-out to all sessions subscribed to channel.
  - `GET /swarm/inbox?session=X&since=offset` — replay missed messages.
- Daemon's existing `OutboxSender` (already retries with exponential
  backoff, dedupes by id) delivers each message to opencode by calling
  `prompt_async` via the existing `opencode-client.ts`.
- **Daemon serializes per-target deliveries**: at most one in-flight
  `prompt_async` per session at a time. This **architecturally**
  eliminates the race we've been fighting — daemon is the single
  writer to opencode for swarm traffic. (We may STILL want the
  `opencode-send` flock or the upstream patch for human-driven sends,
  but they're independent concerns.)
- The opencode plugin (already running per-session) gets a small
  addition that recognizes "swarm message" payloads (by JSON
  prefix or distinct route) and prepends a `[from: ses_xyz]` tag
  before injecting the user message.
- Senders use a new bash wrapper `pigeon-send <to_session> <payload>`
  that POSTs to the local daemon endpoint. Returns immediately with
  ack.
- Cross-machine routing reuses the existing D1 path: pigeon already
  routes Telegram traffic across machines; swarm traffic between
  sessions on different boxes routes the same way for free.

Pros:
- Reuses ~70% of existing pigeon infrastructure.
- Daemon-as-single-writer architecturally fixes the prompt_async race
  for swarm traffic without an opencode patch.
- Persistence + replay + acks come for free.
- Cross-machine swarm is essentially free if both boxes already run
  pigeon.
- No coupling to opencode internals beyond the existing plugin.
- Independent of upstream agent-teams timeline.
- Fits naturally with pigeon's existing skill/docs/operational tooling.

Cons:
- Pigeon scope creep: it was scoped to "Telegram bridge". This
  expands its mission.
- New SPOF: if daemon is down, swarm IPC stops. (Already true for
  Telegram.)
- Latency: ~50-200ms extra per message (bash → daemon → outbox →
  opencode), likely fine for swarm coordination but worse than direct.
- Daemon process owns the SQLite; cross-machine swarm requires
  Cloudflare D1 (or we route locally only and skip cross-machine).

### G-local sub-option

Same as G but only same-machine routing — never round-trip through
Cloudflare D1 for swarm traffic. Keeps pigeon's scope tighter and
removes the Cloudflare dependency for the swarm path. Cross-machine
swarm is future work.

## Concrete questions for ChatGPT

1. **Is "extend pigeon" (G or G-local) the right structural bet
   given everything above**, or should we reject it for reasons we
   haven't surfaced?
   - The thing we're nervous about: pigeon was designed as a
     Telegram bridge. Adding "session-to-session routing" is a
     legitimate scope expansion. What failure modes typically show up
     when a system designed for one route gets a second route bolted on?

2. **Is the "single-writer daemon" design** (daemon serializes
   per-target `prompt_async` deliveries) actually sufficient to fix the
   race architecturally, given that the race lives in
   `Instance.directory` keying on the OpenCode side? We believe yes:
   if the daemon always passes the same `x-opencode-directory` (the
   session's own directory) and serializes per session, the busy guard
   works correctly. But we want a sanity check that we're not missing
   a case (e.g. interaction with `opencode-serve`'s own internal
   request handling, or a parallel write from a non-daemon source).

3. **Should we ALSO ship the upstream-style prefill-fix patch** in
   `opencode-patched`, or is the daemon-single-writer design enough?
   The case for shipping both: human-typed `opencode-send` calls
   bypass the daemon and could re-trigger the race. The case against:
   if we move ALL session-to-session traffic through pigeon, the
   patch is unnecessary; humans typing into `opencode-send` from a
   shell is rare and we control the convention.

4. **Synthetic user message tagging**. The receiving agent will see
   swarm messages as user messages in its transcript. We're considering
   prepending a tag like:
   ```
   [from: ses_24e8ff295... | channel: workers-broadcast | id: msg_abc | replyto: msg_def]
   <payload>
   ```
   so the agent can distinguish swarm messages from human prompts and
   reason about correlation/threading. Is this the right shape, or is
   there a cleaner pattern? Anything LLMs in 2026 are known to handle
   especially well/badly?

5. **Pull-only vs push-with-nudge.** We considered (in F3) a
   pull-only model where the agent calls `mailbox.read` periodically.
   The user pushed back ("agents notoriously bad at remembering to
   poll"). We agree but want ChatGPT's view on the right mix:
   - If we go push-only (every swarm message immediately becomes a
     `prompt_async` injection), receivers are interrupted constantly.
   - If we go pull-only, receivers miss urgent messages.
   - If we go push-with-nudge (queue is truth, "you have N new
     messages" prompts trigger a `mailbox.read`), we add complexity.
   What pattern works in practice for agent-to-agent IPC?

6. **Are we missing options?** Specifically: NATS JetStream, Redis
   Streams, an MCP server pattern, an existing agent-team
   coordination library, anything else that we haven't considered.
   Pigeon is attractive specifically because we already operate it
   and the maintenance overhead is "add to existing system" not
   "add new system" — but we're open to reframing.

7. **Long-term path toward upstream agent-teams.** If we build G
   today and #15205 (or whatever) eventually merges in
   `anomalyco/opencode`, what's the migration path? Are pigeon and
   #15205's design fundamentally compatible (both are
   queue-with-injection patterns) or is there a structural mismatch
   that would force us to rip out our work?

8. **What's the smallest viable G we can ship in a day**? We want a
   working swarm-IPC channel for our current swarm work
   (COPS-6107) ASAP. What's the MVP feature set vs nice-to-have?

## What we know vs. what we're uncertain about

### Verified facts (we've read code, run tests, or confirmed in docs)

- The `Instance.directory` keying behavior in OpenCode v1.14.19 —
  read source, traced the code paths, confirmed via observed bug.
- Anthropic Opus 4.7 / 4.6 and Sonnet 4.6 reject final-assistant
  messages — confirmed in earlier brain-trust round against Anthropic
  docs.
- The flock mitigation works for synchronous bursts but doesn't kill
  existing parallel Instance loops — confirmed by testing.
- Pigeon's SQLite schema and outbox sender exist and have the
  retry/backoff/dedupe described — read source.
- Upstream PR statuses verified via gh CLI today
  (2026-04-21).

### Hypotheses we have NOT verified

- That the daemon-single-writer design fully eliminates the race
  for daemon-mediated traffic (we *think* it does because all
  daemon-routed messages would carry the same `x-opencode-directory`
  for a given session, but we haven't built it yet).
- That ~50-200ms latency is acceptable for swarm coordination — based
  on intuition, not measurement.
- That pigeon's outbox can be reused for "deliver to opencode session"
  with minor schema additions vs major refactor — based on quick
  reading, not careful design work.
- That cubic's "path traversal and race condition" code-review
  findings on PR #12730 are still relevant to its current state
  (PR is 2,595 commits behind dev; we haven't checked).

## Constraints

- **Must work today**, not after upstream lands something. Our
  swarm work is ongoing.
- **Must support pub/sub with replay** (user's hard requirement).
- **Must not require maintaining a 3,000+ line fork patch
  long-term.** F2 (cherry-pick #15205) is therefore off the table.
- **Single-machine usage is the immediate need**; cross-machine is
  nice-to-have for some future swarm spanning devbox + cloudbox or
  similar.
- **Must coexist with `opencode-send`** for ad-hoc human-typed
  messages from a shell. We don't want to break the existing
  workflow that drops a quick "rerun the failing test" into another
  session.
- **Bias toward technologies we already operate**: TypeScript,
  Bun/Node, SQLite, systemd. We're explicitly NOT looking to add
  Kafka, Redis, NATS, RabbitMQ, etc. unless there's a compelling
  reason.

## Files that may be useful to ChatGPT

If ChatGPT can browse to GitHub:
- `johnnymo87/workstation/users/dev/home.base.nix` lines 748-1039
  — `opencode-send` source.
- `anomalyco/opencode` PR #12730 — file-based teams design.
- `anomalyco/opencode` PR #15205 — DB-based teams design (closest to
  what we'd be building in pigeon).
- `anomalyco/opencode` PR #20152 — lightweight team tool (different
  pattern: parent-child).
- `anomalyco/opencode` issue #12711 — design discussion.
- The workstation repo's plan files at
  `docs/plans/2026-04-21-opencode-prefill-fix-design.md` and
  `docs/plans/research/2026-04-21-opencode-prefill-patch-sketch-answer.md`
  — full context on the prefill race investigation.

If ChatGPT can't browse, it has enough in this briefing.

Thanks!
