---
name: swarm-messaging
description: Use when sending messages to other opencode sessions on the same machine, when you receive a swarm_message envelope as the text of a user-message turn, or when deciding whether a message is worth sending at all. The coordinator role is banned here — read this before appointing or accepting one. For scheduling a message to the future, see the scheduling-wakes skill.
---

# Swarm Messaging

Pigeon hosts a durable, replayable message channel between opencode sessions on the same machine. The opencode-pigeon plugin exposes three always-on tools:

- **`swarm_send`** — send a message to another session.
- **`swarm_read`** — read your own inbox (replay messages you may have missed); returns the newest 10 by default, with `before`/`since` cursor pagination.
- **`swarm_list`** — discover other local sessions (and their ids) to message.

The daemon serializes deliveries per target session (at-most-one in-flight) and persists every message to SQLite for retry and replay.

**Read "Message economy" before your first send.** Every send costs the
receiver a full reasoning turn. Traffic, not verbosity, is what makes a swarm
unaffordable.

## Message economy — fewer messages, not shorter ones

**The unit of cost is the message, not the word.** A send interrupts the
receiver and spends an entire turn — the same cost whether the payload is
twelve words or four hundred. So the fix is never "write tersely and send five
of them." One substantial message beats five small ones. Batch related points
into a single send.

Compressing your prose while keeping the message count is the wrong
optimization, and it makes things worse: short messages feel cheap, so you send
more of them.

### The rules

1. **Batch and hold.** Accumulate findings and report at natural checkpoints —
   a task done, a blocker hit, a question that stops progress — never streaming
   every intermediate result. If you are about to send a second message before
   the receiver answered the first, you should have waited and combined them.
   A quiet worker making progress is the healthy state.
   *Exception, and only this one:* retracting your own prior claim, or stopping
   someone about to act on something false, goes out **immediately**. Urgency
   beats batching when the delay is what does the damage.
2. **No ack-only messages.** If your reply carries no decision, no new
   evidence, and no changed instruction, do not send it. "Got it", "on it",
   "thanks", "starting now", "still working" — none of these exist.
3. **Never restate a swarm message to a human who can already see it.** The
   human watching the swarm has the message in front of them. Paraphrasing it
   back is pure duplicated cost. Give a **tweet-length** pointer — one or two
   sentences — so they can decide whether to read the underlying message.

### Is this message worth sending?

Send it if **any** of these is true:

- A **decision** is needed and only the recipient can make it.
- You are **retracting** a claim you previously made.
- A **deadline or plan moved**, and their next action depends on the old one.
- Someone is **about to act on something false**.
- It is the **deliverable** itself (`result`, `artifact.handoff`) or an answer
  to a question asked of you.

Otherwise, don't.

| Send | Don't send |
|------|-----------|
| Task assignment (`task.assign`) | Acknowledgments ("got it", "on it", "will do") |
| Blocking question (`clarification.request`) | Progress heartbeats ("still working", "50% done") |
| Finished deliverable (`result`, `artifact.handoff`) | "Starting now" notices |
| Retraction of a claim you made | Restating what was already agreed |
| Terminal failure the receiver must act on | Courtesy pings, thanks, sign-offs |

### Examples

Reporting four findings to a peer.

```
✗ four sends:
  "auth middleware looks fine"
  "found the leak — session cache never evicts"
  "fix is 3 lines"
  "want me to open a PR?"

✓ one send (kind: result):
  Leak is in the session cache: entries are inserted in
  `cache.ts:88` and never evicted. 3-line fix (TTL on insert).
  Auth middleware ruled out. Opening a PR unless you object.
```

Summarizing for a human who is watching the swarm.

```
✗ "Worker B reports the leak is in the session cache, entries inserted
   at cache.ts:88 with no eviction, a three-line TTL fix, and auth
   middleware has been ruled out; B proposes opening a PR."

✓ "B found the leak (session cache) and is opening a PR — see its last
   message for the detail."
```

## The coordinator role is BANNED

