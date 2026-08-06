---
name: searching-sessions
description: Use when searching OpenCode session history for PRs, Jira tickets, commands, or any text across past sessions.
---

# Searching OpenCode Sessions

Search session transcripts with `oc-search`. Run `oc-search --help` for all options.

## Quick Start

```bash
# Which session created a Jira ticket?
oc-search DATA-4297

# Which session opened a PR?
oc-search 'gh pr create'

# Search conversation text too, not just tool calls
oc-search --types tool,text 'authentication'

# Search everything
oc-search --all 'rules_oci'
```

## Resuming a Found Session

Output's first column is the session `id` (e.g. `ses_2645cd242ffewHTsOoDmVVWW9a`). Pass it to `opencode -s` from the session's directory:

```bash
cd <directory-from-output>
opencode -s <id-from-output>
```

The full id is required — slugs are not unique and `opencode -s` won't accept them.

## If it is slow, you are missing the index

```bash
oc-search --index-info     # is there one, and how far behind is it?
oc-search --index          # build or catch it up
```

Searches are **correct either way** — without an index oc-search falls back to
scanning all 4.1 GB of transcript, which takes minutes and says so on stderr.
A stale index is also safe: everything newer than the index watermark is
resolved by a bounded tail scan.

The first build is a deliberate act: **~80 minutes and ~10.9 GB** in
`~/.cache/oc-search`. Check `df -h` first. After that an hourly user timer
(`oc-search-index.timer`) keeps it caught up in about a second a run — but it
runs `--index --if-exists`, so it will never create an index you did not ask
for.

## Calling it from a script

- Substring semantics are byte-exact and case-sensitive.
- No matches: empty stdout, exit **0**, a note on stderr.
- Gave up: exit **2**, reason on stderr. When stdout is not a TTY oc-search
  enforces its own 25s deadline (`--timeout` to change) specifically so a
  caller gets a diagnosable error rather than having to SIGTERM it.
- `--json` for structured output; `--` before a query that starts with `-`.

## How It Works

Queries the global OpenCode SQLite DB at `~/.local/share/opencode/opencode.db`
(read-only), against a sidecar FTS5 trigram index in `~/.cache/oc-search/`.

Default scope is `tool` parts only (e.g. gh/kubectl commands and outputs). Use `--types` or `--all` for broader search.

## Database

Single global DB. Schema: `project -> session -> message -> part`. Content lives in `part.data` (JSON). Part types by size:

| Type | Content | Default? |
|------|---------|----------|
| tool | shell/tool commands, inputs, outputs | Yes |
| text | Conversation text | No |
| patch | File diffs | No |
| reasoning | Model reasoning | No |
| step-start/finish | Metadata | No |

## Design Decisions

| Decision | Chosen | Note |
|----------|--------|------|
| Search | FTS5 trigram sidecar index, exact-substring | was an `instr()` scan; measured at 4-6 min |
| Staleness | Tail-scan above the index watermark | stale index costs time, never truth |
| Fallback | 16-way parallel scan, loud on stderr | when there is no usable index |
| Scope | Tool parts only by default | `--types` / `--all` |
| Output | Summary table | `--json` flag |
| Language | Python (stdlib only) | was bash; matches `oc-context` |
| DB access | Read-only (`mode=ro`), index kept in `~/.cache` | `opencode.db` is never written |

Measurements, and the lgtm timeout this fixed: `pkgs/oc-search/README.md`.
Original design: `docs/plans/2026-04-13-oc-search-design.md`
