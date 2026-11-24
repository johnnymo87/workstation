# Fleet LLM ledger: every host in Grafana, one quota verdict everywhere

Status: adversarial-reviewer-opus approved after two rounds (2026-11-23).
Bead epic: `eng-agent-platform-ul4.26` (under the stall-watcher epic `eng-agent-platform-ul4`).
Builds on `workstation-4si2` (ledger, quota-watch, Grafana; design
`2026-11-23-llm-spend-metrics-design.md`) and `eng-agent-platform-ul4.24`
(quota-aware coordinators). Absorbs `workstation-4si2.6`.

## Ask (Jonathan, 2026-11-23, stall-watcher channel)

> "devbox (and mac) should also push to grafana, and our unified view of where we
> are on quota should read from that. multi machine by default. … maybe all hosts
> write to grafana, read from teamclaude, and if they need more, they get it from
> grafana"

1. Every host (cloudbox, devbox, Mac) writes its LLM usage to the store behind
   Grafana (`/var/lib/llm-ledger/ledger.db` on cloudbox), broken down by host.
2. Capacity stays TeamClaude status (per-account `u7d`), the pool's source of truth.
3. One verdict (`quota-outlook`), computed once from (2) plus the fleet ledger,
   read identically on every host. devbox coordinator wakes carry the same
   `quota@` line as cloudbox's.

## Facts that shape it

- **Network.** devbox cannot reach cloudbox. All three hosts reach GitHub, and
  all three already have ssh push to the private repo `johnnymo87/quota-telemetry`
  (devbox pushes there hourly today, #929; the Mac exporter is declared, #939,
  but has never pushed — no `mac/` dir). pigeon's hub (Cloudflare Worker + D1,
  free plan, 100k writes/day shared with all chat/relay) carries only
  session-addressed messages; a new KV route would be a third repo and a
  worker deploy, and bulk rows would eat its write cap. Grafana stays on
  127.0.0.1.
- **What each host can report.**
  | host | Max (teamclaude) | cash (Vertex/agy/enterprise) | source |
  |---|---|---|---|
  | cloudbox | via cfp | via cfp | cfp `events.jsonl` → `requests` (per request, with program) |
  | devbox | teamclaude `usage.jsonl` | none (no Vertex) | hourly rows in quota-telemetry |
  | Mac | teamclaude `usage.jsonl` | cfp, Vertex-first under a daily cap | Max: hourly rows; cash: **nowhere today** (cfp events disabled) |
- **The forecast is already fleet-wide where it matters**: `u7d` is per account
  from Anthropic, so it includes every host's draw. What is cloudbox-only is
  `k` (notional Max $ per account-week, used to convert spilled Vertex $ back to
  burn) — today it divides cloudbox-only Max $ by fleet burn, so it is ~1.8×
  too small and over-weights spill — and per-host breakdowns.
- **Spill stays cloudbox's.** Spill means "wanted Max, got Vertex"
  (`route.desired='max' AND backend='vertex'`). devbox has no Vertex; the Mac is
  Vertex-*first* by design, so its Vertex $ are not displaced Max demand and must
  not enter burn.
- stall-watch's client (`stallwatch/quota.py`) runs `llm-ledger quota-outlook`
  from PATH with a 3 s kill, ignores unknown JSON keys, and treats "no binary" as
  feature-off. So devbox needs `llm-ledger` on PATH and a quota-outlook that
  answers in well under 3 s with no network call.

## Design

