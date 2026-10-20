# Goose turn-error state in the nvim pickers

Bead: honk-9qf.15.11.3 (honk beads; parent honk-9qf.15.11, goose sessions in
the `,fs`/`,fp` pickers). Follows `2026-10-19-goose-sessions-in-pickers.md`,
whose rows map goose sessions with `error: false` always.

## Problem

An opencode session whose last turn failed shows as `error` in `,fs`/`,fp`:
pinned to the attention group, piercing facets. A goose session whose last
turn failed shows `idle`, so a failed run looks finished.

## What goose does today (patched/v1.54.0, measured in source)

Most provider failures are NOT reported as failures over ACP:

- `crates/goose/src/agents/agent.rs` (classic loop, the default): in the
  provider-response match, these branches set `provider_errored = true`,
  yield an ordinary assistant TEXT message, and `break` the provider loop:
  - `ContextLengthExceeded` when recovery compaction fails
    ("Ran into this error trying to compact: ..."). When compaction SUCCEEDS
    the same branch continues and the turn may still succeed.
  - `Refusal` ("The provider refused this request...", sets exit_chat).
  - `NetworkError` ("<err>\n\nPlease resend your message to try again.").
  - any other `ProviderError` ("Ran into this error: <err>...").
  - `CreditsExhausted` (yields a SystemNotification) and `Authentication`
    (yields `MessageContent::Error{kind: Authentication}`).
  The ACP turn then ends `stopReason: end_turn`.
- `crates/goose/src/acp/server.rs` `forward_agent_stream` converts only
  Authentication / CreditsExhausted content into a JSON-RPC error
  (`prompt_error_from_message_content`), plus agent-stream `Err` and
  `reply()` setup `Err`.
- `state_machine` (off unless `GOOSE_STATE_MACHINE` or
  `_meta.goose.unrolledAgentLoop`): failures end as a trailing
  `MessageContent::Error` (e.g. ops_retry "Maximum retry attempts...",
  kind Other) and exit_on_error ends the turn.
- After a provider failure the loop can still continue: `can_drain_pending_steers`
  lets a steer queued during the turn start another iteration, which may
  succeed.

So honkd, which sees only the ACP reply, cannot tell a failed turn from a
finished one except for the JSON-RPC subset.

## Decision (option B of three)

A. honkd tracks only JSON-RPC error replies: misses the common case.
B. **The goose fork reports the turn's failure in the prompt response;
   honkd records it per session; honk list and the pickers show it.**
C. honkd pattern-matches goose's error phrasings: breaks silently on any
   wording change.

## Design

Revised after the design review (adversarial-reviewer-opus, 2026-10-20,
verdict BUY-IN WITH CHANGES; /tmp/goose-turn-error-design-review.md). Changes
from that review are marked (review).

### 1. goose fork (patch 15, `patched/v1.54.0`)

The ACP `session/prompt` response carries
`_meta.goose.turnError = { "kind": "<kind>", "message": "<text>" }` when the
turn ENDED in a failure; absent otherwise. `message` is capped at 2 KB on a
UTF-8 character boundary (review).

Terminal failure paths and their kinds (review: the first draft missed five):

| Path (agent.rs, classic loop) | kind |
|---|---|
| pre-loop auto-compaction failure in `reply_impl` (~2738-2745, `return`) | `context_length` |
| in-loop recovery compaction failure (~3622-3632) | `context_length` |
| context still exceeded after compaction, `compaction_attempts >= 2` (~3581-3590) | `context_length` |
| `Refusal` (~3660-3675) | `refusal` |
| `NetworkError` (~3691-3702) | `network` |
| any other `ProviderError` (~3703-3714) | `provider` |
| self-compaction failure, not cancelled (~3042-3053) | `self_compact` |
| recipe retry `MaxAttemptsReached` / retry-logic error (~3847-3867) | `retry_exhausted` |
| empty response after retries, `EMPTY_TURN_MESSAGE` (~3836-3845) | `empty_response` |
| structured output unsupported (~2619-2631) | `unsupported` |
| state machine: trailing `MessageContent::Error` when the machine finishes | `provider` (or `retry_exhausted` for ops_retry) |

