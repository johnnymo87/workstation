# oc-tags: session tagging and a spend-by-tag chart

Date: 2026-09-08
Status: design approved, ready to plan

## Problem

There is no way to ask "which work consumed my LLM budget". opencode records
per-message cost, but nothing groups it by anything a human recognises. The
target artifact is a stacked-area chart: X = time, Y = dollars, one band per
tag, viewable in a browser on the laptop.

## What the number means

**The Y axis is `consumed at list price (USD) — not billed`.**

This wording is load-bearing. Actual metered spend cannot be attributed to
work, and charting it would produce a confident lie. Measured on this host,
30 days, ET buckets:

| day (ET) | metered | notional | ratio |
|---|---|---|---|
| 08-28 | 222 | 1566 | 14% |
| 08-30 | 143 | 143 | 100% |
| 08-31 | 230 | 1355 | 17% |
| 09-04 | 218 | 1115 | 20% |
| 09-08 | 204 | 233 | 88% |
| **30d total** | **$9,133** | **$26,645** | **34%** |

Metered spend is pinned near $210/day by two $100/day budget ceilings
(`CFP_BUDGET_DOLLARS`, `CFP_ENTERPRISE_BUDGET_DOLLARS`, reset hour 0 ET, in
`hosts/cloudbox/configuration.nix:3451-3486`). Everything past the caps spills
to the pooled Claude Max subscription, whose marginal cost is zero. So metered
dollars per tag measure *which work reached the cap first* — i.e. time of day.
Measured per-directory metered/notional ratios ranged 27% (mono) to 100% (lgtm
worktrees) from that effect alone.

List-price consumption is instead proportional to work done and is stable
against routing. It is dominated by context size: of the 84% that is opus-5,
cache-read is ~40% and cache-write ~37% of dollars. The chart therefore
measures **context size × turns**, and the axis label must not overclaim.

