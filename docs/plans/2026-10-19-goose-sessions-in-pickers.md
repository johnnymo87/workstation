# Goose sessions in the nvim pickers (`,fs` and `,fp`), opened in `honk chat`

Bead: honk-9qf.15.11 (honk repo beads). Date: 2026-10-19.

## Problem

Verified on 2026-10-19 (workstation e8241f8):

- `,fs` (session switcher) lists only opencode sessions. Its rows come from
  `oc-session-list --with-state --fold`, which reads opencode.db, the pigeon
  routing DB and the session-state overlays. `oc-session-list --ids 20261016_222`
  returns `[]`.
- `,fp` (stall-watch programs) gets each program's sessions from
  `oc-tags sessions <tag>`, then resolves them with ONE
  `oc-session-list --fold --ids <union>`. oc-tags already stores goose sessions
  as `goose:<goose-id>` (tags.db), but oc-session-list cannot resolve them, so
  they vanish.
- Selecting any row goes `act.decide -> {kind="attach"} -> exec.attach ->
  oc-auto-attach <sid>`, which only accepts `^ses_` and opens
  `opencode attach` in a tab of the project's nvim.

Revised after an adversarial-reviewer-opus design review (same day); the
changes it drove are marked **(review)**.

Goal: goose sessions show up in both pickers next to opencode sessions, and
selecting one opens `honk chat <goose-id>` in the project's nvim tab, the way
opencode sessions open `opencode attach`. Opencode behaviour stays byte-for-byte
the same.

## Decisions

### 1. Row ids are `goose:<goose-id>`

Goose ids look like `20261016_222`. Picker rows for goose sessions use
`id = "goose:20261016_222"`, the namespace oc-tags already uses in tags.db.

- `,fp` joins oc-tags ids to oc-session-list rows by id (`matched_ids` /
  `row.id`), so the prefix makes that join work without translating ids.
- The harness is visible in the id itself. oc-auto-attach and
  `oc_auto_attach.lua` switch on the prefix; nothing else needs a new field.
- The prefix is stripped in exactly two places, both at the honk boundary:
  oc-auto-attach (to look the session up) and `oc_auto_attach.lua` (to build
  `honk chat <goose-id>`).
- `cli.is_valid_id` already accepts it (no comma, no leading `-`).

### 2. Goose rows come from `honk list --json`, merged inside oc-session-list

**Source: honkd, via a new `honk list --json`.** honkd's `session/list` returns
goose's ACP session list (title, cwd, updatedAt, and `_meta` with sessionType,
hasRecipe, lastMessageAt, archivedAt), and adds `_meta.honk.{held,running}`.
That is the only place live goose state exists: `running` is honkd's in-memory
"a turn is in flight". **(review)** honkd also adds `_meta.honk.pending`, the
number of goose->client requests (permission prompts) a held session is parked
on; it already persists them (`HeldSession.pending`). Measured: 372 sessions,
8 pages, usually 0.14-0.36 s, with single calls of 1.7 s and 3.5 s seen.

Rejected alternatives:

- Read goose's `sessions.db` directly (as oc-tags does for spend). It has no
  live state, and it couples the picker to goose's private schema. A session
  you can only open through honkd is not worth listing while honkd is down.
- Merge in Lua (spawn `honk list` beside `oc-session-list` in `cli.fetch`).
  model.lua's contract is "ORDER IS OWNED BY oc-session-list"; a second
  ordering implementation in Lua is exactly what that comment forbids, and the
  stall-watch picker's `--ids` path would need the same merge again.
- Have honkd write opencode-format overlay files into `session-state.d`. The
  overlay merge rules (owners, absence-is-authoritative, nodata tripwires) are
  written for opencode serves; feeding them a foreign writer is a large,
  subtle change for one boolean of state.

