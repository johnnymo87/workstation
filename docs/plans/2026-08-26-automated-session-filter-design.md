# Hiding automated sessions in the session-switcher picker

**Bead:** `workstation-sah1`
**Date:** 2026-08-26
**Status:** design approved; implementation pending

## Problem

The telescope session-switcher (`<leader>fs`, shipped in PR #411) lists sessions
from `oc-session-list --fold`. Most of that list is lgtm auto-review sessions the
user never wants to jump to.

Measured over roughly six hours on 2026-08-26, in the picker's default window:

| time | window | automated | share | visible |
|---|---|---|---|---|
| morning | top 40 | 13 | 33% | 27 |
| midday | top 50 | 26 | 52% | 24 |
| afternoon | top 50 | 31 | 62% | 19 |

The `session_origin` table grew 662 -> 682 -> 692 -> 697 rows across the same
window. The share also rises with depth: 62% at limit 50, 73% at 200, 70% at 400
and 800. This is not a static annoyance; it is a list that degrades as lgtm runs.

## Decisions taken by the user

Both were chosen after being shown the cost:

1. **Hard exclusion, with no reveal mechanism at all.** No fourth facet, no
   toggle key, no reveal-by-typing.
2. **No exception for errored or blocked automated sessions.** The rule is
   stateless: an lgtm session never appears.

The accepted cost of (2) is named in "Known costs" below.

## The predicate

A row is `automated` if and only if its `root_id` has a `session_origin` row
whose `origin` is in a hardcoded allowlist:

```
HIDDEN_ORIGINS       = { "lgtm" }
KNOWN_VISIBLE_ORIGINS = { }
```

Keyed on `root_id`, not `id`: `--fold` emits roots only.

### Why not the alternatives

**Not "has an origin row at all."** `origin` is free-form `TEXT` with no enum
(`session-origin-repo.ts`), and `notify_policy: "all"` is a legal, validated,
accepted value meaning *this session is declared, and you should show every
event*. A roadmap doc already anticipates a second origin
(`my-podcasts-pipeline`). Hiding on row presence is broader than the daemon's own
semantics.

**Not `notify_policy != "all"`.** This was the design's first predicate and it
survived one adversarial review before being replaced. It fails on a plausible
future: a "mute this session's Telegram notifications" feature is the natural
next use of this exact table, and it would write `notify_policy != "all"` for a
*human* session, permanently vanishing it from the picker. An allowlist is
immune, because such a feature writes a different `origin`.

It is also internally inconsistent. The rationale was "provenance, not delivery",
and then it keyed on the delivery field. An allowlist is pure provenance.

**Not the TTL-aware effective policy.** `effectiveNotifyPolicy`
(`notify-policy.ts`) reverts a quiet policy to `"all"` two hours after
`declared_at`, on the invariant that *all suppression is TTL-bounded; nothing is
permanently silent*. Reproducing that faithfully would make the filter a no-op on
every one of the ~697 rows, all of which are older than two hours within minutes
of being written. Reproducing it unfaithfully would mean using pigeon's field
with different semantics than pigeon.

### Why narrowest wins

There is no reveal mechanism. That makes the error costs wildly asymmetric:

- A **false hide** is unrecoverable from inside the picker. The user cannot jump
  to what is not rendered, and unlike a badge there is no self-healing.
- A **false show** is a row of noise, and it announces itself via the tripwire.

Extensibility in the *hiding* direction is therefore the dangerous direction. The
narrowest predicate is correct, and new automations opt in deliberately.

## The tripwire

`buildOriginMap` warns once per distinct `origin` value that is in neither set.
Dedup is per distinct value, not per row, or it would fire hundreds of times.

Two sets rather than one because a single set makes the tripwire self-destruct on
first legitimate use: a new automation the user decides should stay *visible*
would otherwise warn on every picker open forever. This repo's own doctrine is
that a chronic pin "trains the eye to ignore it" (`oc-session-list-fold.ts`) and
that "a tripwire dies of distrust faster than of silence"
(`oc-session-list-state.ts`). `KNOWN_VISIBLE_ORIGINS` is the acknowledgement
channel.

This is also the entire detection story for under-hiding. If lgtm renames its
origin string, the sessions stop being hidden and the tripwire fires loudly
rather than the filter failing silently.

## Placement

**The CLI annotates; the picker filters.**

`buildOriginMap` goes in `oc-session-list-state.ts` alongside `buildOwnersMap`
and `buildUnreadMap`: same database file, same `{ readonly: true }` open, same
`sqlite_master` existence check, same `onWarn` contract. `session_origin` lives in
the same `pigeon-daemon.db` the picker already opens, so this is the same query
surface, not a new dependency or a new failure mode.

It must run **after the union block, over post-union `baseRows`** — not merely
"beside the other builders". The union path injects attention rows from outside
the recency window; a builder computed earlier would leave those rows
unannotated, and an unannotated row is kept, producing a silent under-hide in
exactly the path that matters most.

Two fields are added to every row:

- `origin: string | null` — for debuggability only. Hiding is invisible by
  nature, so this is the only way to answer "why isn't X in my list" without a
  manual SQL query.
- `automated: boolean` — the pre-digested verdict, matching how `unread_state`
  and `effective_state` are already computed CLI-side rather than in Lua.

No CLI behaviour changes. This is annotation only; existing consumers see two new
fields and nothing else moves. `foldRows` spreads `...a.row`, so both fields
survive the fold for free.

### The filter must sit above the pierce

`model.build`'s keep-chain opens with `if pierces then keep = true`, where
`pierces` is true for `error`/`blocked` rows. Adding the automated check as
another `elseif` would let an errored automated row pierce through and appear —
silently contradicting the user's explicit "no exception" decision.

The automated drop is therefore an early exit **above** the pierce, pinned by a
test asserting `automated = true` and `effective_state = "error"` is dropped.

## Fetch limit: 50 -> 200

The exclusion happens after the base query's `LIMIT`, which applies to root
trees. At 62% automated, a limit of 50 leaves 19 rows.

An earlier revision of this design refused to raise the limit, on the grounds
that the surviving real rows are exactly the ones visible today, so nothing is
lost. That claim is true — verified against the `root_recency` CTE, and no
interaction (union path, 200-id cap, fold rank demotion) falsifies it — but it
answers the wrong question. The feature's job is a useful list, and the visible
count is `limit * (1 - p)` with `p` climbing.

The cliff is concrete: the longest consecutive run of automated roots in the top
50 is already 14. A single overnight lgtm batch filling the window renders an
empty picker.

Cost is not a consideration. CLI wall time is flat: 123 ms at limit 50, 123 ms at
200, ~150 ms at 800. The limit is set in `init.lua`'s picker opts (via
`fetch_opts`), not in the CLI default, to scope the blast radius to the picker
and leave ad-hoc CLI use at 50.

