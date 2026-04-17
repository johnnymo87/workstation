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

## How It Works

Queries the global OpenCode SQLite DB at `~/.local/share/opencode/opencode.db`. Searches `part.data` JSON blobs using `instr()` substring matching.

Default scope is `tool` parts only (gh/acli commands and outputs). Use `--types` or `--all` for broader search.

## Database

Single global DB. Schema: `project -> session -> message -> part`. Content lives in `part.data` (JSON). Part types by size:

| Type | Content | Default? |
|------|---------|----------|
| tool | gh/acli commands, inputs, outputs | Yes |
| text | Conversation text | No |
| patch | File diffs | No |
| reasoning | Model reasoning | No |
| step-start/finish | Metadata | No |

## Design Decisions

| Decision | Chosen | Upgrade path |
|----------|--------|--------------|
| Search | `instr()` scan (~few seconds) | FTS5 index if too slow |
| Scope | Tool parts only by default | `--types` / `--all` |
| Output | Summary table | `--json` flag |
| Language | Bash | Python if string handling gets painful |
| DB access | Read-only (`mode=ro`) | n/a |

Full rationale: `docs/plans/2026-04-13-oc-search-design.md`
