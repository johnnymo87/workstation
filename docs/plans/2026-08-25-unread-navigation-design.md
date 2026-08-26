# Unread navigation: land where the new work starts, clear on evidence of presence

**Status:** design, approved. **Revision 2** — the anchor rule and the clearing
policy both changed; revision 1's reasoning is corrected in place rather than
deleted, in two marked passages. **Supersedes:** the auto-clear-on-jump wiring
shipped in workstation PR #411 (S7 Task 4). **Spans three repos:**
`workstation`, `pigeon`, `opencode-patched`.

**What changed in revision 2, and why it matters:** revision 1 concluded "never
auto-clear", on the strength of an asymmetry that turned out to be overstated —
it treated a cleared badge as *unrecoverable* when in fact no content is lost,
only the boundary marking where you had stopped. The narrower and more useful
rule is that **asking a follow-up question is itself evidence you read what came
before it.** That single observation both fixes the anchor (which revision 1 had
corrected in the wrong direction) and restores an automatic clearing path that
revision 1 had deferred.

Two user-stated requirements:

1. Jumping into a session with unread activity should land at the **start of
   what is new**, not at the bottom. "A lot of scroll may have happened and I
   don't know how far back to go to find where it starts."
2. The unread count should only drop **to the extent the user actually
   consumed** it. Motivating fear, quoted: "I want to peek at something and then
   decide I'm not ready to commit to reading it."

Requirement 2 as literally stated — partial credit for a partially-visible
message — is **not** what this design builds, and the reason is in
"Rejected" below. What it builds instead satisfies the stated *intent* at
notification granularity, which the existing schema already supports.

---

## Ground truth

Everything here was verified against the versions actually running, not
inferred. The version check mattered: the `opencode` checkouts on this host sit
at tag `v1.17.13` while the installed binary is `1.18.18`, so every source
citation below was read with `git show v1.18.18:<path>` rather than from a
working tree.

### An "unread" is a Telegram notification, not a message

`session_events(id, session_id, notification_id, kind, sent_at)` —
`pigeon/packages/daemon/src/storage/session-events-schema.ts:38-69`. One row is
**one successfully delivered Telegram notification**; the sole append site is
`commitDelivery` in `worker/outbox-sender.ts:157-180`, inside the delivery
transaction, so a row exists iff delivery succeeded.

Consequences that shape the whole design:

- **No text column.** The payload lives in `outbox.payload` and is deleted
  ~1h after send (`session-events-schema.ts:30-35`). Anything we want to show
  later must be captured at write time or it is gone.
- **`last_event_id` has no relationship to any opencode message id, index or
  transcript position.** Nothing in the row references a message.
- `kind` ∈ `mirror | stop | question | swarm`, and `mirror` is excluded from
  counts (`UNCOUNTED_KINDS`, `session-events-repo.ts:14`).
- `sent_at` is **delivery** time. Outbox retries skew it late, so it cannot be
  used to locate the corresponding message.

**UI copy must never imply a message count.** "3 new" means three
notifications; a single `stop` can summarise an entire turn.

### Read state already has prefix semantics

`session_reads(session_id, last_read_id, updated_at)` with a monotonic
`MAX(existing, incoming)` upsert (`session-events-repo.ts:98-108`). Setting
`last_read_id = k` means "notifications 1..k are read, k+1..n are not".

**This is the load-bearing discovery of the design review.** Partial credit
does not need per-message state or viewport telemetry — it needs a UI that lets
the user choose *k*. The capability has been present all along and unused
because the picker only ever wrote the maximum.

### Where a jump lands

`oc-auto-attach` finds or creates a tmux pane running nvim, then RPCs into it
to open a `:terminal` buffer in a new tab running
`opencode attach <url> --session <sid> --dir <dir>`
(`workstation/assets/nvim/lua/user/oc_auto_attach.lua:59-74`). The thing to be
positioned is therefore opencode's full TUI (TypeScript/solid + opentui at
1.18.18).

### The TUI cannot be told where to scroll — through the documented path

- `POST /tui/execute-command` dispatches through a **13-entry alias map**
  (`handlers/tui.ts:12-26 @ v1.18.18`). `messages_first`, `messages_last`,
  `messages_page_up/down`, `messages_line_up/down`,
  `messages_half_page_up/down` work; `messages_previous` / `messages_next` are
  keybind identifiers only and are unreachable over HTTP.
