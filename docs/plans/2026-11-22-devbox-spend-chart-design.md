# devbox spend chart, with eternal-machinery runtime spend

Status: design, reviewed (adversarial-reviewer-opus, 2026-11-22: "proceed with
changes"; changes folded in below). Bead epic: `bd search "devbox spend chart"`.

## Goal

The Mac shows cloudbox's spend-by-program chart at `http://127.0.0.1:4710/?days=4`
(`oc-tags serve` on cloudbox, reached through the socket-activated
`cloudbox-chart-tunnel`). We want the **same chart for devbox** at
`http://127.0.0.1:4711/?days=4` on the Mac, showing:

- the opencode and goose sessions oc-tags already reads (dev sessions,
  stall-watch coordinators and what they launch), **priced** — see §0;
- **eternal-machinery (EM) in-game agent spend**, one band per persona:
  `em-agents:<persona>`;
- **EM benchmark spend**, one band per suite: `em-bench:<suite>`;
- EM **dev** sessions stay opencode/goose sessions carrying the
  `eternal-machinery` program tag, through the normal tagging path.

Everything on devbox is flat-rate (Claude Max via teamclaude, ChatGPT plans via
codex-lb). The chart is a **proxy for quota burn** at list price — the
constraint that actually bites is the Max plans running out (they did on
2026-11-22 at 17:06Z). It is not a bill.

Two separate charts, not merged: cloudbox's spend is billed Vertex, devbox's is
flat-rate, and the hosts share no data.

## Why the EM runtime is invisible today

| Caller | Path |
|---|---|
| agentos (agno) in-game agents, Run-B consolidation, `/em/summarize` (Haiku), the curator | letta-proxy `:4318` → teamclaude `:3456` → Anthropic |
| benchmark (`agentos/bench/*`), probes, social bench rig, `scripts/experiments/*` | the **scratch** letta-proxy `:4319` (hand-started, `PROXY_COUNT_PARITY=1`) → teamclaude |
| benchmark codex arms (`bench/codex_lb.py`) | codex-lb `:2455` directly |
| agentos codex-lb personas (`app.py:1743`) | codex-lb directly — **no persona uses one today** |
| Elixir OOC reader (`ooc_reader.ex`) | Gemini directly, off unless `OOC_READER=1` |

Nothing on the wire says who is calling (letta-proxy's "lineage" is a
system-prompt hash heuristic), and agentos shares one Claude model object across
personas with matching settings (`app.py:2637-2663`). Attribution must come from
the caller.

## Design (approach A: proxy ledger + attribution header)

### 0. Price devbox's opencode Claude rows (workstation, oc-tags)

On devbox, opencode's `anthropic` provider runs through
`@ex-machina/opencode-anthropic-auth` in oauth mode, which **zeroes every
model's cost** ("zero out cost for max plan"; relied on at
`opencode-config.nix:2576-2580`). oc-tags puts `cost == 0 && tokens > 0` rows in
the unpriced footer (`oc_tags.py:741-745`). Without a fix the chart would show
list-priced EM bands beside $0 for the biggest Max consumer, the Opus/Sonnet dev
sessions — wrong in exactly the direction that matters.

