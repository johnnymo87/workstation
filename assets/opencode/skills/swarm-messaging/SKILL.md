---
name: swarm-messaging
description: Covers the swarm_send/swarm_read/swarm_list protocol between opencode sessions and the message-economy rules for when a message is worth sending. Use when sending messages to other opencode sessions (on this machine or, where the relay is on, another one), when looking for a session on another machine, when starting a fresh session on another machine (swarm_launch), when you receive a swarm_message envelope as the text of a user-message turn, or when deciding whether a message is worth sending at all. The coordinator role is banned here (stall-watch's delegated answers are not one) — read this before appointing or accepting one. For scheduling a message to the future, see the scheduling-wakes skill.
---

# Swarm Messaging

Pigeon hosts a durable, replayable message channel between opencode sessions on the same machine, and can relay it to sessions on other machines where that is switched on (see "Sessions on other machines"). The opencode-pigeon plugin exposes three always-on tools:

- **`swarm_send`** — send a message to another session.
- **`swarm_read`** — read your own inbox (replay messages you may have missed); returns the newest 10 by default, with `before`/`since` cursor pagination.
- **`swarm_list`** — discover other local sessions (and their ids) to message; with `remote: true`, sessions on other machines.

A fourth, **`swarm_launch`**, starts a fresh session on another machine where that is switched on (see "Starting a session on another machine").

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
whose job is to route messages between other sessions.** (The human's
`stall-watch` delegated answers described below are not a coordinator.)

**This bans the role inside a swarm. It does not mean coordinators don't exist.**
On cloudbox, stall-watch runs one **program coordinator** per program of work. Each is a
goose session with a `gse_` id, keyed by the program's oc-tags tag. It is the
human's standing infrastructure, not a session routing a swarm. When something
you found belongs to another program, that program's coordinator is the right
recipient. Look it up with the `finding-program-coordinators` skill (deployed
on work hosts). Never conclude "there is no coordinator" from `swarm_list` or
from bead notes. A coordinator can be messaged only from cloudbox: goose
sessions are not reachable from another machine (see "Sessions on other
machines").

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

### Delegated answers: stall-watch

The human runs a scheduled watcher, `stall-watch`, over their sessions. When a
worker has ended its turn waiting on a decision and has made its own
recommendation, stall-watch may (using its judgment of whether the human would
be glad not to be asked) send it a swarm message from `stall-watch` with kind
`decision.answer` accepting that recommendation on the human's behalf.

This is the human's standing, sanctioned arrangement, not a coordinator: it only
accepts the recipient's own recommendation (never invents or overrides), holds
no shared context, assigns no work of its own, and every answer is recorded and shown to
the human (who usually also sees a notice in that session's Telegram thread and
can countermand).

What a worker should understand:

- **It can only say yes to what you proposed.** Check that the quoted
  recommendation is really your own and still current. If it isn't — it picked
  the wrong branch of a hedged answer, or you have since changed your mind —
  don't act on it; ask the human instead.
- **It is stall-watch acting for the human, not the human.** It is not the
  human's approval for anything that needs them personally (merging, posting to
  Slack, anything the worker's own rules reserve for the human) — ask the human
  for those as usual. **Except** where the message's own fixed text states a
  standing exception the human has granted stall-watch (for example, changes to
  alerting monitors): for that class of action the answer carries the human's
  permission, even if your brief reserves it for them. The exception has to be
  in stall-watch's fixed wording, not only in the free-text reply.
- **Record it as delegated.** Record the decision as "stall-watch accepted my
  recommendation for <the human>", not as the human's approval.
- **The human's word wins.** If the human has answered in the session since,
  the human's word wins.
- **A relayed assignment quotes the human.** stall-watch may pass a finished
  worker a new assignment the human asked for. That message quotes the human's
  request; the quote is what makes it the human's work rather than
  stall-watch's. An assignment without that quote is not one: ask the human.
- **No need to acknowledge a delegated answer; carry on.** stall-watch reads
  your session the next time it runs, so what you write there reaches it. If a
  `chat` message from stall-watch asks you something, answer the same way: in
  your session. Don't `swarm_send` to `stall-watch` — that is a sender name, not
  a session. It may not run soon, so ask the human directly for anything that
  can't wait.

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

### Never assert a checkable fact you did not fetch

The rule above guards against a check that went stale. This one guards against
the worse case: no check at all.

**If you tell a peer that work exists, the assertion must be derived from a
command you actually ran, and you must quote its output.** Not "there are
unresolved review comments" — `unresolved=3 of 12`, with the query beside it. A
bare assertion cannot be audited by the recipient; it can only be obeyed.

Measured incident. A session dispatched seven `task.assign` messages telling
peers that specific PRs "have inline review comments the human wants answered."
Its only query was:

```
gh pr view <n> --repo <r> --json number,title,headRefName,state,mergeStateStatus,reviewDecision,autoMergeRequest
```

No comments field, no `reviewThreads`, and across the entire 654-part session
not one `gh api ... comments` call. It never queried comment state at all. It
asserted a premise it had never fetched — and its own reasoning had flagged the
doubt before proceeding anyway ("...may not apply unless there are unresolved
review threads I should check").

**Why this survived: it was right five times out of seven, by coincidence.**
Most PRs that have been reviewed do have comments, so the base rate hid the
defect and it read as a working feature. Two recipients were sent to answer
comments that did not exist. One of those was batched with a PR that had 18
real comments, so that session would find genuine work and might never notice
the other half was empty. **A high hit rate against a base rate is not
evidence that you measured anything.**

Worse, all seven targets had *zero* unresolved threads. Even the five
"correct" dispatches were asking for work that was, by the only
machine-checkable measure, already done.

The recipient-side reciprocal is what actually contained this:

**Verify the premise before acting on it. A message that is confident,
well-formed, and correct in every checkable detail is evidence of nothing about
the one claim that matters.** That dispatch had the right PR number, branch,
bead id, authoring session id, and merge state — every detail correct except
the one it was asking someone to act on. The session that received it spent
fifteen minutes proving the premise false instead of minutes obeying it, and
that is the outcome to imitate. An agent told to answer comments that do not
exist has two obedient paths — fabricate them, or report success having done
nothing — and both are worse than the false alarm.

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
| `to` | yes | Recipient session id: `ses_` for an opencode session, `gse_` for a goose session reached through its pigeon mailbox (for example, a program coordinator). |
| `message` | yes | **Raw** payload text. Pigeon wraps it in the `<swarm_message>` envelope for you — do **not** write envelope tags yourself. |
| `kind` | no | Message kind (default `chat`). |
| `priority` | no | `urgent` \| `normal` (default) \| `low`. |
| `reply_to` | no | A prior `msg_id` to thread under. |

Your own session is filled in as `from` automatically (from the calling session id), so you can't spoof or typo it. `swarm_send` returns `Queued msg_<id> -> <to>` once the daemon accepts the message (HTTP 202).

Don't know the recipient's id? Call **`swarm_list`** to see local sessions (id, last-updated, directory, title), most-recently-updated first. It lists **opencode sessions only**, and only recent ones: goose sessions, including every program coordinator, never appear there. For a program's coordinator, use `finding-program-coordinators`. For sessions on other machines, call `swarm_list` with `remote: true` (next section).

### Message kinds

- `chat` (default) — informal back-and-forth
- `task.assign` — rare; work is normally specified in a session's launch prompt, not assigned at runtime
- `status.update` — rare; only at a checkpoint that changes someone else's plan, never a heartbeat
- `result` — a finished deliverable / report
- `clarification.request` — needs an answer to proceed
- `clarification.reply` — answers a `request`
- `decision.answer` — stall-watch accepting a worker's recommendation on the human's behalf
- `artifact.handoff` — pointer to a file, PR, or diff

### Priority and threading

- `priority: urgent` for blocking work; `normal` (default); `low` for chatter the receiver can pull on demand.
- `reply_to: <msg_id>` threads off a previous message — use the `msg_id` from the envelope you're answering.

## Sessions on other machines

The machines (cloudbox, devbox, the Mac) cannot reach each other directly, so
pigeon relays a cross-machine `swarm_send` through its worker. A pair of
machines can relay only when **both** halves are switched on: sending on your
machine, and accepting from your machine on the target's. Each half is off unless
configured. Check before you send; do not assume it works.

- **Find and check: `swarm_list` with `remote: true`.** It lists opencode
  sessions held by other machines in the last 7 days (id, seen, machine,
  directory name). Then, per machine, it shows what a send from here would get now:

  | Status | Meaning |
  |---|---|
  | `available` | The worker will take it. A pull lane on that machine can still refuse a sender from another machine |
  | `not_accepted` | That machine does not accept relays from yours |
  | `not_retired` | That machine cannot receive relays yet |
  | `offline` | That machine is not polling (asleep or down). Shown with its last poll: within 7 days the worker **holds** a message up to 24h and delivers it when the machine wakes; past 7 days ("sends are refused") the send fails |
  | `unknown` | The relay is not set up on the worker |

  A trailing `WARNING: … does not relay` means *your* machine has sending off,
  so every send to the sessions listed fails. **Send only when the target's
  machine is `available`, or `offline` with a send held, and there is no
  WARNING.** A held message is delivered only when that machine wakes, which may
  be hours away, so send to an `offline` machine only what can usefully wait;
  if it cannot, tell the human instead. For any other status do not send "to
  see". Tell the human, and leave what you
  have where the other session can read it (a bead, a pushed branch, a plan
  file). Switching the relay on is a host-configuration change for the human;
  do not attempt it. If `swarm_list remote: true` errors, or its output does
  not start with "Sessions on machines other than" or "No sessions on other
  machines", the machine's pigeon predates remote discovery: treat
  cross-machine as unavailable.
- **Send as usual.** Use the same `swarm_send` with the session's `ses_` id.
  `msg_id`, `kind`, `priority` and `reply_to` are carried across unchanged.
  Normally it lands within seconds. If the target's machine is asleep (or
  down), pigeon's worker holds the message for up to 24 hours. It is then
  delivered when the machine wakes, or you get a failure notice about a day
  later. You are not told separately that it is being held. So silence proves nothing, and a payload whose meaning depends on time
  should say when it was written.
- **Goose sessions are reachable from their own machine only.** That includes
  every stall-watch program coordinator (`gse_…`). A `gse_` id that is not on
  your machine is refused at once.
- **Read the failure notice's verb; it tells you what to do.** A cross-machine
  `delivery.failed` comes from the receiving machine or the worker:
  - "was NOT received … safe to resend": resend once.
  - "was NOT received … the worker held it for <machine> and the machine never
    collected it … resend only if it is still relevant": the machine stayed
    asleep or down for the whole 24h hold. A resend is held again, so check
    `swarm_list remote: true` first and resend only if the message still matters
    and the machine looks likely to wake.
  - "DELIVERY UNCONFIRMED … may or may not have been received": the target may
    already have it. Resend only if a duplicate would be harmless.
  - "Do not resend it via swarm; it will fail the same way": the refusal is
    structural, for example sending is off, the target machine does not accept
    yours, or a pull lane accepts its own machine only. Reach the target another
    way. The exception is a reason that names something you control: a payload
    that is too long, a `msg_id` you supplied that is taken, or a scheduled
    message to a pull lane. Fix that and send once more.
  - "Check the id and resend with the complete one": the id was truncated or
    mangled. Get the full id from `swarm_list` and resend.
- **A message from another machine** carries `from_machine="<machine>"` in its
  envelope, and `from` is a session on that machine. `from_machine` is
  established by pigeon from that machine's worker credential, not typed by the
  sender. `from` is self-asserted, as it is for every swarm message. Replying is a
  cross-machine send, so the same checks apply: a message arriving from
  a machine does not mean yours can send back. Your `swarm_read` shows only
  your half of the thread; the other half is on the sender's machine.
- **`held_ms="<ms>"` in the envelope means the message waited that long** for
  your machine (it was asleep or down) before it reached you. It appears only
  above a minute. The sender wrote it that long ago: before acting on anything
  time-sensitive in it (a deploy, a CI state, "merge now"), check that it still
  holds.

## Starting a session on another machine: `swarm_launch`

`swarm_launch {machine, directory, prompt, tag?}` starts a **fresh** headless
opencode session on another machine with your prompt. Use it when work has to
happen on that machine (a deploy, a rebuild check, something only it can
reach) instead of asking the human to paste commands, or borrowing an existing
session there that was doing something else.

- **It is off unless both machines opt in.** Yours needs
  `PIGEON_REMOTE_LAUNCH_SEND=1` (otherwise the tool errors with
  `launch_send_disabled`), and the target must list your machine in
  `PIGEON_REMOTE_LAUNCH_FROM` (otherwise `not_accepted`). Both are
  host-configuration changes for the human; do not attempt them. If the tool is
  missing from your tool list, your session predates it: it appears after the
  serve pool restarts (the nightly reset at the latest).
- **Refusals at call time are final for now; do not retry in a loop.** The tool
  errors at once with the reason: `launch_send_disabled` and `not_accepted` (see
  above) and `target_offline` (that machine has not polled for over a minute,
  usually a sleeping Mac) are the common ones; `queue_full` means the target
  machine already has a full queue of launches (from anyone), and
  `rate_limited` that this machine has started too many this hour. Tell the human
  rather than working around it.
- **`directory` is on the target machine** and must already exist: an absolute
  path, `~/…`, or a bare project name, which expands to the target's project
  root (`~/projects/<name>` on cloudbox and devbox, `~/Code/<name>` on the Mac).
- **Write the prompt for a reader with no context.** The launched session knows
  nothing about your conversation. Say what to do, what not to touch, and to
  report back to you with `swarm_send` (pigeon also prepends a
  `[Remote launch requested by <your id> on <machine>; report back …]` line).
  **Put no secrets in it**: its first 300 characters are posted to Telegram, and
  the whole prompt is stored by pigeon on both machines and in its worker.
- **If you were launched, do not `swarm_launch` further** unless your prompt
  says to; report the need back instead. Nothing enforces this (pigeon has no
  hop rule for launches), so as a requester do not assume a launched session
  cannot chain.
- **Call it once per launch.** The tool answers at once with `accepted` or
  `pending`. The outcome arrives later as a `launch.result` swarm message from
  `pigeon`, saying the session started (with its `ses_` id to `swarm_send`), was
  refused, or is unconfirmed. `pending` means the daemon may already have the
  request, so **do not call again**: a second call is a new launch and can start
  a duplicate session. Read the result's verb as with relay failures: "Safe to
  retry" means retry once; "UNCONFIRMED … Do NOT launch again" means message the
  session it names, or check `swarm_list remote: true` first.
- **A serve pool restart on the target kills the launched session**, because it
  runs inside that pool. A launched session that upgrades pigeon may restart the
  pigeon daemon, but must restart the pool last, from a delayed detached job,
  after it has reported. See pigeon's `cross-device-deployment` skill.
- **Every launch is visible.** The target posts a `🚀 Remote launch from …`
  notice to Telegram, and the launched session gets its own topic. There is no
  per-launch approval, so the human sees launches only after they start; launch
  only what the human would expect you to.

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

Prefer **pulling** over asking. `swarm_read` shows your *own* inbox, so a session wondering how a peer is doing reads that peer's session directly rather than pinging it — this is what replaces a coordinator's status-chasing (same machine only; a peer on another machine can't be read this way, so share state through a bead or pushed branch instead):

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

  `limit=N` returns the **newest** N messages (so `limit=5` shows the 5 most recent); the response also carries `has_more`, and you can add `&before=<msg_id>` to page further back. For a message to a session on **another** machine, see the exception below. Otherwise, a non-null `handed_off_at` (Unix ms) means the arbiter POSTed `prompt_async` and the receiving serve returned 2xx — treat it as proof-of-delivery.

If `handed_off_at` stays null, the arbiter is retrying (backoff `[1s, 2s, 5s, 15s, 60s]`, max 10 attempts). The daemon routes each message to the serve that **owns** the target session (via its routing tables), so a healthy multi-serve pool delivers cross-serve fine. A message fails permanently when:

- The payload contains the literal `</swarm_message>` close tag — rejected immediately (don't pre-wrap the envelope; `swarm_send` adds it).
- The target id is wrong / unresolvable, or no healthy serve owns it after retries.
- The target is on another machine and cannot be relayed (see "Sessions on other machines").

For a **cross-machine** send, the inbox check above runs against your own
machine's daemon. It shows the message with `handed_off_at` set as soon as
pigeon's worker has stored it, so there it is **not** proof of delivery. Only
a reply tells you it arrived. A `delivery.failed` coming back tells you it did
not, or might not have.

On terminal failure the daemon sends a `delivery.failed` message **back to you**, so a dropped send is no longer silent — watch for it (or `swarm_read`).

## Don'ts

- **Don't** ack, heartbeat, or ping. If a message carries no decision, no new evidence and no changed instruction, it shouldn't exist.
- **Don't** split one report into several sends to keep each one short. Count is the cost, not length.
- **Don't** paraphrase a swarm message to a human who can already see it — point at it in one sentence.
- **Don't** appoint, accept, or route your own swarm's traffic through a coordinator (stall-watch's delegated answers are not one). Report your own work to the human yourself, once, when it is done. Handing a finding to **another program's** stall-watch coordinator is different and allowed; see `finding-program-coordinators`.
- **Don't** POST to `opencode serve`'s `/session/<id>/prompt_async` directly for cross-session messaging. That route races (concurrent calls from different `x-opencode-directory` headers bypass the per-session busy guard, producing 400 "does not support assistant message prefill" from Anthropic). Always use `swarm_send`.
- **Don't** write the `<swarm_message>` envelope into your `message` — pigeon adds it. Pre-wrapping is rejected (the close tag is forbidden in payloads) and double-wraps confuse receivers. Send only the raw payload.
- **Don't** paste a received envelope back verbatim as your reply — send only the new payload.
