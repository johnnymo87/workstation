# LLM spend and Max-quota observability: a SQLite ledger and Grafana on cloudbox

Decision bead: `workstation-vhwp` (closed). Implementation epic: `workstation-4si2`.

## Question

Would a free-tier *personal* Datadog org beat our oc-tags SVG charts (Mac
`:4710` for cloudbox, `:4711` for devbox) for any of these?

- Drilling into spend by host, program, persona or suite, model, backend and
  account.
- Alerting on anomalies.
- Warning before the Claude Max pool runs out.

## Decision

**No Datadog.** On cloudbox we will:

- keep a **durable SQLite request ledger** that our own exporter writes;
- run **Grafana OSS** with the `frser-sqlite-datasource` plugin (nixpkgs has
  3.8.2; Grafana is 12.3.6) to provide dashboards and drill-down;
- keep **alerts in Python**, sent through the existing `opencode-drift-alert`
  helper to pigeon `:4731/alert`.

The SVG charts stay as the fallback, and oc-tags stays the source of truth for
which session belongs to which program.

How we got here: deep research (ChatGPT, checked against current docs on
2026-11-22), then an oracle consult, then an adversarial review of the first
draft. That draft used VictoriaMetrics, and the review moved it to SQLite. The
reasons:

| Option | Verdict |
|---|---|
| Datadog Free | **Rejected.** Metrics are kept for **1 day** (confirmed on the pricing page), and our quota resets weekly. The free plan isn't confirmed to include monitors, anomaly monitors or forecast monitors. `/api/v2/series` rejects points older than about 1 h, so the history we already have can't be loaded. On cloudbox the *work* `DD_PAT` is injected into every agent bash call, so a personal pusher would be one env-var mistake away from writing to the work org. |
| Grafana Cloud Free | **Rejected.** It has 10k series, 500 alert rules and free ML forecasting, but retention is **14 days**, it only accepts data up to 2 h out of order (so retags can never be corrected), and the data leaves our hosts. |
| LLM tracing tools (Langfuse, OpenLIT, Helicone) | **Rejected.** They are built around traces and prompts. We already have token counts; what we lack is retention, queryability, alerts and quota semantics. |
| VictoriaMetrics + Grafana (first draft) | **Rejected, after review.** Each label (e.g. `program`) is fixed when the data is written. VM's delete API removes whole series, never a time range, so correcting a retag means deleting the series' entire history. Dedup keeps the largest value, so a cost that moves *away* from a program is double-counted. It also needs a late-event grace period and a locked rebuild. |
| **SQLite ledger + Grafana** | **Chosen.** Programs are joined in when a query runs, so a retag takes effect immediately. There is no dedup, delete or rebuild machinery, and we keep as much history as we choose. At our volume of about 12k requests a day, a full parse takes 3 s, and the ledger grows by about 4M rows a year. |

`vmanomaly` and Grafana's own alerting are not used. Python does the anomaly
and forecast checks, and it keeps drift-alert's backoff and escalation.

## Facts that shape the plan

Each of these was verified by the adversarial reviewer against live data on
2026-11-23.

1. **cfp keeps only 30 days.** `claude-failover-proxy/src/events.ts:225`
   drops events older than `retentionDays`, and `CFP_EVENTS_RETENTION_DAYS=30`
   is set at `hosts/cloudbox/configuration.nix:5501`. The trim rewrites the
   file and `rename`s it, so the inode changes. The live file starts on
   2026-10-23, and **another day is lost every night**. The trim reads the
   whole file into one string, so raising the retention setting is not a
   fix: the file would hit V8's string limit in a few months. **Phase 0 is
   urgent.**
2. **The cfp join works.** Joining `route` to `usage` on `requestId` matches
   184,322 of 184,323 usage events, and their `ts` values are equal. Take
   **`backend` from the usage event**: 3,508 requests were routed to Max and
   then fell over to Vertex. Over 30 days, 96% of cost resolves to a tag row.
