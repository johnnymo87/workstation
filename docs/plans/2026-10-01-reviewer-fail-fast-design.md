# Fail fast when a codex-lb-backed subagent's model is unavailable

Date: 2026-10-01 · Host where observed: devbox · opencode 1.18.18-patched.5 · codex-lb 1.24.0

## Incident

Between 09:56 and 10:52 EDT, seven `adversarial-reviewer-astra` children
(`openai/gpt-6-astra`) were dispatched. Each assistant message had zero parts and
stayed `busy` for hours. Their six parents sat on a `task` tool part in `running`,
so they never went idle and never sent a stop notification. The AGENTS.md fallback
("astra errors or returns empty -> use -opus") never fired, because the dispatch
neither errored nor returned.

## Root cause (verified on the live path)

1. **codex-lb waits silently instead of answering.** Every codex-lb account had
   been `usage_limit_reached` since about 00:02 EDT. When a `/v1/responses`
   request finds no selectable account, codex-lb's HTTP bridge
   (`_http_bridge_capacity_wait_plan`, `http_bridge/streaming.py:599`) sleeps in
   300 s chunks ("Waiting for an account to recover ...") until
   `http_responses_session_bridge_request_budget_seconds` (default **7200 s**) is
   used up, and only then returns `429 usage_limit_reached`.
   - **No bytes during the wait.** With `propagate_http_errors`, codex-lb sends
     nothing at all, not even response headers. curl confirms this: `gpt-6-astra`,
     a bogus `gpt-bogus-xyz` and the listed `gpt-5.6-luna` all gave
     `0 bytes received` at 55 s.
   - **Incident request `2414c5eb`:** the wait started at 09:56:47 and the 429 came
     at 11:56:47.
   - **Disconnects are not detected.** codex-lb never checks for a client
     disconnect during this wait. An aborted request stays parked and keeps logging
     every 300 s.
2. **"astra absent from the catalog" is a symptom, not the cause.** A listed
   model (luna) and a bogus one hang the same way. Both come from the same
   no-active-account state.
3. **opencode had no effective pre-header bound for openai.**
   - `chunkTimeout` only wraps the response body: `wrapSSE` runs after `fetch`
     resolves.
   - opencode 1.18.18 ships an openai `headerTimeout` default of 300 s
     (`provider.ts:208`), but **it never applies here**. The custom loader only
     runs if `result.autoload || providers[providerID]` (`provider.ts:1559`), and
     on our hosts `providers.openai` does not exist yet at that point (no env key;
     `auth.json` holds only `anthropic`). The config providers are merged
     afterwards.
   - **Baseline:** `opencode run -m openai/gpt-5.6-luna` against the stalled
     codex-lb showed no timeout after 6+ minutes.
   - **Incident serve log** (`ses_f083f2387ffe2yA5gEmUHNAVde`):
     - `stream` at 13:56:46Z.
     - `stream error ... Rate limit exceeded` at **15:56:47Z**.
     - A retry 2 s later, into another 2 h wait.
     - Manual cancel at 17:52Z.
   - **An explicit `provider.openai.options.headerTimeout` works.** With 20000,
     opencode raised `ProviderHeaderTimeoutError`, retried 5 times, and the
     session errored after 188 s total.
4. **The task tool swallows the child's error.** `runTask` returns the child's last
   text part or `""`, and never looks at the message `error`. In the end-to-end
   test the parent received `state="completed"` with an empty `<task_result>`.

## Fix

### A. `provider.openai.options.headerTimeout = 120000` (opencode.base.json, all hosts)

- **Bound.** A codex-lb that stalls before sending headers now fails within about
  13 min instead of hours. The arithmetic: 6 attempts × 120 s, plus about 60 s of
  retry backoff. The attempt count is opencode's current one (5 retries,
  observed). If a build ships our `retry-cap.patch` value of 8, the bound grows to
  about 22 min.
- **Healthy-but-slow astra is unaffected.**
  - Healthy codex-lb holds headers only for its 2 s startup probe
    (`_HTTP_BRIDGE_STARTUP_ERROR_PROBE_SECONDS`). After headers it injects an SSE
    keepalive every 10 s (`sse_keepalive_interval_seconds`).
  - Over 30 days of successful astra messages (4174), the time from message
    creation to its first part had a maximum of 66 s. That one outlier had already
    received its `200 OK` within 2 s.
  - A header timeout cannot fire mid-stream, unlike the 600 s `timeout` that was
    removed in 2026-07.