Transport is the existing private GitHub repo, both directions. No new service,
no new exposure, no new repo. (A pigeon-R2 verdict transport was prototyped on
closed draft workstation#947; R2 media keys are not owner-scoped and media was
not designed as a store, so git wins. #947's reader code is reused.)

```
devbox ─┐ hourly rows (git push, :07)          ┌─> cloudbox llm-fleet-import (timer *:14/15)
Mac  ───┘ main: <host>/<ISO-week>.jsonl ───────┘      git fetch → remote_hourly in ledger.db
                                                        │
cloudbox: llm-ledger → quota-watch → llm-outlook-publish
                                       │ force-push branch `outlook` (outlook.json, 1 commit)
                                       ▼
devbox llm-outlook-sync (user timer, 2 min) → ~/.local/state/llm-ledger/outlook.json
devbox `llm-ledger quota-outlook` → reads that file, re-checks age → stall-watch quota@ line
```

Phase 1 (this epic's first window): §1, §3, §4. Phase 2 (beads, after a week
of fleet data): §2 fleet `k`, §5 Mac cash rows.

### 1. Usage in (Grafana by host)

- **Ledger schema** (all `CREATE … IF NOT EXISTS`; nothing existing altered):
  `remote_hourly(host, hour, account, backend, model, requests, input, output,
  cache_read, cache_write_5m, cache_write_1h, cost_usd, PK(host, hour, account,
  backend, model))` and `remote_hosts(host PK, first_hour, exported_through,
  imported_at)`. `hour` and `exported_through` are epoch ms
  (`exported_through` = watermark `hour_utc` + 1 h, the end of coverage). A null
  account is stored as `""` (SQLite PKs allow duplicate NULLs). Accounts stay
  in the DB, never in dashboard JSON (the lint bans `@`).
- **View `fleet_hourly`** = local `hourly` (host = the writer's `--host`) UNION
  ALL `remote_hourly` with `attr_key = 'fleet:<host>'`, `n = requests`,
  `cache_write = 5m + 1h`. Recreated only when its SQL differs from
  `sqlite_master`. Synthetic `session_program` rows `fleet:<host>` → tag
  `fleet:<host>` with `source = 'fleet'` (not `manual`, which
  `load_session_tags` treats as a vanished tags DB), so program panels show
  host bands instead of "unresolved". Per-program detail inside devbox/Mac is
  out of scope (most devbox burn is eternal-machinery agents with no session
  header; its own chart at Mac :4711 covers it).
- **Importer** `llm-ledger import-remote --repo DIR`: for each
  `<host>/*.jsonl` (skipping the ledger's own host) whose git blob id changed
  since last import (`ingest_state`), delete that host's rows in that ISO week
  and insert the file's rows, one transaction, under the ledger lock taken
  **blocking with a timeout** (the writer takes it non-blocking and must not be
  starved). Max rows priced from an **exact-match** model table (opus/sonnet/
  haiku 5-5 and fable-5-2 at the rates in cfp's own price table; 5m writes at the cache-write
  rate, 1h at 2× input); a model not in the table → `cost_usd NULL`, counted.
  Rows without `backend` are stored as the literal `'max'` (never NULL: every
  `backend = 'max'` panel and the `<> 'max'` cash filter would drop NULLs). Malformed rows skipped and counted. One
  summary line; unpriced/malformed counts are reported, not failures.
- **cloudbox unit** `llm-fleet-import` (system, User=dev, timer `*:14/15`, off
  the writer's `*:2/5` minutes): `git fetch` into
  `/var/lib/llm-fleet/telemetry` (its own StateDirectory, **not** under
  `/var/lib/llm-ledger`, which Grafana can read), then `import-remote`.
- **Staleness alert**: quota-watch already has a blind-input path; add
  `fleet-stale` for hosts in `--alert-stale-hosts` (default `devbox`; the Mac
  sleeps legitimately) when `now − exported_through > 3 h`. This also catches
  a broken devbox GitHub key, which would kill export and verdict sync together
  (the devbox exporter has no OnFailure).
- **Mac exporter actually running.** Find out why `mac/` never appeared and fix
  (home-switch not run since #939, no ledger, or ssh push failing).
- **Grafana.** Spend panels read `fleet_hourly`; the `backend`/`model` variable
  queries read `fleet_hourly` too ("All" expands to the option list, so a model
  missing from `hourly` would vanish); new `host` variable. Cash filters become
  `backend <> 'max'` so agy (#945) shows. "Top sessions" excludes `fleet:%`.
  New panels: "Spend by host" (Max notional and cash apart) and "Max share by
  host" (token-based, list-price units, same basis on every host). Quota
  dashboard: "Fleet freshness" stat per host.

### 2. Fleet `k` (phase 2, behind a flag)

`k` has two jobs: converting spill $ to burn (`burn_rate`), and turning dry
hours back into cash (`vertex_usd = zero_h·B·k`). The second needs cloudbox $
per fleet account-week — today's `k_local` exactly — so it stays. Only the
first changes:

- `k_fleet = k_local / s`, with `s` = cloudbox's share of fleet Max usage in
  list-price token units (`oc_tags.opus_list_cost` on both sides, so two price
  tables never meet), over a 7-day window ending at the oldest fleet watermark.
- Remote rows count only if their account maps (explicit email→short-name map,
  kept in the private quota-telemetry repo, never in this public repo; the usage
  seat gets an explicit ignore entry)
  to a pool member with non-null `u7d`; unmapped accounts warn. The usage seat
  is excluded that way. Residual: cloudbox's own Max $ still include the seat
  (cfp events carry no account) — fixing that needs teamclaude's usage log on
  cloudbox, i.e. a teamclaude restart; left to Jonathan.
- Hold the last good `k_fleet` for 48 h when a watermark lags; then fall back.
- `quota_watch_runs` gains `k_fleet` and `k_scope` as the **last** columns
  (replay code indexes `r[14]`). Flag `--fleet-k` off by default; flipped after
  a forward replay over the first full week shows the verdict difference.
- Expected effect is small: `k_local` is ~1.8× low (11-23: devbox Max usage was ~45% of the fleet's), which moves burn ~15% in a spill episode, <2% otherwise.

### 3. Verdict out (every host reads the same line)

- **Publish** `llm-outlook-publish` (cloudbox system oneshot, User=dev,
  `OnSuccess=` of `llm-quota-watch`): `llm-ledger quota-outlook`, plus
  `published_at`, `source_host` and `host_share_24h` (each host's share of
  fleet Max usage, token-based, no $, over a 24 h window ending at the oldest
  fleet watermark, published with each host's `exported_through`) — the "and
  vice versa" view. Written into
  `/var/lib/llm-fleet/outlook` and force-pushed as one orphan commit to branch
  `outlook` (no history growth), with the configured identity. Up to 3 tries
  inside the unit. No per-failure page: quota-watch alerts when the published
  outlook is older than 15 min (it records the last successful push).
- **Sync** `llm-outlook-sync` (devbox user timer, every 2 min, `timeout 60`):
  fetch the `outlook` branch, check it parses as a JSON object ≤ 64 KiB, write
  `~/.local/state/llm-ledger/outlook.json` atomically.
- **Read** (from #947): `llm-ledger` on devbox's PATH; `quota-outlook
  --from-json PATH` or `$LLM_LEDGER_OUTLOOK_JSON`; with neither and no ledger DB
  present, the default synced path. Re-derives age, staleness (1200 s), skew
  and the line from the reading's own `ts`; missing/garbage → `unknown`.
  stall-watch needs no change.
- **Behaviour change on devbox, intended.** Today devbox has no outlook, so a
  snooze lifts as "absent". After this, devbox coordinators see the line,
  `./sw snooze --until-quota` works there, and they hold discretionary work on
  `tight`/`dry` like cloudbox's — the point of ul4.24, applied to the biggest
  burner. An `unknown` (GitHub/cloudbox down) holds an existing snooze for up
  to 2 h, then lifts.
- **Latency.** quota-watch finishes ~T+2m20s; publish ~T+3m; sync ≤ 2 min →
  age 3–7 min steady state against the 20-min stale line.

### 4. Deploy

Order: cloudbox publishing first, then devbox gets `llm-ledger` (else devbox
reads `unknown` from the start). Take only #947's `--from-json` reader, not its
pigeon/R2 fetcher module.

- cloudbox: NixOS switch after `dry-activate` shows none of goose-serve, honkd,
  pigeon-daemon, cfp, teamclaude or the serve pool restarting.
- devbox: a `swarm_launch` session runs `home-manager build`, diffs the unit
  set (it deploys everything merged since devbox's last switch), then runs the
  switch detached with `systemd-run --user` (the session lives in a serve unit).
- Mac: phase 1 needs only the exporter working (no cfp change).

### 5. Mac cash rows (phase 2)

Enabling cfp events on the Mac (`CFP_EVENTS_PATH`) restarts the Mac's cfp, and
would put cash $ in the repo. Exporter gains `--cfp-events`: join route→usage
for model, keep `backend <> 'max'`, aggregate per (hour, backend, model) with
`account = ""` and summed `cost_usd`. Jonathan runs that home-switch.

## Error handling

| Failure | Effect |
|---|---|
| GitHub down | import pauses; devbox verdict → `unknown` after 20 min; cloudbox unaffected |
| devbox exporter stops | `fleet-stale` alert at 3 h; freshness panel |
| Mac exporter stops | freshness panel only |
| malformed / unpriced remote row | skipped / NULL cost, counted in the summary |
| publish push fails | retried; alert when published outlook > 15 min old |
| outlook branch not JSON | sync keeps previous file; reader turns it `unknown` by age |

## Testing

- llm-ledger unittests: import (idempotent, week replace, own-host skip, null
  account, exact pricing incl. 1h, unknown model, watermark → ms end), view and
  synthetic rows, lock blocking; quota-outlook `--from-json` (from #947) and
  default resolution; publish payload (`host_share_24h`, no $); fleet-stale.
- Dashboard lint with the new schema; `nix flake check --keep-going`.
- Live: devbox rows in `fleet_hourly`; devbox `./sw quota` prints the same
  `quota@` line as cloudbox; `mac/` appears.

## Calls left to Jonathan (none block phase 1)

- Restarting cloudbox teamclaude to log per-account usage (cleans the seat out
  of `k`).
- Mac cash $ in the private repo, and the Mac cfp restart (phase 2).

## Out of scope

- Per-program attribution inside devbox/Mac; codex-lb (ChatGPT plans) usage.
- The Mac or devbox computing their own verdicts; Mac consuming the verdict
  (nothing on the Mac reads it).
- Moving the store off cloudbox or exposing Grafana.