3. **Usage lines are written when the response ends**, but their `ts` is when
   the request started. Lines arrive up to about 270 s after their `ts`, and
   the longest request took 358 s. Read the file by byte offset, never by
   time window, so nothing is dropped.
4. **cfp has three backends:** `max`, `vertex` and `enterprise`. Enterprise
   carried about $1.3k of cash from 2026-10-23 to 11-09 and is idle now.
5. **`u7d` jitters.** Every small dip is exactly 0.01, and 553 of the 748 dips
   in the archive go a → a−0.01 → a. The smallest real reset is 0.10. The burn
   accumulator must be a **high-water mark** reset by any drop of more than
   0.05 or by crossing `r7d`. A version that skips dips would overcount by
   about 10%. **`u7d` is null at the moment of reset** (e.g. on 2026-11-20 at
   18:00); carry the previous value forward for up to 15 min.
6. **The pool runs dry at about 0.98, not at 1.0.** teamclaude refuses an
   account at about 0.98 but leaves its status `active`. On 2026-11-22 from
   12:00 to 18:00 EST, all traffic went to Vertex (about $333 cash in 6 h)
   while Σ(1−u7d) read 0.09–0.12. Headroom is Σ max(0, cap − u7d), where
   `cap` is measured or read from teamclaude.
7. **devbox and the Mac share the Max accounts**, so u7d already includes
   their burn. The forecast needs no data from devbox. The token→quota refit
   does, and it needs **the Mac's data too** (the Mac runs cfp and teamclaude
   too; see `users/dev/home.darwin.nix`). **`jmohrbacher` is a seat with a
   spending cap** (`$1,000` limit), not a weekly-quota account.
8. **`u7dF`** is the fable-specific 7-day utilization (`unified7dFable`). It
   is recorded in the ledger but kept out of pool headroom.
9. **Vertex dollars are cash; Max dollars are notional** list price, a proxy
   for quota. Panels never add them up as "spent".

## Architecture

```
cloudbox
  cfp events.jsonl ──(offset tail, inode-aware)──┐
  quota-samples.jsonl (+ gz archives) ───────────┤   llm-ledger (timer, 5 min, flock)
  oc-tags: opencode.db, goose sessions.db, tags.db ─ session→program snapshot
  johnnymo87/quota-telemetry (git pull; devbox/Mac rows) ─┘
                                 │
                                 ▼
          /var/lib/llm-ledger/ledger.db   (SQLite, WAL; dev rw, grafana group r)
            requests(request_id PK, ts, host, session_id, backend, model,
                     input, cache_read, cache_write, output, cost_usd, status,
                     duration_ms)
            quota_samples(ts, account, s, u5h, u7d, u7d_fable, r7d, r5h)
            session_program(session_id PK, program, sub, updated_at)
            hourly_remote(host, hour_utc, account, model, …)   -- from git
                                 │
  quota-watch (timer, 5 min) ────┤── alerts → opencode-drift-alert → pigeon /alert
                                 ▼
          Grafana 127.0.0.1:3000 (frser-sqlite-datasource, provisioned from Nix)
          Mac: socket tunnel :3001 → cloudbox :3000
```

- **Programs are resolved at query time.** Every 5 min, `session_program` is
  rebuilt from oc-tags' `effective_tag` / `root_of` / fold logic: about 11k
  rows, one transaction. A Grafana query joins it to `requests`, so a retag
  shows up on the next refresh.
- **The ledger is append-only and idempotent:** each insert is keyed on
  `request_id` with `INSERT OR IGNORE`. cfp's trim no longer loses anything
  once the exporter has read it. Phase 0 imports the live file at once, which
  saves the 30 days that still exist.
- **Exposure.** cloudbox has a public IP and **no NixOS firewall**; GCP
  ingress rules are the only guard. So Grafana binds explicitly to
  127.0.0.1, with a check for it like the front-door guard, and has analytics
  and update checks turned off. Its admin password comes from sops via
  `$__file{}`. Dashboard JSON in the public repo refers to accounts by
  variable and never names them.

