# Claude Max quota follow-ups: plan (2026-11-23)

Epic `workstation-ynoq`. This plan follows the analysis in
`docs/research/2026-11-23-claude-max-quota-budget.md` (#922). Jonathan agreed
the following on 11-22 at 23:45Z:

- **(a) and (c) now.**
  - (a) is the cache-TTL experiment on one eternal-machinery runner.
  - (c) is the exhaustion forecast, plus Max-only filters and an
    account-weeks column in session-tags.
- **(b) and (d) later**, decided on the numbers. (b) is the budgets; (d) is
  moving subagents to sonnet.
- **Separate their effects.** stall-watch's 11-22 changes are expected to
  help on their own, so the measurement has to tell their effect apart from
  (a)'s. They are listed under (a) below.

## (a) 1-hour cache TTL on one runner (`ynoq.1`)

### Mechanism

- **Code:** johnnymo87/teamclaude#6, deployed on devbox by workstation #924.
- **Upgrade rule:** teamclaude adds `ttl: "1h"` to bare ephemeral
  `cache_control` blocks. It does this only for requests whose
  `x-session-affinity`, `x-session-id` or `x-parent-session-id` header is
  listed in `~/.config/teamclaude-cache-ttl.json`.
  - That file is not a credentials file.
  - It is re-read whenever its modification time changes.
  - If it is missing, the feature is off.
- **Ledger:** `~/.local/state/teamclaude/usage.jsonl`, one line per response
  for every session.
  - Tokens by class, with cache writes split into 5m and 1h.
  - The 7d and 5h utilization from that response's own headers
    (`util7d_source: "response"`).
- **Upstream support:** checked before building. A request through cfp-shaper
  with `ttl:"1h"` returned `usage.cache_creation.ephemeral_1h_input_tokens > 0`
  on the Max pool.

### Test subject

- **Runner:** the chargen eternal-machinery runner, session
  `ses_fb1340bebffeFhaVdt5nKr1q67`, starting with W24 (wake 11-23 01:51Z).
  Its subagents match through `x-parent-session-id`.
- **Shape of a run:** about 15 minutes of booting; a mint with sleeps of 220 s
  and about 1000 s; a 1–2 h landing with implementer and reviewer subagents;
  a 1500 s CI wait; then idle for about 23 h, apart from swarm messages.
- **Controls:**
  - The same session's earlier runs on the 5-minute TTL: W22 (11-21) and W23
    (11-22, about 01:40–04:50Z).
  - W25 (11-24) or W26 (11-25) switched back to 5 minutes, as an A/B on the
    same procedure.
- **Agents outside opencode:** AgentOS (agno) in-game agents are out of scope.
  They do not send opencode's session headers.

### Confounders deployed on 11-22

| Change | Merged | What it does | What it affects |
|---|---|---|---|
| eng-agent-platform #469 | 20:07Z | Runs a coordinator while its cache is still warm | Coordinator (goose) spend |
| eng-agent-platform #470 | 21:07Z | Presence mode, no delegate window | Coordinator spend |
| eng-agent-platform #471 | 22:33Z | Asks big idle workers to compact while warm | **Worker context size**, including chargen's |

All three landed after W23 and before W24. A raw comparison of W24's spend
against W23's would therefore credit #471's smaller contexts to the TTL.

### Measures, chosen to separate the two effects

1. **Primary, TTL-specific:**
   - **The measure:** P(full rewrite | idle gap of 5–60 min) for the runner's
     messages. A full rewrite is a cache write of at least half the context.
     Pairs that span an account switch are excluded.
   - **Expected values:** about 0.99 under the 5-minute TTL (the 11-14 to 11-22
     baseline: 0.33 at 5–6 min, 0.99 for 6–60 min), and about 0 under the
     1-hour TTL.
   - **Why it isolates the TTL:** context size does not enter this ratio, so
     #471 cannot move it. #469 and #470 do not touch workers at all.
2. **Cost per idle gap:**
   - **Benefit:** the rewrite tokens avoided, estimated as context size at the
     gap times the gap count.
   - **Premium:** every 1h cache write the runner made (from the ledger's
     `cache_write_1h`) times (2.0 − 1.25) / 1.25 = 0.6 extra cost.
   - **How it converts:** to list price first, and to account-weeks with the
     token-to-quota weights from `ynoq.2`.
3. **Pool level, for the 11-22 changes:**
   - **Measures:** devbox's daily cache-write tokens from full rewrites after
     idle, with the runner excluded; and devbox goose (coordinator) spend.
   - **Comparison:** 11-14 to 11-21 against 11-23 onward.
   - **What it attributes:** the drop to #471 (worker contexts) and to #469
     and #470 (coordinators). The runner's own saving is reported separately,
     by measure 1.
4. **Account stickiness:**
   - The prompt cache is per account. If teamclaude moves the runner to a
     different account between turns, the next turn re-caches whatever the
     TTL.
   - Count account changes per runner gap in the ledger, and report the
     fraction of gaps lost to them.

### Turning it off

Empty the `sessions` list, or delete the file. No restart is needed.

### Status and loss rule (11-23)

- **First result (W24, 11-23).** Use the teamclaude ledger, not the opencode DB. One opencode assistant message can span several LLM requests, so a long tool call such as a 1000 s `sleep` is a cache gap *inside* a message. A message-level count from the DB therefore undercounts gaps: it found 1 for W24, while the ledger shows 11.
  - **Gaps:** all 11 gaps of 5–60 min after the switch were cache hits (main session 9/9, one subagent 2/2). The 5m baseline was 12/12 full rewrites for the runner (11-19..22, DB count) and 10/11 for a 10-min-wake 5m control.
  - **Tokens:** about 1.45M tokens of rewrite avoided, against a 1h premium of about 0.27M (0.6 × 456k 1h writes). The net saving is about 1.2M 5m-write-equivalents, roughly $6 at list rate for one W24 run.
  - **One loss:** a short subagent with no gaps, which paid a 76k-token premium for nothing. Subagents match through their parent, so this loss cannot be excluded on its own.
  - **Scripts:** the per-session tally is `loss.py` and the DB count is `m1.py`. Both are described in bead `workstation-ynoq.1`.
- **Loss rule (Jonathan, 11-23).** 1h costs more whenever a session writes cache that no later 5–60 min gap reuses. At each re-measure, compare each listed session's 1h premium (0.6 × its 1h write tokens) with the rewrite tokens it avoided (cache reads on the first request after each 5–60 min gap). Remove from the list any session where the premium is larger.

### What the devbox move to goose means for this test

Jonathan has a cloudbox session moving all of devbox from opencode to goose. Goose self-compacts idle sessions above 200k context before the cache goes cold. This mechanism cannot follow sessions there:

- **Goose sessions cannot be matched.** goose reaches teamclaude through cfp-shaper (:3457), which drops `x-session-affinity`/`X-Session-Id`, so the ledger records them as `session: null` and no rule can name them. Matching them would need cfp-shaper to forward a session header, or a rule keyed on something else.
- **The runner's result stops at the move.** Once the runner moves, the test ends: its sessions fall back to 5m.
- **The question becomes partly moot.** Goose's compact-before-cold shrinks the context that a cold gap re-caches, the same lever #471 pulls. What remains is the full rewrite of a smaller (≤200k) context after each 5–60 min gap.
- **Re-measuring on goose.** Measure 1 can be re-run there from the goose sessions DB plus the ledger. Whether 1h is worth wiring through cfp-shaper should be decided on that, not on opencode numbers.

## (c1) Exhaustion forecast and the token-to-quota refit (`ynoq.2`)

The cloudbox session `ses_dfb8c2cac…` owns this, under cloudbox bead
`workstation-qn8u`.

- **Forecast:** built from cloudbox's canary
  (`/var/lib/teamclaude-pool-canary/quota-samples.jsonl`). It combines
  headroom Σ(1 − u7d), refills from resets due before T, and the trailing
  12–24 h burn rate. It alerts when projected exhaustion comes before the reset
  that would cover it.
- **Refit:** each week, regress hourly Δu7d on the tokens of each class from
  **both** hosts. Neither host can read the other's files, so the data moves
  through the private repo `johnnymo87/quota-telemetry`:
  - each host pushes hourly aggregate rows, with one file per host per ISO
    week;
  - row shape:
    `{host, hour_utc, account, model, input, cache_read, cache_write_5m, cache_write_1h, output, requests}`.
- **Who writes what:**
  - devbox's exporter is built from the teamclaude usage ledger (this
    workstream).
  - cloudbox's exporter is built from cfp's `events.jsonl`, and so is the
    reader (cloudbox).

