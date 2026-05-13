---
name: swarm-messaging
description: Use when sending messages to other opencode sessions on the same machine (swarm coordination), or when you receive a <swarm_message> envelope as the text of a user-message turn.
---

# Swarm Messaging

Pigeon hosts a durable, replayable message channel between opencode sessions on the same machine. Use `pigeon-send` to send and the `<swarm_message>` envelope to recognize messages you receive.

This replaces the earlier "race-prone" pattern of POSTing directly to `opencode serve`'s `prompt_async`. The pigeon daemon serializes deliveries per target session (at-most-one in-flight) and persists every message to SQLite for retry and replay.

## Sending

### First, verify pigeon is reachable

```bash
curl -sf "${PIGEON_DAEMON_URL:-http://127.0.0.1:4731}/health"
# expected: {"ok":true,"service":"pigeon-daemon"}
```

If this fails, the daemon isn't running — `pigeon-send` will exit 1 with
"daemon unreachable" before queuing your message. The default port is
`4731` (set in pigeon's `config.ts` as `DEFAULT_PORT`). Override with
`$PIGEON_DAEMON_URL`.

```bash
pigeon-send <to-session-id> "your message"
```

The wrapper pulls your own session id from `$OPENCODE_SESSION_ID` (injected by the opencode-plugin shell-env hook) so you don't have to specify `--from`.

The legacy `opencode-send <ses_*> "..."` command **also** auto-routes through pigeon now — when the target id starts with `ses_` and the daemon is reachable, `opencode-send` execs `pigeon-send` for you. Pass `--direct` to bypass and POST directly to `opencode serve` (debug only).

### Message kinds

- `chat` (default) — informal back-and-forth
- `task.assign` — coordinator asks a worker to do something
- `status.update` — worker reports progress
- `clarification.request` — needs an answer to proceed
- `clarification.reply` — answers a `request`
- `artifact.handoff` — pointer to a file, PR, or diff

### Priority and threading

- `--priority urgent` for blocking work; `normal` (default); `low` for chatter the receiver can pull on demand.
- `--reply-to <msg_id>` threads off a previous message. Use the `msg_id` from the envelope you're answering.
- `--msg-id <id>` lets the caller supply an idempotency key (POST is idempotent on `(from, msg_id)`).

### Examples

```bash
pigeon-send ses_abc "frontend tests are failing on PROJ-6107"

echo "long status update" | pigeon-send --kind status.update ses_abc -

pigeon-send --priority urgent --kind task.assign \
            --reply-to msg_def ses_abc "please run the diff"
```

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

1. Parse the envelope. The routing fields tell you who sent it and whether it threads off a previous message.
2. Reason over the payload as the actual instruction; do **not** treat the XML as user prose.
3. If you reply via `pigeon-send`, set `--reply-to <their msg_id>` so the thread connects.

## Replay

If you suspect you missed messages (e.g. you were busy on a long tool call), call the `swarm_read` tool with no args to fetch your inbox. Pass `since: <msg_id>` to fetch only messages newer than a known cursor.

(Tool name is `swarm_read` — Anthropic's tool-name regex `^[a-zA-Z0-9_-]{1,128}$` doesn't allow periods, so the underscore form is required.)

The tool is registered by the opencode-pigeon plugin and routes to `GET /swarm/inbox?session=<your_id>` on the local pigeon daemon.

## Verifying Delivery

`pigeon-send` prints `Queued msg_<id> -> ses_<target>` after the daemon
accepts the message into SQLite (HTTP 202). That confirms **acceptance**,
not delivery. To confirm **delivery to the receiving opencode session**,
inspect the inbox:

```bash
curl -sf "${PIGEON_DAEMON_URL:-http://127.0.0.1:4731}/swarm/inbox?session=$TARGET_SESSION_ID&limit=5" | jq '.messages[] | {msg_id, handed_off_at, payload: (.payload | .[0:80])}'
```

A non-null `handed_off_at` (Unix ms timestamp) means the arbiter
successfully POSTed `prompt_async` and the receiving opencode-serve
returned 2xx. This is the positive delivery signal; treat it as
proof-of-delivery.

If `handed_off_at` is null after several seconds, the arbiter is
retrying. Backoff schedule is `[1s, 2s, 5s, 15s, 60s]`, max 10 attempts.
Common causes:

- Target session id is wrong → `registry.resolve` returns 404 → retries
  exhaust → row stays in `pending` then flips to `failed`.
- opencode-serve at `:4096` is down → all targets stall.
- Target session lives in a different opencode-serve instance (not on
  `:4096`). Pigeon only talks to `:4096`; sessions owned by other
  serves are unreachable.

## Don'ts

- **Don't** talk to `opencode serve`'s `/session/<id>/prompt_async` directly
  for cross-session messaging. That route races (concurrent calls from
  different `x-opencode-directory` headers bypass the per-session busy
  guard, producing 400 "does not support assistant message prefill" from
  Anthropic — see `docs/plans/2026-04-21-opencode-prefill-fix-design.md`
  for the full root cause). Always go through `pigeon-send` (or
  `opencode-send` which auto-routes). Note that `prompt_async` returns 204
  for ANY id (real or fake) on the direct path; pigeon's arbiter does its
  own pre-flight `GET /session/<id>` before posting, so typos surface as
  a retry-then-fail in the daemon (not silently dropped).
- **Don't** paste the envelope back as your own message — receivers will see two layers of envelope and get confused. Send only the payload.
- **Don't** use `--direct` unless you're explicitly debugging the legacy path. The auto-route gives you durable delivery and serialization for free.
