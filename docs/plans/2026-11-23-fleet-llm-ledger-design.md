# Fleet LLM ledger: every host in Grafana, one quota verdict everywhere

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
  | Mac | teamclaude `usage.jsonl` | cfp, Vertex-first to $100/day | Max: hourly rows; cash: **nowhere today** (cfp events disabled) |
- **The forecast is already fleet-wide where it matters**: `u7d` is per account
  from Anthropic, so it includes every host's draw. What is cloudbox-only is
  `k` (notional Max $ per account-week, used to convert spilled Vertex $ back to
  burn) — today it divides cloudbox-only Max $ by fleet burn, so it is ~2.5×
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
no new exposure, no new repo.

```
devbox ─┐ hourly rows (git push, :07)          ┌─> cloudbox llm-fleet-import (timer, 15 min)
Mac  ───┘ main: <host>/<ISO-week>.jsonl ───────┘      git fetch → remote_hourly in ledger.db
                                                        │
cloudbox: llm-ledger → quota-watch (k from fleet Max $) → llm-outlook-publish
                                                        │ force-push branch `outlook`
                                                        ▼ (outlook.json, one commit)
devbox llm-outlook-sync (user timer, 2 min) → ~/.local/state/llm-ledger/outlook.json
devbox `llm-ledger quota-outlook` → reads that file, re-checks age → stall-watch quota@ line
```

### 1. Usage in (Grafana by host)

- **Ledger schema.** New table
  `remote_hourly(host, hour, account, backend, model, requests, input, output,
  cache_read, cache_write_5m, cache_write_1h, cost_usd, PK(host, hour, account,
  backend, model))` and `remote_hosts(host PK, exported_through, imported_at)`.
  `hour` is epoch ms like `hourly.hour`. Accounts stay in the DB (private), never
  in dashboard JSON (the existing lint already bans `@`).
