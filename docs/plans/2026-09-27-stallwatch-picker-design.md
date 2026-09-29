# Stall-watch picker: programs, goose items, and a jump to their sessions

Status: design, approved by Jonathan in brainstorm 2026-09-27; revised after
adversarial review the same day (findings folded in below).

## Problem

A stall-watcher (private, out of this repo) runs every 15 minutes. For each
*program* it manages -- an oc-tags tag that has been registered with it -- it
classifies idle sessions and has a goose coordinator write *items*: short asks
addressed to the human ("decide X", "blocked on Y"), each naming the sessions
it is about. Today its only output is a digest text file.

The human wants to reach that from the nvim/telescope session switcher:
flip between programs, read goose's message for each, and jump straight to
the sessions an item is about.

## Privacy boundary

This repo is public; the stall-watcher is private. Nothing it produces --
program/tag names, item text, session titles, digest contents -- is written
into this repo: not in code, tests, fixtures, commit messages, or this doc.
The picker reads everything at runtime from the private read command.
Fixtures are synthetic (`alpha`, `beta`, invented text). Diffs are scrubbed by
hand before commit (the automated scrub skips `docs/plans/`).

## Interface contract (consumed, not owned)

The stall-watcher exposes a read-only command, `stallwatch/items.sh --json`,
invoked by absolute path. Version 1:

- top level: `{version, generated_at, latest_digest, programs: [...]}`
- program: `{tag, armed, enabled, last_tick_activity, items: [...]}`
- item: `{program, fingerprint, kind, text, status, what_changed, stale,
  first_seen, updated_at, last_sent, shadow_last_sent,
  sessions: [{id, directory, title, directory_exists}]}`
- only open items; ordered decision > blocker > error > stalled > follow_up >
  declared_wait > info, newest first within a kind.
- on error: stdout `{version: 1, error}`, exit 1.
- additive fields need no version bump; anything else bumps `version`.

The picker never reads the stall-watcher's database directly.

Command location: default `~/projects/eng-agent-platform/stallwatch/items.sh`
overridable by an environment variable. The repo name already appears
elsewhere in this repo, so the default path reveals nothing new. The keymap
is registered only if the command is executable.

## User-facing design

`<leader>fp` ("programs") opens a separate picker. `<leader>fs` is unchanged.
(`<leader>fg`/`fG` are already live grep.)

All data is fetched **once, when the picker opens** (see Data flow). Both
screens are pure functions of that snapshot, so moving between them never
waits on I/O or races an in-flight callback.

### Screen 1 -- Programs

- One row per program: `name · N open (k decision, m blocker) · checked 12m ago`,
  with a marker when the program is not `armed` (log-only) or not `enabled`.
- Rows keep the read command's order (stable between opens, so cursor
  restore is meaningful); urgency is shown in the row text, not by re-sorting.
- Zero programs: a notification ("no programs registered"), not an empty picker.
- Previewer: ONLY the program's top item (revised 2026-09-29) -- the one the
  stall-watcher picked (`top_fingerprint`, else `item.top`, else the first
  item for older snapshots) -- as `[kind] text` with `new`/`changed`/`stale`
  marks and the titles of its sessions, then `why: <top_reason>` when present,
  then `+N more open (M new)` (M = other items that are new or changed). This
  mirrors the Telegram digest's layout. M uses item `status`, so it can differ
  from the digest's own count, which tracks what was already sent. The other
  items are reachable per session on Screen 2.
- Moving the cursor is the "flip between programs".
- `<CR>` opens Screen 2 for that program.
- `<C-d>` shows `latest_digest` in a scratch buffer (`nofile`, `nomodifiable`,
  filled with `readfile`, never `:edit`, so the private path does not land in
  shada/oldfiles). "No digest yet" if null or missing. The title shows the
  digest's age. Digests are the only place resolved items appear, since the read command returns open items only.

### Screen 2 -- Sessions of one program

- **Flagged view (default):** the sessions named by the program's items,
  with the session holding the top item sorted first (also first in the All
  view) so `<CR>` jumps straight to it.
  Rows are **item-driven**: built from `items[].sessions`, then left-joined to
  `oc-session-list` rows by id for state glyph and age. So a flagged session
  still appears when it is archived, automated (lgtm origin -- the automated
  filter is off here), or deleted from opencode; missing annotations fall back
  to `dir_missing = not directory_exists` and title = id.
  Row: `kind badge · state glyph · title │ dir │ age`. A session named by
  several items appears once, with its most urgent badge. Previewer: the text
  of every item naming that session. A session tagged to a different program
  still appears here if this program's item names it.
