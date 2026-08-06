# oc-context

Answers one question cheaply, for a whole swarm at once: **which sessions
should compact?**

```
$ oc-context
  %CTX    TOKENS   WINDOW  MODEL                  STATE     MEAS  CMPCT  SESSION                        DIRECTORY
-----------------------------------------------------------------------------------------------------------------
  60.5    604.8k    1.00M  claude-opus-5          idle        7m    32h  ses_0367a8ed4ffe82kh4yhsjiAX5g /home/dev/projects/salmon-of-knowledge
  55.7    557.3k    1.00M  claude-opus-5          working     5s     3h  ses_04c94d863ffetgzzCqk05zqlo0 /home/dev/projects/salmon-of-knowledge
  48.9    489.0k    1.00M  claude-opus-5          idle       43m      -  ses_02d1425f9ffemZsLBGYLI2ZMxc /home/dev/projects/mono/.worktrees/earmark-ripout
  ...
   n/a         -        -  -                      idle!        -      -  ses_03600ab35ffe3otOTNs09qD6QF /tmp/wake-prune-test2
```

Default scope is **live sessions** — every session with a fresh serve
heartbeat in `~/.local/share/opencode/session-state.d`, i.e. an attached TUI.

## Usage

    oc-context                          # live sessions, fullest first
    oc-context --recent 12              # root sessions updated in the last 12h
    oc-context ses_abc… ses_def…        # specific sessions (children allowed)
    oc-context --children               # include subagent child sessions
    oc-context --min-percent 50         # only the ones near the edge
    oc-context --json                   # machine-readable
    oc-context --no-server              # skip the front door, use models.json

Columns: `%CTX` percent of window used · `TOKENS` estimated live context ·
`MEAS` age of the measurement (the last completed assistant turn) · `CMPCT`
time since this session last compacted · `STATE` from the session-state
overlay (`working`/`idle`, `!` suffix = the session is in an error state).

## What the number IS

For each session, the **last assistant message that is not a compaction
summary** and that carries non-zero token accounting, reported as its
`tokens.total`:

    total = input + output + reasoning + cache.read + cache.write

`input + cache.read + cache.write` is the prompt the provider actually billed
for that request — the context size **at** that request. Adding
`output + reasoning` accounts for the reply, which joins the next request's
prompt. So the figure is a forward estimate of the **next** request's prompt
size in that session.

This is the same quantity OpenCode's TUI footer shows, with one deliberate
difference (below).

### Measured, not asserted

**Ground truth check.** The token fields in `opencode.db` were cross-checked
against the aigateway proxy ledger (`gateway_request_log`), a wholly separate
instrument that parses Vertex's own usage block off the wire. For session
`ses_0367a8ed4…`, four consecutive requests matched **exactly** on every field:

| DB `input/output/cache.write/cache.read` | gateway `input/output/cache_creation_5m/cache_read` |
|---|---|
| 2 / 157 / 1601 / 599510 | 2 / 157 / 1601 / 599510 |
| 2 / 1259 / 859 / 601111 | 2 / 1259 / 859 / 601111 |
| 2 / 825 / 1307 / 601970 | 2 / 825 / 1307 / 601970 |
| 2 / 577 / 903 / 603277  | 2 / 577 / 903 / 603277  |

The gateway's own `total_context_tokens` (604,182 for the last one) equals
`input + cache_write + cache_read` — i.e. exactly the prompt-size decomposition
this tool relies on. `tokens.total` = that, plus output.

**Forward-estimate error.** Over 8,291 consecutive same-model message pairs on
cloudbox in a 24h window, `next request's actual prompt − previous message's
total` was:

| p05 | p25 | median | p75 | p95 | within ±2,000 |
|---|---|---|---|---|---|
| +13 | +78 | **+292** | +1,128 | +5,244 | 86% |

Per model: opus-5 median +239 (89% within 2k), opus-4-8 +191 (90%),
gemini-3.6-flash +598 (77%), fable-5 +1,423 (59%).

The bias is positive — the estimate runs **low** — because content added since
the last completed request is not in it.

### The compaction trap (why this differs from the TUI)

OpenCode's TUI picks `findLast(role === "assistant" && tokens.output > 0)`. A
compaction call *is* an assistant message with output, but it runs on a
different, cheap model (here `gemini-3.6-flash`) against the **pre**-compaction
transcript. Observed in a real session:

| # | agent | model | tokens.total |
|---|---|---|---|
| 153 | build | claude-opus-5 | 677,643 |
| 154 | compaction | gemini-3.6-flash | 210,497 |
| 155 | build | claude-opus-5 | 287,878 |

The TUI reports 210,497 against gemini's 1,048,576 window for the whole gap
between #154 and #155 — the compaction model's own usage, divided by the wrong
window. `oc-context` skips `summary: true` messages, so after a compaction it
reports the last *real* turn (#153, stale-but-honest) until #155 lands. `MEAS`
tells you how stale, and `CMPCT` tells you a compaction has happened since.

## What it does NOT capture

- **Anything added since the last completed assistant turn.** A user message
  you just typed, a queued prompt, a large tool result not yet sent. This is
  the +292-median / +5.2k-p95 gap above. A session that just swallowed a 100k
  file will under-report until its next turn completes.
- **Sessions with no completed assistant turn.** Reported as `n/a`, never as
  `0%`.
- **Mid-turn state.** The figure is the last *completed* request. A session
  that has been `working` for two minutes is already past it.
- **Subagent context.** Child sessions are excluded unless `--children` or
  named explicitly. A `Task` subagent's context is its own and dies with the
  task; it does not add to the parent.
- **Whether the window is real.** `WINDOW` is OpenCode's configured
  `limit.context` (from the live `/config/providers`, else the models.dev
  cache), not something verified against the provider.
- **Model changes mid-session.** The window shown is the *last message's*
  model's. Switch models and the percentage is re-based.
- **The auto-compaction threshold.** OpenCode would auto-compact at
  `limit.context − min(20_000, limit.output)`… but this repo ships
  `compaction: { auto: false, prune: false }`, so nothing will compact for you.
  That is the whole reason this tool exists; it deliberately does not print a
  threshold that is switched off.
- **Non-token context pressure.** Nothing here says whether the context is
  *usefully* full or full of stale tool output.

## Sources

| Thing | Where |
|---|---|
| Tokens per message | `~/.local/share/opencode/opencode.db`, `message.data` JSON (read-only) |
| Live session set | `~/.local/share/opencode/session-state.d/*.json` heartbeats |
| Context windows | `GET /config/providers` on the front door (`:4700`), else `~/.cache/opencode/models.json` |

The front door is used, never an individual serve — see the opacity guard in
`users/dev/test-frontdoor-opacity.sh`.

## Tests

    python3 pkgs/oc-context/test_oc_context.py

39 stdlib-`unittest` tests over temp sqlite fixtures; no network. Wired into CI
as the `oc-context` flake check.
