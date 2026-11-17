---
name: finding-program-coordinators
description: Looks up the coordinator session of a program of work (a session-tags tag) and the id to swarm_send to. Use when asked to report, hand off, or escalate something to another program's coordinator, when work you found belongs to a different program's tag or epic, when you are about to conclude a program has no coordinator, or when you see a gse_ session id or a "📋 <tag>" label and need to know what it is.
---

# Finding a Program's Coordinator

Almost every active program of work has a **coordinator**. It is a long-lived
goose session run by `stall-watch`, one per program, and it is keyed by the
program's session-tags tag. You reach it with `swarm_send` to a **`gse_`** id.
The lookup is one read-only query.

**Each machine that runs stall-watch has coordinators for its own programs**:
cloudbox for the work programs, devbox (since 2026-11-04) for the personal ones,
such as `eternal-machinery`. A coordinator lives on the machine that runs its
program, which may not be the machine you are on. That does not stop you: the
lookup finds coordinators on other machines too, and pigeon's cross-machine
relay delivers to them and routes their replies back to you.

Program coordinators are the human's standing infrastructure. If a finding
belongs to another program, its coordinator is the right recipient. When you
pass on something the human said, quote him and say when; the coordinator will
take it as his.

**"The coordinator" can mean something else in a repo.** eternal-machinery, for
one, has an in-game AgentOS agent named `coordinator`. When the human says
"report this to the coordinator" while you are working on a program, they mean
that program's stall-watch coordinator unless the context is plainly the
in-repo thing. If you can't tell, ask.

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
| (not tried) `session-tags` | Would not have helped. Coordinator sessions are **not** tagged with their program's tag. They report as `stall-watcher-runs` or `auto:goose/stallwatch-<tag>-<ms>`. |

The tag was enough. It is the key to the registry, and the session never
queried the registry.

On 2026-11-05 it happened again on devbox, for a different reason: stall-watch
had been running there for a day, but this skill was still deployed to work
hosts only and `coordinator` was not on the agent's PATH. The session guessed
a recipient instead. Both are fixed; the skill and the command are on every host.

On 2026-11-17 the devbox eternal-machinery coordinator was asked to report a
finding to the stall-watcher coordinator on cloudbox, and could not.
`coordinator stall-watcher` answered that the coordinator "runs on cloudbox;
this host cannot reach it" (exit 2), and goose's `swarm_list remote: true` did
not show coordinators. Pigeon had made coordinators reachable and listed across
machines on 2026-11-06, but neither tool had learned to use that. Both do now:
`coordinator` asks pigeon for other machines' coordinators, and both
harnesses' `swarm_list remote: true` lists them.

(The table above describes 2026-10-24. Since 2026-11-06 opencode's `swarm_list`
does show this machine's goose sessions with coordinators marked; the registry
is still the authority, because only it checks that the program is live.)

## The lookup

Run `coordinator`, printing its exit code. It is on PATH on every host, and it
is read-only. It finds a program's coordinator wherever it runs: this host's
stall-watch registry for this host's programs, and pigeon's listing of other
machines' coordinators for the rest (`--all` prints both):

```bash
coordinator <tag>; echo "exit=$?"
coordinator --all; echo "exit=$?"
```

Your shell tool may not show you the exit code on its own, and one output reads
the same under exit 1 and exit 3. **Classify the result by the `exit=` line,
not by the text.**

| Exit | Output | Meaning |
|---|---|---|
| 0 | `<tag>  to=gse_…  heartbeat=on\|off`, or for another machine's program `<tag>  to=gse_…  machine=<m>  relay=available  heartbeat=…` | Verified. `swarm_send` to the `to=` id; pigeon relays it if it is on another machine. `relay=offline (held …)` means that machine is asleep: the message is held up to 24h and delivered when it wakes. `heartbeat` does not affect delivery (see "Before you send"). |
| 1 | `<tag>: no bound coordinator`, `<tag>: no such program in programs.toml`, a line ending `not a live coordinator, do not send` (the program is paused, disabled, or gone from `programs.toml`), or a line saying pigeon can't route to it | Don't send, even though pigeon would still wake a paused program's coordinator. See "No coordinator found". |
| 2 | `program <tag>'s coordinator is gse_… on <machine>, but a swarm_send from this host would be refused: <reason>…`, `no stall-watch on THIS host…`, or `no eng-agent-platform checkout on THIS host…` | The coordinator exists (or may) but this host cannot deliver to it or look it up: the relay is off or refused for that machine, the program belongs to this host and stall-watch does not run here, or the command has no checkout to run (then try `swarm_list remote: true`). See "No coordinator found". |
| 3 | An `error:` or `warning:` on stderr, with or without a `to=` line | The lookup failed, or a cross-check was skipped. A `to=` line may still be right, but it is unverified. **Do not conclude there is no coordinator.** Retry once. If it exits 3 again, tell the human what it printed. |
| 127 | `coordinator: command not found` | The install is broken (workstation installs it on every host). Treat it as exit 3, and include `hostname` and `ls -l ~/.nix-profile/bin/coordinator` in what you tell the human. |

