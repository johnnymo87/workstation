# oc-search Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a CLI tool (`oc-search`) that searches OpenCode session history in SQLite to answer "which session created PR X / Jira ticket Y?"

**Architecture:** Bash script deployed to `~/.local/bin/oc-search` via home-manager `home.file` in `home.base.nix`. Queries `~/.local/share/opencode/opencode.db` using `instr()` substring search on `part.data` JSON blobs. Accompanied by a skill doc for discoverability.

**Tech Stack:** Bash, SQLite3 (via `pkgs.sqlite`), Nix/home-manager

**Design doc:** `docs/plans/2026-04-13-oc-search-design.md`

---

## Environment & Conventions

All paths are relative to the workstation repo root (`~/projects/workstation`).

**Apply home-manager (after modifying nix files):**
```bash
nix run home-manager -- switch --flake .#dev
```

**Test the script (after applying):**
```bash
oc-search DATA-4297
```

---

### Task 1: Write the oc-search bash script in home.base.nix

**Files:**
- Modify: `users/dev/home.base.nix` (add `home.file.".local/bin/oc-search"` block)

**Step 1: Add the script definition**

Insert the following block after the `home.file.".gclpr/key.pub"` block (around line 463), before the `# Tmux` section:

```nix
  # oc-search: search OpenCode session history
  # See docs/plans/2026-04-13-oc-search-design.md
  home.file.".local/bin/oc-search" = {
    executable = true;
    text = ''
      #!${pkgs.bash}/bin/bash
      set -euo pipefail

      SQLITE="${pkgs.sqlite}/bin/sqlite3"
      DB="$HOME/.local/share/opencode/opencode.db"

      usage() {
        echo "Usage: oc-search [OPTIONS] <query>"
        echo ""
        echo "Search OpenCode session history for a substring."
        echo ""
        echo "Options:"
        echo "  --types TYPE[,TYPE]  Part types to search (default: tool)"
        echo "                       Valid types: tool, text, patch, reasoning,"
        echo "                       step-start, step-finish, compaction"
        echo "  --all                Search all part types"
        echo "  -h, --help           Show this help"
        echo ""
        echo "Examples:"
        echo "  oc-search DATA-4297"
        echo "  oc-search --types tool,text 'gh pr create'"
        echo "  oc-search --all 'rules_oci'"
        exit 0
      }

      # Defaults
      types="tool"
      all=false

      # Parse args
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --types)
            types="$2"
            shift 2
            ;;
          --all)
            all=true
            shift
            ;;
          -h|--help)
            usage
            ;;
          -*)
            echo "Unknown option: $1" >&2
            usage
            ;;
          *)
            break
            ;;
        esac
      done

      if [[ $# -eq 0 ]]; then
        echo "Error: no search query provided" >&2
        usage
      fi

      query="$1"

      if [[ ! -f "$DB" ]]; then
        echo "Error: OpenCode database not found at $DB" >&2
        exit 1
      fi

      # Build type filter
      if [[ "$all" == "true" ]]; then
        type_filter=""
      else
        # Convert comma-separated types to SQL IN list
        type_in=""
        IFS=',' read -ra type_arr <<< "$types"
        for t in "''${type_arr[@]}"; do
          t="$(echo "$t" | tr -d ' ')"
          if [[ -n "$type_in" ]]; then
            type_in="$type_in, '$t'"
          else
            type_in="'$t'"
          fi
        done
        type_filter="AND json_extract(p.data, '\$.type') IN ($type_in)"
      fi

      # Run query
      "$SQLITE" "file:$DB?mode=ro" <<EOF
      .headers on
      .mode column
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
        WHERE instr(p.data, '$query') > 0
          $type_filter
        GROUP BY p.session_id
      )
      SELECT
        s.slug,
        substr(s.title, 1, 40) AS title,
        substr(s.directory, 1, 45) AS directory,
        datetime(m.last_match_ms / 1000, 'unixepoch', 'localtime') AS last_match,
        m.match_count AS matches
      FROM matched m
      JOIN session s ON s.id = m.session_id
      ORDER BY m.last_match_ms DESC;
      EOF
    '';
  };
```