## The hidden count

The prompt title becomes `Sessions (all) · 31 hidden`, and
`Sessions (all) · 31 hidden [⚠ 2]` when warnings exist.

Hiding is invisible by nature. Without this, a short or empty list is
unattributable — which is the founding rule of this whole feature line: "no
sessions" and "the tool broke" must never look alike.

Three properties are load-bearing:

- **Facet-independent.** The count is automated-drops only, computed before the
  facet branch, so it is the same number under every facet. A count that changed
  meaning per facet would be incoherent.
- **Window-scoped, and only honest because of the wording.** It counts rows
  hidden within the fetched window, not hidden overall. Its job is attribution
  ("this list is short because of me, not an outage"), which it does. It would
  become a lie if worded as a total.
- **Returned as a second value from `model.build`, never as a field on the rows
  table.** A non-integer key would flip `vim.islist` false and trip the
  top-level-list guard in `cli.lua`.

Both title-computation sites must consume it — the one at picker open and the one
in `cycle_facet` — or facet cycling displays a stale count.

An all-automated window yields an empty picker with the count in the title and
*not* the "No open sessions found" line, because `spec.warning_lines` receives the
raw pre-filter result. That is currently a property of call order; it gets a test
so a later cleanup cannot quietly invert it.

## Failure direction

Routing DB missing, `session_origin` absent, or the read throws:
`automated: false` on every row, plus a warning. **Everything shows.**

There is no `?`-badge equivalent for a row that is not rendered, so the only safe
failure is showing too much. This mirrors `buildUnreadMap`, which renders `?`
rather than guessing. Manual test 5 on 2026-08-26 confirmed these warnings are
visible in the prompt title and as notifications.

## Known costs

**An adopted lgtm session is permanently invisible.** pigeon explicitly
contemplates a human adopting one (`notify-policy.ts`), the origin row
deliberately outlives the session, and this design attaches a second,
*non-TTL-bounded* suppression to that row from another repo. If the user adopts a
review session and works in it, `model.build` drops it above the facet check, so
even `facet = attached` will not find it. The recourse is
`DELETE /session-origin?session_id=...`, which is pigeon's own documented escape
hatch and un-hides the session here for free — but it is a curl, invoked from
outside the tool, while looking at a picker that shows nothing wrong.

