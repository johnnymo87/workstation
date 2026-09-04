# Scroll to unread: land where the new work starts

Phase 2 of `workstation-v8jh`, plus the caller that makes it observable.
Design: `docs/plans/2026-08-25-unread-navigation-design.md` (Rev 2), sections 5
and 6. Anchor capture (phase 1b) shipped in pigeon#133 and stores the target;
nothing reads it yet.

**Research overturned two of the design's decisions and deleted a third piece of
work entirely.** All three are load-bearing, so they come first.

---

## What research changed

### 1. The design's endpoint cannot be reached. `/tui/*` is 501 at the front door.

Section 5 specifies a new `tui.message.scroll` route, reasoning — correctly —
that it must be a *new* route rather than an addition to the `/tui/publish`
whitelist, because `publish()` returns `true` unconditionally and an unpatched
serve would answer `200 true` while doing nothing.

That reasoning is right. The path is wrong. The front door classifies **all 14
`/tui/*` routes as class `tui` → 501 by design**
(`pkgs/opencode-frontdoor/src/routes.dispositions.ts:193-197`: *"TUI control
routes require process-local UI state; frontdoor returns 501 by design"*).
Verified against the running door:

```
POST /tui/select-session     -> 501 {"error":"not_implemented"}
POST /tui/scroll-to-message  -> 404 {"error":"not_found"}
```

The door is a **closed allowlist**, not a proxy with a default route: an
unrecognised path is 404, never forwarded
(`src/proxy.ts:613-628`). And the door **never reads the request body**
(`src/sid.ts` extracts the session id from path or query only), so even a
permitted `/tui/*` path could not be owner-routed — it would land on the anchor
serve, which is the wrong process three times in four.

**The route becomes session-scoped:**

```
POST /session/{sessionID}/scroll-to-message   body: {"messageID": "msg_..."}
```

Class `session-path` → action `route-session` → the door resolves the owner via
pigeon and forwards. The sessionID is a **routing key**, exactly as in our own
`session-mcp-routes.patch`, whose comment states the pattern verbatim: *"These
live under `/session/:sessionID/mcp…` so the front door can owner-route them for
free… the sessionID exists solely as a routing key."*

The design's 404-detection property survives intact: an unpatched serve returns
404 for an unknown session-scoped path, so "this serve has no idea what you are
asking" is still distinguishable from success. That was the point, and it is
preserved.

### 2. The scroll mechanic already exists. We were about to reimplement it.

The design prescribes copying the TUI's existing idiom:

```ts
const child = scroll.getChildren().find((c) => c.id === messageID)
if (child) scroll.scrollBy(child.y - scroll.y - 1)
```

`@opentui/core@0.4.5` — the version the v1.18.18 catalog pins exactly — already
ships **`ScrollBoxRenderable.scrollChildIntoView(childId: string)`**, confirmed
in the published type definitions (`renderables/ScrollBox.d.ts:84`). It does
`content.findDescendantById(childId)`, computes a nearest-edge delta, and
scrolls. opencode's TUI uses it **zero** times; all four hand-rolled sites
predate or ignore it.

This is the third time this week that checking whether a capability already
exists has changed a design — clearing already existed (pigeon#125), and
`clampPreservingSurrogates` already existed in 1b. The TUI half of the patch
collapses from ~40 lines to ~8.

**It also resolves the risk that would have sunk the mechanic.** All four
existing call sites jump to *nearby* messages; ours jumps to one potentially
hundreds of rows up, and a clamped or stale `child.y` would have produced a
wrong landing that no test would catch.

The conclusion is that `child.y` **is** valid offscreen, so the mechanic works at
distance. The reason is narrower than it first appears, and the narrowness is the
part worth carrying: `updateLayout` calls `child.updateFromLayout()` on every
**direct** child before any culling happens, and culled children do **not**
recurse. Message boxes are direct children of the scrollbox content — the
existing `scroll.getChildren().find(c => c.id === targetID)` idiom
(`index.tsx:419`) only works at all because ids live at direct-child depth — so
they are laid out regardless of visibility. But `findDescendantById` *recurses*,
so if upstream ever wraps messages one box deeper, positions inside a culled
subtree go stale and the jump silently mis-lands. The patch carries a comment
naming that assumption.

(My first draft justified this with "`_getVisibleChildren` consumes child
positions to decide culling". That reasoning is circular and does not establish
the guarantee even though the conclusion happens to be right.)

`getNearestDelta` aligns the element's **top** to the viewport top when the
element starts above the viewport and is *smaller* than it — precisely "land
where the new work starts". When the anchor is **taller** than the viewport it
aligns the element's **bottom** instead, so a huge pasted turn lands at its end;
arguably better, since the unread work begins just below it, but it is an edge a
tester could file as a bug. On a miss it returns early (`if (!child) return`),
silently, without throwing. That is our degrade path, and it is the library's own
behaviour rather than something we build.

### 3. No new pigeon endpoint. The picker doesn't use HTTP for unread at all.

Section 6 says "look up the anchor… and fire". That implied a daemon endpoint.
It isn't needed: the picker shells out to `oc-session-list`, which opens
pigeon's SQLite **read-only** and computes unread itself
(`assets/opencode/plugins/oc-session-list-state.ts:163-240`). The anchor rides
the query the picker already runs, as one more column on the row it already has.

An entire repo's worth of work leaves the plan.

---

## Design

Four components, three repos, landing as one user-visible increment because
none of them is observable alone.

### A. `oc-session-list` learns the anchor (workstation)

`buildUnreadMap`'s existing aggregate gains the anchor of the **oldest uncleared
non-mirror** event:

```sql
(SELECT e2.anchor_msg_id
   FROM session_events e2
  WHERE e2.session_id = e.session_id
    AND e2.id > COALESCE(r.last_read_id, 0)
    AND e2.kind <> 'mirror'
    AND e2.anchor_msg_id IS NOT NULL
  ORDER BY e2.id ASC
  LIMIT 1) AS anchor_msg_id
```

The `IS NOT NULL` predicate is load-bearing and was missing from the first draft
of this plan. Without it the subquery takes the oldest uncleared row's anchor
**even when that anchor is NULL** — and NULL anchors genuinely coexist with real
ones: every pre-1b row (alive until retention expires them), and any
notification delivered before a session's first human TUI turn. In that mixed
case the oldest row shadows the newer anchored ones and the user gets no scroll
despite having unread work *and* a perfectly usable target. Landing at the
earliest **anchored** unread instead is slightly-too-late rather than
nothing-at-all, and its failure direction is re-reading — the direction this
feature has treated as safe throughout.

Oldest, not newest: the badge counts everything since the watermark, so the
jump must land at the **start** of that run, not its end. `MAX(e.id)` — what
`last_event_id` already uses — would land at the newest, showing the user the
thing they can already see.

**Obligation 1 from phase 1b, discharged.** The `kind <> 'mirror'` filter is
mandatory and is *the same filter the count uses*. `/mirror` calls `markAllRead`
(which is `MAX(id)` over rows that already exist) **before** enqueueing its own
row, which is appended later at delivery — so mirror rows routinely sit above
the watermark. Without the filter the picker scrolls to a mirror row and
disagrees with the badge the user is looking at.

Verified today: pigeon's authoritative `UNCOUNTED_KINDS`
(`session-events-repo.ts:14`) is exactly `["mirror"]`, and the CLI hardcodes
`e.kind <> 'mirror'` at `:190`. They agree **now**. They are two copies of one
constant, in two languages, in two repos, with nothing tying them together —
adding a kind to `UNCOUNTED_KINDS` would silently desync the picker. The
duplication gets a comment on both sides naming the other.

**The column must be probed, not assumed.** The CLI is a *different binary* from
the daemon that migrates the schema. If the CLI ships before the migration runs,
`SELECT anchor_msg_id` throws, `buildUnreadMap` returns `null`, and every
session's `unread_state` becomes `"unavailable"` — **the badges disappear
entirely**. A missing anchor must degrade to "no scroll", never to "no badges".
So: `PRAGMA table_info(session_events)` first, select the column only when
present, and emit `anchor_msg_id: null` otherwise. This extends the existing
missing-table→null path rather than inventing a new one.

New row field: `anchor_msg_id: string | null`. Absent for every pre-1b row,
which is the backfill answer (design open question 5) — null means don't scroll.

### B. The opencode patch (opencode-patched, patch #31)

Upstream pin is already **1.18.18** (`patches/apply.sh:5`), the stack is **27**
patches, and header number **31** is the next free one (30 is
`db-isolation-guard`; numbering is stable identity, not position).

| File | Change |
|---|---|
| `packages/schema/src/tui-event.ts` | `MessageScroll = Event.define({ type: "tui.message.scroll", schema: { sessionID, messageID } })`, appended to `Definitions` |
| `.../httpapi/groups/session.ts` | `scrollToMessage` path + endpoint under `/session/{sessionID}/` |
| `.../httpapi/handlers/session.ts` | handler: validate, publish, return true |
| `packages/tui/src/routes/session/index.tsx` | the guarded handler |
| generated SDK + `openapi.json` | `bun ./script/generate.ts` |
| `test/server/httpapi-exercise/index.ts` | endpoint registration |
| `.github/workflows/build-release.yml` | a step **naming** the test file |

That last row is not optional. The repo says so three times, in the imperative:
*"a patch-carried test that no workflow names is inert"* (`apply.sh:391-394`,
`:472-474`, `build-release.yml:139-141`). CI runs only the files it names; there
is no repo-wide `bun test` and no typecheck in CI.

**The handler must set `sessionID` on the published event.** Our own
`event-session-scope.patch` filters the SSE stream by `data.sessionID ∈
session_ids` and **passes through every event lacking a string `sessionID`**.
Omit it and the scroll broadcasts to every TUI on that serve and directory —
every attached session jumps at once. The field is in the schema, so this is
enforced by construction rather than by care.

The TUI handler:

```tsx
const [pendingScroll, setPendingScroll] = createSignal<string | undefined>()

onCleanup(
  event.on("tui.message.scroll", (evt) => {
    if (evt.properties.sessionID !== route.sessionID) return
    // `force` is the user's own jump; everything else is a speculative retry
    // that must not move a viewport the user has taken over. See "the late scroll".
    if (!evt.properties.force && scroll && !atBottom(scroll)) return
    setPendingScroll(evt.properties.messageID)
  }),
)

// Reactivity is the readiness signal: fire as soon as the anchor exists, once.
createEffect(() => {
  const id = pendingScroll()
  if (!id) return
  if (!messages().some((m) => m.id === id)) return // not synced yet; re-runs when it is
  if (!scroll || scroll.isDestroyed) return
  scroll.scrollChildIntoView(id)
  setPendingScroll(undefined)
})
```

The handler no longer scrolls; it records. The effect owns the scroll, so the
render race is waited out rather than retried, and the at-bottom check moves to
*receipt* time — the moment that reflects what the user was actually doing when
they jumped.

`isDestroyed` as well as `!scroll`, matching the neighbouring `toBottom`
(`index.tsx:426`): `<Show when={session()}>` can destroy and recreate the
scrollbox with the ref briefly pointing at a corpse.

Three things it does deliberately:

- **`onCleanup`.** The two neighbouring `event.on` registrations
  (`index.tsx:328`, `:358`) capture nothing and leak across route remounts. They
  happen to stay correct because `route` is a live store proxy, which is
  presumably why nobody noticed. Ours disposes. One word, strictly better than
  its neighbours, and not a refactor of them.
- **The `!scroll` guard.** `scroll` is assigned by a ref at first render. The
  existing `getChildren()` sites don't guard because they are reachable only
  from user commands, i.e. after render. **Ours is not user-triggered** and can
  arrive before first paint.
- **The at-bottom guard**, below.

### The late scroll, and why the guard does more than it looks

The transport is **live-only SSE with no replay**. A scroll published before the
TUI has mounted the session route is dropped. Two jump cases differ materially:

- **Session already open** (`focus_here` / `switch_pane`): TUI is mounted, event
  lands, works. This is the common case in daily use.
- **Cold attach**: the picker fire-and-forgets `oc-auto-attach` with no wait, a
  whole TUI process starts, and completion **is not observable** — the picker
  discards the return value, and test 65 already exists to acknowledge that
  "jump succeeded" is unknowable here.

There are in fact **two** races here, and the first draft of this plan used one
blunt instrument for both. Separating them is what makes the design honest:

- the **mount race** — the event is published before the TUI has subscribed and
  mounted the session route, so it is dropped;
- the **render race** — the event arrives, but the anchor message has not been
  fetched or laid out yet, so `scrollChildIntoView` finds nothing.

They have different shapes and want different answers. The mount race is a cheap
handshake with a short window; the render race is an unbounded wait on a network
fetch. Retrying the second one on a timer is guessing at something that is
directly observable from inside the component.

**So the TUI does not scroll on receipt. It remembers.** The event sets a pending
target; a reactive effect scrolls when the anchor actually exists, once, and then
clears it. Solid's reactivity *is* the readiness signal — no timer, no window,
no polling. If the message arrives ten seconds later, the scroll still happens.

That removes the render race from the retry's job entirely. The retries now cover
only the mount handshake, and **one** delivered event is sufficient forever
after, no matter how slowly the content loads.

Two ordering hazards the effect must respect, both verified in v1.18.18:

- `session/index.tsx:314` force-scrolls to the bottom (`scrollBy(100_000)`)
  immediately after `sync.session.sync(sessionID)` resolves. Any scroll applied
  before that line is clobbered. The pending target must **suppress** that
  bottom-scroll rather than race it — suppression is explicit, ordering is
  fragile.
- The pending target must be cleared when `route.sessionID` changes, or a stale
  target follows the user into the next session.

Blind retry still has its hazard: **a scroll landing seconds late yanks the
viewport out from under a user who has already started reading.**

The at-bottom guard removes that hazard *by construction*. A freshly attached
TUI sits at the bottom, so the guard passes and the scroll lands. If the user has
scrolled anywhere themselves, the viewport is no longer at the bottom and every
later event is dropped. The user's own scrolling always wins.

**But an unconditional guard breaks the warm case it was supposed to protect.**
If the session is already open and the user left it scrolled up an hour ago, the
viewport is not at the bottom — so all four attempts drop, *including attempt 0,
which is the direct response to the user pressing jump right now*. The guard
cannot tell "actively reading" from "stale scroll position from this morning",
and treating them alike silently ignores an explicit request. Hence `force`,
set on **attempt 0 only**: that attempt is the user's instruction and overrides
the guard; attempts 1-3 are speculative and stay guarded. In the cold case
`force` costs nothing, because a starting TUI is at the bottom anyway.

The same guard makes the retries **self-limiting**: once any attempt is
delivered and the target is pending, later attempts set the same target and
change nothing. The schedule therefore needs no cleverness and no feedback
signal, which is fortunate, because none exists — the handler publishes to a bus
and returns `true` whether or not any TUI is listening.

### Why readiness cannot simply be observed, having looked

Three candidates were checked in source before settling for retries on the
handshake:

- **The TUI control channel** (`server/shared/tui-control.ts`) is a genuine
  request/*response* RPC whose queue even buffers when no consumer is waiting —
  which would have been retention for free. It is **dead on both ends**:
  `submitTuiRequest` has no callers, and nothing in `packages/tui/src` polls
  `/tui/control/next`. Only the legacy generated SDK and the docs mention it.
  Reviving it means building both ends of a vestigial mechanism whose queue is a
  process-global, so with two TUIs on one serve either could steal the other's
  request.
- **`oc-auto-attach`'s existing readiness wait** verifies that the attach process
  *stays alive*, and earlier that the session is visible over HTTP and nvim's RPC
  is up. None of that means the session route is mounted.
- **The server's SSE subscriber set** would show that *some* client connected —
  not that this session's route is mounted, and certainly not that messages
  rendered. There are three layers of readiness and the server can see only the
  first.

The only place all three facts are simultaneously true is inside the session
component's reactive scope. That is exactly where the pending-target effect
lives, so the part of the problem that is observable is now handled by
observation, and only the unobservable handshake is retried.

### The launch-time flag, considered and rejected

Passing the target at startup — `opencode attach --session X --scroll-to msg_Y`,
seeded like `route.prompt` — is the obvious way to make the cold case race-free
by construction. It was rejected on two verified facts:

- **`yargs` is `.strict()`** (`packages/opencode/src/index.ts:116`). An unknown
  flag is a hard failure, so a picker passing `--scroll-to` to an older binary
  breaks **attach entirely** — no TUI at all, rather than no scroll. Skew is
  guaranteed in both directions: the picker's lua lives in long-running nvim
  processes that do not restart with opencode, and any rollback of the patched
  binary would break cold attach wholesale. The failure direction flips from
  benign to breaking the feature's own host.
- **The precedent does not exist.** `initialRoute` (`context/route.tsx:44-53`)
  reconstructs a session route with **only** `sessionID` and strips everything
  else, and `--session` does not ride `initialRoute` at all. The design would be
  *creating* a CLI→route-payload path, not following one.

If it is ever revisited, it should ride an environment variable rather than a
flag, because an old binary ignores an unknown env var silently.

Tolerance is `maxScrollTop - 1` rather than equality, matching opentui's own
`isAtStickyReengagePoint`, so a streaming token arriving mid-jump does not
defeat the guard.

### C. The front door learns the route (workstation)

One row in `pkgs/opencode-frontdoor/src/routes.classification.ts`:

```ts
{ method: "POST", path: "/session/{sessionID}/scroll-to-message", class: "session-path" }
```

plus the `/api/...` mirror if `/doc` advertises it. Class `session-path` is a
**non-denying** action, so it needs no disposition entry, and the disposition,
kind and constraint censuses — which are computed only over denials
(`route-gate.ts:360-515`) — are untouched.

**But one census IS affected, and getting this wrong breaks the deploy.** Check
C's media-type walk (`route-gate.ts:318-330`) runs for **every** advertised
route, before and independent of the denial branch, and
`EXPECTED_MEDIA_TYPE_CENSUS` pins `'application/json': 512`
(`route-gate.ts:128-133`). A new endpoint declares JSON responses — the bare
path and, if advertised, the `/api/` mirror — so the count rises and the gate
fails. **The exact increment must be measured from the generated spec, not
guessed**, and this plan deliberately does not state a number.

**This is a simultaneity constraint, which is stricter than the two ordering
constraints below.** `route-gate` boots the *pinned* opencode and fetches its
live `/doc`, so:

- land the census edit **before** the version bump → it disagrees with the old
  `/doc` (still 512) → gate fails;
- land it **after** → the bump PR itself fails CI and auto-merge is blocked.

So the census edit **must ride the version-bump change itself** — pushed onto
the auto-opened bump PR's branch, or the bump opened by hand instead. The
classification row has no such constraint and may land earlier: Check A iterates
`/doc` only (`route-gate.ts:303-357`), and the sole reverse check
(`:588-594`) covers dispositions, which a `session-path` row does not create. So
extra rows for not-yet-advertised routes are genuinely harmless — that part of
the original claim survives verification; the census part did not.

Also check `timeouts.ts` for whether the new POST needs a first-byte-timeout
entry or inherits an acceptable default.

### D. The picker fires it (workstation)

A new `exec.scroll_to_message(payload, opts)` following the established
`clear_unread` idiom — curl, `--max-time`, `{ stdin = false }`, `pcall`, the
`opts.system or vim.system` seam — with two differences: it targets the **front
door** (`FRONTDOOR_URL`, default `http://127.0.0.1:4700`) rather than pigeon, and
it needs no auth header, because the door as deployed requires none.

Fired from the dispatch site in `init.lua` after the descriptor is handled, at
**0 / 300 / 900 / 2000 ms** via `vim.defer_fn`, four attempts, hard stop.

- **Not** on `refuse_dir_missing` — that path deliberately does not navigate.
- **Not** when `anchor_msg_id` is null — skip the retries entirely rather than
  spraying at a target that does not exist.
- Same schedule for all navigating descriptors. Case 1 succeeds on attempt 0 and
  the guard drops the rest; branching on descriptor kind would buy nothing.

**Jumping still writes no unread state** — phase 3 established that accepting a
row clears no badge, and this preserves it: a read-only `SELECT` the picker
already performs, plus a TUI viewport command. Tests 63/64/65 assert zero writes
on the jump path and must keep passing.

It is *not* true that the request writes nothing at all, and the distinction is
worth stating so nobody rediscovers it. The door classifies this POST as a
mutating session request (`sticky.ts:89-94`), so each attempt refreshes a sticky
lease and can trigger a lease-renewal `/place` — a write to pigeon's **routing**
state, not to read state. No placement is caused: `scroll-to-message` is not in
`PROMOTING_SUFFIXES` (`place.ts:157-171`).

**The picker ignores the response entirely, deliberately.** Two paths make that
the right call rather than laziness: with pigeon down the door 503s a mutating
request rather than running it against a non-owner (`proxy.ts:849-851`), and a
session not yet routed is forwarded to the prospective serve
(`proxy.ts:834-841`), where the event may publish on the wrong bus and no-op.
Both mean "no scroll", both are rescued by a later attempt once placement
settles, and neither is worth a feedback loop.

**No front-door-opacity exemption is required.** The guard scans only
`pkgs/*/default.nix`, four `users/dev/home.*.nix`, and two host configs —
`assets/nvim/**` is not scanned at all — and its token set matches
`127.0.0.1:409[6-9]`, not `4700`. Verified by reading the matcher rather than
assuming. One trap to avoid: `(OPENCODE_URL|OPENCODE_ANCHOR_URL)=` matches
**regardless of value**, so the variable must not be named `OPENCODE_URL` even
when it holds the door's address.

---

## Open questions, answered

**Q2 (attach/scroll race).** Bounded blind retry at 0/300/900/2000 ms, four
attempts, made safe and self-limiting by the at-bottom guard. Fails toward "no
scroll" after the bound. Cold attach slower than ~2 s lands at the bottom, which
is today's behaviour. If that turns out to be common, the escalation is
server-side retention — deliberately not pre-paid, because retention would solve
the *attach* race while leaving the *render* race, and would then need readiness
sequencing, a TTL and a consume path, all permanent in a 27-patch stack with no
sunset path.

**Q3 (compaction).** A compacted-away anchor means `findDescendantById` misses
and `scrollChildIntoView` returns silently. The viewport stays at the bottom.
Correct as-is; **no retry loop, no fallback target.** The pending target simply
never resolves.

**The feature has a reach of roughly 100 messages, and this is not a design
choice.** The TUI fetches `session.messages({ sessionID, limit: 100 })`
(`context/sync.tsx:603`) and renders only what it fetched. An anchor older than
the newest 100 messages is never in the store, never rendered, and cannot be
scrolled to **by any mechanism** — launch parameter, retention, or event. It
degrades correctly (no scroll, land at bottom).

> **CORRECTED 2026-09-04, after live testing. This paragraph was written as
> though the ceiling were an edge case. It is the common case, and the feature
> does nothing about three quarters of the time.**
>
> Measured over the 120 most recent non-mirror anchored events (118 resolvable
> in `opencode.db`): the anchor sits a **median of 192 messages** from the end
> of the transcript — p25 66, p75 340, max 498. **Only 32/118 (27%) fall within
> the 100-message window.** The first two real user tests both missed, at 174
> and 192 back.
>
> The error was reasoning about the limit as though messages were conversational
> turns. They are not. The anchor is the last *human* turn before a
> notification, and one human turn in an agentic session produces dozens to
> hundreds of assistant and tool messages — so an anchor far beyond 100 back is
> the **normal shape** of any session worth notifying about, not a pathological
> one. One query against `opencode.db` before building would have shown this.
>
> Everything else was verified working at the same time: the picker fires (the
> 0/300/900/2000 schedule is visible in the door log), the door routes
> `status: 200 action: route-session`, the serve publishes rather than 404s, the
> TUI clients run the patched binary, and pigeon has written 405 anchors. **The
> failure is only that the target is not loaded**, i.e. the designed degrade
> path firing far more often than predicted.
>
> **Fix (tracked as `workstation-psh9`), as originally stated:** `MessagesQuery`
> accepts `before` as well as `limit` (`groups/session.ts:43-47`), so page
> **backwards** from the oldest loaded message until the anchor appears.
>
> **That was wrong in two ways, both found by reading the handler before writing
> any code (shipped 2026-09-04 as `v1.18.18-patched.2`, opencode-patched#47):**
>
> 1. **`before` is an opaque CURSOR, not a message id.** `handlers/session.ts`
>    does `MessageV2.cursor.decode(before)` and 400s on anything else; the cursor
>    comes only from the `X-Next-Cursor`/`Link` response headers of a previous
>    page, which the generated SDK does not surface conveniently. `before`
>    without `limit` is itself a BadRequest. Paging "from the oldest loaded
>    message" would have failed on the first call.
> 2. **No paging is needed at all.** `limit: N` alone returns the newest N, and
>    `limit` absent or 0 returns everything. One `limit: 512` request covers the
>    observed maximum distance of 498.
>
> **And the 100 is a store invariant with TWO trim sites, not a fetch size:** the
> initial sync slices to the newest 100 and deletes the parts of everything
> older, and the `message.updated` handler shifts the oldest off on *every*
> insert past 100. The transcript is also **not virtualized** — `<For each={
> messages()}>` makes every stored message a live renderable — so
> `scrollChildIntoView` can only reach a message that is in the store, and
> reaching an older anchor means rendering everything between it and the present.
> There is no way around that cost while the list is unvirtualized.
>
> **What shipped.** Both trim sites consult a per-session cap. A jump whose
> anchor is absent does one bounded `limit: 512` fetch; `planReach` keeps only
> anchor-minus-margin so the rendered count is the anchor's distance plus 20
> (median ~210, not 512); `mergeReach` reconciles that window against the **live**
> store rather than a pre-fetch snapshot, prepending only strictly-older messages
> so the list stays sorted for the binary-search inserts that follow. An
> in-flight map makes a second jump join the first. The cap is released on
> `onCleanup`.
>
> **Windowed replace was rejected on evidence,** not taste: `status()` derives
> working/idle from `messages.at(-1)`, and the prompt, subagent footer and move
> dialog all read the list tail, so a detached historical window would lie to all
> of them.
>
> **Measured cost:** the deep fetch takes ~7.6s and moves ~5.2MiB on a real
> 759-message session, against ~2.1s and ~1.2MiB for the ordinary one. Hence a
> progress notice, and an explicit "too far back" notice on a miss — silence for
> eight seconds is indistinguishable from the failure this change removes.
>
> **The blocker adversarial review caught, worth remembering:** releasing the cap
> via `on(() => route.sessionID)` is DEAD CODE. `app.tsx` mounts this route under
> a **keyed** `<Show>`, which disposes and rebuilds the component per session, so
> `route.sessionID` never changes within an instance. The `pendingScroll` clear
> that shipped in patch 31 was dead for the same reason — harmless only because a
> fresh instance gets a fresh signal, not because it worked, and its comment
> claimed a behaviour it never had. Without the fix, every jumped session would
> have kept its enlarged list and ~5MiB for the life of the process: strictly
> worse than the no-op it replaces.
>
> **Two gaps left open deliberately:** the shift-one eviction still shifts the
> viewport if enough messages arrive while the user reads history above the
> bottom (`workstation-hswe`; the margin buys ~20, and a jumped session is
> usually idle because the anchor is written when the agent *finishes*), and the
> render cost is measured at the fetch but not at paint (`workstation-p267`).
>
> **Do not simply raise the initial limit.** That would slow every session open
> to serve a minority case, and at a p75 of 340 it would have to be raised far
> enough to hurt.

**Q7 (two TUIs on one session).** Both receive the event and both scroll, each
subject to its own at-bottom guard — so a TUI whose user is already reading does
not move. Stated expectation, not a surprise.

**Obligation 2 from 1b (stale anchor vs null).** Keep the stale anchor; do not
null it. A Telegram-driven session's anchor is its last *TUI* turn, possibly
hours back, because Telegram replies are recorded as injected prompts and never
anchor. Landing there is still landing at the start of what the user has not
seen **in this interface**, and the failure direction is re-reading rather than
skipping. Nulling it would trade a slightly-too-early landing for no landing at
all, which is strictly less information.

---

## Landing order

The ordering is forced in three places — two sequencing constraints and one
stricter *simultaneity* constraint — and free everywhere else.

1. **opencode-patched**: patch #31 → merge → cut a release. The base tag
   `v1.18.18-patched` is taken, so this needs `--field revision=N`; release is
   `workflow_dispatch` only (never tag-push) and takes ~4-5 min for four
   platforms. Darwin assets are ad-hoc codesigned on a real macOS runner or the
   binary is SIGKILLed on launch — a green CI is *not* proof the darwin asset
   works.
2. **workstation, one PR**: the classification row, the CLI anchor column, and
   the picker call. The row **must not land after** the version bump.
3. **Version bump + media-type census, together in one change.**
   `update-opencode-patched.yml` tracks the highest `v1.18.18-patched.N` under
   the existing cron hold and opens the bump automatically once the release
   publishes — but that auto PR will **fail `nix flake check`** on the
   media-type census until the census edit joins it. Push the census edit onto
   its branch, or open the bump by hand. Measure the new
   `'application/json'` count from the gate's own failure output rather than
   predicting it.
4. **`nix run home-manager -- switch --flake .#cloudbox`** — required and
   manual; a restart alone re-execs the same nix store path.
5. Serve pool restart — the nightly 03:00 covers this step, and only this step.

Step 1 gates step 3 because the bump needs the release's four platform hashes.

---

## Verification

Unit-level, per component:

- **CLI**: oldest-not-newest; the mirror filter; missing-column probe →
  `anchor_msg_id: null` **with badges intact** (the regression that matters);
  missing table → unchanged existing behaviour.
- **Patch**: the session-scope guard drops another session's event; the
  at-bottom guard drops when scrolled away and passes at the bottom; **`force`
  overrides the guard**; a missing child no-ops without throwing; the published
  event carries `sessionID`.
- **Picker**: URL and body shape; fires on navigating descriptors; does **not**
  fire on `refuse_dir_missing` or on a null anchor; **`force` set on attempt 0
  and on no other attempt**; the retry schedule; still writes no unread state.

Every new Lua assertion must be reflected in the pinned counts in `flake.nix`
(spec is currently **432**, six `PASS` lines) or `nix flake check` fails.

**Mutation testing, predicting survivors first.** Phase 1b's first run left three
survivors — both swarm sites and the question site — because every test drove
mirror and stop; that was the same blind spot as phase 3, where every test drove
`attach`. The lesson did not transfer on its own either time. The obvious
candidates to predict here are the mirror filter, the oldest-vs-newest ordering,
the `IS NOT NULL` predicate, the at-bottom guard, `force` being set on attempt 0
only, and the `refuse_dir_missing` exclusion. Patch-carried tests
must additionally be proven non-vacuous by reverting the production hunk, which
is this repo's stated convention.

**End-to-end, by the user, once deployed**: a session with unread work, jumped to
from the picker, lands at the first unread turn rather than the bottom — and
jumping to a session with no unread lands at the bottom exactly as today.
