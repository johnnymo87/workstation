# oc-search: opt-in goose transcript search (`--goose`)

Bead: `eng-agent-platform-c87c.2` (epic `eng-agent-platform-c87c`, oc-* tools goose-friendly).

## Goal

`oc-search --goose QUERY` also searches goose session transcripts
(`~/.local/share/goose/sessions/sessions.db`, table `messages`) and merges the
matching goose sessions into the same table/JSON output as opencode sessions.
Without `--goose` the output is byte-identical to today's.

## Why opt-in

oc-search's table is a contract: lgtm (`src/context.ts`
`buildSessionHistorySection`) runs `oc-search --types tool,text --limit 10
<repo>` and pastes the table into a review packet. Its parser only counts
lines (header + rule + rows), so goose rows would not break it, but they would
change what reviewers see. The bead's review note asks for a flag first.
Precedent: `oc-session-list --goose` is also opt-in and uses `goose:<id>` ids.
Flipping the default (and having lgtm pass `--goose`) is a separate follow-up.

## Measured (cloudbox, 2026-11-05)

- goose `messages`: 52,607 rows, 180 MB of `content_json`, 2,889 sessions.
  opencode `part` is ~3.35M rows / >4 GB, which is why it needs an index.
- Live scan with `json_each` + type filter, warm: `mono` 0.26s (21k items,
  1,994 sessions), `workstation` 0.22s, a miss 0.19s. Cold full read ~6s.
  **No index is needed for goose; a live `instr` scan is the design.**
- `content_json` is a JSON array of content items. Item types present:
  `text`, `toolRequest`, `toolResponse`, `thinking`, `error`,
  `actionRequired`. Tool results are `toolResponse` items in user-role rows.
- `messages.created_timestamp` is epoch **seconds**.
- `sessions.session_type`: `hidden` 2,445 sessions (stall-watch coordinator
  sessions whose input is other sessions' transcripts, plus recipe retries),
  `user` 305, `acp` 171, `sub_agent` 6, `scheduled` 1. Hidden sessions hold
  97 MB of the 180 MB and are mostly re-quoted transcripts.

## Design

### CLI

- `--goose`: also search goose transcripts.
- `--goose-db PATH`: goose DB path (default
  `~/.local/share/goose/sessions/sessions.db`); implies `--goose`.
- `--index`, `--index-info`, `--rebuild`, `--if-exists`: unchanged; they never
  touch goose.

### Matching semantics

One match = one content item (the analogue of one opencode `part`), byte-exact
case-sensitive substring (`instr`) over the item's JSON text, like opencode's
`instr(part.data, ?)`.

`--types` maps opencode part types to goose item types:

| opencode `--types` value | goose item types |
|---|---|
| `tool` | `toolRequest`, `toolResponse` |
| `text` | `text` |
| `reasoning` | `thinking`, `redactedThinking` |
| anything else (`patch`, `step-start`, `file`, ...) | none |

`--all` matches every item type. Unknown goose item types are therefore only
reachable with `--all`.

Query shape (one statement, read-only connection, `mode=ro`, `busy_timeout`,
`query_only`):

```sql
SELECT m.session_id, count(*), max(m.created_timestamp)
FROM messages m JOIN sessions s ON s.id = m.session_id, json_each(m.content_json) j
WHERE s.session_type != 'hidden'
  AND json_valid(m.content_json)
  AND instr(m.content_json, :q) > 0          -- cheap prefilter
  AND instr(j.value, :q) > 0
  AND json_extract(j.value, '$.type') IN (...)  -- omitted for --all
GROUP BY m.session_id
```

Use `json_extract`, not `->>` (older SQLite on some hosts).
`last_match_ms = max(created_timestamp) * 1000`.

`hidden` sessions are excluded: goose itself hides them from its session
list, and they are re-quoted copies of other transcripts, so they would
duplicate every opencode hit.

### Output rows

Same keys as opencode rows: `id` = `goose:<session id>` (oc-session-list
convention), `title` = `sessions.name`, `directory` = `sessions.working_dir`,
`last_match_ms`, `matches`. Merged into the opencode rows and sorted by the
existing total order `(last_match_ms DESC, id DESC)`. Table layout unchanged.

### `--limit N`

Goose hits are all computed (cheap). Final rows = top N of (opencode top N ∪
goose hits) under the total order. This is exact: the union's top N is a
subset of each source's top N.

### Failure handling

- goose DB missing or unreadable with `--goose`: one `oc-search: ...` warning
  on stderr, opencode results printed as usual, exit 0.
- The goose query runs under the existing `Deadline`; a deadline trip there
  is the same exit-2 abort as for opencode.
- The "no sessions matched" message covers both sources.

### Name

Stays `oc-search` (precedent: oc-revive, oc-cost).

## Tests (hermetic, `pkgs/oc-search/test_oc_search.py`)

A goose fixture builder (temp `sessions.db` with `sessions` + `messages`
using the real column names). Cases:

1. Without `--goose`, output is unchanged even if a goose DB exists at the
   default path (patch the default path to a fixture DB to prove it is not read).
2. `--goose` merges goose rows with `goose:` ids, title, directory, counts and
   ms timestamps, ordered with opencode rows.
3. `--types` mapping: tool/text/reasoning; `--all`; unmapped type yields no goose hits.
4. Match counted per item, not per message (message with two matching items = 2).
5. `hidden` sessions excluded.
6. `--limit` across both sources picks the right top N.
7. Missing / corrupt goose DB: warning, opencode rows intact, exit 0.
8. Malformed `content_json` row is skipped, not fatal.
9. `--goose-db` implies `--goose`.
10. `--json` rows carry the same keys for both sources.

Module-level guard: tests point the default goose DB path at a nonexistent
temp path so no test reads the real goose DB.

## Docs

README: a "goose transcripts (`--goose`)" section with the table above and
the hidden-session rule. `default.nix` description mentions goose.

## Verification

- `python3 pkgs/oc-search/test_oc_search.py`
- `nix build .#checks.aarch64-linux.oc-search` and test-reachability
- Live: `oc-search --goose --types tool,text --limit 10 mono` on cloudbox,
  and confirm output without `--goose` is byte-identical to `main`'s binary.

## Follow-up (not this PR)

Decide whether `--goose` becomes default and whether lgtm passes it.
