---
name: finding-program-coordinators
description: Looks up the coordinator session of a program of work (an oc-tags tag) and the id to swarm_send to. Use when asked to report, hand off, or escalate something to another program's coordinator, when work you found belongs to a different program's tag or epic, when you are about to conclude a program has no coordinator, or when you see a gse_ session id or a "📋 <tag>" label and need to know what it is.
---

# Finding a Program's Coordinator

On cloudbox, almost every active program of work has a **coordinator**. It is a
long-lived goose session run by `stall-watch`, one per program, and it is keyed
by the program's oc-tags tag. You reach it with `swarm_send` to a **`gse_`** id.
The lookup is one read-only query.

This is not the coordinator role that `swarm-messaging` bans. That ban covers
an opencode session that appoints itself, or is appointed, to route messages
inside a swarm. Program coordinators are the human's standing infrastructure.
If a finding belongs to another program, its coordinator is the right
recipient.

## Why this skill exists

On 2026-10-24 a session found an issue that belonged to another program. The
human asked it to report the issue to that program's coordinator. The session
concluded that no coordinator existed, which was wrong. Here is what it tried:

| It tried | Why that could not find the coordinator |
|---|---|
| `swarm_list` | Lists **opencode** sessions only (and only recent ones). Coordinators are goose sessions, so none of them appear. |
| The program epic's bead notes ("there is no coordinator") | The notes described one swarm's own topology. Nobody updates a program's beads when stall-watch binds or rebinds its coordinator, so the notes are not a registry. |
| grep of `opencode.db` titles | The wrong database. Coordinators live in goose's `sessions.db`, and their titles are not the tag. |
| `swarm_send` to the `ses_` that launched the program's swarm | A launcher is not a coordinator. Its worktree was gone, and pigeon returned `delivery.failed`. |
| (not tried) `oc-tags` | Would not have helped. Coordinator sessions are **not** tagged with their program's tag. They report as `stall-watcher-runs` or `auto:goose/stallwatch-<tag>-<ms>`. |

The tag was enough. It is the key to the registry, and the session never
queried the registry.

## The lookup

stall-watch's state DB is the registry. The `pigeon_session` column holds the id
to `swarm_send` to. That is the same value the coordinators' own `./sw peers`
command reads. (`./sw` will not run outside its coordinator: it refuses on
identity.) There is no `sqlite3` CLI on cloudbox, so use python:

```bash
TAG=<program-tag>
python3 - "$TAG" <<'PY'
import os, sqlite3, sys
tag = sys.argv[1]
db = os.path.expanduser("~/.local/state/stall-watch/state.db")
if not os.path.exists(db):
    sys.exit("no stall-watch on this host: no program coordinators here")
con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)   # read-only
row = con.execute("SELECT coord_mode, coord_session, pigeon_session"
                  " FROM program WHERE tag=?", (tag,)).fetchone()
if not row or not row[2]:
    sys.exit(f"{tag}: no bound coordinator (row={row})")
print(f"{tag}  to={row[2]}  goose={row[1]}  mode={row[0]}")
PY
```

To list every program that has one, use
`SELECT tag, pigeon_session FROM program WHERE pigeon_session IS NOT NULL`.

**Then confirm pigeon can route to it.** Pigeon is the daemon that actually
delivers your message:

```bash
AUTH=(); [ -r /run/secrets/pigeon_daemon_auth_token ] && \
  AUTH=(-H "Authorization: Bearer $(cat /run/secrets/pigeon_daemon_auth_token)")
curl -sf "${AUTH[@]}" "${PIGEON_DAEMON_URL:-http://127.0.0.1:4731}/sessions" \
  | jq -r --arg l "📋 $TAG" '.sessions[] | select(.label == $l)
      | "\(.session_id)  state=\(.state)  pulls=\(.pull_sources | join(","))"'
```

You want exactly one row. Its `session_id` should equal `to=` above,
`state=running`, and `pulls` should include `swarm`. Every coordinator is
registered under the label `📋 <tag>`, with a working directory under
`~/.local/state/stall-watch/coord-sessions/<tag>-<ms>/`. If the two sources
disagree, the state DB wins: stall-watch rebinds and deletes superseded `gse_`
rows, so a stray pigeon row is the stale side.

**Which tag?** Use the tag of the program that owns the problem, not your own.
If you only know the epic, the mapping from tag to `beads_epic` is in
`~/projects/eng-agent-platform/stallwatch/programs.toml` (a private repo).
`oc-tags which <ses_>` on any of that program's worker sessions also gives you
the tag.

## Before you send

- **A coordinator is not woken by your message.** Swarm mail to a `gse_` is
  drained by the stall-watch tick and shown to the coordinator at its **next
  wake**. A wake comes from the human's reply in its Telegram topic, an alert,
  its daily reminder review, or its heartbeat. Most programs run with the
  heartbeat off (`heartbeat = true` in `programs.toml` means on), so the next
  wake can be hours away. If the issue is urgent, send the message **and** tell
  the human in one line that you sent it. Don't assume the coordinator has
  seen it.
- **Write it so a stranger can act on it.** The coordinator has not seen your
  conversation. In one message, include the finding, the evidence (file:line,
  bead id, PR, query output), what you think it means for its program, and what
  you need back, if anything. Use kind `result` for a report and
  `clarification.request` if you need an answer. The `swarm-messaging` economy
  rules apply: one substantial message, and no follow-up pings.
- **Expect the reply as a swarm message.** A coordinator with swarm tools
  replies to your `ses_` id, and that reply wakes you.
- **Report to the program through its coordinator, not its workers.** A worker
  holds one slice of the program. The coordinator holds the whole of it, and
  it is the session the human talks to about that program.

## No coordinator found

Report the absence only after the lookup above says so: no row for the tag,
`pigeon_session` empty, or no state DB on this host (macOS, devbox). Then
**tell the human** that program X has no bound coordinator, give the evidence
(the query output), and wait for them to say where the finding should go. Don't
fall back to messaging a worker or a launcher session. A dead `ses_` produces
`delivery.failed`. A live one is the wrong recipient.