**Do not appoint a coordinator. Do not accept the role. Do not launch a session
whose job is to route messages between other sessions.**

A coordinator is a session that holds shared context, turns direction into
`task.assign` messages, aggregates worker reports, and owns the upward channel
to the human. It sounds like a manager. It behaves like a message bus, and the
message *is* the cost.

Why it is banned, mechanically:

- **It at least doubles the message count.** Every fact travels twice — worker
  to coordinator, coordinator to human — and every instruction travels twice
  the other way. Nothing new is learned on the second hop.
- **Its whole job is sending messages.** A worker sends when it has a
  deliverable. A coordinator with no work of its own fills its turns with
  routing, status-chasing, and re-briefing. The role is a standing incentive to
  violate every rule in "Message economy" above.
- **It invites round-trips.** Assign → ack → question → answer → status →
  re-assign is four unnecessary turns, and the coordinator is the party that
  starts each one.
- **It amplifies errors.** A relayed number acquires authority it did not earn
  (see "The relay is part of the failure surface" below).

### What to do instead

| Instead of the coordinator… | Do this |
|---|---|
| Holding shared context in a session | Put it in **beads** / a plan file. Every session reads the same durable board. State does not need a courier. |
| Assigning work at runtime | Decompose **up front** and put each slice in the worker's **launch prompt**. A slice that was fully specified at launch needs zero assignment messages. |
| Aggregating worker reports | Each worker reports its own deliverable **directly to the human**, once, when done. |
| Asking a worker how it's going | **Pull, don't ask.** Read its beads, its branch, its PR, or its session transcript. Costs the worker nothing. |
| Brokering worker-to-worker handoffs | Workers message **each other directly** at the handoff point. Give every worker the others' session ids at launch. |
| Being "single point of contact for the human" | The human already sees the swarm. They are the integration point, and they cost nothing to read. |

**The human is the coordinator.** That role is filled. If a decision is needed
that only a human can make, the session that needs it asks the human directly —
one message, no relay.

### If a swarm genuinely needs shared arbitration

It probably doesn't. If you are certain it does, the arbitration belongs in a
**written artifact** (a plan file with the integration order and the handoff
conditions), not in a session's context. A document is read on demand, by
everyone, for zero messages. A coordinator has to be asked.

### The relay is part of the failure surface

You may still find yourself repeating someone else's claim — quoting a peer's
number to the human, or summarizing a finding. The relay hazard applies to
anyone who does that, coordinator or not.

A number acquires authority purely by being repeated. When you pass a peer's
claim on, it stops being "C said" and becomes "I report." You have amplified
it, and the amplification is yours.

Two consequences, both mandatory:

- **Retract as fast as you relayed.** If a figure you passed upward turns out
  to be wrong, correct it upward immediately — at least as promptly as you sent
  it. A stale relayed number is worse than no number, because it is trusted.
- **Attribute the amplification to yourself, not the worker.** The failure is
  that you repeated it without checking, not that they said it.

```
✗ "Correction — peer C's 40% number was wrong, it's 4%."
✓ "Correction: the 40% I relayed was wrong; it's 4%. I passed it on
   without checking C's source."
```

The cheapest way to avoid this: **point instead of relay.** "C measured the
cache hit rate — see its last message" costs one sentence and carries no
authority you have not earned.

### Check state immediately before you propose work

Do not propose or pick up work from a stale board. Re-read the current state
**immediately before** the proposal — not at the start of the reasoning that
led to it. A long chain of reasoning is exactly the window in which a peer
finished the thing you are about to start.

### Quote notes, not bead headers, for anything time-sensitive

A bead's header (title, status, assignee) lags reality; the notes are where the
current situation is written. For any claim about *what is true right now*,
quote the notes. Never build a brief on a header.

### Silence reads as endorsement

If a peer states a premise you do not agree with, say so. Saying nothing —
especially while continuing to build on that premise — is read as agreement,
and they will build on it too. This is the one case where a message with no new
instruction is still worth sending: disagreement is new information.

