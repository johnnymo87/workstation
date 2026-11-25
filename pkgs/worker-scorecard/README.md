# worker-scorecard

Per-worker cost and PR outcome for one program's worker sessions, on both
harnesses (opencode and goose), with a per-arm headline of **total $ / merged
PR**. Built for the goose rollout's stage-1 measurement (bead
`workstation-6w7i.4`, epic `workstation-6w7i`).

    worker-scorecard goose                    # root sessions created in the last 30 days
    worker-scorecard goose --since 2026-11-18 --until 2026-12-02
    worker-scorecard goose --json
    worker-scorecard goose --include ses_... --exclude goose:20261117_4

Read-only everywhere: opencode.db and goose's sessions.db are opened `mode=ro`,
the gateway ledger is SELECTed through psql, lgtm's attribution cache is read,
and GitHub is queried with `gh api graphql`.

## Headline

Per arm: total $ of every worker in the arm (abandoned ones included) divided by
the arm's merged PRs. Not a per-worker median: a median drops the cost of
workers that never merged and rewards splitting work into more PRs.

## Which sessions are workers

The candidates are `session-tags sessions <tag>` (root ids, both harnesses;
goose ids print as `goose:YYYYMMDD_N`) whose root was **created** in the window.
A candidate is a worker when its first user message (the brief) either

- says it was `sent by the <tag> program's stall-watch coordinator` (every
  coordinator brief so far opens that way), or
- carries an arm line (below),

or, for a root created on or after 2026-11-24 00:00 ET, when the tag's own
stall-watch coordinator (a goose session in `coord-sessions/<tag>-<ms>`) has
the launch in its **tool output**: `native=<id> ` from `honk launch`, or
`Session launched: <id>` / `Tagged session '<id>'` / `--session <id>` from
opencode-launch. eng-agent-platform #502 retired the coin flip on 11-24, so
briefs no longer carry an arm line, and their wording varies by coordinator;
text alone cannot tell a coordinator's worker from a worker's sub-worker that
copies its brief (`Model:` line included). Text the coordinator wrote itself
does not count, and neither does a launch by another program's coordinator.
The date gate keeps the stage-1 A/B numbers as they were.

Everything else (a session Jonathan started by hand, a benchmark, a worker's
own sub-worker) is listed under "Excluded" with the reason, its $ and its PR
count, so what was left out stays visible. A bare mention of
"stall-watch coordinators" does not count: sub-worker briefs mention them.
`--include` / `--exclude` override per id.

## Arm

From the brief: `Stage-1 arm: goose` or `Stage-1 arm: opencode`, which
stall-watch's `worker_harness = "ab"` mode writes (6w7i.1). The parser accepts
`arm: <goose|opencode>` anywhere, case-insensitively. A brief without one is in
arm `<harness>-baseline`. A marker that disagrees with the store the session
actually lives in is shown as `(MISMATCH)`.

## Cost basis

Over the whole session tree: the root and every descendant (opencode
`session.parent_id`, goose `sessions.parent_session_id`).

- **Claude**: every call priced from the harness's own tokens at the gateway
  ledger's Opus card: in 4, out 20 (reasoning at out), cache read 0.2, 5-minute
  cache write 5 $/M. Never from the gateway ledger, because cfp's Max overflow
  leaves no ledger row and the ledger alone silently drops Claude calls.
  opencode: `message.data.tokens` (input is already uncached). goose:
  `usage_ledger`, where `input_tokens` includes cache read and write, so uncached
  is `input - cache_read - cache_write`; a goose session whose
  `model_config_json.request_params.cache_ttl` is `1h` has its cache writes
  priced at the gateway's 1-hour rate, 8 $/M (opencode writes only 5-minute
  entries: the gateway has no 1-hour writes from it). Rows without a model
  (`carried_forward`) are skipped with a warning. Non-Opus Claude models are
  priced at the same card and listed in the warnings.
- **Gemini**: `gateway_request_log` rows whose `client_session_id` is in the
  tree, at their recorded dollars. The gateway has recorded session ids only
  since 2026-11-16 23:55Z, so a session's calls from before its first ledger row
  are priced from the harness's tokens at the gateway's own gemini-3.8-flash card
  (0.75 / 3.75 / 0.075 $/M); the worker table shows `(ledger calls / card
  calls)`. On 2026-11-17 the card and the ledger agreed within 1% on four
  subagent sessions. A ledger row is used only inside its session's own
  lifetime (first message - 5 s to last message + 60 s): goose ids
  (`YYYYMMDD_N`) are a per-store counter, and test goose stores send the same
  ids to the same gateway. A model with no price on either side (gemini-4-carbon has
  NULL dollars in the ledger) counts as $0 and is listed in the warnings.
- If psql fails, every Gemini call is priced from the card and the report says
  so.

Wall time is the first to the last message anywhere in the tree. A worker that
was reassigned to new work keeps one root, so its wall time and cost include all
of it.

## PRs and outcomes

PR discovery is lgtm's: its attribution cache
(`~/.local/state/lgtm/shepherd/attribution-cache.json`, written by
`src/prAttribution.ts` and `src/gooseAttribution.ts` from both stores). For each
PR any worker has evidence for (a branch-only candidate whose create named no
`--repo` is found by searching GitHub for my PRs from that head), the scorecard
applies a port of lgtm's
`selectAttribution` / `resolveAttribution` against GitHub's `createdAt` and
`headRefName`, so a PR counts for a worker exactly when lgtm would route that
PR's wakes to it. Keep the port in step with lgtm.

Per PR, from GitHub:

- state: merged / closed / open;
- reverted within 7 days: a PR in the same repo, created within 7 days of the
  merge, whose title contains "revert" and either quotes the title or names
  `repo#N` / `/pull/N` in the body;
- CI-red rounds: PR commits whose check rollup is FAILURE or ERROR. A red run
  that was re-run green on the same commit is not counted;
- review-fix rounds: commits dated after the first review by anyone other than
  the PR's author.

## Step-ins

- **J msgs**: the root session's user messages that are not the brief, not
  synthetic (hook output), not a `<swarm_message>`, and not the agent-written
  resume prompt that follows a compaction. In goose: `turnContext` rows are
  hooks, a `userVisible: false` row is the compaction summary (the resume
  steer after it is skipped), tool responses (stored as role user) are
  ignored, and `agentVisible` is not used, because compaction flips every
  earlier message, the brief included, to `agentVisible: false`. Mid-turn
  steers Jonathan types count.
- **sw msgs**: swarm messages from stall-watch: `from="stall-watch"` (how it
  reaches opencode workers), or a payload opening "From stall-watch's
  coordinator" / "stall-watch here" (it reaches goose workers from the
  coordinator's own `gse_` id).

## Tests

    python3 pkgs/worker-scorecard/test_worker_scorecard.py

Wired into `nix flake check` as `checks.worker-scorecard-tests`, with the test
count pinned.