A Python traceback counts as exit 3, whatever the exit code says.

`--all` prints one line per bound program. It exits 0, or 3 when a cross-check
was skipped and it still printed a `to=` line.

What it checks for this host's programs: the registry is stall-watch's
`~/.local/state/stall-watch/state.db`, table `program`, column `pigeon_session`.
The coordinators' own `./sw peers` reads the same column through the same code.
(`./sw` refuses to run outside its coordinator.) `coordinator` then checks that
the program is enabled and in tools mode in `programs.toml`, because a row can
outlive its program, and that the program is not paused (pigeon would still
wake a paused program's coordinator, but a paused program is not one to hand
work to). Last, it
checks that pigeon `GET /sessions` has the id `running` with a `swarm`
mailbox. Every coordinator is registered there under the label
`📋 <tag>`, with a working directory under
`~/.local/state/stall-watch/coord-sessions/<tag>-<ms>/`.

For another machine's program it asks this host's pigeon daemon
(`GET /swarm/remote-sessions`, whose `coordinators` are the sessions bound to
the `stallwatch:<tag>` Telegram topics on other machines), checks the program
is enabled and in tools mode in this checkout's `programs.toml`, and checks
what the relay would do with a send to that machine. It cannot see the other
machine's `state.db`, so a **paused** program's coordinator on another machine
still prints as exit 0. If the program is missing from this checkout's
`programs.toml` (a stale checkout) but pigeon lists its coordinator, it prints
the `to=` line and exits 3.

Without the command (a host with no eng-agent-platform checkout), the same
listing is one call: **`swarm_list` with `remote: true`** prints "Program
coordinators (stall-watch) on machines other than <host>", one
`gse_…  <machine>  coordinator of <tag>` row each, in opencode and in goose.
It does none of the liveness checks above.

**Which tag?** Use the tag of the program that owns the problem, not your own.
If you only know the epic, the mapping from tag to `beads_epic` is in
`~/projects/eng-agent-platform/stallwatch/programs.toml` (a private repo). Each
program there also names the `machine` it runs on.
`session-tags which <ses_>` on any of that program's worker sessions also gives you
the tag.

## Before you send

- **Your message wakes the coordinator.** Since 2026-10-31, pigeon pushes swarm
  mail into a coordinator's goose session as its own turn the moment you send
  it, the same way it pushes into an opencode session. That holds whether the
  program's heartbeat is on or off. If the coordinator is mid-turn, the message
  queues behind that turn. Its answer is also posted in the human's Telegram
  topic for that program, so the human sees the exchange without you reporting
  it. Sending is handing off: no separate message to the human, just one line
  in your end-of-turn report saying which coordinator you messaged.
- **Write it so a stranger can act on it.** The coordinator has not seen your
  conversation. In one message, include the finding, the evidence (file:line,
  bead id, PR, query output), what you think it means for its program, and what
  you need back, if anything. Use kind `result` for a report and
  `clarification.request` if you need an answer. The `swarm-messaging` economy
  rules apply: one substantial message, and no follow-up pings.
- **Expect the reply as a swarm message.** A coordinator with swarm tools
  replies to your `ses_` id, and that reply wakes you if your session is still
  alive. Don't answer a reply that leaves nothing to say: there is no cap on
  coordinator turns, so two sessions acknowledging each other would loop.
- **Report to the program through its coordinator, not its workers.** A worker
  holds one slice of the program. The coordinator holds the whole of it, and
  it is the session the human talks to about that program.

## No coordinator found

Report the absence only after `coordinator` exits 1. Exit 2 and exit 3 are not
an absence.

- **`no such program in programs.toml`** usually means the tag is wrong. Run
  `coordinator --all`, which lists only this host's programs that have a
  coordinator, or check `programs.toml` (see "Which tag?") for the right tag
  before you tell anyone anything. If you are sure of the tag, the program may
  be newer than this host's checkout of `programs.toml`: say that, not that
  there is no coordinator.
- **`not routable in pigeon`** can be temporary while a coordinator is being
  rebound. Retry once after a few minutes.
- **Otherwise,** tell the human that program X has no reachable coordinator.
  Quote the line `coordinator` printed rather than paraphrasing it, and wait
  for them to say where the finding should go.

Exit 2 does **not** mean there is no coordinator. It means this host cannot
deliver to it. Say exactly that, quote the line (it names the coordinator's
machine and the reason), and ask the human to forward the finding.

In either case, don't fall back to messaging a worker or a launcher session. A
dead `ses_` produces `delivery.failed`. A live one is the wrong recipient.
