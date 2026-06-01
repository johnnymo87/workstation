# Research: `opencode-launch` with selective MCP servers enabled

**Date:** 2026-06-01
**Host investigated:** cloudbox (GCP ARM, NixOS)
**opencode-serve version:** 1.15.13 (patched fork)
**Status:** Feasibility + design. No code or config changed. Two design
decisions resolved by the user (see "Decisions (resolved)").

## Goal

Let `opencode-launch` spawn a headless session with one or more specific MCP
servers' tools **enabled for that session only**, even though MCP-server tools
are globally disabled by default. Motivating case: launch a worker with the
**slack** MCP enabled so it can read/post Slack without being the dedicated,
capability-restricted `slack` subagent.

## TL;DR recommendation

Add a single repeatable `--mcp <server>` flag to `opencode-launch`. For each
`--mcp X` the script:

1. `POST /mcp/X/connect` (with the session's directory header), then
2. adds `"X_*": true` to the `tools` map on the `prompt_async` body.

This is the **per-message tools override** path. It composes with `--model`,
supports multiple servers trivially, and — unlike pinning to an agent — leaves
the spawned session's normal capabilities (bash/read/edit/task/…) intact while
adding the MCP tools on top. A dedicated/reusable agent is the *wrong* primary
lever here (argued below); the existing `slack` subagent is deliberately
crippled (no read/write/bash) and is only right for slack-only research.

**User decisions (2026-06-01):** (1) CLI surface is `--mcp` only — no
`--enable-tools` escape hatch, no `--agent` flag for now. (2) `--mcp slack`
enables the **full read+write** slack tool set (`slack_*: true`), including the
post-message tool. Both are revisitable; the mechanism cleanly supports a
read-only mode later (see appendix on tools-map precedence).

All claims below were verified against the live 1.15.13 server, not assumed.

## What's true right now (verified)

### Config mechanism (re-verified)

- MCP servers are defined under `"mcp"` in
  `assets/opencode/opencode.base.json` (chrome-devtools, notion) and extended
  in `users/dev/opencode-config.nix` (atlassian/atlassian-alt via overlay;
  slack/pagerduty/datadog/basecamp injected at home-manager activation from
  Keychain on macOS / sops on cloudbox).
- Global gate: `opencode.base.json` has top-level `"tools": { "slack_*":
  false }` (lines 10-12).
- Per-agent re-enable: `"agent": { "slack": { "tools": { "slack_*": true } } }`
  (lines 20-24), and the file agent `assets/opencode/agents/slack.md` enables
  the individual `slack_*` tools while turning **off** read/write/bash/glob/grep.
- Every injected MCP server is written with `"enabled": false`.

### Is slack MCP configured on cloudbox? — YES (but disabled)

Live runtime `~/.config/opencode/opencode.json` on cloudbox:

```jsonc
"mcp": { ... "slack": {
  "type": "local",
  "command": ["npx","-y","slack-mcp-server@latest","--transport","stdio"],
  "enabled": false,
  "environment": {
    "SLACK_MCP_XOXP_TOKEN": "<79-char xoxp token present>",
    "SLACK_MCP_ADD_MESSAGE_TOOL": "true"   // write/post tool is built in
  }
}}
"tools":        { "slack_*": false }
"agent.slack":  { "tools": { "slack_*": true } }
```

Host coverage: slack MCP is injected **only on macOS and cloudbox**
(`injectSlackMcpSecrets` = `isDarwin`, `injectSlackMcpSecretsSops` =
`isCloudbox`). **devbox and crostini have no slack MCP block at all** — so a
`--mcp slack` launch can only work on macOS + cloudbox.

### `enabled: false` means the server is not connected and its tools do not exist

`GET /mcp` → `slack: { status: "disabled" }`. `GET /experimental/tool/ids`
returns 16 ids, **none** `slack_*`. This is the linchpin finding: **a disabled
MCP server registers zero tools**, so neither agent-pin nor a tools-override can
surface them until the server is connected. (This also means the `slack` agent
does *not* work on its own today without a connect step — see below.)

### The HTTP API exposes exactly the levers we need

From the live OpenAPI (`GET /doc`, 1.15.13):

- `POST /session` body accepts: `parentID, title, agent (string), model
  {id,providerID,variant}, metadata, permission, workspaceID`.
  **No session-level `tools` field.** So a durable, all-messages tools override
  is *not* available at session scope — only `agent` is.
- `POST /session/{id}/prompt_async` body accepts: `parts (required)`,
  `model {providerID,modelID}`, `agent (string)`, **`tools` (map of
  `name -> boolean`)**, `system (string)`, `variant (string)`, `noReply`,
  `format`. The `tools` map is the per-message override.
- `POST /mcp/{name}/connect` and `/disconnect` — connect/disconnect a server at
  runtime. **No body**; the only inputs are the path `name` and the
  `directory`/`workspace` query (i.e. it is scoped to a workspace instance, not
  a single session).
- `GET /mcp` is **workspace-scoped**: with the `x-opencode-directory` header it
  returns per-directory status; the connect/disconnect/status all key off the
  same directory routing the session uses.

### End-to-end behavior (live experiments on cloudbox, then reverted)

All test sessions were deleted and slack was returned to `disabled` afterward;
the runtime config file was never modified.

| # | Setup | Prompt `tools` / `agent` | Result |
|---|-------|--------------------------|--------|
| 1 | `POST /mcp/slack/connect` first | `tools:{"slack_channels_list":true}` | Model called `slack_channels_list`, got real channels. ✅ |
| 2 | slack **disconnected** | `tools:{"slack_channels_list":true}` | Tool absent → model replied `NO_SLACK_TOOL`. ❌ (no auto-connect) |
| 3 | connected | `tools:{"slack_*":true}` (glob) | Tool called, real data. ✅ glob works at message scope |
| 4 | connected | `agent:"slack"`, no tools override | slack subagent used as the session agent, tool called, real data. ✅ |

Conclusions:

- **No auto-connect.** A `tools`/`agent` reference to a disabled server does
  nothing; you must `POST /mcp/<name>/connect` explicitly.
- The per-message `tools` map **supports the `<server>_*` glob**, so one entry
  enables a whole server.
- A `mode: subagent` (the `slack` agent) **can** be used as a top-level
  prompt's `agent`.
- Connecting is workspace-scoped and **low blast radius**: it starts the server
  process and registers tools, but the global `tools:{slack_*:false}` keeps
  them disabled for every session that does not explicitly opt in via its own
  `tools`/`agent`. Leaving slack connected does not leak tools to other
  sessions in that directory.

## `opencode-launch` today (re-verified)

Generated by Nix in `users/dev/home.base.nix` (`opencode-launch =
pkgs.writeShellApplication { ... }`, lines 7-160). Flow:

1. Health check `GET /global/health`.
2. `POST /session` with `x-opencode-directory: $directory` → `session_id`.
3. `POST /session/$session_id/prompt_async` with
   `{parts:[{type:"text",text:$prompt}]}` (plus `model:{providerID,modelID}` if
   `--model` given).
4. Optional `oc-auto-attach` (no-op on headless cloudbox).

It supports only `--model`, an optional directory, and the prompt. The change
slots cleanly into steps 2/3.

## Approaches considered

### (a) Agent selection — `--agent <name>` → `POST /session {agent}` / prompt `agent`

- Pinning to the existing `slack` subagent gives slack tools but **strips
  read/write/bash/glob/grep** (per `slack.md`) and swaps in the slack system
  prompt. That produces a slack-only bot, not a general worker that can *also*
  touch Slack — the opposite of the stated goal.
- Still requires a connect step first (experiment 2/4).
- An `--agent` flag is independently useful (pin to oracle/explore/etc.) and is
  cheap to add, but it is the **wrong lever for the MCP-enable goal** because it
  couples tools to a whole persona (system prompt + tool restrictions + model).
- It would, however, make slack durable across *every* message in the session
  (session-scoped `agent`), which the tools-override does not (see limitation).

### (b) Per-session / per-message `tools` override — **recommended**

- `prompt_async.tools = {"slack_*": true}` after a connect. Verified end-to-end
  (experiments 1, 3).
- Pros: orthogonal to model and agent; multi-server is just more keys; keeps the
  worker's full toolset; smallest blast radius; no config/agent proliferation.
- Limitation: the override is **per message**. It covers the entire agent loop
  of the initial launch prompt (multi-step tool use within that turn works —
  verified). But a *later, separate* prompt to the same session (e.g. via
  `opencode-send`/swarm) would need to re-pass `tools`. For `opencode-launch`,
  which fires a single initial prompt and lets the session run autonomously,
  this is the right granularity. (`opencode-send` could grow the same flag
  later if multi-turn slack is needed.)
- There is **no session-scoped `tools` field** on `POST /session`, so we cannot
  make it durable without either an agent (option a) or a custom agent
  (option d).

### (c) Per-session config override (env var / `--config` / `OPENCODE_CONFIG*`)

- `opencode-launch` does not start an opencode process — it talks to a
  long-running `opencode serve`. `OPENCODE_CONFIG` / `OPENCODE_CONFIG_CONTENT`
  are read by *that* server at *its* startup, not per HTTP request. So a
  per-session config injection is not reachable from the launcher without
  restarting the shared serve (unacceptable blast radius). Rejected.

### (d) Dedicated reusable "worker + slack" agent (config change)

- A new agent that keeps full build tools *and* enables `slack_*` would be
  durable (session-scoped) and clean to pin via `--agent`. But it requires a
  nix/home-manager change (out of scope for this brief), and it does not scale:
  every server combination (slack, slack+atlassian, …) is a new agent. The flag
  approach subsumes it. Worth revisiting only if a recurring named persona is
  wanted.

## Recommendation (why b over the rest)

Add a single repeatable `--mcp <server>` flag to `opencode-launch`:

- `--mcp slack` → connect `slack` + add `"slack_*": true` (read+write,
  per the user's decision).
- `--mcp slack --mcp atlassian` → connect both + add both globs.

Rationale: it is the only lever that (1) needs no config rebuild, (2) keeps the
worker's normal capabilities, (3) composes with `--model` and a future
`--agent`, (4) supports multiple servers, and (5) has minimal blast radius
(connect is workspace-scoped and gated by the global `slack_*:false`).
Verified working end-to-end on 1.15.13. The `--enable-tools` escape hatch and a
read-only slack mode were considered and intentionally dropped for now; both are
cheap to add later if needed (the tools-map precedence in the appendix makes a
read-only `--mcp slack` a one-line change).

## Concrete sketch of the `opencode-launch` change

The script body is a Nix `writeShellApplication` heredoc, so shell `${...}`
must be written `''${...}` and `$VAR` is fine. Pseudocode (bash level):

```bash
# new state alongside model_spec
mcp_servers=()        # from --mcp (repeatable)

# arg parsing: add cases
  --mcp)
    [ -n "''${2:-}" ] || { echo "Error: --mcp requires a server name" >&2; exit 1; }
    mcp_servers+=("$2"); shift 2 ;;
  --mcp=*)
    name="''${1#--mcp=}"
    [ -n "$name" ] || { echo "Error: --mcp requires a server name" >&2; exit 1; }
    mcp_servers+=("$name"); shift ;;

# after session is created, before sending the prompt:
# connect each requested server (workspace-scoped via the directory header)
tools_json='{}'
for srv in $(printf '%s\n' "''${mcp_servers[@]}" | sort -u); do
  code=$(curl -s -o /dev/null -w '%{http_code}' \
    -X POST "$OPENCODE_URL/mcp/$srv/connect" \
    -H "x-opencode-directory: $directory")
  if [ "$code" = "404" ]; then
    echo "Error: MCP server '$srv' is not configured on this host" >&2; exit 1
  elif [ "$code" != "200" ]; then
    echo "Error: failed to connect MCP server '$srv' (HTTP $code)" >&2; exit 1
  fi
  tools_json=$(jq -c --arg k "''${srv}_*" '. + {($k): true}' <<<"$tools_json")
done

# fold tools (and model, as today) into the prompt payload
prompt_payload=$(jq -n --arg p "$prompt" --argjson tools "$tools_json" \
  '{parts:[{type:"text",text:$p}]} + (if ($tools|length)>0 then {tools:$tools} else {} end)')
# (if --model present, also merge {model:{providerID,modelID}} as today)
```

Notes:
- Connect is idempotent-ish: re-connecting an already-connected server returns
  200. We do not disconnect afterward (low blast radius; next serve restart /
  nightly reset clears it).
- 404 from connect cleanly distinguishes "server not configured on this host"
  (e.g. slack on devbox/crostini, or missing token) from real failures.
- `--mcp` composes with `--model` (independent payload fields).
- `--mcp slack` enables `slack_*` = read **and** write (post-message). See
  appendix: a read-only variant would emit
  `{"slack_*":true,"slack_conversations_add_message":false}` (exact key beats
  glob), but the user opted for full read+write.

## Decisions (resolved)

1. **CLI surface → `--mcp <server>` only.** No `--enable-tools` escape hatch and
   no `--agent` pin for now (both can be added later; the `--agent` flag would be
   orthogonal and cheap, and a read-only mode is a one-liner — see appendix).
2. **Slack write → enabled.** `--mcp slack` enables the full `slack_*` set,
   including `slack_conversations_add_message`, so a spawned session can both
   read and post Slack. (`SLACK_MCP_ADD_MESSAGE_TOOL=true` is already set in the
   server env.) Operator-facing caveat worth keeping in mind: this auto-grants
   Slack-post to any session launched with `--mcp slack`, including swarm
   workers.

## Appendix: commands used to verify

- `GET /global/health` → `{healthy:true, version:"1.15.13"}`
- `GET /doc` → OpenAPI; inspected `/session`, `/session/{id}/prompt_async`,
  `/mcp/{name}/connect|disconnect`, `/agent`, `/experimental/tool*` schemas.
- `GET /mcp` (with/without `x-opencode-directory`) → workspace-scoped status.
- `POST /mcp/slack/connect|disconnect` → toggled status disabled↔connected.
- 5 throwaway sessions (gemini-3.5-flash) exercising tools-override and
  agent-pin, read-only (`slack_channels_list`), then aborted + deleted.

### Tools-map precedence (bonus finding)

A prompt with `tools:{"slack_*":true,"slack_channels_list":false}` and an
instruction to call `slack_channels_list` produced `NO_TOOL`: the **exact key
overrides the glob**. So a read-only `--mcp slack` is a one-line change —
`{"slack_*":true,"slack_conversations_add_message":false}` — if the write
default is ever reconsidered.
