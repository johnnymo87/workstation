---
name: swarm-messaging
description: Use when sending messages to other opencode sessions on the same machine (swarm coordination), or when you receive a <swarm_message> envelope as the text of a user-message turn.
---

# Swarm Messaging

Pigeon hosts a durable, replayable message channel between opencode sessions on the same machine. The opencode-pigeon plugin exposes three always-on tools:

- **`swarm_send`** — send a message to another session.
- **`swarm_read`** — read your own inbox (replay messages you may have missed); returns the newest 10 by default, with `before`/`since` cursor pagination.
- **`swarm_list`** — discover other local sessions (and their ids) to message.

The daemon serializes deliveries per target session (at-most-one in-flight) and persists every message to SQLite for retry and replay. This replaces the earlier race-prone pattern of POSTing directly to `opencode serve`'s `prompt_async`.

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
- `task.assign` — coordinator asks a worker to do something
- `status.update` — worker reports progress
- `result` — a finished deliverable / report
- `clarification.request` — needs an answer to proceed
- `clarification.reply` — answers a `request`
- `artifact.handoff` — pointer to a file, PR, or diff

### Priority and threading

- `priority: urgent` for blocking work; `normal` (default); `low` for chatter the receiver can pull on demand.
- `reply_to: <msg_id>` threads off a previous message — use the `msg_id` from the envelope you're answering.

## Message economy — send less

Every send costs the receiver a full turn: it interrupts whatever they're
doing and spends a whole reasoning cycle on your message. The failure mode in
practice is not messages that are too long — it's messages that didn't need to
exist. Treat each send as expensive.

**Send only when the message changes what the receiver will do:**

| Send | Don't send |
|------|-----------|
| Task assignment (`task.assign`) | Acknowledgments ("got it", "on it", "will do") |
| Blocking question (`clarification.request`) | Progress heartbeats ("still working", "50% done") |
| Finished deliverable (`result`, `artifact.handoff`) | "Starting now" notices |
| Terminal failure / blocker the receiver must act on | Restating what was already agreed |
| Answer to a question asked of you | Courtesy pings, thanks, sign-offs |

Rules of thumb:

- **Batch.** If you're tempted to send a second message before the receiver
  answered the first, fold it in. Accumulate findings into one consolidated
  update instead of N incremental ones.
- **Reply only when a reply is needed.** `task.assign` needs an eventual
  `result`; a `status.update` needs no reply; a `result` needs a reply only if
  acceptance or review is expected.
- **Prefer pull over push.** Workers report at agreed milestones or on
  completion — not on a timer. Anything the receiver could pull on demand
  (`swarm_read`, inbox) should be `priority: low` or not sent at all.
- **Default to silence.** If unsure whether a message is needed, don't send
  it. A quiet worker making progress is the healthy state; the coordinator can
  always ask.

## Receiving

When a swarm message arrives, you'll see a user-message turn whose text is the envelope:

```xml
<swarm_message v="1" kind="task.assign"
               from="ses_abc..." to="ses_def..."
               msg_id="msg_..." priority="normal">
The actual payload here.
</swarm_message>
```

Steps:

1. Parse the envelope. The routing fields tell you who sent it and whether it threads off a previous message (`reply_to`).
2. Reason over the payload as the actual instruction; do **not** treat the XML as user prose.
3. If you reply with `swarm_send`, set `reply_to` to their `msg_id` so the thread connects.

## Replay & pagination

If you suspect you missed messages (e.g. you were busy on a long tool call), call the **`swarm_read`** tool. With no args it returns the **newest 10** messages (most recent last), so a single call stays bounded instead of dumping your whole retained backlog into context.

To see more, paginate with cursors — each value is a `msg_id`:

| Arg | Direction | Meaning |
|-----|-----------|---------|
| `before: <msg_id>` | scroll **back** | The newest messages *older* than the cursor. Pass the oldest `msg_id` you've seen to walk backward one page at a time. |
| `since: <msg_id>` | drain **forward** | The oldest messages *newer* than the cursor, so you advance without skipping the middle. Pass the newest `msg_id` you've processed to continue. |
| `limit: <N>` | — | Override the default page size of 10. |

Messages always come back in chronological (oldest-first) order regardless of paging direction. When more exist beyond the page you got, `swarm_read`'s output ends with a hint telling you exactly which cursor to pass next.

(Tool names are `swarm_read`/`swarm_send`/`swarm_list` — Anthropic's tool-name regex `^[a-zA-Z0-9_-]{1,128}$` doesn't allow periods, so the underscore form is required.)

## Verifying delivery

`swarm_send` returning `Queued msg_<id> -> <target>` confirms **acceptance** into the daemon's SQLite (HTTP 202), not **delivery** to the receiving session.

- The receiver can confirm by calling `swarm_read` and seeing your message.
- To check delivery to *another* session from the outside, inspect its inbox:

  ```bash
  curl -sf "${PIGEON_DAEMON_URL:-http://127.0.0.1:4731}/swarm/inbox?session=$TARGET_SESSION_ID&limit=5" \
    | jq '.messages[] | {msg_id, handed_off_at, payload: (.payload | .[0:80])}'
  ```

  `limit=N` returns the **newest** N messages (so `limit=5` shows the 5 most recent); the response also carries `has_more`, and you can add `&before=<msg_id>` to page further back. A non-null `handed_off_at` (Unix ms) means the arbiter POSTed `prompt_async` and the receiving serve returned 2xx — treat it as proof-of-delivery.

If `handed_off_at` stays null, the arbiter is retrying (backoff `[1s, 2s, 5s, 15s, 60s]`, max 10 attempts). The daemon routes each message to the serve that **owns** the target session (via its routing tables), so a healthy multi-serve pool delivers cross-serve fine. A message fails permanently when:

- The payload contains the literal `</swarm_message>` close tag — rejected immediately (don't pre-wrap the envelope; `swarm_send` adds it). 
- The target id is wrong / unresolvable, or no healthy serve owns it after retries.

On terminal failure the daemon sends a `delivery.failed` message **back to you**, so a dropped send is no longer silent — watch for it (or `swarm_read`).

## Don'ts

- **Don't** POST to `opencode serve`'s `/session/<id>/prompt_async` directly for cross-session messaging. That route races (concurrent calls from different `x-opencode-directory` headers bypass the per-session busy guard, producing 400 "does not support assistant message prefill" from Anthropic). Always use `swarm_send`.
- **Don't** write the `<swarm_message>` envelope into your `message` — pigeon adds it. Pre-wrapping is rejected (the close tag is forbidden in payloads) and double-wraps confuse receivers. Send only the raw payload.
- **Don't** paste a received envelope back verbatim as your reply — send only the new payload.
- **Don't** ack, heartbeat, or ping. If a message doesn't change what the receiver will do, it shouldn't exist (see "Message economy" above).