## (c2) session-tags Max filters (`ynoq.3`)

Owned here; oc-tags has one editor.

- `--provider <id>` filters opencode rows by `providerID`. On devbox, Max is
  `anthropic`.
- `--backend max` on cloudbox joins cfp `events.jsonl` usage rows to route rows
  on `requestId`, then maps `sessionId` to its root tag. `ses_` ids are
  opencode; `YYYYMMDD_N` ids are goose, with root `goose:<id>`.
- An account-weeks column: list $ divided by a configurable $ per
  account-week, with a default of 1,520 at opus-5-5 list price until
  `ynoq.2`'s refit replaces it.

## Correction to #922

**devbox goose is not on codex-lb.** `goose-serve` defaults to provider
`anthropic`, through cfp-shaper on `:3457` and then teamclaude.

Over the last 7 days devbox goose ran 7 opus sessions: about 340M cache read,
97M cache write and 2.2M output. That comes to roughly $600 a week at list, or
about 0.4 account-weeks. It is a lower bound, because goose's own counters
undercount on cloudbox.

**Effect on #922's figures:**
- devbox becomes about 4.2 account-weeks a week and cloudbox about 2.8.
- The total stays about 7.0, because the calibration is fixed by the canary.
- eternal-machinery's share does not change much: about 3.1–3.3.
- "Stall-watch coordinators cost nothing on devbox" is wrong. They cost about
  0.4 account-weeks or more, which is what #469 and #470 target.