- **`dispatchCommand(name)` is arity-1.** No command can carry a message id.
- **Unknown commands return HTTP 200 `true` silently.** The event is
  non-durable so it skips schema validation and `undefined` is dropped from
  JSON. *You cannot probe validity by response code* — which is why this design
  was settled by reading source rather than by probing a live daemon.
- **It broadcasts.** No sessionID in the payload; filtering is
  directory+workspace only, and in the patched build the workspace guard
  degrades to `undefined === undefined`. With ~15 agent TUIs on this host, and
  `session_interrupt` / `session_compact` riding the same bus, firing TUI
  commands over HTTP is actively unsafe.
- `--replay-limit` / `--no-replay` are **mini-only**; the full TUI errors out
  on them (`cli/cmd/attach.ts @ v1.18.18`).

### But the TUI can anchor to a message internally

`routes/session/index.tsx @ v1.18.18` repeats one idiom four times (lines
419-420, 529-532, 552-555, 854-857):

```ts
const child = scroll.getChildren().find((c) => c.id === messageID)
if (child) scroll.scrollBy(child.y - scroll.y - 1)
```

Used by "Jump to message" (`session.timeline`, `<leader>g`, `/timeline`), by
fork, by `messages_last_user`, and by `message.next/previous`. `DialogTimeline`
lists user messages with a timestamp footer.

**Only `UserMessage` renders `id={props.message.id}`** (index.tsx:1399 — the
only `id=` on a message in the whole session directory). `AssistantMessage`
returns a bare fragment emitting per-part siblings with no wrapper element, so
there is nothing to hang an id on; adding one is a flex-layout change with
visual-regression risk across every assistant message. Opencode's own
`session.timeline` and `messages_last_user` accept the same limitation.

**There is no unread concept anywhere in the TUI** — no divider, no
"new messages below" marker, no seen state, no scroll-position persistence. The
`unseenCount` that exists lives in `packages/app` (web/desktop), not the TUI.

### Message identity

Ids are `msg_` + 26 chars, **ascending and sortable, with a ms creation
timestamp embedded and extractable** (`core/src/id/id.ts`,
`schema/src/identifier.ts @ v1.18.18`). `GET /session/:id/message` exposes ids
and `time.created`. We do not use timestamp matching (see `sent_at` above), but
this is why the anchor can be validated if ever needed.

---

## The trap that would have made this fail silently

The obvious implementation of the anchor is "send the message id the plugin
already has at the notification site". **That is wrong and it fails quietly.**

At the `stop` enqueue site the plugin holds
`messageTail.getCurrentMessageId(sessionID)`
(`pigeon/packages/opencode-plugin/src/index.ts:479`), already computed and used
for dedup. But `currentMessageId` is assigned **only** under
`if (info.role === "assistant")` (`message-tail.ts:170-187`) — it is an
*assistant* message id. The TUI can only anchor to *user* messages. Stored
naively, every anchor would reference a node that does not exist in the render
tree, `find()` would return undefined, and the scroll would do nothing: no
error, no log, a jump that lands at the bottom exactly like today.

That is the silent-no-op failure class this feature exists to remove, and no
test short of driving a real TUI would catch it.

**The anchor is therefore a USER message id** — and *which* user message is the
subtlety that design review caught, because the obvious choice is also wrong.

### The anchor is the most recent HUMAN-AUTHORED user turn

The first revision of this document said "span-start user turn", to avoid a
failure it had correctly identified: **swarm peer messages and scheduled wakes
arrive as user-role turns.** So

```
U1 (human asks)  →  agent works ...  →  U2 (swarm peer / scheduled wake
                                             lands mid-run, user-role)
                 →  agent keeps working ...  →  session.idle → one `stop`
```

produces **one** notification covering `U1 → end`, and anchoring at `U2` would
land the reader *past* `U1..U2` agent work they never saw — content above the
landing point, no marker, no error.

**But "span-start" is the wrong correction, and it is wrong in the opposite
direction.** If `U2` was authored by *the human*, they were present: they saw
the output of `U1`'s turn and replied to it. Anchoring at `U1` then drags them
back through material they have already read, and the notification predating
`U2` was arguably never unread at all.

The discriminator is not position in the span. It is **authorship**:

| U2's author | what it proves | correct anchor |
|---|---|---|
| the human | they were present and read up to here | `U2` |
| swarm peer / scheduled wake | nothing | the last human turn at or before the span |

