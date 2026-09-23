---
name: operating-aigateway
description: Use when operating, deploying, debugging, or extending the aigateway LLM cost-capture proxy on cloudbox — routing opencode's Vertex providers through it, querying the per-request cost ledger (gateway_request_log), adding model prices, or rolling routing back.
---

# Operating the aigateway (cloudbox)

A local reverse proxy between opencode and Vertex: it forwards each request,
parses the response's token usage, prices it, and writes one row per request to
a Postgres ledger so LLM spend is attributable by user / model / session.

The companion follower that captures opencode-serve's own `service=llm` log lines
is a different artifact — see the `auditing-opencode-llm-calls` skill.

## Conventions (public-repo scrubbing)

This is a public repo. The gateway's source lives in the private monorepo, whose
org-prefixed Bazel package is omitted here per `scrubbing-company-references`.
In the commands below, set it once (it expands in your shell, so labels stay
copy-pasteable):

```bash
GW=//YOUR_ORG/data/aigateway   # the gateway's monorepo Bazel package
```

The GCP project is read from the `google_cloud_project` secret (never hardcoded).

## Where things live

| Thing | Path / command |
|-------|----------------|
| Stack | docker-compose project `dev` (`dev-gateway-1`, `dev-postgres-1`, `dev-redis-1`); ports 8080 / 5432 / 6379 |
| Lifecycle | `aigateway-enable` / `aigateway-disable` — **not** bare `systemctl start`, see "Turning it on and off" |
| Intent flag | `/var/lib/aigateway/enabled` (`hosts/cloudbox/aigateway-flag.nix`) — the unit's `ConditionPathExists`, and what the canary and opencode routing both read |
| Liveness | `aigateway-canary.service` + minutely timer; forensics in `/var/lib/aigateway-canary/wedge-*` |
| Health | `curl -s 127.0.0.1:8080/actuator/health` → `{"status":"UP"}` (unauthenticated; so is `/actuator/health/liveness`, which the canary probes. Every other path on :8080 returns 401 — a TCP check is not a health check) |
| Ledger | db `aigateway`, user `aigateway`, in `dev-postgres-1`; table `gateway_request_log` |
| opencode routing | `home.activation.injectAigatewayBaseUrl` in `users/dev/opencode-config.nix` |
| Gateway code | `$GW/server/{PriceTable,UsageParser,ProxyController}.kt`; migrations in `$GW/db/migrations/` |

## Turning it on and off

```bash
aigateway-enable    # touch /var/lib/aigateway/enabled, then start the unit
aigateway-disable   # remove the flag, then stop the unit
```

Use these rather than `systemctl start/stop`. Operator intent is the **flag**,
not the unit's runtime state, and three things read it: the unit's
`ConditionPathExists`, `aigateway-canary`, and the opencode routing activation.
A bare `systemctl stop` leaves the flag set, so the canary restarts the gateway
within a minute — correctly, since you never said you wanted it off. The stop
itself always succeeds: the canary uses `--job-mode=fail` and skips any pass
that finds the unit mid-transition, precisely so it can never cancel somebody
else's job (a `nixos-rebuild switch` stopping docker, most of all).

**Why intent is a file** (2026-09-13, bd `workstation-f794`). It used to be
`systemctl is-active`, which cannot distinguish "the operator turned it off"
from "something killed it". On 2026-09-13 a `nixos-rebuild switch` carrying #510
changed `docker.service`; switch-to-configuration **stopped and then started**
docker (a stop+start pair, not a restart — that is the socket-activated
`.service` branch in switch-to-configuration-ng). `Requires=docker.service`
propagated the stop to the gateway, but stc only restarts units *it* stopped,
and this one was a propagation victim rather than a member of `units_to_stop`.
With `wantedBy = [ ]` nothing else pulled it. Result: 2h13m of dead :8080.

Facts worth keeping, because each of them defeats an obvious "fix":

- **`PartOf=docker.service` would not have helped.** PartOf propagates stop and
  restart *jobs*; stc issued a stop and a start. And on a genuine
  `systemctl restart docker`, plain `Requires=` already propagates the restart,
  so PartOf adds nothing there either.
- **`Restart=on-failure` is inert here.** A propagated stop exits *success*.
  That line was already in the unit throughout the outage.