- **All view (`<C-f>` toggles):** every root session carrying the program's
  tag. A *stable partition* of one CLI result -- flagged first, then the rest,
  each in `oc-session-list` order. This is a partition, not a re-sort, so the
  CLI still owns ordering.
- Subagents are never shown: if an item names a child session, `oc-session-list --ids` annotates the folded root row with `matched_ids` containing the requested ids that resolved into its tree. The picker indexes root rows by `matched_ids`, displaying the launching root session for child items and attaching all child items to the root row.
- `<CR>` jumps using the switcher's existing decision/exec path: focus the tab
  here, switch tmux pane to the nvim that has it, or `oc-auto-attach` a new
  tab. A missing directory refuses with a warning.
- `<C-b>` returns to Screen 1 with the cursor restored: close, then
  `vim.schedule` a reopen with telescope's `default_selection_index`. Its
  interaction with the switcher's `sorting_strategy = "descending"` is pinned
  by a test.

### Out of scope (deliberately)

- Ack/snooze/mark-done of items: the stall-watcher has no inbound path.
  Items clear when the human acts in the session and goose notices.
- A digest-history screen: one key to the latest digest suffices for now.
- Live refresh while open: data is fetched per open; the source changes
  every 15 minutes at most.

## Data flow

At open, in order, all async:

1. Run the read command (explicit timeout, ~5 s).
2. `oc-tags sessions <tag>` for each program -> tagged root ids.
3. One `oc-session-list --with-state --fold --ids <union>` over item session
   ids plus tagged ids.
4. Capture the tmux client once (`exec.tmux_client`) for later jumps.

Why `--ids`: the switcher's normal window (50, or 200) holds only a small
fraction of these sessions -- measured, most item sessions and most tagged
sessions fall outside it -- so joining against the default listing would
leave most rows blank.

## Components

- `oc-session-list --ids <sid,...>` (new flag, generic): route the ids through
  the existing `queryTreesForSessions` (already used for the overlay union),
  then the usual state + fold. Resolves child -> root, computes
  `dir_missing`/`effective_state`/`automated`, owns ordering. Tested in
  `pkgs/oc-session-list/test.sh`.
- `oc-tags sessions <tag>` (new subcommand, generic): newline-separated root
  session ids carrying a tag. Keeps tags.db knowledge inside oc-tags rather
  than coupling `oc-session-list` to it. Tested in oc-tags' suite.
- `assets/nvim/lua/user/stallwatch_picker/`:
  - `source.lua` -- the async snapshot fetch above; decode, error, version.
  - `model.lua` (pure) -- program rows, flagged/all session rows, the
    left-join and fallbacks, dedupe, badge precedence, previewer text.
  - `spec.lua` (pure) -- entry formatting, titles, glyphs.
  - `init.lua` -- the thin telescope layer: two pickers, mappings, back-nav.
  - Jumping reuses `session_switcher` `flow.new{}:accept(row, cb)` ->
    `act.decide` / `exec` / `discovery`. `decide` needs only `row.id` and
    `row.dir_missing`, which the join always supplies.

Pure modules never `require("telescope")`, so they load under CI.

## Failure handling

| Condition | Behaviour |
|---|---|
| read command not executable | `<leader>fp` not registered |
| command exits 1 with `{error}` | notification with the error; no picker. `error` is checked before `version` |
| command exits non-zero with no JSON | notification with its stderr |
| command times out (a tick holds the DB) | "stall-watch busy, retry" |
| `version ~= 1` | refuse, say so |
| zero programs | "no programs registered" |
| optional field missing | tolerated; that part of the row is blank |
| oc-tags / oc-session-list fail | flagged view still works from item data alone; ⚠ in title |
| session or directory gone | existing jump checks refuse with a warning |
| no digest | `<C-d>` says "no digest yet" |

## Testing

- Unit tests for `model`/`spec`/`source` in the existing `nvim --clean -l`
  harness against a synthetic v1 fixture; wired into `checks.nvim-lua` with
  pinned counts (and reachable per `checks.test-reachability`).
- A field-presence test: every field the picker reads exists in the fixture,
  so contract drift updates the fixture deliberately.
- oc-tags subcommand tested in its own suite; `oc-session-list --ids` in
  `pkgs/oc-session-list/test.sh` (child id -> root row, archived excluded,
  unknown id ignored). An id the CLI drops (archived, unknown) still renders
  in the flagged view from item data alone.
- Model tests cover the item-driven cases: archived, automated, deleted
  session, missing optional fields, zero programs.
- Manual acceptance against the live command before completion; nothing from
  that run is committed.
