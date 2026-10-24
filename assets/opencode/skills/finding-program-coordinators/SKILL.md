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

Run the bundled script. It is read-only:

```bash
~/.agents/skills/finding-program-coordinators/find-coordinator.py <tag>
~/.agents/skills/finding-program-coordinators/find-coordinator.py --all
```

| Output | Exit | Meaning |
|---|---|---|
| `<tag>  to=gse_…  heartbeat=on\|off` | 0 | `swarm_send` to the `to=` id. See "Before you send" for what `heartbeat` changes. |
| `<tag>: no bound coordinator`, or a line saying nothing reads the mailbox or pigeon can't route to it | 1 | Don't send. See "No coordinator found". |
| `no stall-watch on THIS host…` | 2 | You are not on cloudbox. See "No coordinator found". |

A `warning:` on stderr means one cross-check was skipped, either because
`programs.toml` was unreadable or because pigeon was unreachable. The id is
still the registry's, but treat it as unverified.

What it checks: the registry is stall-watch's
`~/.local/state/stall-watch/state.db`, table `program`, column `pigeon_session`.
The coordinators' own `./sw peers` reads the same column. (`./sw` refuses to
run outside its coordinator.) The script then checks the program is enabled
and in tools mode in `programs.toml`, because a row can outlive its program.
Last, it checks that pigeon `GET /sessions` has the id `running` with a
`swarm` mailbox. Every coordinator is registered there under the label
`📋 <tag>`, with a working directory under
`~/.local/state/stall-watch/coord-sessions/<tag>-<ms>/`.

**Which tag?** Use the tag of the program that owns the problem, not your own.
If you only know the epic, the mapping from tag to `beads_epic` is in
`~/projects/eng-agent-platform/stallwatch/programs.toml` (a private repo).
`oc-tags which <ses_>` on any of that program's worker sessions also gives you
the tag.

## Before you send

- **A coordinator is not woken by your message.** Swarm mail to a `gse_` is
  drained by the stall-watch tick and shown to the coordinator at its **next
  wake**. With `heartbeat=on`, that is soon. Most programs run with the
  heartbeat **off**. Their coordinators wake when the human writes in their
  Telegram topic, on an alert, or on a review of items they already hold. For
  a quiet program that can be days away, or never.
- **So with `heartbeat=off`, sending is not handing off.** Send the message,
  **and** tell the human in one line that program X's coordinator has a message
  from you. Do this every time, urgent or not, and above all when nobody asked
  you to report. Your session might be gone by the time the coordinator reads
  the message, so the human must know it is there. This matches the
  coordinators' own rule: they treat a handoff as done only when the receiver's
  heartbeat is on.
- **Write it so a stranger can act on it.** The coordinator has not seen your
  conversation. In one message, include the finding, the evidence (file:line,
  bead id, PR, query output), what you think it means for its program, and what
  you need back, if anything. Use kind `result` for a report and
  `clarification.request` if you need an answer. The `swarm-messaging` economy
  rules apply: one substantial message, and no follow-up pings.
- **Expect the reply as a swarm message, possibly much later.** A coordinator
  with swarm tools replies to your `ses_` id, and that reply wakes you if your
  session is still alive.
- **Report to the program through its coordinator, not its workers.** A worker
  holds one slice of the program. The coordinator holds the whole of it, and
  it is the session the human talks to about that program.

## No coordinator found

Report the absence only after the lookup above says so on cloudbox: no row for
the tag, `pigeon_session` empty, or the program disabled. Then **tell the
human** that program X has no bound coordinator, give the evidence (the query
output), and wait for them to say where the finding should go.

On macOS or devbox there is no state DB. That does **not** mean there is no
coordinator. It means this host cannot reach one. Say exactly that, and ask
the human to forward the finding.

In either case, don't fall back to messaging a worker or a launcher session. A
dead `ses_` produces `delivery.failed`. A live one is the wrong recipient.