**A stuck review is unreachable from the picker.** If an lgtm session errors or
blocks on a question, pigeon still delivers that to Telegram (`errors-only`
suppresses only Stop, Retry and aborted Error). The user is told, and then cannot
reach the session from the picker. This was chosen explicitly.

### Rejected mitigation: "hide automated unless attached"

Adversarial review proposed scoping the predicate to `automated AND not attached`
— hide automated sessions you are not sitting in — as one inch of safety for the
adoption case without adding a reveal mechanism.

This is rejected because it would defeat the filter. lgtm launches sessions via
`opencode-launch --tmux-session lgtm`, which hands off to `oc-auto-attach`, which
targets tmux panes, in which `nvims` listens on `/tmp/nvim-<pane>.sock`.
`discovery.lua` finds exactly those sockets, so lgtm sessions are `attached` while
a batch is running. The mitigation would unhide them precisely when the filter
matters most.

At rest there is no lgtm tmux session — the nightly reset tears it down — so this
is an argument from the launch path rather than a live measurement.

## Testing

`buildOriginMap` is tested against a **real temporary SQLite database**, not an
injected stub. `oc-session-list-state.ts` records that an unused test seam is
untested surface free to drift, and `buildUnreadMap` has no seam for that reason.

Cases: no origin row; `origin = "lgtm"`; an unknown origin (not hidden, tripwire
fires exactly once); `notify_policy` variations that must **not** change the
verdict under this predicate; a row in `KNOWN_VISIBLE_ORIGINS`; missing table;
missing database; read throws. Plus the `queryWithState` merge in both its
branches, mirroring the existing unread coverage, and a **union-path fixture**
whose automated root arrives from outside the recency window.

The `id`-versus-`root_id` mutation needs a **child-keyed origin fixture**.
Production has zero child origin rows across 800 trees, so a realistic fixture
would never catch that mutation.

Lua: automated rows dropped; kept when the field is absent or false;
`automated ∧ error → dropped`; CLI order preserved; hidden count correct and
identical across facets; count not stale after facet cycling; all-automated
window yields empty list plus count and no "No open sessions found".

Mutation tests, with survivors predicted before running: swap the allowlist for a
row-presence check; delete the filter; invert the degrade to hide-on-failure; key
on `id` instead of `root_id`; move the filter below the pierce.

Pinned counts to bump in the same commit: bun `expected_expects` (262), Lua model
stage (87), Lua spec stage (407, because the prompt title and `init.lua` change).
`automated` is a boolean rather than a vocabulary, so no third cross-language
mirror check is needed alongside the `effective_state` and `unread_state` ones.

Before shipping, measure nvim-side `vim.json.decode` cost at limit 200. CLI wall
time was measured flat, but decode happens on the main loop on every picker open
and every facet cycle.

## Cross-repo documentation

Both are one comment each:

- **pigeon**, on `session_origin`: name the picker as a second consumer of this
  table whose suppression is *not* TTL-bounded, so a future editor of the quiet
  invariant knows it is not the only reader.
- **lgtm**, at `dispatch.ts` where `origin: "lgtm"` is written: note that the
  literal string is load-bearing for the workstation picker's allowlist. pigeon
  only stores the string; lgtm is the party that could rename it.

Plus a one-line runbook next to the filter: to find out why a session is not
listed, check the `origin` field in `oc-session-list --fold` output, or
`GET /session-origin?session_id=...`.

## Review history

Two adversarial review rounds, both `adversarial-reviewer-fable`.

**Round 1** confirmed the placement, the failure direction and the
"nothing is lost" claim; found one real defect (the pierce-precedence bug, which
would have silently contradicted the user's no-exception decision); and reversed
the "no limit bump" decision with a fresher measurement than the design carried.
It accepted the `notify_policy` predicate and asked only for a comment and a
tripwire.

**Round 2** reviewed the revision, agreed the allowlist overrule of round 1 was
correct, and found: the tripwire needed a second tier or it would self-destruct on
first legitimate use; the limit's home was unspecified; the builder placement
wording was loose enough to permit a refactor that breaks the union path; and the
hidden count needed explicit plumbing to avoid the `vim.islist` guard. Its one
rejected recommendation is documented above.
