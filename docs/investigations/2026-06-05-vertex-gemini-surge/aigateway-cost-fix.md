# aigateway cost fix — opus capture + Gemini-on-Vertex support

**Date:** 2026-06-05
**Host:** cloudbox
**Repo:** `mono` (worktree `~/projects/mono-aigateway`, branch `no-jira-aigateway-cost-fix` off `origin/main`)
**Service:** `wonder/data/aigateway`
**Running stack:** docker-compose project `dev` (`dev-gateway-1`, `dev-postgres-1`, `dev-redis-1`), ports 8080/5432/6379

## Summary

Two defects fixed, plus one robustness improvement, all under TDD:

1. **Task 1 — opus cost capture (confirmed root cause).** `PriceTable` had no
   `claude-opus-4-8` entry, so `compute()` threw `IllegalArgumentException`,
   `ProxyController` caught it and dropped **both** tokens and dollars. 11,129
   `claude-opus-4-8@default` ledger rows had NULL usage/cost. Fixed by adding
   the authoritative `claude-opus-4-8` price (incl. its >200k tier).
2. **Task 1 — robustness.** When pricing is unknown, the gateway no longer
   discards the parsed token usage; it now persists tokens with NULL dollars.
   Required relaxing the `cost_breakdown_consistency` CHECK constraint via a new
   Flyway migration.
3. **Task 2 — Gemini-on-Vertex support.** Added a Gemini `usageMetadata` parser
   branch, a `gemini-3.5-flash` price entry, and publisher-aware routing in
   `ProxyController` so `publishers/google/.../:streamGenerateContent` traffic is
   parsed, priced, and ledgered.

