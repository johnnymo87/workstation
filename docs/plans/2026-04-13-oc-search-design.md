# oc-search: OpenCode Session Search CLI

**Goal:** Answer "which session created PR X?" or "which session created Jira ticket Y?" by searching the OpenCode SQLite database from the command line.

**Architecture:** A bash script at `~/.local/bin/oc-search` queries `~/.local/share/opencode/opencode.db` using substring search on `part.data` JSON blobs. Deployed via home-manager `home.file`. Accompanied by a skill doc at `assets/opencode/skills/searching-sessions/SKILL.md`.

## Why not existing tools

We evaluated community plugins (opencode-mem, opencode-agent-memory, opencode-working-memory, claude-mem-opencode). All are persistent-memory systems that store AI-extracted summaries in separate vector databases. None search the actual session transcript data. OpenCode has no built-in full-text search across session content -- only title search via `/sessions`.

## Usage

```bash
oc-search DATA-4297                      # search tool-call parts only (default)
oc-search --types tool,text DATA-4297    # search specific part types
oc-search --all DATA-4297                # search all part types
```

**Output:** Summary table sorted by last match timestamp (descending).

```
SLUG         TITLE     DIR                     LAST MATCH           MATCHES
eager-moon   SC int    /home/dev/.../mono      2026-04-10 14:08     3
```

## Database

Single global SQLite DB at `~/.local/share/opencode/opencode.db` (4.2 GB + 2.1 GB WAL as of April 2026). Schema:

```
project  1──M  session  1──M  message  1──M  part
```

Content lives in `part.data` (JSON blobs, ~475 MB across 170K rows). Part types by size:

| Type | Count | Size (MB) | Content |
|------|-------|-----------|---------|
| tool | 53K | 423 | gh/acli commands, inputs, outputs -- **primary search target** |
| text | 19K | 21 | Conversation text from user and assistant |
| patch | 15K | 10 | File diffs |
| reasoning | 11K | 12 | Model reasoning traces |
| step-start/finish | 71K | 10 | Metadata (snapshots, token counts) |
| compaction | 59 | 0 | Compaction markers |

## SQL query

```sql
PRAGMA query_only=ON;
PRAGMA busy_timeout=2000;
PRAGMA temp_store=MEMORY;
PRAGMA cache_size=-65536;

WITH matched AS (
  SELECT
    p.session_id,
    COUNT(*) AS match_count,
    MAX(p.time_created) AS last_match_ms
  FROM part p
  WHERE json_extract(p.data, '$.type') IN (${type_list})
    AND instr(p.data, :query) > 0
  GROUP BY p.session_id
)
SELECT
  s.slug,
  s.title,
  s.directory,
  datetime(m.last_match_ms / 1000, 'unixepoch', 'localtime') AS last_match,
  m.match_count
FROM matched m
JOIN session s ON s.id = m.session_id
ORDER BY m.last_match_ms DESC;
```

Key choices in the query:

- **`instr()` not `LIKE`** -- user input is a literal substring, not a pattern. `LIKE` treats `%` and `_` as wildcards, requiring escaping. `instr()` avoids that.
- **`json_extract` only for type filtering** -- extracting specific JSON fields for the search predicate is slower (SQLite converts text JSON to internal JSONB on every row) and fragile against schema drift. Raw blob search catches all fields.
- **Parameterized query** -- user string passed as a bound parameter, never interpolated into SQL.
- **DB opened read-only** (`file:...?mode=ro`) -- we never modify the DB.

## Scope control

| Flag | Part types searched | Use case |
|------|-------------------|----------|
| (default) | `tool` | "Who created this PR/ticket?" |
| `--types tool,text` | Explicit list | Targeted search |
| `--all` | All types | Exhaustive grep |

`step-start`, `step-finish`, and `compaction` parts are mostly metadata noise but included with `--all` for completeness.

## Deployment

Inline bash in `home.base.nix` via `home.file.".local/bin/oc-search"`, same pattern as `ensure-projects`. Uses `${pkgs.sqlite}/bin/sqlite3` (pinned Nix store path, no nix-shell overhead). Available on all platforms after `home-manager switch`.

Skill registered in `opencode-skills.nix` under `crossPlatformSkills`.

## Design decisions

| Decision | Chosen | Rationale | Upgrade path |
|----------|--------|-----------|--------------|
| Search method | `instr()` scan | Simple, ~few seconds on 475MB, occasional use | FTS5 index if DB grows or search becomes frequent |
| Type filtering | `json_extract` for `$.type` only | Coarse filter is cheap; fine-grained field extraction is slower and fragile | Add `--field` flag for targeted extraction |
| Default scope | `tool` parts only (423 MB) | Directly answers "who created X" | `--types` for explicit control |
| Output format | Summary table | Quick human scan | Add `--json` flag for composability |
| Language | Bash | Matches repo conventions (ensure-projects, pull-workstation) | Rewrite in Python if string/JSON handling becomes painful |
| Deployment | `home.file` inline | Versioned, reproducible, lightweight | Nix package in `pkgs/` if it grows |
| sqlite3 | `pkgs.sqlite` store path | No nix-shell startup overhead | Already solved |
| DB access | `mode=ro` + `PRAGMA query_only=ON` | Read-only; never modify the live DB | n/a |
| WAL handling | None (let SQLite handle it) | SQLite reads WAL transparently; checkpointing is the writer's concern | Separate maintenance script if needed |
| Pragmas | `busy_timeout=2000`, `temp_store=MEMORY`, `cache_size=-65536` | Tolerate concurrent writes; keep temp data in memory; 64 MiB page cache | Tune after benchmarking |

## YAGNI

Not building: FTS5 index, vector/semantic search, MCP server, OpenCode custom tool, web UI, persistent index, watch mode, `message.data` search (it's role/agent/token metadata).

## Deliverables

1. **Script:** `home.file.".local/bin/oc-search"` in `home.base.nix`
2. **Skill:** `assets/opencode/skills/searching-sessions/SKILL.md`
3. **Registration:** Add `"searching-sessions"` to `crossPlatformSkills` in `opencode-skills.nix`