**Merge point: oc-session-list, `--with-state --goose` only.** A new module,
`oc-session-list-goose.ts`, turns honk's list into `SessionWithStateRow`s.
`main()` appends them to the opencode rows AFTER `queryWithState` (so they
never enter the overlay merge, owner map, or nodata tripwire) and BEFORE
`foldRows` (so the existing sort places them: attention group first, then
tree-max recency).

**(review) Opt-in, and in parallel.** Goose rows need `--goose`, which only the
picker Lua passes (`cli.build_argv`; `flow` defaults `goose = true`,
`stallwatch_picker/source` sets it). Every other caller, including the flat
forensics use, is unchanged. Opt-in also covers deploy skew: a running nvim
keeps its old Lua modules until it restarts, and an old picker must not list
rows its old open path cannot open. `main()` became async: it starts
`honk list --json` before the sqlite work and awaits it at the merge, so the
two overlap. Timeout 2.5 s: the total is then max(2.5 s, DB time), inside the
picker's 5 s budget, while 1.5 s would drop goose rows on a busy open.

**Degradation**, following the file's "every degraded path reports" rule, with
one exception:

- `honk` not on PATH and honk not set up (no `~/.local/state/honk/secret`, no
  `HONK_URL`/`HONK_SECRET`): silent, no goose rows. Only cloudbox installs
  honk; a permanent warning on every other host would train the eye to ignore
  warnings. **(review)** Set up but not on PATH is a warning: that is the
  stripped-PATH breakage class, not an absent harness.
- `honk list --json` fails, times out, or prints unparseable output: one
  stderr warning (`goose sessions unavailable: <first stderr line>`), no goose
  rows. The picker already surfaces stderr lines as warnings in its title.
- `OC_SESSION_LIST_HONK` overrides the command (tests use a fake).

### 3. Mapping a goose session to the row model

| row field | value |
|---|---|
| `id`, `root_id` | `goose:<sessionId>` |
| `parent_id` | `null` (goose lists roots only; subagents are `hidden` sessions) |
| `title` | goose title, else `""` |
| `directory` | `cwd` |
| `time_updated`, `updatedAt`, `lastActivity` | goose's own sort key: lastMessageAt, else updatedAt, epoch ms **(review)** |
| `activity` | `"working"` if `_meta.honk.running`, else `"idle"` |
| `pendingPermissions` | one `"honk"` entry per pending request **(review)**, so the fold makes the row `blocked` (pinned, pierces the facet) |
| `error`, `pendingQuestions` | `false`, `[]` |
| `automated` | `true` when `hasRecipe` (lanes, stall-watch coordinators, probes) |
| `origin` | `"goose-recipe"` when automated, else `null` |
| `unread`, `unread_state`, `last_event_id` | from pigeon, see below |
| `anchor_msg_id` | always `null` (honk has no scroll-to yet) |
| `pigeon_session_id` | pigeon's `gse_...` id for this goose session, or null |
| `harness` | `"goose"` (informational; nothing branches on it) |

Archived sessions (`archivedAt` set) are dropped, as opencode drops archived
rows.

**State honesty.** `running` is honkd's view. A goose session driven outside
honkd (the goose CLI, `goose run` recipes) reads `idle` even mid-turn. Those
sessions are nearly all recipe runs, which are `automated` and hidden from
the `,fs` browse list. A session parked on a permission prompt reads
`blocked` once honkd reports `pending` (an older honkd sends nothing, and the
row reads `working`). Error state for goose is not reported.

**Window.** Browse mode keeps the `limit` most recent non-archived, NON-recipe
goose sessions. Recipe runs are ~70% of goose sessions and arrive every few
minutes; counted against the window they would push every human chat out.
**(review)** It also drops goose sessions older than the opencode window's
edge (`windowFloor`: the oldest tree-max `time_updated` among the opencode
roots, applied only when the opencode window is full). Without it the two
harnesses had different horizons: the 200th opencode root was 3.9 days old,
and 100 of 103 listable goose sessions were older -- mostly `/tmp` probe
sessions, which have no recipe. Measured with the floor: 3 goose rows join
200 opencode rows. `--ids` mode keeps exactly the requested `goose:` ids that
honk listed (recipe runs included, marked `automated`), ignores the floor, and
sets `matched_ids` to the requested form.

