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
| Lifecycle | `sudo systemctl {start,stop,status} aigateway.service` (system unit; compose dir from the `aigateway_dir` sops secret) |
| Health | `curl -s localhost:8080/actuator/health` → `{"status":"UP"}` |
| Ledger | db `aigateway`, user `aigateway`, in `dev-postgres-1`; table `gateway_request_log` |
| opencode routing | `home.activation.injectAigatewayBaseUrl` in `users/dev/opencode-config.nix` |
| Gateway code | `$GW/server/{PriceTable,UsageParser,ProxyController}.kt`; migrations in `$GW/db/migrations/` |

## Routing opencode through the gateway

`injectAigatewayBaseUrl` rewrites `~/.config/opencode/opencode.json` on every
`home-manager switch`, gated on BOTH `systemctl is-active aigateway.service` AND
the `google_cloud_project` secret. When enabled it sets two baseURLs (with the
project baked into the path):

- `provider.google-vertex-anthropic.options.baseURL` → `http://localhost:8080/v1/projects/$p/locations/global/publishers/anthropic/models`
- `provider.google-vertex.options.baseURL` (gemini) → `http://localhost:8080/v1beta1/projects/$p/locations/global/publishers/google` (note `v1beta1`, no trailing `/models`)

When the gateway is stopped OR the secret is missing, it strips both → opencode
hits Vertex directly. Apply changes:

```bash
home-manager switch --flake .#cloudbox
```

If eval fails with `access to absolute path '/home' is forbidden in pure
evaluation mode` (caused by any absolute-path reference in the flake), append
`--impure`.

> `gemini-3.6-flash` is the GLOBAL DEFAULT model on cloudbox, so routing it makes
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

Then confirm health is `UP` and a fresh request produces a populated ledger row.

## Rollback / panic toggle

```bash
# Fastest, temporary (re-asserted on next home-manager switch):
runtime=~/.config/opencode/opencode.json
tmp="$(mktemp)"; jq 'del(.provider."google-vertex".options.baseURL)' "$runtime" > "$tmp" && mv "$tmp" "$runtime"
sudo systemctl restart opencode-serve.service

# Managed: gate OFF both providers (stop gateway, then re-switch strips the overrides):
sudo systemctl stop aigateway.service && home-manager switch --flake .#cloudbox
```

## Gotchas

- The `dev` stack's postgres is EPHEMERAL (no named volume) — a full stack
  recreate loses the ledger. Recreate gateway/migrate only, never the whole stack.
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
