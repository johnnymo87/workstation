My read: build G-local now, not F1/F3/F4, and treat the small route-rebind patch as a separate hardening fix rather than as the IPC solution.

F1 and F4 miss your hard requirement set outright because they do not give you durable replay, broadcast, or meaningful acknowledgments. F3 would get you the right semantics, but it throws away transport machinery you already operate. Upstream is also not converged enough to wait on: the active designs today are a storage-backed named-messaging team system with synthetic user-message injection and auto-wake (#12711/#12730/#12731), a DB-backed team system (#15205), and a lightweight ephemeral parent→children team tool (#20152). That is useful signal about direction, but not a stable platform to block on. 
GitHub
+4
GitHub
+4
GitHub
+4

1) Is “extend pigeon” the right structural bet?

Yes — with one important refinement: reuse pigeon’s delivery engine, not necessarily its exact Telegram-shaped schema. I would ship G-local first, with a clean internal boundary:

swarm message model: sender, recipients/channel, payload, msg_id, reply_to, priority, timestamps

delivery model: per-target attempts, state, retry/backoff, dedupe

adapter: “deliver to opencode session via prompt_async with canonical target directory”

That keeps “Telegram bridge” from turning into “miscellaneous bus of everything.”

The common failure modes when a one-route system gets a second route bolted on are:

semantic leakage: Telegram assumptions creep into swarm routing, or vice versa

ack confusion: “queued”, “handed off”, and “agent actually saw it” get collapsed into one status

head-of-line blocking: one stuck target or route delays unrelated traffic

retry duplication: a transport retry gets mistaken for a new logical message

feedback loops: session A message causes B to answer, which the router re-injects in a loop

schema calcification: you start with a convenient shared table, then every new transport has to fake Telegram-ish fields forever

So I would extend pigeon as a brokered transport service, but keep swarm as a first-class subsystem, not as “Telegram but with session IDs.” That is the difference between healthy scope expansion and messy scope creep. The good news is that the upstream OpenCode team proposals are already leaning toward persisted team state and synthetic message delivery rather than a pure in-memory peer bus, so your instincts are aligned with where the ecosystem is moving. 
GitHub
+2
GitHub
+2

2) Is the single-writer daemon actually sufficient to fix the race?

For daemon-mediated traffic, probably yes. Globally, no.

Your core reasoning is sound because OpenCode’s lookup and state behavior really is sensitive to the current directory/project context. Issue #14595 documents the same class from another angle: querying a session from the wrong directory lands in the wrong project-scoped storage, because the API middleware derives the instance/project context from the request’s directory parameter/header. 
GitHub

So the daemon design is sufficient for the traffic it owns if all of these are true:

The daemon resolves session → canonical directory from server/session metadata and never trusts caller-supplied directory.

Every prompt injection path targeting that session goes through the same per-session arbiter.

The arbiter is one queue per target session, not one queue per source or per route.

Telegram-originated injections and swarm-originated injections share the same per-session serialization if they can hit the same session.

The case you are most likely missing is this: serializing HTTP requests is not the same as serializing logical deliveries if prompt_async returns 204 before the turn finishes. If the server’s busy guard is functioning and all requests land in the same instance, you are protected against the parallel-loop race you described; your own mitigation experience supports that. But for clean ordering and lower transcript churn, the daemon should still model delivery as a small state machine, not just “POST succeeded.” In practice I’d use these levels:

accepted: persisted in pigeon

handed_off: daemon successfully injected into OpenCode

received: plugin or session-side hook confirms receipt / transcript write

seen: optional, if the agent/tool explicitly acks

completed: optional workflow-level ack

So: yes for the race class you found, provided the daemon is the sole arbiter for all synthetic prompt injections to a target session and canonicalizes directory from the target, not the sender. Not enough if humans or other tooling can still POST directly around it.

3) Should you also ship the upstream-style prefill-fix patch?

Yes. I would not block G-local on it, but I would still ship it.

Reason: the patch is not “the IPC design.” It is a server correctness hardening against a fragile caller-controlled routing surface. OpenCode has other recent bugs in the same family where path or directory mismatches land work in the wrong instance/project context or split state between instances. That is exactly the kind of surface you want to harden even if your new swarm path is well-behaved. 
GitHub
+1

So my sequencing would be:

Ship G-local first for the actual swarm requirements.

Then ship the small route-rebind patch as defense in depth.

Keep opencode-send, but have it default to the daemon path when the target is a session ID.

That gives you a transport that works today and a server that is less easy to miscall tomorrow.

4) Synthetic user message tagging: what shape?

Your proposed shape is close, but I would make it more structured and more compact.

Anthropic’s docs explicitly say prefilling is unsupported on Claude Opus 4.7, Opus 4.6, and Sonnet 4.6, and recommend structured outputs or clear instruction structure instead. Their prompt guidance also favors stable, explicit structure. So I would not lean on clever prose headers; I would use a short, stable machine-readable envelope. 
Claude API Docs
+1

Something like:

XML
<swarm_message
  v="1"
  kind="task.assign"
  from="ses_24e8ff295"
  to="ses_abcd1234"
  channel="workers"
  msg_id="msg_abc"
  reply_to="msg_def"
  priority="normal"
  ack="requested">
Please run the frontend regression suite in the COPS-6107 worktree and report only failures that reproduce twice.
</swarm_message>

Why this shape works better:

compact enough not to bloat transcript

obvious separation between control plane and payload

easy for agents to quote back exactly

easy to migrate later because it is transport-agnostic

I would keep only these fields in-transcript:

v

kind

from

to or channel

msg_id

reply_to

priority

Everything else belongs in pigeon state, not in the model context.

Also: do not put delivery bookkeeping in the transcript if the plugin can do it automatically. Receipt ack should be machine-level, not something the LLM has to remember.

5) Pull-only vs push-with-nudge

For agent IPC, the pattern that works best is usually:

queue as source of truth + push nudge + explicit read tool

Not pull-only, and not full-payload push for everything.

The upstream team proposal already uses direct synthetic message injection plus auto-wake for teammate messaging. That is fine for sparse coordination, but your traffic mix includes status chatter, collaborative back-and-forth, and artifact handoff; blindly injecting every message will become interruption-heavy and transcript-noisy. 
GitHub

So I would split by class:

interrupting / urgent: inject immediately

task assignment

clarification request that blocks progress

human override

normal: queue + nudge

“you have 3 new swarm messages; call swarm.read”

low priority: pull only

status heartbeats

noisy artifact references

bulk logs

That implies one extra piece in G-local MVP: a tiny swarm.read tool or plugin command that returns unread messages since offset. Without that, replay exists at the broker but not as a natural agent behavior.

6) Are you missing options?

Not really, under your constraints.

There are technically viable alternatives, but they do not beat G-local for your situation:

NATS JetStream / Redis Streams: good technology, wrong tradeoff here. You said you do not want new infra unless there is a compelling reason, and I do not see one.

MCP server as broker: useful as an integration surface, but not the durability/ack/replay substrate by itself.

Fresh mailbox tool from scratch: clean in theory, but you already have most of the painful operational bits in pigeon.

Wait for upstream: not credible enough given the current open/stale team proposals and lack of maintainer movement on them. As of today, the main design issue is still open from Feb. 8, 2026; the team-core PR is also still open with users still asking on Apr. 21 why it has not merged; the DB-backed variant was opened Feb. 26; and the lightweight team tool on Mar. 30. 
GitHub
+3
GitHub
+3
GitHub
+3

The one option I think you should add to your mental list is:

local SQLite log + UNIX-socket daemon, with D1 as an optional later transport adapter

That is basically G-local, but phrased more explicitly as “single-machine first, remote transport second.”

7) Long-term path toward upstream agent-teams

I do think there is a migration path.

The biggest reason is that the closest upstream designs are already built around persisted team state and synthetic session messaging, not around a fundamentally different actor runtime. PR #12730 routes messages by injecting synthetic user messages and auto-waking idle sessions, and #15205 is explicitly a DB-backed coordination system for parallel multi-session collaboration. 
GitHub
+1

That means your future-compatible boundary should be:

external API: send, broadcast, read, ack

internal adapter today: prompt injection via pigeon

internal adapter later: native OpenCode team/message APIs or DB hooks

The likely mismatch is topology, not transport:

your swarm wants peer sessions + pub/sub

upstream #15205 / #12711 family is more lead + teammates

#20152 is even narrower: ephemeral parent → children only. 
GitHub
+2
GitHub
+2

So do not model your API as “team lead / teammate” unless that is truly what you want long-term. Model it as a general message bus with channels. That gives you a subset you can later map onto native team features.

8) Smallest viable G you can ship in a day

I would aim for this and no more:

G-local only

same-machine SQLite

no D1 / no Cloudflare path yet

One canonical session registry

session_id -> directory

daemon resolves target directory itself

Two endpoints

POST /swarm/send

GET /swarm/inbox?session=X&since=offset

Optional third endpoint only if easy

POST /swarm/broadcast

static channel membership is enough for day 1

Per-target serialized delivery worker

one logical queue per session

shared across swarm and Telegram if both can target same session

Ack levels

return 202 accepted when persisted

mark handed_off when prompt injection succeeds

stop there for MVP

Minimal envelope

version, kind, from, msg_id, reply_to, channel/to, priority

payload text

nothing more

One read path for replay

a tiny plugin/tool like swarm.read(since?)

even if urgent messages are pushed, backlog must be readable

Repoint opencode-send

keep the CLI

make session-targeted sends go through pigeon by default

Not in day-1 MVP:

cross-machine routing

agent-level “seen” receipts

dynamic subscriptions UI

exactly-once delivery

rich artifact attachment transport

full thread trees

generalized pub/sub ACLs

What I would actually do

Build G-local

Reuse pigeon’s delivery/retry/idempotency machinery, not necessarily the exact outbox table

Unify all prompt injections per target session behind one arbiter

Add swarm.read

Ship the small route-rebind patch after that

That gets you something that works for COPS-6107 now, matches your hard requirements, and does not paint you into a corner if upstream eventually lands native teams.