**Unread.** pigeon keys goose sessions by its own id (`gse_<uuid>`) and stores
the goose id in `sessions.backend_session_id`. The goose module maps
`goose id -> gse id` (newest `updated_at` wins if pigeon has several) and reads
the counts from the same `buildUnreadMap` the opencode rows use (called
without `onWarn`: the opencode path already reports a bad routing DB). No
routing DB -> `unavailable`; no mapping or no events -> `absent`.

**Mark read (`<M-r>`).** `act.mark_read_watermark` uses
`row.pigeon_session_id` when present, else `row.id`, so the POST goes to
pigeon's id for the session. Opencode rows have no such field and are unaffected.

### 4. Opening a goose row

`act.decide`, `init.dispatch` and `exec.attach` do not change: a goose row
without a live hit yields `{kind="attach", sid="goose:..."}` and
`exec.attach` runs `oc-auto-attach goose:<id>`. Its scroll env var is only set
for `msg_` anchors, and goose rows carry none.

**oc-auto-attach** accepts `^goose:[0-9]{8}_[0-9]+$` alongside `^ses_...`. For a
goose id it:

1. ignores `OPENCODE_SCROLL_TO` (and still unsets it);
2. replaces steps 1 and 1.5 (front-door probe, pigeon route/place) with
   `honk list --json` and a jq lookup of the session's `cwd`. Not listed ->
   exit 3 ("not found"); honk failed -> exit 2 ("not ready");
3. runs the unchanged tmux/nvim routing (project key, window, nvims, readiness,
   lock, settle loop), sending `harness:"goose"` in the open payload.
4. **(review)** If the target nvim runs pre-goose Lua, it rejects the id.
   Measured: the old `open()` raises "invalid sid" and the RPC fails (exit 5);
   the goose path now logs that the nvim needs a restart. If `open()` instead
   returns 0 quietly, the goose path exits 10 with the same hint rather than
   waiting 15 s for an "unknown" status. The opencode path is unchanged.

**oc_auto_attach.lua** `open()` accepts the goose id when
`harness == "goose"`, and runs `honk chat <goose-id>` (cwd = session dir)
instead of `opencode attach`. It sets `b:oc_session_id = "goose:<id>"` and
records `statuses` the same way, so discovery (`rpc.snapshot`) reports the tab
and the next `,fs` jumps to it (`focus_here` / `switch_pane`) instead of
opening a second one. honk exits immediately when honkd is unreachable, which
the existing settle window reports as a failed attach.

**Directory gone.** `act.decide` still refuses rows with `dir_missing`.
`exec.refuse_dir_missing` only offers an `oc-revive` for `^ses_` ids, so goose
rows get the plain refusal.

### 5. Presentation

`spec.format` appends `[honk]` to goose rows (after the age, before
`[dir gone]`), so it is clear which TUI a row opens. The ordinal (title +
basename) does not change.

### 6. `,fp` coverage

Once oc-session-list resolves `goose:` ids (with `--goose`, which
`stallwatch_picker/source` now passes), every goose session tagged with a
program tag appears in that program's "all" view. No model change is needed:
the row id `goose:<id>` is exactly what oc-tags stores, so the existing
`tagged[row.id]` join matches. **(review)** An earlier draft also taught
`all_rows` to read `matched_ids`; that was dead code and was dropped.

Today this shows nothing: no goose session reachable through `session/list`
carries a stall-watch program tag (the one `goose`-tagged session is a hidden
subagent session). Tagging a goose session: `oc-tags set <tag> goose:<id>`.
Making `honk chat --new` tag at creation (as `opencode-launch --tag` does) is
the follow-up that makes `,fp` useful for goose.

