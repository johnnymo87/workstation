---
name: opencode-send
description: Use when you need to post a message into another OpenCode session running on the same machine — cross-session coordination, kicking off work in a parallel session, or relaying results between sessions.
---

# Sending Messages to Another OpenCode Session

`opencode-send` posts a text prompt into another local OpenCode session. Run `opencode-send --help` for all options.

By default, when the target id matches `^ses_` and the local pigeon daemon is reachable, `opencode-send` **auto-routes through pigeon** for durable, retried, race-safe delivery. Pass `--direct` to bypass pigeon and POST straight to opencode serve (legacy/debug only).

## Quick Start

```bash
# Discover a session id
opencode-send --list

# Send (auto-routes via pigeon for ses_* targets)
opencode-send ses_abc123 "please run the failing test in src/auth.ts"

# Pipe a longer message from stdin
cat plan.md | opencode-send ses_abc123 -

# Bypass pigeon (legacy direct-to-opencode-serve path)
opencode-send --direct ses_abc123 "hello"
```

## Two Paths, One CLI

| Path | When | What it does |
|---|---|---|
| Auto-route via pigeon (default) | Target id matches `^ses_` AND pigeon `/health` returns 2xx | `exec pigeon-send --from $OPENCODE_SESSION_ID <to> <message>` — the daemon serializes per-target deliveries, persists for retry/replay, and wraps the payload in a `<swarm_message>` envelope on the receiving side. |
| Direct to opencode serve | `--direct` flag, OR target doesn't match `^ses_`, OR pigeon `/health` not reachable | POST to `http://127.0.0.1:4096/session/<id>/prompt_async` with an flock guard. Legacy v1 path; vulnerable to the prompt_async race when two callers from different cwds hit the same session. |

If you don't know which path was taken, check the output line:

- `Queued msg_... -> ses_... (kind=chat priority=normal, N chars)` — pigeon path.
- `Sent to ses_... (cwd=..., N chars)` — direct path.

## When To Use

- **Hand off work between sessions:** "Session A finished the design, now tell session B to implement it."
- **Worker → worker coordination:** A backend worker tells the frontend worker "the API is deployed at `/v2/foo`". (Workers can talk to each other directly; they don't need to route through a coordinator unless the coordinator's shared-context role matters for the message.)
- **Trigger a parallel session:** You launched a headless session via `opencode-launch` and want to feed it follow-up instructions.
- **Relay results:** Pass a summary, file path, or error trace from one session into another's input stream.
- **Decompose multi-repo work:** See the `swarm-shaped-work` skill for when to swarm vs. iterate sequentially.

## When NOT To Use

- **You want to message a session on a different machine.** Both paths are local-only. Use Telegram + `/launch` for cross-machine work.
- **You want to send to your own current session.** That's just typing into the TUI.
- **You want command output, not a prompt.** This delivers a user message; the receiving session's agent decides what to do with it.

## Finding The Session ID

`opencode-send --list` prints the local sessions sorted by last-updated:

```
ID                                UPDATED     DIRECTORY                                 TITLE
ses_268183fceffep6ViEE20s5XWc8    3m          /home/dev                                 PDF code extraction from page 2
ses_272a9b9b8ffeVBXCz6SQmsJF4l    1h          /home/dev/projects/pigeon                 Implement opencode-send CLI
```

Other sources of session ids:

- Telegram pigeon notifications include the session id on its own line.
- `lgtm-sessions` lists active lgtm-dispatched sessions with their ids.
- `opencode attach <url> --session <id>` — the ids you'd attach to.
- **Your own session's id:** `echo $OPENCODE_SESSION_ID` from inside any bash tool call. Injected by the `shell-env` plugin (`assets/opencode/plugins/shell-env.ts`) so an agent can hand its own id to a peer for back-and-forth messaging.

## Receiving Side

Messages sent through pigeon arrive in the target's transcript wrapped in an XML envelope:

```xml
<swarm_message v="1" kind="chat"
               from="ses_abc..." to="ses_def..."
               msg_id="msg_..." priority="normal">
your message text here
</swarm_message>
```

