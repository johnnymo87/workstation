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

Run `coordinator`, printing its exit code. It is on PATH on cloudbox, and it is
read-only:

```bash
coordinator <tag>; echo "exit=$?"
coordinator --all; echo "exit=$?"
```

Your shell tool may not show you the exit code on its own, and one output reads
the same under exit 1 and exit 3. **Classify the result by the `exit=` line,
not by the text.**

| Exit | Output | Meaning |
|---|---|---|
| 0 | `<tag>  to=gse_…  heartbeat=on\|off` | Verified. `swarm_send` to the `to=` id. See "Before you send" for what `heartbeat` changes. |
| 1 | `<tag>: no bound coordinator`, `<tag>: no such program in programs.toml`, or a line saying nothing reads the mailbox or pigeon can't route to it | Don't send. See "No coordinator found". |
| 2 | `no stall-watch on THIS host…` | You are not on cloudbox. See "No coordinator found". |
| 3 | An `error:` or `warning:` on stderr, with or without a `to=` line | The lookup failed, or a cross-check was skipped. A `to=` line may still be right, but it is unverified. **Do not conclude there is no coordinator.** Retry once. If it exits 3 again, tell the human what it printed. |
| 127 | `coordinator: command not found` | Run `hostname`. On `cloudbox`, the install is broken: treat it as exit 3, and include `ls -l ~/.local/bin/coordinator` in what you tell the human. On any other host, treat it as exit 2, because only cloudbox installs the command. |

A Python traceback counts as exit 3, whatever the exit code says.

`--all` prints one line per bound program. It exits 0, or 3 when a cross-check
was skipped and it still printed a `to=` line.

What it checks: the registry is stall-watch's
`~/.local/state/stall-watch/state.db`, table `program`, column `pigeon_session`.
The coordinators' own `./sw peers` reads the same column through the same code.
(`./sw` refuses to run outside its coordinator.) `coordinator` then checks that
the program is enabled and in tools mode in `programs.toml`, because a row can
outlive its program, and that the stall-watch tick would actually drain the
mailbox. Last, it checks that pigeon `GET /sessions` has the id `running` with a
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

Report the absence only after `coordinator` exits 1 on cloudbox. Exit 3 is not
an absence.

- **`no such program in programs.toml`** usually means the tag is wrong. Run
  `coordinator --all`, which lists only programs that have a coordinator, or
  check `programs.toml` (see "Which tag?") for the right tag before you tell
  anyone anything.
- **`not routable in pigeon`** can be temporary while a coordinator is being
  rebound. Retry once after a few minutes.
- **Otherwise,** tell the human that program X has no reachable coordinator.
  Quote the line `coordinator` printed rather than paraphrasing it, and wait
  for them to say where the finding should go.

On macOS or devbox there is no state DB. That does **not** mean there is no
coordinator. It means this host cannot reach one. Say exactly that, and ask
the human to forward the finding.

In either case, don't fall back to messaging a worker or a launcher session. A
dead `ses_` produces `delivery.failed`. A live one is the wrong recipient.