## Known limits and follow-ups

- Goose error state is not reported.
- `,fs` id-search mode for goose ids (`spec.id_query` only knows `ses_`).
- `honk chat --new --tag <tag>`, without which `,fp` lists no goose sessions.
- Scroll-to-message for honk (M4 backlog, honk-9qf.15).
- `exec.attach` ignores oc-auto-attach's exit code (for opencode too), so a
  failed open is silent in the picker; the reason is only in the log.
- Each pick holds the session in honkd while its tab is open. honkd caps held
  sessions at 64 (idle TTL 900 s); opening many old sessions can reach it.
- Not verified: whether pigeon clears a goose session's unread count when you
  type in `honk chat`. If it does not, `<M-r>` is the only way to clear it.
- `/tmp` probe sessions newer than the opencode window's edge still show.

## Plan

Two PRs, honk first (workstation's change needs the new flag on PATH).

### PR 1 (honk): `honk list --json`, and honkd reports pending requests

- `SessionEntry` gains `updated_at`, `last_message_at`, `archived_at`,
  `session_type`, `has_recipe`, `pending_requests`, parsed from the
  `session/list` entry and its `_meta`. Missing fields stay `None`.
- `honk list --json` prints one JSON array of objects:
  `{sessionId, title, cwd, held, running, updatedAt, lastMessageAt, archivedAt, sessionType, hasRecipe, pendingRequests}`
  (absent values are `null`). Text output stays as it is.
- honkd's `session/list` augmentation adds `_meta.honk.pending`.
- Tests: parsing the extra fields; JSON shape of an entry; the CLI flag; a
  honkd test that a parked permission request shows as `pending: 1` and drops
  to 0 once answered.

### PR 2 (workstation): pickers

TDD, in this order:

1. `oc-session-list-goose.ts` + bun tests: honk output -> rows (mapping table,
   archived dropped, limit, window floor, pending -> blocked, `--ids` filter
   with `matched_ids`, unread mapping via a temp pigeon DB, degradation:
   absent honk silent, set-up-but-missing warns, failing honk warns, bad JSON
   warns, timeout warns).
2. `oc-session-list.ts`: `--goose`, `OC_SESSION_LIST_HONK`, async parallel
   fetch, merge before fold; `--ids` partitions `goose:` ids from opencode
   ids. Extend `pkgs/oc-session-list/test.sh` with fake honks.
3. `cli.lua` / `flow.lua` / `stallwatch_picker/source.lua`: pass `--goose`.
4. `act.lua`: watermark prefers `pigeon_session_id`.
5. `spec.lua`: `[honk]` mark.
6. `oc_auto_attach.lua`: goose branch in `open()` (jobstart stub test, plus
   the opencode path unchanged).
7. `pkgs/oc-auto-attach`: goose id branch, run against the built script with
   fake honks (exit 1/2/3 cases, no front-door probe).
8. `flake.nix`: assertion-count pins for every suite above.

Verification: run the flake checks touched (`nvim-lua`, `oc-session-list-bin`,
plugin vitest), then a manual check on cloudbox after the author deploys:
`oc-session-list --with-state --fold | jq '.[] | select(.harness=="goose")'`,
open `,fs`, select a goose row, confirm a `honk chat` tab opens, reopen `,fs`
and confirm it jumps to that tab.

Deploy (author-gated): merge honk PR, bump the honk input in workstation
(`nix flake update honk`), merge workstation PR, then
`home-manager switch --flake .#cloudbox`. Each nvim picks up the new Lua when it
next starts (Lua modules stay loaded in a running nvim); until then it neither
asks for goose rows nor can open them. Picks route into the PROJECT's nvim, which
must also be restarted. honkd's `pending` field needs a honkd restart (the unit
is keep-old); without it goose rows still list and open, but a session parked
on a permission prompt reads `working`. goose-serve and pigeon need nothing.
