# devbox reads cloudbox's quota verdict

Bead `workstation-91cw`. Epic `eng-agent-platform-ul4.24`; design is in
eng-agent-platform, `docs/plans/2026-11-23-quota-aware-coordinators-design.md`. Builds on
#944 (`llm-ledger quota-outlook` on cloudbox).

## Goal

devbox's stall-watch coordinator wakes should carry the `quota@HH:MM: AMPLE|TIGHT|DRY …`
line, and the verdict should be real, not `unknown`.

## Decision: read cloudbox's verdict, don't compute one

The Max accounts are a single pool that both hosts draw on. quota-watch takes headroom
and burn from each account's 7-day utilization, and that figure is account-wide, so
cloudbox's verdict already counts devbox's usage. Two inputs are cloudbox-only, its Vertex
spill estimate and its per-host request rows, and neither one decides the verdict on its
own. A second quota-watch on devbox would mean porting the ledger, the canary and the
failure alerts, and it would send duplicate pool-dry pages. (This was decided with the
eternal-machinery coordinator, quoting Jonathan: "same pool".)

## Transport: pigeon's worker R2 media store

devbox cannot ssh to cloudbox, and the two hosts are not on a shared tailnet. Both
already authenticate to pigeon's Cloudflare worker with a machine key
(`/run/secrets/pigeon_worker_key`, `/run/secrets/ccr_worker_url`), and the worker exposes
a generic blob store:

- `POST /media/upload` (multipart `key`, `mime`, `filename`, `file`) overwrites an R2
  object.
- `GET /media/<key>` returns it.

Keys outside `inbound/` and `outbound/` are never cleaned up, so a fixed key simply
persists and is overwritten each time. Uploads involve no D1 writes, so the worker's
free-tier D1 write budget is not touched.

Key: `state/cloudbox/quota-outlook.json`.

Why not the alternatives:

- **The `johnnymo87/quota-telemetry` git repo, reversed.** About 288 commits a day of
  churn, plus git on the hot path.
- **Swarm messages.** Each one wakes an LLM turn.
- **Session labels.** Too small to carry the payload, and filtered.

Caveat: any machine key can overwrite any media key. The payload is advisory, and the
reader re-derives staleness from the reading's own `ts`, so a bad or stopped writer
degrades to `unknown`.

## devbox (this PR)

- `users/dev/quota-outlook-remote.nix`:
  - **`quota-outlook-fetch.timer`:** a user timer every 2 min that GETs the key into
    `~/.local/state/quota-outlook/cloudbox.json`.
    - The file is replaced atomically, and only with a JSON object that has a string
      `verdict`.
    - On a 404 or any error the old copy stays in place.
    - The key is passed in a header through a file descriptor, never on argv.
  - **`llm-ledger` on dev's PATH:** a wrapper that sets `LLM_LEDGER_OUTLOOK_JSON` to
    that file. It goes in `home.packages`, not `systemPackages`, which would restart
    teamclaude.
- `llm-ledger quota-outlook --from-json PATH`, which defaults to `$LLM_LEDGER_OUTLOOK_JSON`
  when no `--db` is given:
  - It re-derives `age_s`, staleness (more than 20 min means `unknown`), clock skew and the
    line from the reading's `ts`, using the same code as the DB path.
  - A remote `unknown` stays `unknown`.
  - A stalled chain therefore shows up in the wake as `quota@…: unknown` within 20 min of
    cloudbox's last quota-watch run.

## cloudbox (stall-watcher program's change; spec)

After each successful `llm-quota-watch` run, publish the outlook. Run it as an
`OnSuccess=` unit, or best-effort in `ExecStartPost=` with a leading `-`, so that a
publish failure never fails quota-watch or pages:

```bash
out=$(llm-ledger quota-outlook)                      # always exits 0, one JSON object
curl -sS --max-time 20 -o /dev/null -w '%{http_code}' \
  -H @<(printf 'Authorization: Bearer %s\n' "$(cat /run/secrets/pigeon_worker_key)") \
  -F key=state/cloudbox/quota-outlook.json -F mime=application/json \
  -F filename=quota-outlook.json -F "file=@-;type=application/json" \
  "$(cat /run/secrets/ccr_worker_url)/media/upload" <<<"$out"
```

Requirements:

- The unit can read `/run/secrets/pigeon_worker_key` and `ccr_worker_url` (both `dev`,
  mode 0400).
- It must not run under `ProtectHome` or `PrivateNetwork`.
- Cadence follows quota-watch, every 5 min. End-to-end age at devbox is then about 5 min
  for quota-watch, plus 2 min for the fetch, plus run times. That is well inside the
  20 min staleness limit.
- Publish whatever `quota-outlook` prints, including `unknown`. devbox treats it as
  unknown.

Check from devbox:

```bash
systemctl --user start quota-outlook-fetch; llm-ledger quota-outlook
```

## Per-host usage both ways (sized, not built)

- **devbox's usage in cloudbox's ledger.** devbox already pushes hourly per-account token
  rows to `johnnymo87/quota-telemetry` (`users/dev/quota-telemetry.nix`, bead `ynoq.2`).
  What's missing is a cloudbox importer that turns them into ledger rows with
  `host='devbox'`. Their granularity is hourly aggregates, not requests, and they need
  pricing. That belongs with the existing refit workstream (`ynoq.2` / cloudbox
  `workstation-qn8u`). Size: medium, mostly cloudbox-side.
- **cloudbox's usage visible from devbox.** Once the ledger has per-host rows, the publish
  above can carry a small per-host summary in the same object, or a second key. Size:
  small, after the first half.