Not turn errors (decided): max turns (a stop, not a failure; ACP's
`max_turn_requests` stopReason is the right channel and out of scope), a
failing slash command such as a manual `/compact` (the user ran a command;
the session is not failing), tool failures. Auth and credits already end
the turn with a JSON-RPC error; the slot is not needed for them.

Mechanism: a turn-error slot on the `Agent`, not a new `AgentEvent` variant
(`AgentEvent` is matched without wildcard arms in goose-cli, gateway and
subagents; a variant means patching them all on every rebase).

- `Agent.turn_errors: Mutex<HashMap<session_id, TurnError>>`, keyed by
  session like steers and `self_compact_runs` (review).
- Reset for the session at the TOP of `reply()` / `reply_impl`, before the
  pre-loop compaction, not inside `reply_internal` (review).
- Set in each terminal path above. Cleared again when a provider response in
  the same turn succeeds (the `Ok` arm, once per iteration via a local
  flag), so recovery after compaction, a steer, a goal/grind nudge or a
  stop-hook deny that then succeeds ends clean. Chunks are ordered, so
  Ok-then-Err within an iteration ends set.
- State machine: `reply_with_state_machine` checks `trailing_error` once the
  machine finishes and sets the slot (`ExitOnErrorOperation` has no Agent).
- ACP `on_prompt` takes the slot RIGHT AFTER `forward_agent_stream` returns
  and BEFORE `clear_active_run` (review: after the run is cleared, another
  prompt on the same connection could start a run on the same Agent and
  reset the slot). Not taken (and not reported) when the turn was cancelled
  or `forward_agent_stream` returned `Err`.

Agents and runs (corrected, review): each ACP connection has its own
`AgentManager`, so roaming connections can hold distinct Agents for one
session; the RUN is unique across connections (shared registry). `on_prompt`
reads the slot on the same `Arc<Agent>` it called `reply()` on, so the read
is correct. Subagents build their own Agent.

Nothing is persisted in sessions.db (no schema change). Alternative
considered: goose persists the last turn error per session and returns it
from `session/list`; covers non-honkd clients but needs a DB write per failed
turn and a bigger session-store patch. All interactive goose use here goes
through honkd, and `goose run` recipe runs are hidden from the picker.

### 2. honkd

- `State.turn_errors: BTreeMap<sid, {kind, message, at_unix}>` with a
  FIELD-level `#[serde(default)]` (load-bearing: `State` has no
  container-level default, and a missing field would make `StateStore::open`
  refuse to start). Test: a pre-change state.json loads (review).
- Record / clear SYNCHRONOUSLY in the actor's `Action::Reply` arm, in actor
  order, not in `handle_reply_text` after the export spawn (review: a parked
  turn N+1 failing inline could be recorded before turn N's late clean reply,
  which would then clear it). Writes are folded into the existing state
  mutate for the reply, and a clear writes only when an entry exists (no
  extra save on clean turns).
- Clear at run start (`on_run_state(Some)` / the run being announced), like
  opencode's clear-on-busy, so "running => not errored" holds by
  construction (review).
- Rules for a TURN reply:
  - `Result` with `_meta.goose.turnError` -> record `{kind, message}`.
  - `Result` without it, genuine stopReason (including a user cancel) ->
    clear.
  - honkd-synthesized interrupt `Result{cancelled, _meta.honk.reason}` with
    reason `upstream_restart` or `delivery_unknown` -> record
    `{kind: "interrupted"}`; reason `cancelled` -> clear (review).
  - `Reply::Error` that is not busy (auth, credits, stream error,
    upstream gone) -> record `{kind: "rpc", message}`.
  - `on_prompt_send_failed` (`turn: None`, the prompt never reached goose)
    -> record `{kind: "rpc"}`: the user's last attempt failed (review:
    decided explicitly).
  - Boot-time lost-track ledger entries -> not recorded (honkd does not
    know the outcome).
  - busy errors -> neither record nor clear.