- **Not covered: stalls after headers.** Keepalives defeat both `chunkTimeout`
  and this setting, so those are bounded only by codex-lb's own timers (up to
  2 h).
- **Watch: local per-account caps.** `account_stream_cap` (8) and
  `account_response_create_cap` (4) on our single account also trigger the
  header-holding wait. That would happen with more than 8 concurrent openai
  streams. The journal since 09-20 shows 0 such waits; all 543 were usage-limit
  waits.

### B. Plugin `assets/opencode/plugins/subagent-failure.ts` (all hosts)

1. **`tool.execute.before`: pre-dispatch probe.** For a `task` call whose
   `subagent_type` ends in `-astra`, it runs `astra-probe` (12 s timeout).
   - **DOWN (exit 1):** it throws. The parent's Task call fails in seconds with
     "`<agent>` was NOT dispatched … astra-probe: `<reason>` … Dispatch
     `<base>-opus` …".
   - **UP, UNKNOWN, missing binary, or timeout:** it fails open.
   - **Why before dispatch:** this covers the common outage without ever creating
     the parked codex-lb requests that header-timeout retries leave behind. Those
     requests would fire upstream, and burn quota, once the account recovers.
   - **Throw, not reroute:** the error is explicit, and the parent's existing
     fallback rule makes the announced switch to opus.
2. **`tool.execute.after`: surface the child's error.** For a non-background,
   `state="completed"` task block, it fetches the child's newest message
   (`limit=1`, 5 s timeout).
   - **If that message carries `error`:** it rewrites the block to
     `state="error"` / `<task_error>` and includes:
     - the agent and model;
     - the error text;
     - "This is NOT a result";
     - any partial text, labelled TRUNCATED;
     - the fallback to `<base>-opus` for `-astra`/`-fable`, or generic advice for
       other agents (no invented twins).
   - **If the lookup fails:** the output is left untouched (fail-open). The same
     applies when the hook itself throws, when `output` is undefined (the
     slash-command subtask failure path; a throw there would re-run the
     subtask), and when the result is over the 50 KB / 2000-line tool-output cap
     (upstream truncates it before the hook runs, so the block regex misses).
   - **Fallback advice:** an `-opus` twin's failure gets "do not substitute;
     stop and report", because it *is* the fallback. Other agents get "report
     the failure".
   - **Known gap:** the before-hook's refusal is a clean tool error on the normal
     Task path, but on the slash-command subtask path it would surface as a
     defect. No command is bound to an `-astra` agent today.

Both hooks are verified end to end on a throwaway `opencode serve`, which uses
loopback `ctx.client`, unlike in-process `opencode run`:

- The refusal arrived in 10 s.
- The header-timeout child came back as `<task_error>` after 129 s (with a 10 s
  test timeout).

### Oracle twins: covered deliberately

`oracle-astra` and `adversarial-reviewer-astra` come from the same
`mkAstraVariant` and use the same provider. A therefore covers both, and B keys
on the `-astra` suffix, so it covers both too. Fixing only the reviewer would
leave `oracle-astra`, which is also a devbox default, with the identical hang. No
agent-file or generator change is needed. The descriptions' fallback clause now
reads "is refused, errors, or returns empty".

### Docs

- **`assets/opencode/AGENTS.md`:** the dead-astra cases are now loud.
  - **Hang:** a hang is defined by **lack of progress**, not elapsed time. 19% of
    healthy astra children run longer than 15 min, and the maximum was 740 min.
  - **Who acts:** the human or a watcher acts on a hang. The blocked parent
    cannot.
- **Shepherding skill and the `opencode-agents` skill:** the same wording.

## Deployment (not done in this PR)

- **Apply:** `home-manager switch`, then wait for the pool to restart (nightly
  reset, or a manual pool restart). Serves read config and plugins at boot.
- **Rollback:** the runtime merge keeps keys that are no longer managed, so a
  revert must also run
  `jq 'del(.provider.openai.options.headerTimeout)'` on
  `~/.config/opencode/opencode.json`.

## Follow-ups

- **codex-lb:** fail fast when every account is usage-limited (it already does
  for `no_accounts`), or detect disconnects during the capacity wait.
- **astra-probe:** it reported "absent from catalog" when the primary state was
  "no account active". Check accounts first.
- **Upstream opencode:**
  - The openai `headerTimeout` default is skipped when the provider is
    config-only.
  - The task tool drops the child's error. B is a local shim for this.