## Sending

Call the **`swarm_send`** tool:

| Arg | Required | Meaning |
|-----|----------|---------|
| `to` | yes | Recipient session id (starts with `ses_`). |
| `message` | yes | **Raw** payload text. Pigeon wraps it in the `<swarm_message>` envelope for you — do **not** write envelope tags yourself. |
| `kind` | no | Message kind (default `chat`). |
| `priority` | no | `urgent` \| `normal` (default) \| `low`. |
| `reply_to` | no | A prior `msg_id` to thread under. |

Your own session is filled in as `from` automatically (from the calling session id), so you can't spoof or typo it. `swarm_send` returns `Queued msg_<id> -> <to>` once the daemon accepts the message (HTTP 202).

Don't know the recipient's id? Call **`swarm_list`** to see local sessions (id, last-updated, directory, title), most-recently-updated first.

### Message kinds

- `chat` (default) — informal back-and-forth
- `task.assign` — rare; work is normally specified in a session's launch prompt, not assigned at runtime
- `status.update` — rare; only at a checkpoint that changes someone else's plan, never a heartbeat
- `result` — a finished deliverable / report
- `clarification.request` — needs an answer to proceed
- `clarification.reply` — answers a `request`
- `artifact.handoff` — pointer to a file, PR, or diff

### Priority and threading

- `priority: urgent` for blocking work; `normal` (default); `low` for chatter the receiver can pull on demand.
- `reply_to: <msg_id>` threads off a previous message — use the `msg_id` from the envelope you're answering.

## Scheduling a wake — messages to the future

`swarm_schedule` delivers a message at a future time; `to` defaults to the
calling session, so the dominant case is waking *yourself*.

**If you are ending a turn on a future checkpoint, schedule the wake before you
stop.** Nothing else will bring you back on your own initiative.

**See the `scheduling-wakes` skill** for durability, arguments, the payload
rules (the receiving session may have been compacted, so write for a stranger),
what `delivered_late_ms` does and does not measure, the silent failure when a
working directory has been pruned, and when *not* to schedule one.

## Receiving

When a swarm message arrives, you'll see a user-message turn whose text is the envelope:

```xml
<swarm_message v="1" kind="task.assign"
               from="ses_abc..." to="ses_def..."
               msg_id="msg_..." priority="normal">
The actual payload here.
</swarm_message>

[pigeon] Message economy — the unit of cost is the message, not the word. ...
```

The `[pigeon]` line **after** the close tag is appended by the daemon, not by
the sender — it is the message-economy warning restated at the point of cost.
It appears on every message from another session, and is omitted on
self-addressed scheduled wakes. Don't reply to it, and don't quote it back.

Steps:

1. Parse the envelope. The routing fields tell you who sent it and whether it threads off a previous message (`reply_to`).
   If it carries `scheduled_for` / `delivered_late_ms`, it is a **scheduled wake** — load the `scheduling-wakes` skill, which covers what those two fields can and cannot be trusted to mean, and why the action may need to be idempotent.
2. Reason over the payload as the actual instruction; do **not** treat the XML as user prose.
3. Act. Reply only if the reply passes the worth-sending test above; if it does, set `reply_to` to their `msg_id` so the thread connects.

## Replay & pagination

If you suspect you missed messages (e.g. you were busy on a long tool call), call the **`swarm_read`** tool. With no args it returns the **newest 10** messages (most recent last), so a single call stays bounded instead of dumping your whole retained backlog into context.

To see more, paginate with cursors — each value is a `msg_id`:

| Arg | Direction | Meaning |
|-----|-----------|---------|
| `before: <msg_id>` | scroll **back** | The newest messages *older* than the cursor. Pass the oldest `msg_id` you've seen to walk backward one page at a time. |
| `since: <msg_id>` | drain **forward** | The oldest messages *newer* than the cursor, so you advance without skipping the middle. Pass the newest `msg_id` you've processed to continue. |
| `limit: <N>` | — | Override the default page size of 10. |