- **View `fleet_hourly`** = local `hourly` (host = the writer's `--host`) UNION
  ALL `remote_hourly` with `attr_key = 'fleet:<host>'`. The writer recreates the
  view each run. Remote hosts get synthetic `session_program` rows
  (`fleet:<host>` → tag `fleet:<host>`), so program panels show "devbox"/"mac"
  bands instead of "unresolved". Per-program breakdown *within* devbox/Mac is out
  of scope (most devbox burn is eternal-machinery agents that send no session
  header; its own chart at Mac :4711 already covers it).
- **Importer** `llm-ledger import-remote --repo DIR`: for each `<host>/*.jsonl`
  (skipping the ledger's own host) whose git blob id changed since last import
  (kept in `ingest_state`), delete that host's rows in that ISO week and insert
  the file's rows in one transaction under the ledger lock. Max rows are priced
  with `oc_tags.goose_rate_for` (5m writes at the cache-write rate, 1h writes at
  2× input); cash rows carry cfp's `cost_usd`. Unknown model → `cost_usd NULL`
  and one warning line, not a failure. `_exported_through.json` → `remote_hosts`.
- **cloudbox unit** `llm-fleet-import` (system, User=dev, timer `*:12/15`):
  `git fetch` (ssh key `~/.ssh/id_ed25519_github`, already on cloudbox) into
  `/var/lib/llm-ledger/fleet-repo`, then `import-remote`. Its own failure alert
  with backoff; a GitHub blip does not touch the writer's alert.
- **Mac cash rows.** Enable cfp events on the Mac (`CFP_EVENTS_PATH`,
  `CFP_EVENTS_RETENTION_DAYS=30`). The exporter gains `--cfp-events PATH`: join
  route→usage by `requestId` for the model, keep `backend != 'max'` (Max is
  already counted from teamclaude, with its account), aggregate per (hour,
  backend, model) with `account = ""` and summed `cost_usd`. Rows without
  `backend` are Max (devbox's rows stay valid unchanged).
- **Mac exporter actually running.** Find out why `mac/` never appeared
  (home-switch not run since #939, no ledger, or ssh push failing) and fix.
- **Grafana.** Spend dashboard panels read `fleet_hourly` and gain a `host`
  variable; add "Spend by host" (Max notional and cash kept apart, as now) and
  "Max burn by host" (host Max $/h ÷ latest `k`, in account-weeks/h). Quota
  dashboard: "Remote freshness" stat per host (`now − exported_through`). No
  alert on remote staleness: a sleeping Mac is legitimately stale.
- **Freshness.** Remote rows lag 1–2 h (complete hours only). Acceptable for
  dashboards; the verdict does not depend on them (see 2).

### 2. Verdict (computed once, on cloudbox)

- Capacity, burn and refill stay exactly as today (TeamClaude `u7d` via the
  canary). No host computes its own verdict, so they cannot disagree.
- **Fleet `k`.** `k = (cloudbox Max $ + remote Max $, 7 d) / burn_7d`, excluding
  `--exclude-account` accounts from remote rows (cloudbox rows carry no account).
  Used only when every host in `--fleet-hosts` (default `devbox,mac`) has rows
  covering the whole 7-day window and `exported_through ≥ T − 3 h`; otherwise the
  current local `k`. `quota_watch_runs` gains `k_scope` (`fleet`|`local`). So
  nothing changes on deploy; `k` goes fleet-wide by itself 7 days after the Mac
  starts exporting. Before turning it on we replay both ways and record the
  verdict difference in the bead.

### 3. Verdict out (every host reads the same line)

- **Publish** `llm-outlook-publish` (cloudbox system oneshot, User=dev, started by
  `OnSuccess=` of `llm-quota-watch`): run `llm-ledger quota-outlook`, add
  `published_at` and `source_host`, write `outlook.json` into a dedicated local
  repo and force-push a single orphan commit to branch `outlook` (no history
  growth, ~288 pushes/day). Contents are the outlook only — verdict, headroom,
  burn, dry hours, next refill, line — no $ figures. Committed with the
  configured identity (no inline `-c user.*`).
- **Sync** `llm-outlook-sync` (devbox home-manager user timer, every 2 min,
  bounded `timeout 60`): `git fetch` the `outlook` branch, validate it parses as a
  JSON object, write `~/.local/state/llm-ledger/outlook.json` atomically.
- **Read.** `llm-ledger` goes on devbox's PATH (home.packages). `quota-outlook`
  resolution: `--remote-file`/`$LLM_LEDGER_OUTLOOK_FILE` if given; else the DB if
  it exists (cloudbox, unchanged); else the default synced file. Remote mode
  re-computes `age_s = now − ts` and applies the same rules as local (stale over
  1200 s, skew, bad verdict → `unknown` with `error`), passing `line` through.
  A missing file → `unknown` ("no published outlook"), never a crash. stall-watch
  needs no change.
- **Latency budget.** canary `*:0/5` → writer `*:2/5` → quota-watch → publish
  (~T+3 min) → sync ≤ 2 min → steady-state age 5–10 min, against the 20-min
  stale line. A GitHub outage longer than ~10 min turns devbox `unknown`, which
  the snooze logic already handles (lifts after 2 h unknown).

## Error handling

| Failure | Effect |
|---|---|
| GitHub down | import pauses (dashboards lag); devbox verdict → `unknown` after 20 min; cloudbox unaffected |
| exporter stops on a host | `remote_hosts.exported_through` freezes (freshness panel); `k` falls back to local |
| malformed remote row | skipped, counted in one warning line; file still imported |
| publish push fails | unit fails, alert with backoff; devbox goes `unknown` at 20 min |
| outlook branch content not JSON | sync keeps the previous file; reader's age check turns it `unknown` |

## Testing

- llm-ledger unittests: import (idempotent re-import, week replace, own-host
  skip, pricing incl. 1h, cash rows, unknown model, watermark), view contents,
  synthetic session_program rows; quota-watch fleet-k (coverage gate both ways,
  excluded account, `k_scope`); quota-outlook remote mode (fresh, stale, skew,
  missing file, garbage, resolution order, <3 s).
- exporter tests: cfp route→usage join, `max` excluded, no-backend rows = Max.
- Dashboard lint passes with the new schema; flake check.
- Live: devbox rows in `fleet_hourly`; devbox `./sw quota` prints the same line
  as cloudbox's; Mac `mac/` dir appears.

## Deploy

- cloudbox: NixOS switch for the new units/timer only, after `dry-activate`
  shows none of goose-serve, honkd, pigeon-daemon, cfp, teamclaude or the serve
  pool restarting.
- devbox: home-manager switch via a `swarm_launch` session.
- Mac: `home-switch` (no root) via a `swarm_launch` session to the Mac, or steps
  for Jonathan.

## Out of scope

- Per-program attribution inside devbox/Mac; codex-lb (ChatGPT plans) usage.
- The Mac or devbox computing their own verdicts; Mac consuming the verdict
  (nothing on the Mac reads it).
- Moving the store off cloudbox or exposing Grafana.