## Implementation constraints

These come from the second review pass, and each one was verified.

- **The journal mode must be DELETE, not WAL.** The frser plugin opens and
  closes the database on every query. Once the timer writer has exited, a
  WAL database has no `-shm`, and a read-only reader can't recreate it
  (reproduced: "attempt to write a readonly database").
  - The writer sets `busy_timeout` to at least 30 s.
  - The database lives at `/var/lib/llm-ledger`, created through tmpfiles:
    owned by dev, with group `llm-ledger` (grafana is a member) having `r` on
    the file and `x` on the directory.
  - It can't live under `~`, because the grafana unit runs with
    `ProtectHome=true`.
- **`session_program` covers every session id seen in the ledger**, not just
  the rows in tags.db. cfp records the *calling* session, and 16% of the cost
  comes from opencode child sessions.
  - Each row stores `effective_tag(root_of(sid))`, or the `auto:` key for an
    untagged root.
  - For goose, resolve the root in sessions.db, then take
    `goose:<root>` from tags.db, falling back to `goose_auto_key`.
  - Rows are **upserted, never deleted**, because pruning changes roots.
  - The raw tag is stored, and `program`/`sub` are derived from it when a
    query runs. `fold` is a rendering option, not part of the data.
  - Queries use `LEFT JOIN … COALESCE(program,'unresolved')`.
- **frser 3.8.2 has no `$__timeFilter`, and it reads numeric time as
  seconds.** Write the filters by hand as `ts >= $__from AND ts < $__to`,
  with `ts` as integer epoch ms. Bucket with
  `(ts/$__interval_ms)*$__interval_ms/1000`. `quota_samples.ts` is stored as
  an integer, because the canary's ISO strings change their UTC offset at
  DST.
- **Indexes and rollup:**
  - Indexes: `requests(ts, session_id, backend, model, cost_usd)`,
    `requests(session_id, ts)` and `session_program(program, session_id)`.
  - An `hourly(hour, session_id, backend, model, …)` rollup. Each writer run
    recomputes every hour that its new rows touch.
  - Panels covering a year read the rollup (0.26 s vs 3.5 s for 365 days),
    and drill-down reads `requests`.
- **Raw archive.** Every day the raw cfp lines are also written to a gz file
  next to the ledger (12 MB per 30 days), so the ledger can always be rebuilt
  and isn't the only copy. The snapshot taken on 2026-11-23 is imported too.
- **Ordering.** One timer runs the writer, then the snapshot refresh, then
  `quota-watch`, so the alerts see fresh rows.

## Alerts (Python `quota-watch`)

The checks run every 5 min and send through `opencode-drift-alert`, which
handles backoff and escalation and posts `{text, severity}` to pigeon, plus
`links` to the Grafana panel.

- **Projected shortfall.** Step headroom forward through each account's `r7d`
  reset over the next 24 h:
  - Inputs: burn `B = max(burn_6h, burn_24h)` from the accumulator, and Vertex
    spillover notional ÷ k added back while the pool is dry.
  - Output: hours at zero headroom, and the Vertex dollars those hours would
    cost.
  - Fires at ≥ 2 h projected, with hysteresis so it doesn't flap. A refill
    restores the current `u7d` (the conservative routing assumption; cfp's
    final-window routing makes the true refill larger).
- **An account at or above 0.90** (warning). **Pool dry now** (headroom
  below 0.02 while any traffic goes to Vertex), which the existing canary
  misses because the accounts still read `active`.
- **Program burst:** a program's last hour is more than 3× its 7-day p90
  hourly spend and more than $5. A program with no history fires at more
  than $15 in an hour.
- **Runaway session:** a session costs more than $20 in a trailing hour. Over
  30 days, 4 sessions crossed $20 and 112 crossed $10.