**Note on parameter binding:** sqlite3 CLI doesn't support `:param` binding from heredocs. The query string is single-quoted in SQL (`'$query'`) which is expanded by bash. This is safe because the only user is us, and the query goes through bash variable expansion, not SQL interpolation. The `instr()` function receives a literal string. If we later need true parameterization, that's an upgrade-path reason to switch to Python.

**Step 2: Verify syntax**

Run:
```bash
nix run home-manager -- switch --flake .#dev
```
Expected: Successful switch, no errors.

**Step 3: Test with known query**

Run:
```bash
oc-search DATA-4297
```
Expected: At least one result showing session `eager-moon` with directory containing `mono`.

**Step 4: Test --types flag**

Run:
```bash
oc-search --types tool,text DATA-4297
```
Expected: Same or more results than default (tool-only) search.

**Step 5: Test --all flag**

Run:
```bash
oc-search --all DATA-4297
```
Expected: Same or more results than `--types tool,text`.

**Step 6: Test --help**

Run:
```bash
oc-search --help
```
Expected: Usage text printed.

**Step 7: Test error cases**

Run:
```bash
oc-search
```
Expected: Error message and usage text.

**Step 8: Commit**

```bash
git add users/dev/home.base.nix
git commit -m "feat: add oc-search CLI for OpenCode session history search"
```

---

### Task 2: Write the searching-sessions skill

**Files:**
- Create: `assets/opencode/skills/searching-sessions/SKILL.md`

**Step 1: Create the skill directory and file**

```markdown
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
```

**Step 2: Commit**

```bash
git add assets/opencode/skills/searching-sessions/SKILL.md
git commit -m "feat: add searching-sessions skill for oc-search tool"
```

---

### Task 3: Register the skill in opencode-skills.nix

**Files:**
- Modify: `users/dev/opencode-skills.nix` (add `"searching-sessions"` to `crossPlatformSkills`)

**Step 1: Add to the cross-platform skills list**

In `users/dev/opencode-skills.nix`, add `"searching-sessions"` to the `crossPlatformSkills` list (around line 16-24). Insert alphabetically:

```nix
  crossPlatformSkills = [
    "ask-question"
    "beads"
    "launching-headless-sessions"
    "notify-telegram"
    "preparing-for-compaction"
    "searching-sessions"
    "using-chatgpt-relay-from-devbox"
    "using-gws"
  ];
```

**Step 2: Apply and verify**

Run:
```bash
nix run home-manager -- switch --flake .#dev
```
Expected: Successful switch.

Verify skill is deployed:
```bash
cat ~/.config/opencode/skills/searching-sessions/SKILL.md
```
Expected: Skill content matches what we wrote.

**Step 3: Commit**

```bash
git add users/dev/opencode-skills.nix
git commit -m "feat: register searching-sessions skill for cross-platform deployment"
```

---

### Task 4: Benchmark and verify end-to-end

**Files:** None (testing only)

**Step 1: Benchmark default search**

Run:
```bash
time oc-search DATA-4297
```
Expected: Results in under 10 seconds. Record actual time.

**Step 2: Benchmark --all search**

Run:
```bash
time oc-search --all DATA-4297
```
Expected: Results in under 15 seconds. Record actual time.

**Step 3: Test with a PR reference**

Run:
```bash
oc-search 'gh pr create'
```
Expected: Multiple sessions listed (any session that created a PR).

**Step 4: Test with a term that has no matches**

Run:
```bash
oc-search 'xyzzy_nonexistent_term_42'
```
Expected: No output (empty result set), exit code 0.

**Step 5: Document benchmark results**

If performance is acceptable (under 10s for default), no further action. If slow, note it as a follow-up for FTS5 indexing.