Receiving agents should:

1. Recognize the envelope and read the routing fields (who, kind, priority, optional `reply_to` for threading).
2. Reason over the **payload**, not the XML.
3. If replying, use `pigeon-send --reply-to <their msg_id>` (or just `opencode-send` again — auto-route handles it).

Messages sent via `--direct` arrive as a plain user message with no envelope.

The `swarm-messaging` skill is the dedicated guide for the receiving side and goes deeper on kinds, priorities, and replay via `swarm.read`.

## Why Auto-Route?

The legacy `--direct` path has a known race: two `prompt_async` calls to the same session from **different** `x-opencode-directory` headers bypass the per-session busy guard, producing parallel LLM turns and a 400 "does not support assistant message prefill" from Anthropic. Auto-routing through pigeon fixes this architecturally — the daemon is the single writer per target, with at-most-one in-flight `prompt_async` per session id.

You also get for free:

- **Durable delivery.** The daemon persists every message before returning 202. Restarts and crashes don't lose messages.
- **Retry with backoff.** If `prompt_async` returns 5xx or the target is briefly unreachable, the arbiter retries with `[1s, 2s, 5s, 15s, 60s]` schedule, MAX_ATTEMPTS=10.
- **Replay.** Receivers can call the `swarm.read` opencode tool to fetch their inbox if they think they missed something.

`--direct` is preserved as the escape hatch for cases where you specifically want the legacy path (e.g. debugging the daemon or proving a bug exists).

## Gotchas

- **Pigeon must be reachable for auto-route.** If `curl /health` fails (no pigeon installed, daemon down), `opencode-send` silently falls through to direct mode. Verify by checking the output line — `Queued ...` means pigeon path, `Sent to ...` means direct.
- **You can interrupt a busy session.** If the target is mid-turn, your message lands on the queue and runs after the current turn completes. Avoid sending to an active session unless that's intentional.
- **Cross-session messages are visible in the target's transcript** as a regular user message (envelope-wrapped on the pigeon path). They show up in `oc-search` and the TUI history like any other prompt.
- **`POST /session/<id>/prompt_async` returns 204 for any id** (real or fake). The direct path does a pre-flight `GET /session/<id>` to catch typos; the pigeon path queues regardless and the arbiter surfaces the 404 as a retry-then-fail.

## Options

| Flag | Purpose |
|---|---|
| `--list` | List local sessions instead of sending. |
| `--cwd DIR` | Set the `x-opencode-directory` header (direct path only; default: `$PWD`). |
| `--url URL` | Override opencode serve base URL (direct path only; default `http://127.0.0.1:4096`, env `OPENCODE_URL`). |
| `--no-lock` | Skip the per-session flock on the direct path (default: lock enabled). |
| `--direct` | Skip pigeon routing and POST directly to opencode serve. Legacy/debug only. |
| `-` as message | Read message from stdin. |

## Lower-Level Primitive

`pigeon-send` is the underlying CLI that talks to the daemon directly. Use it when you want explicit control over `--kind`, `--priority`, `--reply-to`, or `--msg-id`:

```bash
pigeon-send --kind task.assign --priority urgent \
            --reply-to msg_def ses_abc "please run the diff"
```

`opencode-send` exists primarily for backwards compatibility with scripts and skills that already reference it. For new sender code, reach for `pigeon-send` directly when you need the rich options.

See the `swarm-messaging` skill for the full sender + receiver protocol.

## Design Notes

| Decision | Chosen | Why |
|---|---|---|
| Default transport | Pigeon (auto-route for `ses_*`) | Architecturally fixes the prompt_async race, gives durable delivery + retry + replay |
| Escape hatch | `--direct` flag | Legacy path retained for debug / explicit bypass |
| Implementation | Bash + curl + jq | Matches `oc-search` / `lgtm-sessions` style; trivial to audit |
| Discovery | `--list` via `GET /session` | Lets agents find targets without leaving the shell |
| Auto-route guard | `^ses_` regex + pigeon `/health` 2xx | Falls through to direct if pigeon is missing or unreachable, so the wrapper degrades gracefully |