Fix: in `aggregate`, reprice rows with provider `anthropic`, cost 0 and tokens
present, from the rate table. **Verify on devbox first**: whether opencode's
`tokens.input` excludes cache read/write (pick the formula from data, not from
`compute_goose_cost`'s goose semantics), and whether goose's `usage_ledger.cost`
there is `0.0` rather than NULL — `compute_goose_cost` returns `(0.0, False)`
for a non-None zero (`oc_tags.py:507-508`), which is silently $0 and not even
listed as unpriced. Reprice that too if so.

### 1. Attribution (EM repo)

**The port decides the role; the header supplies only the name.** `:4318` is
`agents`, any other port `bench`. The standing rule already enforces this
(`AnthropicModel` and the probes refuse `:4318`). A header whose role disagrees
with the port is recorded under the port's role with `conflict: true`.

Header: `X-EM-Spend: <role>/<name>`, value grammar
`^(agents|bench)/[a-z0-9][a-z0-9_.-]{0,63}$`; senders lowercase the name. A
malformed value records as `<port-role>/invalid`.

- **agentos personas:** each persona gets its own Claude instance — add
  `spec.key` to the model cache key (as the codex-lb branch already does,
  `app.py:2656`) and put `default_headers={"X-EM-Spend": f"agents/{key}"}` in
  `client_params`. Race-free, unlike injecting per-request headers from
  `_before_every_request` on a shared instance (that wrapper can
  `await asyncio.to_thread` between setting and sending, `app.py:2112-2115`).
  Run B's `copy.copy(shared)` (`app.py:3097-3110`) inherits the dict, which is
  correct. The cost is one HTTP client per persona; the implementer re-reads the
  reason for the shared cache (xauuj, `app.py:2600-2603`) and records why it is
  safe to split. `test_agno_surface.py` pins `default_headers` reaching both the
  plain and beta async clients.
- **`/em/summarize`:** `agents/<agent_key>` per call (`summarize.py:374`, client
  built per call). **Curator:** `agents/curator`.
- **bench:** each CLI declares its suite once in `main()` (env `EM_SPEND`
  overrides); it reaches the wire through the **client**
  (`AnthropicModel._default_client` `default_headers`, `CodexLbModel._headers()`),
  never the request body (would change `request_hash` → `ManifestMismatch`,
  `manifest.py:448,458`). The social bench rig (`bench/social/agno_rig.py:256`)
  builds real agents through `app.build_agents` on `:4319`; port-decides-role
  records it as `bench/<persona>` unless it passes a suite name — it should
  (`Settings.spend_name`), as should the probes that reuse `app.build_model`.

### 2. Ledger (EM repo, `scripts/letta-proxy/proxy.py`)

- **Strip** `X-EM-Spend` from forwarded headers on every path
  (`transform_headers`, `proxy.py:214`).
- In `_log_cache` (`proxy.py:816`), which runs once per messages call after the
  final attempt (the replaced attempts are 401/400, unbilled; `count_tokens`
  never matches `is_messages_request`), append one line:

  ```json
  {"v":1,"key":"<uuid4>","at":"<ISO-8601 UTC>","port":4318,
   "spend":"agents/warrior_f","attributed":true,"conflict":false,
   "model":"claude-sonnet-5-5","status":200,"outcome":"ok",
   "input":12,"output":340,"cache_read":48210,"cache_write":340,
   "max_context":48562}
  ```

  All four counters are **summed over `usage.iterations`**, including
  **output** (`wire_totals` semantics, `agentos/usage.py:31-43`) —
  `cache_log_fields` sums only in/read/write and top-level `output_tokens` is the
  final iteration only, so reusing it would drop compaction summaries' output.
  `input` is uncached input. `max_context` = the largest per-iteration
  input+read+write, kept so long-context tiers (Haiku 5.5 bills 5× above 100k)
  can be priced later; v1 pricing ignores it.
- Upstream exception → 502: write a zero-token row with `outcome:"proxy_error"`
  so the call is counted, if not priced. Proxy shutdown mid-call
  (`CancelledError`) writes nothing; stated undercount.
- Missing header → `<port-role>/unknown`, `attributed:false`: visible before
  every caller is converted.
- **Monthly shards:** `${EM_SPEND_LEDGER_DIR:-${XDG_STATE_HOME:-~/.local/state}/eternal-machinery/spend}/spend-YYYY-MM.jsonl`,
  month of `at`, chosen per write. `O_APPEND`, one `os.write` per complete line
  (~300 B), return value checked; written from the existing `_analyse_call`
  worker thread. A failed write logs WARNING and never fails the call.
- `/health` adds `{"ledger": "<dir>"}`.
- `test_proxy.py` pins the ledger dir to a temp dir in `setUpModule` so tests
  never write the real ledger.

**Stale proxies** (the bench proxy has been run from a copy,
`~/bench-runs/proxy/bench-proxy-4319.py`; `:4318` is long-lived under devenv and
keeps running pre-change code until restarted):

- the chart's footer shows `EM ledger: last row Nh ago (:4318 …, :4319 …)` —
  catches every case;
- agentos logs a WARNING at boot if `/health` lacks `ledger`;
- bench CLIs that already call `_check_transport` probe `/health` **separately**
  and refuse to start without `ledger` (`EM_SPEND_ALLOW_NO_LEDGER=1` overrides,
  loudly). The probe must **not** go through `PROXY_SETTING_KEYS`
  (`model.py:41`): the transport descriptor is hashed and persisted
  (`development.py:1028`), so adding to it breaks resume/calibration identity.
  Fakes and codex-only runs skip the probe. Before forcing the repo proxy, the
  implementer finds out why the `~/bench-runs` copy existed (pinning code for a
  campaign?) and preserves that need.

### 3. codex-lb calls (EM repo, bench only)

`CodexLbModel.create` appends the same row client-side for **every response
`from_chat_response` returns** — including `provider_model_mismatch`,
`invalid_tool_arguments`, `refusal`, `max_tokens` (`codex_lb.py:390-405`), all
billed. `port: 2455`, model from `response["provider"]["model"]`. Its usage is
already Anthropic-shaped with `input_tokens = prompt − cached`
(`codex_lb.py:310-327`): **copy, don't subtract again**; `cache_read` = cached,
`cache_write` = 0. Writer: `agentos/spend_ledger.py`; the proxy stays a
standalone script and does not import it. The row format is the contract,
pinned by a test on each side. `CodexLbAmbiguousCall` carries no usage: no row,
stated undercount.

Not read instead: codex-lb's `request_logs` (upstream schema that churns,
`cost_usd` null, needs per-caller UA marking and a second reader). agentos codex
personas: none exist; a bead records the gap.

### 4. oc-tags reader (workstation, `pkgs/oc-tags/oc_tags.py`)

