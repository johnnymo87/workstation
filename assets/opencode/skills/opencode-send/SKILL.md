---
name: opencode-send
description: Use when you need to post a message into another OpenCode session running on the same machine (cross-session coordination, kicking off work in a parallel session, or relaying results between sessions).
---

# Sending Messages to Another OpenCode Session

Post a text prompt into any OpenCode session running on the local machine using `opencode-send`. Run `opencode-send --help` for all options.

This is purely local opencode-to-opencode messaging. It does **not** go through pigeon/Telegram — it talks directly to opencode serve at `http://127.0.0.1:4096`.

## Quick Start

```bash
# Discover a session ID
opencode-send --list

# Send a one-liner
opencode-send ses_abc123 "please run the failing test in src/auth.ts"

# Pipe a longer message from stdin
cat plan.md | opencode-send ses_abc123 -

# Send from inside a project directory (sets x-opencode-directory header)
opencode-send --cwd ~/projects/pigeon ses_abc123 "rerun npm run typecheck"
```

## When to Use

- **Hand off work between sessions:** "Session A finished the design, now tell session B to implement it."
- **Trigger a parallel session:** You launched a headless session via `/launch` (or `opencode-launch`) and want to feed it follow-up instructions.
- **Relay results:** Pass a summary, file path, or error trace from one session into another's input stream.

## When NOT to Use

- **You want to message a session on a different machine.** This v1 is local-only. Use Telegram + `/launch` for cross-machine work.
- **You want to send to your own current session.** That's just typing into the TUI.
- **You want command output, not a prompt.** This delivers a user message; the receiving session's agent decides what to do with it.

## Finding the Session ID

`opencode-send --list` prints the local sessions sorted by last-updated:

```
ID                                UPDATED     DIRECTORY                                 TITLE
ses_268183fceffep6ViEE20s5XWc8    3m          /home/dev                                 PDF code extraction from page 2
ses_272a9b9b8ffeVBXCz6SQmsJF4l    1h          /home/dev/projects/pigeon                 Implement opencode-send CLI
```

Other sources of session IDs:
- Telegram pigeon notifications include the session ID on its own line.
- `lgtm-sessions` lists active lgtm-dispatched sessions with their IDs.
- `opencode attach <url> --session <id>` — the IDs you'd attach to.
- **Your own session's ID:** `echo $OPENCODE_SESSION_ID` from inside any bash tool call. Injected by the `shell-env` plugin (`assets/opencode/plugins/shell-env.ts`) so an agent can hand its own ID to a peer for back-and-forth messaging.

## How It Works

```
opencode-send <id> "msg"
        │
        ▼
POST http://127.0.0.1:4096/session/<id>/prompt_async
  Header: x-opencode-directory: <cwd>
  Body:   {"parts":[{"type":"text","text":"msg"}]}
```

The receiving session sees the message exactly as if a Telegram reply or pigeon-delivered command had arrived: it enters the agent's input stream and triggers a new turn.

Before sending, `opencode-send` does a pre-flight `GET /session/<id>` to verify the target exists. A 404 fails the command with a clear error and a hint to run `--list` — so typos and stale IDs are caught up front.

## Gotchas

- **You can interrupt a busy session.** If the target is mid-turn, your message lands on the queue and runs after the current turn completes (or alongside, depending on the agent). Avoid sending to an active session unless that's intentional.
- **Cross-session messages are visible in the target's transcript** as a regular user message. They show up in `/sessions` and `oc-search` like any other prompt.
- **POST `/session/<id>/prompt_async` returns 204 for any id** (real or fake). That's why the pre-flight GET is necessary — the POST response alone doesn't confirm delivery to a real session.

## Options

| Flag             | Purpose                                                |
|------------------|--------------------------------------------------------|
| `--list`         | List local sessions instead of sending                 |
| `--cwd DIR`      | Set the `x-opencode-directory` header (default: `$PWD`) |
| `--url URL`      | Override opencode serve base URL (default `http://127.0.0.1:4096`, env `OPENCODE_URL`) |
| `-` as message   | Read message from stdin                                |

## Design Notes

| Decision           | Chosen                                | Why                                                              |
|--------------------|---------------------------------------|------------------------------------------------------------------|
| Transport          | Direct to opencode serve              | No daemon dependency, no auth, no D1 round trip                  |
| Scope              | Local-only (v1)                       | Cross-machine adds auth + daemon route; not needed yet           |
| Implementation     | Bash + curl + jq                      | Matches `oc-search` / `lgtm-sessions` style; trivial to audit    |
| Discovery          | `--list` via `GET /session`           | Lets agents find targets without leaving the shell               |
| `cwd` default      | `$PWD`                                | Most invocations are from the project the session lives in       |

For cross-machine messaging in the future, route through the pigeon daemon's worker-injection path instead.