**So the anchor is the most recent HUMAN-AUTHORED user turn at or before the
unread span.** Injected turns are skipped for anchoring purposes entirely.

`currentMessageId` remains wrong for the separate reason given above — it points
at whichever assistant message happened to be in flight — whereas a human user
turn is a stable boundary matching how `session.timeline` and
`messages_last_user` already behave.

### Telling a human turn from an injected one

Swarm and wake payloads are delivered through
`POST /session/:id/prompt_async` (`daemon/src/opencode-client.ts:330`), which
produces a user message structurally **identical** to a human typing — there is
no `origin` or `source` field on the message schema to key off.

What distinguishes them is the text: pigeon wraps every swarm payload in
`<swarm_message …>` … `</swarm_message>` (`daemon/src/swarm/envelope.ts:122`),
and `payloadHasCloseTag` (`envelope.ts:75`) **rejects any payload containing a
close tag** at both the enqueue validator and the renderer. The envelope
boundary therefore cannot be forged by payload content, which is what makes
text-based detection trustworthy rather than merely convenient.

**Residual risk, accepted and stated.** The test *excludes* enveloped turns; it
does not *positively* identify a human. An unenveloped injection — an
`opencode run` invocation, or future automation that prompts a session directly
— would read as human presence and clear notifications predating it. This is
bounded (only notifications older than the injection are affected) and it costs
a bookmark rather than content, but it is a genuine false-clear path and it does
not self-heal. Telegram replies land on the correct side of this line: they are
plain text and they genuinely are the human.

### "Oldest uncleared" must skip uncounted kinds

`mirror` rows exist in the ledger and are excluded only from the *count*
(`session-events-repo.ts:14,62-63`). If the scroll target or the drill-down list
is chosen without applying the same filter, a `mirror` row can select the anchor
and the drill-down will disagree with the badge the user is looking at.

---

## Design

### 1. Clearing follows presence, not navigation

Remove the auto-fire of the watermark write from the accept path in
`session_switcher/init.lua`. `exec.clear_unread` survives unchanged as the
mechanism — its guards, auth handling and payload validation are exactly what
the replacements need — but **jumping** no longer triggers it.

**A correction to this document's own earlier reasoning.** Revision 1 justified
"never auto-clear" with an asymmetry: a badge that fails to clear self-heals,
whereas cleared-but-unread is *unrecoverable*. The second half was overstated,
and it was carrying more argumentative weight than the facts support. Clearing
destroys no content — every message remains in the transcript. What it destroys
is the **boundary**: the record of where you had stopped. Losing a bookmark is a
real cost and worth designing against, but it is not data loss, and treating it
as such pushed this design to a blunter rule than the evidence justified.

The honest rule is narrower: **do not clear on a signal that does not imply the
human was present.** Sorted by what each signal actually proves:

| signal | implies the human read it | behaviour |
|---|---|---|
| jumping to the session | **no** — the stated purpose is often to peek | scroll; clear nothing |
| **the human authors a turn** | **yes, up to that point** | advance the watermark past notifications predating it |
| a swarm peer or wake arrives | no | ignore entirely |
| the human reads but never types | yes, but unobservably | explicit gesture |

Asking a follow-up question *is* evidence of having read what came before it —
close to proof, not a heuristic. That is why it clears and why jumping does not.

Authorship is determined by the envelope test described above, with the residual
risk recorded there.

### 1b. The explicit gesture, for the unobservable case

Reading a session and then closing it without typing leaves no trace, so the
drill-down and its "mark read through here" remain necessary — but as the
**cover for a case the automatic path cannot see**, not as the only way to clear
anything.

### 2. A drill-down that makes prefix-clearing selectable

Prefix-clearing needs something to point at, and today's picker shows one row
per session with a count. Add a second level: session row → its unread
notifications → **"mark read through here"**, which sets `last_read_id` to that
notification's id. Everything below stays unread.

This is requirement 2, quantized to notifications instead of pixels.

### 3. Two new columns on `session_events`

Both written at enqueue/send time, in the same place, because neither is
recoverable afterwards:

| column | purpose |
|---|---|
| `anchor_msg_id` | most recent **human-authored** user message id (see above); the scroll target |
| `excerpt` | first ~150 chars of **pre-format plain text**, so the drill-down is readable |

A drill-down of bare timestamps is nearly useless, which is what makes `excerpt`
part of this feature rather than a follow-up. `sent_at` alone already gives
"3 new since 14:02" with zero schema change, but that is orientation, not
selection.