`read_em_ledger`, modelled on `read_lgtm_ledger` (`oc_tags.py:872`) but
**streaming line by line over only the monthly shards the window touches**
(the lgtm reader `readlines()` the whole file; the serve is capped at
`MemoryMax=1G`):

- dir `OC_TAGS_EM_LEDGER_DIR` / default above; absent → no rows, no warning;
- dedupe on `key`; `v != 1` or bad `at` → one warning with a count;
- root `em:<role>/<name>`, tag `em-agents:<name>` / `em-bench:<name>`, source
  `manual`, unless tags.db names the root;
- cost = `compute_goose_cost(model, input + cache_read + cache_write, output,
  cache_read, cache_write, None, day=...)` — that function takes goose-style
  *inclusive* input (`oc_tags.py:490`); the ledger stores uncached, so re-add.
  Pinned by a hand-computed test;
- unknown model → unpriced, never $0. Add missing rates: `claude-haiku-5-5` at
  minimum, and the codex models the bench uses (from `opencode-config.nix`'s
  codex-lb table);
- `proxy_error` rows: counted in the footer (`N proxy errors, unpriced`);
- not part of `claude_day`/cap/coverage (needs cfp; devbox has none);
- `load_aggregate`'s early return (`oc_tags.py:1026-1032`) must count the EM
  ledger as a source;
- `oc-tags which em:…` gets a branch like the `lgtm-goose:` one
  (`oc_tags.py:2019-2030`) instead of falling through to `auto:no-dir`;
- footer: ledger freshness per port (above).

Chart: `top_n` exists. Add `fold=<prefix>[,<prefix>]` summing `<prefix>:<x>`
tags into one band `<prefix>` before ranking. Default stays per-persona/per-suite
(the requested view); `fold=em-agents,em-bench` gives the family view, and
`top_n` can be raised if dev programs get pushed into "other".

### 5. devbox serve + Mac tunnel (workstation)

- `users/dev/oc-tags-serve.nix`: enable on devbox too, same `127.0.0.1:4710`.
- `scripts/update-ssh-config.sh`: `Host devbox-chart` **inside the devbox managed
  block** (picks up the hcloud IP), dedicated ControlPath, `ControlMaster no`,
  manual-fallback `LocalForward 4711 127.0.0.1:4710`.
- `users/dev/home.darwin.nix`: socket-activated `devbox-chart-tunnel` launchd
  agent on Mac `127.0.0.1:4711`, one `ssh -W` per connection. The cloudbox
  version's ControlMaster dance exists only because IAP spawns gcloud per
  connection; plain ssh to devbox is ~0.3 s, so drop it.
- Troubleshooting notes beside the cloudbox ones.

## Error handling

| Failure | Behaviour |
|---|---|
| ledger write fails | proxy WARNING; call unaffected; freshness footer may show it |
| stale proxy (no ledger code) | freshness footer; agentos boot WARNING; bench refuses |
| caller sends no header | `*/unknown` band |
| role/port disagree | port wins, `conflict:true` |
| row schema drift | one oc-tags warning with count |
| unknown model | unpriced entry |
| proxy 502 | zero-token `proxy_error` row, footer count |
| proxy shutdown mid-call / codex ambiguous call | no row; documented undercount |

## Testing

- proxy (`python -m unittest scripts/letta-proxy/test_proxy.py`): header
  stripped on messages and count_tokens; one row per final attempt; none for
  count_tokens; port-decides-role and conflict; invalid value; iteration sums
  incl. output; SSE; proxy_error row; shard by month; write failure tolerated;
  temp ledger dir.
- agentos: two personas with identical settings get distinct headers; Run B
  inherits; summarize/curator headers; social rig and probes not `agents`; bench
  client headers leave `request_hash` and `transport_sha256` unchanged; codex row
  for every returned outcome, no double subtraction; `/health` gate and override.
- oc-tags: reader fixtures (dedupe, schema warning, pricing, unpriced,
  proxy_error, shard selection by window, freshness), anthropic $0 repricing,
  `fold=`, `which em:…`.
- devbox: unit active, `curl 127.0.0.1:4710/healthz`; Mac:
  `curl 127.0.0.1:4711/?days=4` renders with EM bands.

## Follow-ups found during design (separate beads)

- `:4318` upstream timeout 120 s vs agentos client 600 s (`proxy.py:591`,
  `app.py:1721`): long calls 502 while Anthropic may still bill. Live bug.
- EM `bench/prices.py:41-46` has Sonnet 5.5 cache_read 0.20; oc-cost/oc-tags
  have 0.10 (re-checked 2026-11-19). ~2× disagreement on cache-heavy calls.
- Later: a teamclaude-observed-tokens vs chart-accounted footer — ground truth
  for coverage; would have caught §0 automatically.

## Out of scope

- Gemini OOC reader and `scripts/experiments/ooc_reader` Gemini calls.
- agentos codex-lb personas (none exist).
- Merging cloudbox and devbox charts.
- Measuring real Max quota consumption (teamclaude utilisation).
- EM running on cloudbox would chart there beside billed spend; not a case today.