Actual money is shown as a separate thin **reference line** ("billed via cfp,
capped $100+$100/day"), never as a band. The headline stat above the chart is
**"cap hit at HH:MM"**, which is the one actionable thing the money side says.

### Source of the dollar figure

Sum the **stored** `message.data->>'$.cost'` for `role=assistant` rows. Do not
recompute from tokens against a local rate book.

Measured 30d, stored (`rec`) vs recomputed via `oc_cost.RATES` (`est`):

| provider/model | msgs | rec | est |
|---|---|---|---|
| vertex-anthropic/opus-5 | 92,723 | $22,403.41 | $22,403.41 |
| vertex-anthropic/fable-5 | 7,481 | $2,832.16 | $2,832.16 |
| vertex-anthropic/fable-5-1 | 3,759 | $583.15 | **$965.83** |
| vertex-anthropic/opus-4-8 | 625 | $261.45 | $261.45 |
| vertex/gemini-3.7 | 12,700 | $247.54 | $247.54 |
| vertex/gemini-3.6 | 2,705 | $140.30 | **$70.15** |
| vertex/gemini-3.8 | 2,521 | $40.54 | $40.54 |
| openai/gpt-5.5 | 25 | $4.28 | $4.28 |

Five material models agree to the cent. In both disagreements the **rate book
is the outlier**: `oc_cost.RATES` has no `claude-fable-5-1` row, so
`rate_for`'s longest-prefix match (`oc_cost.py:152-157`) falls back to
`claude-fable-5` and prices cache_read at $1.00 where three independent sources
(opencode's stored cost, cfp `usage.cost` solved from token counts, and the
aigateway ledger's `cache_read_dollars/cache_read_tokens`) all say $0.25.

Three further reasons stored wins:

1. **Prefix matching converts "unknown model" into "silently wrong price."**
   `claude-opus-5-1` will inherit opus-5 rates the day it ships, with no signal.
2. Stored cost is what opencode's own TUI and session list show. A chart that
   disagrees with the TUI on the same session ($966 vs $583) loses trust on
   first inspection.
3. Zero rate book to own.

Historical note: `pkgs/oc-cost/README.md` documents `$.cost` over-counting
~$2,400 on `claude-opus-4-7` via a models.dev phantom >200K tier. That model is
no longer material (opus-4-8 now matches to the cent). `oc-cost --reconcile`
remains the place where rate-book disagreement is surfaced deliberately.

Correcting `oc_cost.RATES` (add `claude-fable-5-1` at 10/50/0.25/12.5 with a
cited pricing-page source; decide the disputed `gemini-3.6` intro-rate row; make
unknown models fail loud rather than prefix-price) is a **separate correctness
PR against oc-cost**, not a dependency of this work.

### Drift alarm

Two free oracles, rendered in the page footer, both independent of any rate
book:

1. Per-day Σ stored cost for Claude providers vs cfp's `notionalVertexCost`
   from `history.jsonl`. Baseline 0.98; flag outside 0.90–1.05.
2. Coverage note: title-generation calls never produce a message row (~2% gap),
   so the footer states "coverage vs cfp notional: 98%".

## Tags

### Model

Two tables in the sidecar DB:

- `session_tag(session_id TEXT PRIMARY KEY, tag TEXT, created_at INTEGER)`
- `dir_tag(pattern TEXT PRIMARY KEY, tag TEXT, created_at INTEGER)`

**Exactly one tag per session.** A stacked area chart's defining property is
that its top edge equals the total; many-tags-per-session breaks that
arithmetic (a session tagged `{a,b}` costing $100 makes the stack read $200).
The primary key enforces the partition. Additional free-form labels are not in
scope.

Tag strings may contain `/` (e.g. `work/cops-6757`) so prefix grouping is
available later without a schema change. Case-normalised on write.

### Effective tag precedence

1. `session_tag` for the root session, if present (manual, wins)
2. `dir_tag` pattern matching the root session's `directory` (manual, durable,
   covers past and future sessions in one write)
3. `auto:<key>` fallback

### The auto key

- worktree (`.../.worktrees/<slug>`) → `auto:<project>/<slug>` — **keep the
  slug**. Slugs like `fbm-transform-evidence`, `w3-pr2`, `cops-6757-baf-dating`
  *are* the epic signal; stripping them was an error in an earlier draft that
  folded $15k into one undifferentiated `auto:mono` band.
- primary root checkout → `auto:<project>`
- `/tmp/*` → `auto:tmp`

Auto series render desaturated. `oc-tags top` counts auto-tagged roots as
**untagged**, so the tagging backlog stays visible rather than being hidden
behind a plausible-looking label.

### Why manual tagging is still required

Measured, 30d, cost attributed to root session directory:

| bucket | dollars | share |
|---|---|---|
| worktree (slug carries signal) | $9,004 | 34% |
| primary-root `mono` | $8,524 | 32% |
| primary-root `salmon-of-knowledge` | $3,881 | 15% |
| primary-root `workstation` | $3,019 | 11% |
| all other primary roots | ~$2,070 | 8% |

**66% of dollars sit in primary-root sessions, where the directory says
nothing.** Auto-tagging alone answers at most a third of the question. This is
why the manual path is the product, not a nicety — and why `oc-tags top` ranks
primary-root sessions by cost and shows `session.title` (titles like "FBM OOS
webhook investigation" $1,051, "LGTM timer: NYC hours" $1,038 are already good
labels).

Tagging load: ~35–50 roots/week over $10, ~16/week over $50. Directory-pattern
tags plus root-only `top` keep the recurring chore near the latter.

### Rollup

Child sessions (subagents, swarm workers) attribute to their **root**. Walk
`session.parent_id` to the topmost *existing* ancestor, with a visited-set cycle
guard. Measured depth is ≤1 (6,174 children, 5,862 roots), but 983 sessions have
a `parent_id` absent from the table; those must attribute to the topmost
existing ancestor rather than being dropped, or dollars vanish silently.

Retagging is retroactive by design — a session-level tag rewrites that
session's history. `created_at` is audit metadata only.

## Data access

- `opencode.db` opened **read-only** (`file:...?mode=ro`), `busy_timeout` set,
  a fresh connection per request. Never `immutable=1` (WAL needs a writable
  `-shm`, which exists while any serve runs).
- **One SQL aggregate**, not a per-session loop. Measured warm: full-scan
  `GROUP BY session_id` = 0.4 s; a session-first index loop = 0.5 s. Session-first
  buys nothing and costs complexity.
- No rollup/materialised table. Rows are *updated* when a turn completes, so an
  incremental rollup keyed on `time_created` would miss late-landing cost.
- Sidecar at `~/.local/share/oc-tags/tags.db` — its own directory, so an
  `opencode.db` wipe (`fixing-opencode-db`) does not take the tags with it.
- Buckets in **America/New_York**, because the spend caps reset at 0 ET. UTC
  buckets would smear the cap edge across two days. Hourly for windows ≤ 3 days,
  daily beyond (720 hourly bars × 15 series is unreadable and fat).

## Server

`oc-tags serve --port=4710`:

- stdlib `http.server.HTTPServer` bound to `127.0.0.1`
- server-rendered inline SVG; **zero client JavaScript**
- state entirely in GET params (`?days=&bucket=&hide=a,b`), so URLs are
  shareable and the back button works
- Top-N series plus an `other` band
- an `unpriced` band pinned in the legend regardless of Top-N, labelled in
  tokens rather than dollars, so a newly-shipped model can never silently read
  as $0
- the last bucket marked *partial* (in-flight rows carry no cost until the turn
  completes)
- tag strings escaped on render
- a locked database renders an error page, not a dead socket

Run ad hoc. A systemd user unit only once the tool has earned one.

## Exposure

A **separate on-demand `Host cloudbox-chart` block** in
`scripts/update-ssh-config.sh` with `LocalForward 4710 127.0.0.1:4710`.

Not added to the always-on `cloudbox-tunnel` block: that runs under
`ExitOnForwardFailure=yes` from a macOS LaunchAgent, so a port clash on the Mac
would kill the whole tunnel, taking gclpr, chatgpt-relay and the Jenkins :8443
forward with it. (Note the existing `cloudbox-cutover` block is a
`RemoteForward`; this is the opposite direction.)

The chart binds loopback only. It never addresses the serve pool
(`127.0.0.1:4096-4099`), so the front-door opacity guard
(`users/dev/test-frontdoor-opacity.sh`) is not engaged, and it does not route
through the front door — that is a serve proxy, not a dashboard host.

## Packaging

`pkgs/oc-tags`, Python **stdlib only**, `buildPythonApplication`, matching
`pkgs/oc-context` and `pkgs/oc-cost`. No dependency closure.

If any oc-cost helper is ever needed, copy the file into the derivation's
libexec and `sys.path` it (the `install ${../../assets/...}` pattern at
`pkgs/worktree-guard-hook/default.nix:39` is the precedent). Do not convert
oc-cost to `buildPythonPackage`.

## CLI

```
oc-tags set <tag> [session-id]      # defaults to $OPENCODE_SESSION_ID, resolved to root
oc-tags set --dir <path> <tag>      # directory-pattern tag; covers past and future
oc-tags ls [--counts]
oc-tags rm <session-id|--dir <path>>
oc-tags top [--days N]              # highest-dollar roots lacking a manual tag, with titles
oc-tags report [--days N]           # text table: dollars by tag by day
oc-tags serve [--port 4710]
```

`$OPENCODE_SESSION_ID` is injected into every bash call by
`assets/opencode/plugins/shell-env.ts:248`, so an agent can tag its own session
with no argument.

## Ship order

1. `set` / `ls` / `rm` / `top` / `report` — the text table is independently
   useful and proves the tagging habit sticks.
2. `serve` — the chart, same package.

## Testing

A real `checks.oc-tags` entry in `flake.nix` (a `checkPhase` does not count —
`users/dev/test-unwired-tests.sh`), `runCommand` + `test_*.py` against temporary
SQLite fixtures, mirroring `checks.oc-context` / `checks.oc-cost` including the
pinned test count.

Fixtures must include: a dangling `parent_id`, a worktree directory, a
primary-root directory, a `/tmp` directory, an unpriced model, a zero-token
error row, an in-flight row, and an ET bucket boundary. Bucketing, the auto-key
rule, the root walk and the SVG geometry are pure functions and need no socket.

`zoneinfo` needs tzdata inside the `runCommand` sandbox — add
`python3Packages.tzdata` to the check's dependencies or the suite passes locally
and fails only under `nix flake check`.

## Explicitly out of scope

- Drill-down from the chart to sessions, and tag editing in the browser
- Many tags per session
- Any materialised rollup
- Parsing the 70 MB `events.jsonl` at render time (the pre-aggregated
  `history.jsonl`, plus `spend.json` / `spend-enterprise.json` for today, is
  enough for the reference line)
- Gateway-true per-tag dollars (would need session-id propagation into aigateway
  headers and a durable Postgres volume)

## Known limitations to state in the UI

- Title-generation calls never become messages (~2% of notional).
- Requests that error before a usage event are uncounted.
- The chart's history is bounded by opencode.db retention; the documented
  mega-session `DELETE FROM message` remedy in
  `.opencode/skills/triaging-opencode-sluggishness` erases chart history while
  the cfp reference line stays intact.