- `session/list` adds `_meta.honk.error = {kind, message, at}` or `null` for
  every listed session, held or not, but only for entries younger than a
  read-time TTL of 48 h (review: an abandoned errored session, e.g. after a
  refusal that says "start a new session", must not stay pinned). Boot prune
  drops entries older than 7 days. Any new turn on the session also clears.
- The turn hook's `turn.ended` gains an optional `turn_error` (same shape)
  for pigeon to use later; pigeon ignores unknown fields. (Not used here.)

### 3. honk client

`SessionEntry.last_error: Option<{kind, message, at}>` from
`/_meta/honk/error` (absent or JSON null -> None); `honk list --json` adds
`lastError` (null when none), like `pendingRequests`.

### 4. workstation

- `oc-session-list-goose.ts`: parse `lastError` as "a non-null object with a
  string kind, else null" (like `pendingRequests`); `error =
  lastError != null && !running` (review: the effective_state precedence puts
  error ahead of working). `effective_state` then resolves to `error` and
  the fold sort pins it to the attention group, like opencode.
- Window: an errored row bypasses the floor and limit (it needs you) only
  when its error is newer than the window floor; an older one is windowed
  like any idle row (review).
- No Lua change: `error` is already in `M.ATTENTION`, and automated rows are
  dropped above the pierce, so an errored recipe run stays hidden like an
  errored automated opencode session.

## Deploy order and skew

1. goose fork PR -> tag `patched-1.54.0.9` -> workstation `pkgs/goose` bump
   (version + hash). goose-serve restart (author-gated; sessions in flight
   are interrupted). An old goose simply never sends turnError.
2. honk PR (honkd + client). honkd restart (keep-old unit, author-gated).
   An old honkd never sends `_meta.honk.error`; an old honk client ignores it.
3. workstation PR (flake bump of honk + oc-session-list change). Treats a
   missing `lastError` as no error.
Each step is inert without the next, so any order of deploys is safe; the
feature appears when all three are live.

## Tests

(review) In addition to the list below: goose -- pre-loop auto-compaction
failure, compaction_attempts >= 2, self-compaction failure, recipe
MaxAttemptsReached, empty turn after retries, error -> steer -> success,
error -> goal nudge -> success, Ok-then-Err in one iteration, a second prompt
right after the run clears does not wipe the first turn's slot, multibyte
truncation, no turnError when forward_agent_stream errs, state-machine
trailing error. honkd -- old state.json loads; the reorder race (delayed
export via HONKD_TEST_EXPORT_DELAY_MS with an inline-failing parked turn);
upstream_restart/delivery_unknown interrupts record `interrupted`; busy errors
neither record nor clear; a user cancel clears; run start clears; read-time
TTL. workstation -- running + lastError -> working; lastError missing / null /
malformed -> no error; a stale error outside the floor is not unioned in.


- goose: agent-level tests with a scripted provider (the existing
  `crates/goose/tests/agent.rs` / mock provider pattern) for: network error
  -> turnError network; refusal; generic; context-length with failing
  compaction -> context_length; context-length with successful compaction ->
  none; success -> none; cancelled -> none. ACP server test that
  `session/prompt` carries `_meta.goose.turnError` (acp_server_test pattern).
- honkd: stub-goose test with a stub whose prompt response carries
  `_meta.goose.turnError` (honk-testgoose fake) -> session/list error set;
  next clean turn clears; Reply::Error recorded; persisted across restart;
  boot prune.
- honk: SessionEntry parse/to_json with and without the field.
- workstation: bun mapping (lastError -> error, running wins), built-binary
  stage 7 fixture, nvim-lua unchanged pins unless rows change.

## Known limits

- Turns not run through honkd (`goose run` CLI) are not tracked.
- Tool failures are not turn errors (the turn itself succeeded).
- `kind`/`message` come from goose's ProviderError Display; wording is not
  a contract, `kind` is.