All three verified live against the running stack. The opencode default-routing
flip for Gemini is **prepared but GATED** (see [§7](#7-gated-opencode-gemini-routing-ready-but-off)).

Diffstat (mono): 7 files changed, +496/-22, plus 1 new migration.

---

## 1. Task 1 — opus root cause (confirmed)

### Symptom
```
 model                     | rows  | with_tokens | with_dollars
---------------------------+-------+-------------+--------------
 claude-opus-4-8@default   | 11129 |           0 |            0
 claude-haiku-4-5@20251001 |   202 |         201 |          201
 unknown                   |   144 |           0 |            0
 claude-opus-4-8           |     1 |           0 |            0
```
Opus rows: 0% populated. Haiku rows: ~100% populated.

### Mechanism (verified by reading `origin/main`)
- [`PriceTable.kt`](../../../../mono/wonder/data/aigateway/server/PriceTable.kt)
  `prices` map had `claude-opus-4-7`, `-4-5`, `claude-sonnet-4-5`,
  `claude-haiku-4-5` — but **not** `claude-opus-4-8`.
- `PriceTable.compute()` strips the Vertex `@<version>` suffix
  (`model.substringBefore('@')` → `claude-opus-4-8`); the lookup misses and
  throws `IllegalArgumentException("Unknown model")`.
- `ProxyController` (`doOnComplete`) caught the exception, traced
  `aigateway.pricing.unknown_model`, and set **`finalUsage = null`** + cost
  null. So both the parsed tokens *and* the dollars were dropped, producing the
  all-NULL rows.

The haiku model was in the table, so its rows priced fine — confirming the
defect was model-table coverage, not the parse path.

### Fix
Added `claude-opus-4-8` to `PriceTable` with **authoritative** pricing sourced
from opencode's own billing DB (`~/.cache/opencode/models.json`, entry
`google-vertex-anthropic/claude-opus-4-8@default`) and `opencode.json`:

| Tier        | input | output | cache_read | cache_write (5m) |
|-------------|-------|--------|------------|------------------|
| under 200k  | 5.00  | 25.00  | 0.50       | 6.25             |
| over 200k   | 10.00 | 37.50  | 0.50¹      | 10.00 (1h)       |

¹ The `ModelPrices` struct carries a single `cacheRead`/cache-write rate, so the
flat 0.50/6.25/10.00 cache rates apply at both tiers. Authoritative over-200k
cache_read is 1.00 — see [§8 known gaps](#8-known-gaps--follow-ups). This mirrors
the existing `claude-sonnet-4-5` convention (tiered input/output, flat cache).

> **Verified, did not assume:** the prompt flagged opus-4-7 as `$5/$25`, cache
> `6.25/10/0.50`. Authoritative data confirms opus-4-8 matches opus-4-7
> **under 200k**, but opus-4-8 (and per models.dev, opus-4-7 too) has a >200k
> tier of `$10/$37.5`. The existing opus-4-7/4-5 entries are flat — a
> pre-existing under-charge above 200k, flagged in [§8](#8-known-gaps--follow-ups).

`PriceTable.kt` diff (new entry, abbreviated):
```kotlin
"claude-opus-4-8" to
  ModelPrices(
    input200kUnder = BigDecimal("5.00"),  input200kOver = BigDecimal("10.00"),
    output200kUnder = BigDecimal("25.00"), output200kOver = BigDecimal("37.50"),
    cacheWrite5m = BigDecimal("6.25"), cacheWrite1h = BigDecimal("10.00"),
    cacheRead = BigDecimal("0.50"),
  ),
```

### The 11,129 NULL rows cannot be backfilled
The tokens were never stored (the parse result was discarded at request time).
There is no source to reconstruct per-request token counts after the fact, so
those historical rows stay NULL. The fix is forward-looking only.

---

## 2. Task 1 — robustness: persist tokens when pricing is unknown

Even after adding opus-4-8, the next unknown model would repeat the data loss.
Changed `ProxyController` so the `unknown_model` catch keeps the parsed usage and
only nulls the cost:

```kotlin
// before:  catch (e) { trace(...); finalUsage = null; null }
// after:   catch (e) { trace(...); null }   // parsedUsage preserved
...
writeLedgerAsync(..., usage = parsedUsage, cost = parsedCost)
```

This was blocked by the DB: the original `cost_breakdown_consistency` CHECK
(migration `V20260507154731`) required the **entire** token+dollar group to be
atomically all-NULL or all-non-NULL, so "tokens present, dollars NULL" violated
it. New migration relaxes it into two independent groups + one cross-rule:

`V20260605181028__relax_cost_breakdown_consistency_allow_tokens_without_dollars.sql`
(created via `tools/new-migration.sh aigateway ...`, 14-digit UTC timestamp per
the flyway-timestamp-migrations skill):

- token group: atomically all-NULL or all-non-NULL
- cost group (dollars + `context_tier`): atomically all-NULL or all-non-NULL
- cross-rule: `total_dollars IS NULL OR input_tokens IS NOT NULL` (dollars
  require tokens; the inverse stays forbidden)

Allowed states: `(NULL,NULL)`, `(tokens,dollars)`, and the **new**
`(tokens,NULL)`. Existing rows are all in the first two states, so the new
constraint validates cleanly against current data (confirmed live below).

---

## 3. Task 2 — Gemini-on-Vertex support

### How opencode/Gemini hits Vertex (verified against the AI SDK)
From `@ai-sdk/google-vertex@4.0.112` and `@ai-sdk/google@3.0.73` in
`~/projects/opencode/node_modules`:
- gemini base URL: `https://{region-}aiplatform.googleapis.com/v1beta1/projects/{project}/locations/{region}/publishers/google`
  (note `v1beta1`, `publishers/google`, **no** trailing `/models`)
- streaming call: `${baseURL}/models/${modelId}:streamGenerateContent?alt=sse`
  (SSE response)
- non-streaming: `${baseURL}/models/${modelId}:generateContent`

So through the gateway a request looks like:
```
POST /v1beta1/projects/<p>/locations/global/publishers/google/models/gemini-3.5-flash:streamGenerateContent?alt=sse
Authorization: Bearer ya29...
```
`ProxyController`'s existing regexes already handle this:
`LOCATION_REGEX`→`global`, `MODEL_REGEX`→`gemini-3.5-flash`. The proxy/forward
path is publisher-agnostic (`InstrumentedAnthropicVertexClient.forward` is a
transparent HTTP forward by path), so **no transport branch was needed** — only
the usage-parse dialect and pricing differ.

### Changes
1. **`UsageParser.parseGemini(buffer, isStreaming)`** — parses Gemini
   `usageMetadata` (SSE-streamed for `streamGenerateContent`; usage is in the
   final/cumulative chunk). Field mapping follows the AI SDK's billing
   convention (`convertGoogleGenerativeAIUsage`):
   - `inputTokens  = promptTokenCount - cachedContentTokenCount`
   - `cacheRead    = cachedContentTokenCount`
   - `outputTokens = candidatesTokenCount + thoughtsTokenCount` (thinking bills as output)
   - cache-creation / ephemeral = 0 (Gemini has no per-request cache-write tokens)

   Handles SSE (`data:` lines, take last `usageMetadata`), a single JSON object
   (`generateContent`), and a JSON array (non-SSE `streamGenerateContent`).
2. **`PriceTable` `gemini-3.5-flash`** — flat input 1.50 / output 9.00 /
   cache_read 0.15 per 1M (authoritative: `models.json` +
   `opencode.json google-vertex/gemini-3.5-flash`). No >200k tier, no
   cache-write (cache-write rates = 0).
3. **`ProxyController`** — `PUBLISHER_REGEX = /publishers/([^/]+)`; if publisher
   is `google` → `usageParser.parseGemini(...)`, else `usageParser.parse(...)`.
   Also extended `requestedStreaming` to recognize `:streamGenerateContent`.

### Auth path unchanged (works for Gemini)
`AuthFilter` and `EmailResolver` are path-agnostic — they operate on the
`Authorization` bearer (`ya29...` → Google `tokeninfo` → email), independent of
publisher. The live Gemini test below resolved the caller email correctly.

---

## 4. Test results (TDD, `bazel test --config ai`)

Every change was written test-first (RED → GREEN). Full suite:

```
//wonder/data/aigateway/db:db-ktlint-test                              PASSED
//wonder/data/aigateway/server:server_lib-ktlint-test                 PASSED
//wonder/data/aigateway/server/testing:AuthFilterTest                 PASSED (+ktlint)
//wonder/data/aigateway/server/testing:EmailResolverTest              PASSED (+ktlint)
//wonder/data/aigateway/server/testing:LedgerWriterTest               PASSED (+ktlint)
//wonder/data/aigateway/server/testing:PriceTableTest                 PASSED (+ktlint)
//wonder/data/aigateway/server/testing:ProxyControllerTest            PASSED (+ktlint)
//wonder/data/aigateway/server/testing:UsageParserTest                PASSED (+ktlint)
Executed 14 tests: 14 pass.
```

New/changed tests:
- `PriceTableTest`: opus-4-8 under/over 200k, opus-4-8 `@default` suffix,
  gemini-3.5-flash priced, gemini flat above 200k.
- `UsageParserTest`: gemini `generateContent` object, gemini SSE (final
  usageMetadata, thoughts→output, cached subtraction), gemini JSON array,
  null/empty cases.
- `ProxyControllerTest`: unknown-model now **persists usage with null cost**
  (was: null/null); google publisher path routes to `parseGemini` and writes
  usage+cost (and `parse` is NOT called).
- `LedgerWriterTest`: tokens-without-dollars now **succeeds** (was: expected
  constraint violation); added inverse `dollars-without-tokens` still violates;
  kept `cost-without-context_tier` violates.

---

## 5. Deploy verification (live, against the running `dev` stack)

Rebuilt jars from the worktree, staged compose files + jars into the running
stack's working dir (`~/projects/mono/wonder/data/aigateway/dev/`), then
rebuilt **only** `migrate` + `gateway` (postgres/redis untouched → existing
ledger preserved, so the migration was validated against the real 11,476 rows).

### Migration applied to the live DB
```
Current version of schema "public": 20260507154731
Migrating schema "public" to version "20260605181028 - relax cost breakdown consistency..."
Successfully applied 1 migration to schema "public", now at version v20260605181028
```
`aigateway_flyway_schema_history` now lists both migrations (`success = t`), and
`pg_get_constraintdef(cost_breakdown_consistency)` shows the relaxed two-group +
cross-rule form. Existing 11,129 all-NULL opus rows validated fine.

### 5a. Opus fix — real call through gateway (NEW populated row)
`POST .../publishers/anthropic/models/claude-opus-4-8@default:streamRawPredict`
with a real `gcloud auth print-access-token` → HTTP 200,
`X-Gateway-Request-Id: a6affe6a-...`. Ledger:
```
request_id           | a6affe6a-d7af-4a11-a02b-8dbe7576644a
user_email           | jmohrbacher@wonder.com
model                | claude-opus-4-8@default
http_status          | 200
input_tokens         | 16
output_tokens        | 4
total_context_tokens | 16
input_dollars        | 0.000080   (16 × 5.00/M ✓)
output_dollars       | 0.000100   (4 × 25.00/M ✓)
total_dollars        | 0.000180
context_tier         | under_200k
```

### 5b. Gemini — real call through gateway (NEW populated row)
`POST .../publishers/google/models/gemini-3.5-flash:streamGenerateContent?alt=sse`
→ HTTP 200, `Content-Type: text/event-stream`. usageMetadata:
`promptTokenCount=7, thoughtsTokenCount=13`. Ledger:
```
request_id           | ed6b5c05-d2e2-470b-919c-da39c9bc54d7
user_email           | jmohrbacher@wonder.com
model                | gemini-3.5-flash
region               | global
http_status          | 200
is_streaming         | t                (SSE correctly detected)
input_tokens         | 7                (7 prompt − 0 cached)
output_tokens        | 13               (0 candidates + 13 thoughts)
input_dollars        | 0.000011         (7 × 1.50/M ✓)
output_dollars       | 0.000117         (13 × 9.00/M ✓)
total_dollars        | 0.000128
context_tier         | under_200k
```

### 5c. Robustness — unpriced model persists tokens (NEW row, NULL dollars)
`gemini-2.5-flash` (real model, intentionally NOT in PriceTable) → HTTP 200:
```
model                | gemini-2.5-flash
input_tokens         | 7
output_tokens        | 12
total_dollars        | (null)    ← previously the whole row would be all-NULL
context_tier         | (null)
```
Demonstrates the robustness fix live: tokens survive even when pricing is
unavailable.

### 5d. Gemini thinking-token arithmetic (review follow-up, verified live)
PR review (Krosantos) flagged that `output = candidatesTokenCount +
thoughtsTokenCount` is only correct if `candidatesTokenCount` *excludes*
thinking tokens. Confirmed live with a thinking-enabled `gemini-3.5-flash`
request (both fields non-zero):
```
promptTokenCount=37  candidatesTokenCount=24  thoughtsTokenCount=157  totalTokenCount=218
37 + 24 + 157 = 218 == totalTokenCount   →  candidates and thoughts are DISJOINT
```
Ledger row: `input_tokens=37, output_tokens=181 (24+157), output_dollars=0.001629`.
The additive mapping is correct; no double-count. Documented in-code at
`UsageParser.parseGeminiUsageNode` so the sum isn't collapsed later.

### Post-deploy ledger (rows created after deploy)
```
 model                   | rows | with_tokens | with_dollars
-------------------------+------+-------------+--------------
 claude-opus-4-8@default |   44 |          44 |           44   ← 100% populated (was 0%)
 gemini-3.5-flash        |    1 |           1 |            1
 gemini-2.5-flash        |    1 |           1 |            0   ← robustness (unpriced)
```
The 44 opus rows include this very opencode session's own opus turns now flowing
through the fixed gateway — additional live proof under real traffic.

---

## 6. Files changed (mono PR)

```
M wonder/data/aigateway/server/PriceTable.kt           (+ opus-4-8, gemini-3.5-flash)
M wonder/data/aigateway/server/UsageParser.kt          (+ parseGemini dialect)
M wonder/data/aigateway/server/ProxyController.kt       (publisher routing + keep usage on unknown price)
M wonder/data/aigateway/server/testing/PriceTableTest.kt
M wonder/data/aigateway/server/testing/UsageParserTest.kt
M wonder/data/aigateway/server/testing/ProxyControllerTest.kt
M wonder/data/aigateway/server/testing/LedgerWriterTest.kt
A wonder/data/aigateway/db/migrations/V20260605181028__relax_cost_breakdown_consistency_allow_tokens_without_dollars.sql
```
No BUILD changes needed (`server_lib` globs `*.kt`; `migration_files` globs
`migrations/*.sql`).

---

## 7. GATED: opencode Gemini routing (ready but OFF)

> **Do not enable without explicit sign-off.** `google-vertex/gemini-3.5-flash`
> is the **global default model** on cloudbox (`opencode.json .model =
> "google-vertex/gemini-3.5-flash"`). A broken gateway route would break **all**
> Gemini sessions on this host (interactive + `opencode-serve`/pigeon/Telegram).
> The gateway side is now safe and verified; only the routing flip is gated.

### What changes
Today `opencode.json` only overrides the **anthropic** provider's baseURL
(`provider.google-vertex-anthropic.options.baseURL` → `http://localhost:8080/...
/publishers/anthropic/models`). The **Gemini** provider (`google-vertex`) has no
override, so it goes direct to Vertex and never hits the ledger.

To route Gemini through the gateway, set:
```
provider.google-vertex.options.baseURL =
  "http://localhost:8080/v1beta1/projects/<project>/locations/global/publishers/google"
```
**Shape verified twice:** (a) against `@ai-sdk/google-vertex` `getBaseURL`
(`v1beta1`, `publishers/google`, no trailing `/models`); (b) by the live test in
§5b — that exact path returned 200 + a populated ledger row.

### Recommended implementation (workstation — NOT applied here)
Extend `home.activation.injectAigatewayBaseUrl` in
`users/dev/opencode-config.nix` to write/strip the Gemini override alongside the
existing anthropic one. In the **inject** branch (after the anthropic `jq`):
```bash
gemini_url="http://localhost:8080/v1beta1/projects/$project/locations/global/publishers/google"
tmp="$(mktemp "${runtime}.tmp.XXXXXX")"
jq --arg url "$gemini_url" \
  '.provider."google-vertex".options.baseURL = $url' "$runtime" > "$tmp"
mv "$tmp" "$runtime"
```
In the **strip** branch (mirror the anthropic del-ladder for `google-vertex`):
```bash
jq 'del(.provider."google-vertex".options.baseURL)
    | if .provider."google-vertex".options == {} then del(.provider."google-vertex".options) else . end
    | if .provider."google-vertex" == {} then del(.provider."google-vertex") else . end
    | if .provider == {} then del(.provider) else . end' "$runtime" > "$tmp"
mv "$tmp" "$runtime"
```
Fold the gemini URL into the existing `new_hash` so the opencode-serve
auto-restart still fires on change. Keep it gated on the same
`systemctl is-active aigateway.service` + `GOOGLE_CLOUD_PROJECT` trigger.

> This report deliberately does **not** modify any workstation file.

### Manual enable (fastest, reversible, no Nix change) — for the sign-off test
```bash
# ENABLE Gemini routing:
runtime="$HOME/.config/opencode/opencode.json"
project="$(gcloud config get-value project)"   # or /run/secrets/google_cloud_project
url="http://localhost:8080/v1beta1/projects/$project/locations/global/publishers/google"
tmp="$(mktemp)"; jq --arg url "$url" '.provider."google-vertex".options.baseURL=$url' "$runtime" > "$tmp" && mv "$tmp" "$runtime"
sudo systemctl restart opencode-serve.service     # pick up for serve sessions

# VERIFY: send any prompt in a NEW session, then:
docker exec dev-postgres-1 psql -U aigateway -d aigateway -c \
  "SELECT model,http_status,total_dollars FROM gateway_request_log \
   WHERE model LIKE 'gemini%' ORDER BY id DESC LIMIT 3;"

# DISABLE (panic button):
tmp="$(mktemp)"; jq 'del(.provider."google-vertex".options.baseURL)' "$runtime" > "$tmp" && mv "$tmp" "$runtime"
sudo systemctl restart opencode-serve.service
```
The Nix activation will re-assert the managed state on the next
`home-manager switch`, so the manual edit is a temporary test toggle.

### Pre-un-gate checklist (do before flipping the flag)
- [ ] One live **thinking-enabled** Gemini call confirms `output = candidates +
      thoughts` (done once already in §5d; re-confirm if the model/SDK changes).
- [ ] One live **tool-use** (function-calling) Gemini call to confirm whether
      `toolUsePromptTokenCount` is reported *separately* from
      `promptTokenCount`. If `total = prompt + candidates + thoughts + toolUse`
      (separate), input is undercounted on tool-use traffic and the parser must
      add it (see [§8](#8-known-gaps--follow-ups)). opencode's own AI SDK ignores
      this field, so the current parser stays consistent with opencode's billing
      either way — but tool-use is opencode's dominant traffic, so confirm before
      un-gating.
- [ ] Confirm the gateway stack's postgres durability posture is acceptable for
      production-default Gemini volume (currently ephemeral).

### Risks to weigh before sign-off
- Gemini is the global default → blast radius = every session on cloudbox.
- The aigateway docker stack is currently a dev/volunteer stack with an
  **ephemeral** postgres (no named volume); a stack recreate loses the ledger.
- No auto-bypass on gateway-down (matches the anthropic design's "FAFO"
  posture): if the gateway is down with the override set, Gemini calls get
  connection-refused.

---

## 8. Known gaps / follow-ups

1. **opus-4-7 / opus-4-5 are flat-priced above 200k.** Authoritative data shows
   both have a >200k tier (input 10 / output 37.5). Their existing PriceTable
   entries charge the flat under-200k rate above 200k — a pre-existing
   under-charge, left out of scope (this PR only adds opus-4-8 correctly).
   Recommend a follow-up to align them.
2. **Cache rates aren't tiered.** `ModelPrices` has a single `cacheRead` /
   cache-write rate, so opus-4-8 >200k cache_read uses 0.50 (authoritative:
   1.00). Affects only cache-heavy >200k opus requests. A structural fix (tiered
   cache rates) would address opus-4-8 and the others uniformly.
3. **Gemini multimodal pricing.** The ledger prices on total token counts;
   `gemini-3.5-flash` lists `input_audio` at 1.5 (= text input here, so no
   difference today), but image/video token pricing nuances are not modeled.
4. **`gemini-2.5-flash` (and other live Gemini models) are unpriced.** Only the
   opencode-declared default (`gemini-3.5-flash`) is in the table; others now
   ledger tokens with NULL dollars (robustness path). Add entries if those
   models start flowing.
5. **`toolUsePromptTokenCount` is not added to input.** The Gemini parser mirrors
   `@ai-sdk/google`'s `convertGoogleGenerativeAIUsage` (opencode's billing
   source), which uses `promptTokenCount` alone. If a live tool-use call shows
   `toolUsePromptTokenCount` is reported separately from `promptTokenCount`,
   tool-use input is undercounted — revisit before un-gating (see the pre-un-gate
   checklist in [§7](#7-gated-opencode-gemini-routing-ready-but-off)). Documented
   in-code at `UsageParser.parseGeminiUsageNode`.
```