- **The unit being `active` says nothing about the gateway being up.** It is
  `Type=oneshot` + `RemainAfterExit`, succeeding the moment `docker compose up
  -d` detaches, and the containers carry `RestartPolicy=no`. A container that
  dies or wedges leaves the unit reading `active` forever. That is the second
  thing the canary exists for.
- **The Claude path is not independent of the gateway.** cfp's Vertex leg
  forwards to `CFP_AIGATEWAY_URL=http://127.0.0.1:8080`. During the 2026-09-13
  outage Claude only kept working because cfp was over budget and routing to
  Max; at the `CFP_RESET_HOUR=0` budget reset it would have gone back to a dead
  backend. "Gemini is down" and "Claude is fine" is a same-day coincidence, not
  a property.
- **The nightly reset heals this class.** `reset-workspace` restarts
  `opencode-serve-pool.target`; the serves are `PartOf` it and `wants=`
  aigateway, so the way back up re-pulls the gateway. That bounded the outage at
  ~8h, which is why it looked like "down forever" but was not.

## Routing opencode through the gateway

`injectAigatewayBaseUrl` rewrites `~/.config/opencode/opencode.json` on every
`home-manager switch`, gated on BOTH the intent flag AND the
`google_cloud_project` secret. When enabled it sets two baseURLs (with the
project baked into the path):

- `provider.google-vertex-anthropic.options.baseURL` → `http://127.0.0.1:8080/v1/projects/$p/locations/global/publishers/anthropic/models`
- `provider.google-vertex.options.baseURL` (gemini) → `http://127.0.0.1:8080/v1beta1/projects/$p/locations/global/publishers/google` (note `v1beta1`, no trailing `/models`)

When the flag is absent OR the secret is missing, it strips both → opencode hits
Vertex directly.

**Always `127.0.0.1`, never `localhost`.** The gateway publishes on IPv4
loopback only, which leaves `[::1]:8080` free, and `kubectl port-forward
8080:8080` binds it. Once that happens, `localhost` resolves to `::1` some of
the time, and requests go through the forward instead of the gateway. The
symptom is a Spring-shaped `{"timestamp",...,"status":404,"path":...}` error
that has **no matching ledger row**. Check with `ss -tlnp | grep ':8080 '`: the
gateway should be the only listener.

Note the deliberate asymmetry: **flag set but gateway currently down still
points opencode at :8080.** That is a loud failure (ECONNREFUSED on the first
gemini turn) which the canary heals within a minute. The alternative — silently
falling back to direct Vertex — is a quiet failure that loses exactly the
per-request attribution the gateway exists to collect, and it does not undo
itself when the gateway returns, because nothing re-runs this activation.

Apply changes:

```bash
home-manager switch --flake .#cloudbox
```

If eval fails with `access to absolute path '/home' is forbidden in pure
evaluation mode` (caused by any absolute-path reference in the flake), append
`--impure`.

> `gemini-3.8-flash` is the GLOBAL DEFAULT model on cloudbox, so routing it makes
> every session depend on the gateway being up — there is no auto-bypass when the
> gateway is down. Treat routing changes as high blast-radius and verify a live
> ledger row before declaring success.

## Querying the cost ledger

```bash
q() { docker exec dev-postgres-1 psql -U aigateway -d aigateway "$@"; }
# recent rows
q -c "SELECT request_started_at, user_email, model, http_status, input_tokens, output_tokens, total_dollars, context_tier FROM gateway_request_log ORDER BY id DESC LIMIT 20;"
# spend by model, last day
q -c "SELECT model, count(*), round(sum(total_dollars),4) AS dollars FROM gateway_request_log WHERE request_started_at > now()-interval '1 day' GROUP BY model ORDER BY dollars DESC NULLS LAST;"
# unpriced models (tokens present, dollars NULL) → candidates for a PriceTable entry
q -c "SELECT model, count(*) FROM gateway_request_log WHERE input_tokens IS NOT NULL AND total_dollars IS NULL GROUP BY model;"
```

Timestamp columns are `request_started_at` / `request_completed_at` (there is no
`created_at`). `context_tier` is `under_200k` / `over_200k`; `is_streaming` flags
SSE responses.

## Adding a model price (most common change)

