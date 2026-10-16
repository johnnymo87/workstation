---
name: measuring-session-context
description: Use when deciding which OpenCode sessions should compact, when you need a session's current context size / percent of context window, or when interpreting a token number from opencode.db as "context length". Covers the oc-context CLI and the two ways that number lies.
---

# Measuring OpenCode session context

`oc-context` prints, per session, the estimated live context in tokens, the
model's context window, and the percent used — sorted fullest-first.

```bash
oc-context                 # every session with a live TUI heartbeat
oc-context --recent 12     # root sessions updated in the last 12h
oc-context --min-percent 50
oc-context ses_abc…        # one session (children allowed by name)
oc-context --json
```

Full documentation, measurement methodology, and the verification receipts:
`pkgs/oc-context/README.md`.

## What the number means

The last **non-compaction** assistant message's `tokens.total`
(`input + output + reasoning + cache.read + cache.write`). That is the prompt
the provider billed for that request, plus the reply that joins the next one —
so it is a forward estimate of the **next** request's prompt size.

Verified two ways: field-for-field against the aigateway proxy ledger
(independent wire-level instrument, exact match), and as a forward estimate
over 8,291 consecutive message pairs (median error **+292 tokens**, p95 +5,244,
within ±2k 86% of the time). The bias is positive: it runs **low**.

## Two ways a token number lies

**1. Cumulative ≠ context.** `session.tokens_*` (and `GET /session`) are
*lifetime* sums across every request in the session — hundreds of millions of
cache-read tokens on a long session. They are a cost number, not a context
number. Use `oc-cost` for spend; use `oc-context` for occupancy.

**2. The compaction message.** A compaction runs on a *different, cheap* model
against the *pre*-compaction transcript. OpenCode's own TUI footer does
`findLast(assistant && output > 0)`, picks it up, and divides the pre-compaction
size by the compaction model's window until the next real turn lands.
`oc-context` skips `summary: true` messages for exactly this reason. If the
TUI and `oc-context` disagree right after a compaction, `oc-context` is right.

## Deciding who compacts

Read three columns together:

- `%CTX` — how full.
- `MEAS` — how old the measurement is. A session `working` for minutes has
  already moved past its last number.
- `CMPCT` — time since it last compacted. `-` and a high `%CTX` means it has
  never shed anything.

Do not compact a session whose `STATE` is `working`; wait for `idle`.

**Nothing compacts on its own here.** This repo ships
`compaction: { auto: false, prune: false }` (`assets/opencode/opencode.base.json`),
so the built-in auto-compact threshold never fires. Whoever reads this table is
the mechanism.