Messages always come back in chronological (oldest-first) order regardless of paging direction. When more exist beyond the page you got, `swarm_read`'s output ends with a hint telling you exactly which cursor to pass next.

Prefer **pulling** over asking. `swarm_read` shows your *own* inbox, so a session wondering how a peer is doing reads that peer's session directly rather than pinging it — this is what replaces a coordinator's status-chasing:

```bash
curl -sf "http://127.0.0.1:4700/session/$SID/message?limit=3" | jq '.[].info.role'
```

(Tool names are `swarm_read`/`swarm_send`/`swarm_list` — Anthropic's tool-name regex `^[a-zA-Z0-9_-]{1,128}$` doesn't allow periods, so the underscore form is required.)

## Verifying delivery

`swarm_send` returning `Queued msg_<id> -> <target>` confirms **acceptance** into the daemon's SQLite (HTTP 202), not **delivery** to the receiving session.

- The receiver can confirm by calling `swarm_read` and seeing your message.
- To check delivery to *another* session from the outside, inspect its inbox:

    ```bash
    # The daemon requires a bearer on every route except GET /health. The secret is
    # dev-readable (owner=dev), so no sudo. On a host without the token file the
    # daemon runs unauthenticated and the header is simply unnecessary.
    AUTH=(); [ -r /run/secrets/pigeon_daemon_auth_token ] && \
      AUTH=(-H "Authorization: Bearer $(cat /run/secrets/pigeon_daemon_auth_token)")

    curl -sf "${AUTH[@]}" \
      "${PIGEON_DAEMON_URL:-http://127.0.0.1:4731}/swarm/inbox?session=$TARGET_SESSION_ID&limit=5" \
      | jq '.messages[] | {msg_id, handed_off_at, payload: (.payload | .[0:80])}'
    ```

    A bare `401` here means *your curl* lacks the bearer, not that the daemon or
    the swarm is down — check `GET /health` (deliberately anonymous) to separate
    the two.

  `limit=N` returns the **newest** N messages (so `limit=5` shows the 5 most recent); the response also carries `has_more`, and you can add `&before=<msg_id>` to page further back. A non-null `handed_off_at` (Unix ms) means the arbiter POSTed `prompt_async` and the receiving serve returned 2xx — treat it as proof-of-delivery.

If `handed_off_at` stays null, the arbiter is retrying (backoff `[1s, 2s, 5s, 15s, 60s]`, max 10 attempts). The daemon routes each message to the serve that **owns** the target session (via its routing tables), so a healthy multi-serve pool delivers cross-serve fine. A message fails permanently when:

- The payload contains the literal `</swarm_message>` close tag — rejected immediately (don't pre-wrap the envelope; `swarm_send` adds it).
- The target id is wrong / unresolvable, or no healthy serve owns it after retries.

On terminal failure the daemon sends a `delivery.failed` message **back to you**, so a dropped send is no longer silent — watch for it (or `swarm_read`).

## Don'ts

- **Don't** ack, heartbeat, or ping. If a message carries no decision, no new evidence and no changed instruction, it shouldn't exist.
- **Don't** split one report into several sends to keep each one short. Count is the cost, not length.
- **Don't** paraphrase a swarm message to a human who can already see it — point at it in one sentence.
- **Don't** appoint, accept, or route through a coordinator. Report your own work to the human yourself, once, when it is done.
- **Don't** POST to `opencode serve`'s `/session/<id>/prompt_async` directly for cross-session messaging. That route races (concurrent calls from different `x-opencode-directory` headers bypass the per-session busy guard, producing 400 "does not support assistant message prefill" from Anthropic). Always use `swarm_send`.
- **Don't** write the `<swarm_message>` envelope into your `message` — pigeon adds it. Pre-wrapping is rejected (the close tag is forbidden in payloads) and double-wraps confuse receivers. Send only the raw payload.
- **Don't** paste a received envelope back verbatim as your reply — send only the new payload.