**`excerpt` must be captured before Telegram formatting, not sliced off
`outbox.payload`.** By the time a payload reaches `commitDelivery` it is
HTML-formatted with entities, escapes, session-prefix and chunk headers
(`worker/*.ts`, `split-message.ts`); its first 150 characters are markup soup.
The source is the plain summary the plugin already sends
(`opencode-plugin/src/index.ts:490`), or the daemon's equivalent pre-format
value.

**Retention delta, accepted:** `SESSION_EVENTS_RETENTION_MS = 2 × SESSION_TTL_MS`
(14 days), so excerpts persist far longer than the ~1h `outbox.payload` they
derive from. This is agent-output text in the same trust domain as the full
transcripts already sitting in local `opencode.db`, so the delta is real but
small. Worth stating rather than discovering.

### 4. Plugin tracks the last user message id

Add `lastUserMessageId` per session to `message-tail`, and thread it through
`notifyStop` → `/stop` body → `outbox` → `session_events.anchor_msg_id`.
`question` and `swarm` notifications need their anchor source decided
separately; they are not simply the same value.

### 5. One opencode patch

A new `tui.message.scroll` event carrying `{sessionID, messageID}`, handled
**inside the session route** rather than in `app.tsx`:

```
routes/session/index.tsx @ v1.18.18
345   let scroll: ScrollBoxRenderable
359   event.on("session.status", (evt) => {
360     if (evt.properties.sessionID !== route.sessionID) return
```

Both the scrollbox and the route's own session id are already in scope there,
and the component only exists while a session is mounted. **The handler is
self-scoping by construction**, so the broadcast hazard is designed out rather
than patched around, and `dispatchCommand`'s arity-1 limit is bypassed entirely
instead of being fought.

Not touching `app.tsx` is deliberate — `vim.patch` already owns that file.

**It must be a NEW endpoint, not an addition to the existing `publish`
whitelist.** `handlers/tui.ts publish()` forwards only whitelisted `TuiEvent`
types and **returns `true` regardless** — so a serve running unpatched opencode
would answer `200 true` to a scroll request and do nothing, leaving the picker
unable to distinguish "scrolled" from "this serve has no idea what you are
asking". That is the same silent no-op this document condemns two sections
earlier. A new route yields `404` on an unpatched serve, which is detectable.
This matters concretely because the serve pool restarts nightly and per-serve
patch level can lag, so the mixed state genuinely occurs.

**Scope, measured:** 6 files, ~127 changed lines, ~250-320 diff-lines as a
`.patch` — comparable to the existing `session-mcp-routes.patch` (404).
**Zero conflicts** with the current 26-patch stack except the two generated SDK
files, which means ordering it last in `PATCHES=()`.

**Maintenance, measured across the whole `v1.17.13 → v1.18.18` bump:** five of
the six target files took **zero** upstream commits; all server-side and schema
files are frozen. The one active file, `routes/session/index.tsx`, took 7
commits (+93/-14), but four were an experimental "codemode" add-and-revert that
nets to nothing, one was a dependency bump, and **none touched the insertion
region**. Expect one context re-port every two or three version bumps. There is
no sunset path — this is a local feature, permanent maintenance, same class as
`serve-lease.patch`.

### 6. The picker scrolls on jump

After attach, look up the anchor of the **oldest uncleared** notification and
fire `tui.message.scroll`.

**Every failure path degrades to today's behaviour of landing at the bottom.**
Null anchor, absent daemon, compacted-away message, unpatched opencode, TUI not
yet rendered — all of these mean "do not scroll", never "fail the jump". A
missing anchor must not become a broken jump.

---

---

## Landing order, and the window it protects

This spans three repos. Revision 1 identified a hard ordering constraint —
removing auto-clear before the drill-down exists would leave badges unclearable,
and the drill-down is blocked on a **per-notification list endpoint that does
not exist today** (the daemon exposes only the aggregate `unreadBySession`).
PR #411 already shipped auto-clear to a running machine, so the regression risk
was live rather than hypothetical.

**Clear-on-human-turn substantially relaxes that constraint**, because it lives
in pigeon and the plugin rather than in the picker. Once it ships, badges keep
clearing through the common path with no picker UI involved at all, so the
drill-down stops being the only escape hatch and becomes the convenience it
should have been.

Required order:

1. **pigeon** — two columns, human-turn detection (envelope test), the
   watermark advance on a human-authored turn, and anchor capture in the plugin.
   **After this step alone, badges already clear correctly for the common case.**