1. Add the entry to `PriceTable.kt` test-first against `PriceTableTest`.
2. `bazel test --config ai $GW/server/testing:PriceTableTest`
3. Deploy (below). Unpriced models already ledger tokens with NULL dollars, so
   this is forward-only — historical NULL-dollar rows cannot be backfilled (the
   tokens were never stored).

## Deploying gateway code changes

The `dev` stack's Dockerfiles `COPY server.jar` / `migrate.jar` (springboot fat
jars). Rebuild, stage into the compose dir, and recreate ONLY gateway + migrate
so the ledger (postgres) survives:

```bash
cd ~/projects/mono            # your monorepo checkout / worktree
bazel build --config ai $GW/server:server $GW/db:migrate
d="$(cat /run/secrets/aigateway_dir)"        # compose dir (kept in sops)
cp "bazel-bin/${GW#//}/server/server.jar" "$d/server.jar"
cp "bazel-bin/${GW#//}/db/migrate.jar"     "$d/migrate.jar"
docker compose -p dev up -d --build --no-deps migrate gateway
```

> **You have about 3 minutes of unhealthiness before the canary intervenes.**
> It restarts the stack after 3 consecutive failed health probes at 60s
> spacing. A normal rebuild fits inside that; a slow build or a long migration
> may not, and being `compose stop`ped mid-deploy is confusing rather than
> harmful. Bracket a deploy you expect to be slow with `aigateway-disable` /
> `aigateway-enable` — remembering that disabling also strips opencode's
> routing on the next home-manager switch.

Then confirm health is `UP` and a fresh request produces a populated ledger row.

## Rollback / panic toggle

```bash
# Fastest, temporary (re-asserted on next home-manager switch):
runtime=~/.config/opencode/opencode.json
tmp="$(mktemp)"; jq 'del(.provider."google-vertex".options.baseURL)' "$runtime" > "$tmp" && mv "$tmp" "$runtime"
sudo systemctl restart opencode-serve.service

# Managed: gate OFF both providers (clear intent, then re-switch strips the overrides):
aigateway-disable && home-manager switch --flake .#cloudbox
```

`sudo systemctl stop aigateway.service` is NOT a rollback: the flag stays set,
so the canary restarts it within the minute and the next switch re-asserts the
overrides.

## Gotchas

- The `dev` stack's postgres is EPHEMERAL (no named volume) — a full stack
  recreate loses the ledger. Recreate gateway/migrate only, never the whole stack.
- `ExecStart` is `docker compose up -d --no-recreate`, which is what keeps that
  postgres alive across restarts — and the same flag means **compose-file changes
  never take effect via the unit**. A changed `docker-compose.yml` (e.g. #510's
  loopback port pin) needs a deliberate manual recreate of the affected service.
- Container restart policy is `no` on gateway/postgres/redis, so docker will not
  bring back a crashed container; `aigateway-canary` is the only thing that will.
  Adding `restart: unless-stopped` in the monorepo compose file would close that
  gap at the right layer.
- Gemini tool-use: `toolUsePromptTokenCount` is NOT added to input (mirrors
  `@ai-sdk/google` billing, which is opencode's source of truth). If a live
  tool-use call shows it reported separately from `promptTokenCount`, tool-use
  input is undercounted — confirm before relying on absolute Gemini input counts.
- Migrations follow the `flyway-timestamp-migrations` convention (14-digit UTC
  version). The ledger CHECK constraint allows tokens-without-dollars but forbids
  dollars-without-tokens.
- **1h-cache-TTL coupling:** `ProxyController.kt`'s `VERTEX_INCOMPATIBLE_BETA_HEADERS`
  strips the `extended-cache-ttl-2025-04-11` `anthropic-beta` because Vertex
  rejects it. Correct today (caching is flat 5m ephemeral), but it means a future
  move to **1h cache TTL would silently no-op on the Vertex leg**: a
  `cache_control: { ttl: "1h" }` rides along while the enabling beta is stripped
  here, so Anthropic-on-Vertex downgrades it to 5m (or 400s). If 1h TTL is ever
  reintroduced (see `docs/plans/2026-04-21-cache-write-mitigation-design.md`),
  revisit this filter: either stop stripping the beta for Vertex (only if Vertex
  has since added support — verify with a `rawPredict` probe) or scope the 1h
  marker to the first-party/Max (TeamClaude) leg only. Bead
  `claude-failover-proxy-rtq` (2026-06-20 caching audit).