- **Stale inputs:** the ledger or the quota samples haven't advanced in
  15 min. This check runs outside Grafana, so it still fires when Grafana is
  down.
- **Validation:** replay since 2026-10-25, the first date with `r7d`. The
  checks must fire for the dry spell of 2026-11-22, and the noise from the
  other replayed episodes is recorded.

## Token→quota refit (absorbs `workstation-qn8u`)

The fit is `k = Σ notional Max $ / Σ consumed account-weeks`, computed weekly.
It is valid only when Max $ from every host that draws on the pool is
included: cloudbox from the ledger, devbox and the Mac from `quota-telemetry`.
Exclude `jmohrbacher`, which has a spending cap rather than a quota. Until
the Mac's rows exist, k is reported as **a lower bound**. A drift in k is a
signal in its own right.

## Phases (beads)

0. **The ledger.** `workstation-4si2.1`
   - An `llm-ledger` timer: tail the cfp events by byte offset, detecting
     inode changes, join route to usage, and `INSERT OR IGNORE`.
   - Import the quota samples as integer timestamps, including the gz
     archives.
   - Archive the raw lines as gz every day.
   - Build the `hourly` rollup and the `session_program` snapshot.
   - DELETE journal mode, the tmpfiles group, and the indexes.
   - Import the 2026-11-23 snapshot.
   - Timing: the snapshot covers data until about 2026-12-22, so there are
     about 4 weeks of slack before the trim would lose anything.
1. **`quota-watch`.** `workstation-4si2.2`
   - High-water-mark accumulator, cap-aware headroom, null carry-forward,
     shortfall forecast and the alerts above.
   - Tests built from the full archive: 81 resets, two pool-wide off-schedule
     resets, and gaps in membership.
   - Replay validation.
   - Supersedes the forecast half of `workstation-qn8u`.
2. **Grafana on cloudbox.** `workstation-4si2.3` — **Built**
   - NixOS service in `hosts/cloudbox/grafana.nix` with `frser-sqlite-datasource` plugin
     and provisioned read-only datasource uid `llm-ledger` (`/var/lib/llm-ledger/ledger.db`);
     grafana user joins `llm-ledger` group.
   - Loopback bind (`127.0.0.1:3000`) guarded by `cloudbox-grafana-exposure` check;
     sops admin password and secret key owned by `grafana:grafana` 0400; admin password
     is read with `sudo cat /run/secrets/grafana_admin_password`.
   - Mac launchd agent `cloudbox-grafana-tunnel` on `:3001` riding the `cloudbox-chart`
     SSH host block and ControlMaster.
3. **Dashboards.** `workstation-4si2.4`
   - Spend by program over time (Max notional and Vertex cash shown apart),
     drill-down to model, sub and session, top sessions, and headroom vs burn
     with the forecast.
   - Grafana variables for host, backend, program and model.
   - Agreement with the SVG chart is checked against an **expected gap
     defined in advance**: the SVG also prices non-cfp sources.
4. **Alerts on programs and sessions** `workstation-4si2.5` (the burst, runaway and stale checks in
   `quota-watch`), replay-validated.
5. **Other hosts.** `workstation-4si2.6` Import `johnnymo87/quota-telemetry` rows: devbox from the
   devbox quota worker, the Mac to be arranged. Weekly refit of k. em
   programs show up in the dashboard.
6. *(Optional)* **Per-account attribution.** `workstation-4si2.7` cfp/teamclaude records which Max
   account served each request, and the dashboard gets an account dimension.

## Open questions for Jonathan

- Does traffic for the capped `jmohrbacher` seat go through cfp's `max`
  backend? If so, k can't be clean until phase 6.
- Should the Mac export its Max usage to `quota-telemetry`? Without it, k is
  a lower bound.

## Out of scope

- Datadog in any form.
- Prompt or response content.
- Replacing the SVG charts until the dashboard has run for a couple of weeks.
- devbox-local runaway detection. Revisit if an hour of git lag proves too
  slow.