2. **opencode-patched** — the scroll route, so a patched serve exists to talk
   to.
3. **workstation** — remove auto-clear-on-jump, add the scroll call.
4. **Later, and now genuinely optional:** the per-notification list endpoint and
   the drill-down, covering only the read-but-never-typed case.

**Cheap insurance, still worth shipping in step 3:** a session-level "mark all
read" gesture. It needs only the `lastEventId` the picker already holds, so
nothing upstream can block it, and it covers the read-silently case until step 4
exists.

**Plugin changes reach long-running serves only at restart** (the nightly
reset), so for roughly a day after step 1, existing sessions keep producing
rows with a `NULL` anchor. The null-degrade path covers this, but it should be
expected rather than diagnosed.

## Accepted limitation: the watermark cannot move backwards

`advanceRead` is a `MAX()` upsert, so "mark read through here" — and especially
"mark all read" — is **irreversible in one keystroke**. Choosing the wrong
drill-down row produces exactly the outcome that motivated removing auto-clear
in the first place.

Undo is out of scope: it would mean abandoning the monotonic property that makes
stale and retried writes safe. The explicit gesture already clears the
zero-false-positive bar that automatic clearing failed. A confirmation step on
"mark all read" specifically is worth considering, since that is the one gesture
whose blast radius is the entire session.

## Deliberately not built

- **Viewport telemetry / true partial-message credit.** Needs a message-granular
  ledger, per-message partial read state, and scroll reporting out of a TUI that
  tracks none of it — two repos plus a permanently maintained patch streaming
  viewport state, to serve a distinction the data cannot express. The prefix
  approach delivers the stated intent at a fraction of the cost.
- **Assistant-message anchoring.** Requires a wrapper box around assistant
  parts; flex-layout regression risk on every assistant message. Upstream's own
  navigation accepts the same limitation.
- **Timestamp-matching a notification to a message.** `sent_at` is delivery
  time and retry-skewed.
- **HTTP TUI control via `/tui/execute-command`.** Broadcasts across every
  attached TUI, and `session_interrupt` shares the bus.
- **tmux `send-keys` into the attach pane.** Per-pane and therefore targeted,
  but keys arriving before the TUI is ready, or while in prompt mode, become
  **text submitted to the agent**. The worst failure is acting, not
  mis-scrolling.
- **Time-based auto-clear** ("attached for N seconds"). Attach duration is
  uncorrelated with reading; fails the zero-false-clear bar.
- ~~**Clear-on-reply.**~~ **Promoted into the design in revision 2** — it is now
  the primary clearing path, not a deferred accelerator. Revision 1 deferred it
  on the grounds that swarm peers arrive as user-role turns and would false-clear
  notifications a human never saw. That objection was correct but soluble: the
  `<swarm_message>` envelope is unforgeable (`payloadHasCloseTag`), so injected
  turns can be excluded. See "Clearing follows presence, not navigation".

---

## Open questions for the implementation plan

1. **When can a user turn be classified as human vs injected?** The envelope
   test needs the message *text*, which arrives as parts and is debounced
   (`userBuffers`, `message-tail.ts:312`). Confirm the full first text part is
   available before the turn must be classified, and decide the behaviour for a
   turn classified after the watermark decision would otherwise have been made.
   Default must be "treat as injected" — the direction that fails toward keeping
   something unread rather than clearing it.
2. **Attach/scroll race.** The TUI must have rendered the message before the
   event lands, or `find()` hits nothing. Needs a settle strategy, and it must
   fail toward "no scroll" rather than "retry forever".
3. **Compaction.** What happens when `anchor_msg_id` refers to a message that
   no longer exists in the transcript.
4. **Anchors for `question` and `swarm` kinds**, which do not share `stop`'s
   call site.
5. **Backfill.** Existing `session_events` rows have no anchor or excerpt; the
   drill-down and scroll must both behave sanely for them.
6. **Migration mechanics** for two added columns. Note the daemon is the *single
   writer* of its SQLite database — the plugin and picker reach it over HTTP —
   so a guarded `ALTER TABLE ADD COLUMN` at startup is sufficient. The
   ~15-concurrent-writers concern applies to `opencode.db`, not to pigeon's.
7. **Two TUIs mounted on the same session** both receive the scroll event and
   both move. Believed benign (both land at the same unread boundary), but it
   should be a stated expectation rather than a surprise.
