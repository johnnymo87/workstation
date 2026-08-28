---
name: opencode-launch
description: Launch headless opencode sessions from CLI, and grant MCP servers (slack, atlassian, ...) to sessions. Use when you need to start a new opencode session in the background to work on a task in parallel, when spawning work on a specific directory, or when an ALREADY-RUNNING session (e.g. a swarm worker) needs an MCP server it wasn't launched with.
allowed-tools: [Bash, Read]
---

# Launching Headless OpenCode Sessions

Start a new headless opencode session from the CLI without going through Telegram.

## Quick Start

```bash
# Launch in a specific directory
opencode-launch ~/projects/pigeon "fix the failing test in src/auth.ts"

# Launch in the current directory
opencode-launch "run the build and fix any type errors"

# Launch a worker with the Slack MCP enabled (read + write)
opencode-launch --mcp slack ~/projects/pigeon "summarize the last hour of #incidents"
```

## What This Does

1. Health-checks the local `opencode serve` instance (port 4096)
2. Creates a new session via `POST /session`
3. Sends the prompt via `POST /session/{id}/prompt_async`
4. Prints the session ID and commands to attach or kill

The session runs headless. The pigeon plugin inside the session auto-registers
with the daemon, so you will receive Telegram notifications for stop/question events.

## Choosing the Model (`--model`)

`--model <provider>/<model>` pins the launched session's model. Before creating
the session, `opencode-launch` resolves the model id against the serve's
`GET /config/providers` catalog:

- **Bare id → auto-resolved.** A suffix-less id like
  `google-vertex-anthropic/claude-opus-5` is expanded to the unique registered
  id (`…/claude-opus-5@default`) and a `Note:` line is printed. This is why a
  bare id no longer silently launches a dead session.
- **Unknown / ambiguous id → loud pre-launch error (exit 1).** No orphan session
  is created; the error lists the provider's available models.
- **Catalog unreachable → degrade.** The id is sent as-given (pre-resolution
  behavior), never worse.

> Why this matters: `prompt_async` is asynchronous. An unregistered model id
> returns HTTP 200 at launch and only dies *later* in the agent loop with
> `Die(ProviderModelNotFoundError)` — the session is created, a title is
> generated, the TUI opens, but the main loop never runs and you get no model
> response. Front-loaded resolution turns that invisible failure into an
> auto-correction or a clear error. Fully-qualified ids still work unchanged.

## Enabling MCP Server Tools (`--mcp`)

MCP-server tools (slack, atlassian, etc.) are globally disabled by default. The
repeatable `--mcp <server>` flag turns a server on **for the launched session**:

```bash
opencode-launch --mcp slack ~/projects/pigeon "summarize #incidents today"
opencode-launch --mcp slack --mcp atlassian ~/projects/foo "cross-post the ticket"
```

For each `--mcp X`, `opencode-launch`:

1. `POST /mcp/X/connect` (workspace-scoped via the `x-opencode-directory` header).
   There is **no auto-connect** — referencing a disabled server's tools without
   connecting first does nothing, so this step is required.
2. Folds `{"X_*": true}` into the `tools` map of the initial `prompt_async` body,
   enabling the whole `X_*` tool set for that prompt.

It composes with `--model`. Unlike pinning to a dedicated agent (e.g. the `slack`
subagent, which strips read/write/bash), the worker keeps its full toolset and
gains the MCP tools on top.

Key caveats:

- **Host availability.** The slack MCP is configured only on **macOS and
  cloudbox** (devbox has no slack block). `--mcp <server>` on a host
  where the server isn't configured fails with
  `Error: MCP server '<server>' is not configured on this host` (exit 1).
- **slack is read + write.** `--mcp slack` enables `slack_*`, which **includes
  the post-message tool** (`slack_conversations_add_message`). A session launched
  this way can post to Slack — grant it deliberately, especially for swarm
  workers. Prefer `--mcp slack-ro` when the worker only needs to read.
- **Launch-time only.** `--mcp` is a flag on `opencode-launch`; it cannot help a
  session that is already running. For that, use `oc-mcp-enable` (next section).

> **The `tools` map is not per-message.** An earlier version of this doc said the
> `tools` override "applies only to the launch prompt". That is wrong, and it is
> worth knowing because it is a footgun: opencode's prompt-body `tools` map is
> `@deprecated`, and the server converts it into permission rules that
> **overwrite `session.permission` wholesale** for the rest of the session
> (`session/prompt.ts`, `input.tools` → `session.permission = permissions`).
> Only the `tools[k] === false` *exposure* filter is genuinely per-message.
> The reason a later `swarm_send` to a worker still can't reach Slack is not the
> `tools` map expiring — it's that a worker launched **without** `--mcp` never
> had the MCP client connected in the first place.

## Granting MCP to an Already-Running Session (`oc-mcp-enable`)

`opencode-launch --mcp` only works at launch. When a session is **already
running** — the classic case: mid-swarm you decide that a peer worker
needs to post to Slack — use `oc-mcp-enable` instead of killing and relaunching
the worker (which would throw away its context):

```bash
oc-mcp-enable <session-id> slack-ro          # read-oriented
oc-mcp-enable <session-id> slack             # READ + WRITE (can post!)
oc-mcp-enable <session-id> slack atlassian   # several at once
oc-mcp-enable --status <session-id>          # what's connected + the ruleset
oc-mcp-enable --revoke <session-id> slack    # take it away again
```

**The grant takes effect on that session's NEXT prompt.** Tools are resolved per
message, so the sequence is: `oc-mcp-enable <worker>
slack` → then `swarm_send` the actual instruction. Verified end to end on
cloudbox 2026-08-05: a running session that answered "NONE" to "what slack tools
do you have?" gained the full `slack-ro_*` set and successfully executed
`slack-ro_channels_me` on a pigeon-delivered `swarm_send` — no relaunch.

It does exactly two HTTP calls through the front door, and **both are required**:

1. `POST /session/<id>/mcp/<server>/connect` — spawns/attaches the MCP client.
   This is what puts the server's tools into the candidate tool set. There is no
   auto-connect: a disabled server's tools simply don't exist until you connect.
2. `PATCH /session/<id>` with a `{permission: [...]}` ruleset allowing
   `<server>_*`. Without it the tools are *visible* to the model but every call
   falls through to the default `ask` action, which in a headless session blocks
   forever waiting for a human who isn't there.

### Scope: connect is per-DIRECTORY, permission is per-SESSION

This asymmetry matters and is easy to get wrong:

- **MCP connection state is per-directory**, held in opencode's `InstanceState`
  on the serve process that owns the session (keyed by the session's
  `directory`). The `<session-id>` in the connect path is a **routing key** — it
  tells the front door which serve owns the session and supplies the directory.
  Connecting `slack` for session A therefore also connects it for **every other
  session in the same directory on that serve**. It does *not* reach a session in
  a different directory, and it does not survive a serve restart — nor an
  *instance dispose*, which a `POST /config` update or a worktree reload is
  enough to cause.
- **Tool authorization is per-session and persistent**, living in
  `session.permission`. `PATCH /session/<id>` **merges** (appends) rules, and the
  last matching rule wins — unlike the prompt `tools` map, which replaces.

### You no longer have to re-enable after a serve restart

That asymmetry used to mean a long-running session silently lost its Slack tools
every few hours: the durable grant still said `slack_*: allow` while the client
behind it was gone. The `mcp-autoconnect` plugin
(`assets/opencode/plugins/mcp-autoconnect.ts`) now closes the gap — at the start
of every turn it reads the session's own permission ruleset and reconnects
anything granted-but-not-connected, *before* the turn resolves its tools. So the
reconnect costs nothing and needs no prompt of its own.

**It only does this for servers the global `tools` map gates off** — today
`slack` and `slack-ro`. That is deliberate: connect is directory-wide, so
auto-reconnecting an *ungated* server would push its tools into every
co-directory session (and for `datadog`/`pagerduty` that 400s every Vertex
Gemini turn there). `atlassian` and the rest still need a manual `oc-mcp-enable`
after a serve restart; gating one in `opencode.base.json` is what opts it in.

What it does **not** do is remove the one-turn delay on the *first* grant: that
is a stale `session.permission` snapshot taken once per turn in upstream's
`runLoop`. Root cause, evidence and the one-line upstream patch are in
`docs/plans/2026-08-28-mcp-grant-liveness.md`.

Consequence for `--revoke`: it appends a `deny` rule for `<server>_*` on that one
session and deliberately does **not** disconnect the server, because the
connection is shared. Denying removes the tools from that session's view
entirely (verified: the session answers `TOOL_UNAVAILABLE`), while leaving peers
in the same directory untouched.

### Security: this lets one session grant another the ability to post to Slack

`oc-mcp-enable <worker> slack` gives that worker
`slack_conversations_add_message` — a real, unreviewable write to a shared
company channel, granted by an agent rather than by Jonathan. There is no
authentication on this path: the front door is uncredentialed on loopback, so
any process on the box (including any opencode session) can already do these two
HTTP calls by hand. `oc-mcp-enable` makes an existing capability ergonomic; it
does not create one. Hardening the CLI alone would therefore be theater — the
control has to sit at the front door or in opencode itself to mean anything.

Given that, the discipline is conventional rather than enforced:

- **Default to `slack-ro`.** Grant `slack` (write) only when posting is the
  actual task. Note `slack-ro` is "read-oriented", not inert — it still exposes
  `conversations_join/leave/mark` and `usergroups_create/update`. It does not
  expose the post-message tool, which is the property that matters here.
- **Grant late and narrow.** Enable immediately before the `swarm_send` that
  needs it, and `--revoke` after, rather than granting a worker Slack for its
  whole life.
- **Remember connect is directory-wide.** Granting write to one session in a
  directory connects the write-capable client for every session there. Only the
  permission rule is per-session, and only the sessions you PATCH can call it —
  but a peer in that directory is one `PATCH` (or one prompt-body `tools` map)
  away from the same capability.

## Landing a Writable Session in a Worktree (`--worktree`)

`--worktree <slug>` lands the session in a fresh git worktree instead of at the
passed directory's root. Use it for **writable** sessions (anything that edits
code — swarm workers, implementation launches) so the session never starts in a
repo's primary root. In mono that root is the read-only trunk: a git pre-commit
hook refuses commits there, so writable work started at the root gets stuck at
commit time with nowhere to land.

```bash
# writable worker: isolated in ~/projects/mono/.worktrees/cops-1234 off trunk
opencode-launch --worktree cops-1234 ~/projects/mono "implement the X importer"

# read-only session (review / coordinate / "what does this do?"): NO --worktree,
# so it gets the clean current trunk to read.
opencode-launch ~/projects/mono "what does the FBM importer do?"
```

What it does, in order:

- After the health + model checks and **just before** the session is created, it
  runs `work <slug>` in `<directory>` (which must be a git repo), branching a
  fresh `.worktrees/<slug>` off the local trunk, and reassigns the session's
  directory to that worktree. Everything downstream (pool placement, MCP connect,
  the auto-attached TUI) follows automatically.
- The `work` fetch is bounded + best-effort, so `--worktree` never blocks or
  fails the launch on a slow/absent network.
- If `work` fails (not a git repo, slug already taken, `origin/HEAD` unset) the
  launch **aborts loudly** — it never silently falls back to launching writable
  work at the root.
- If any later step fails, an `EXIT` trap removes the just-created worktree +
  branch, so a failed launch never orphans one.

Lifecycle: a successful `--worktree` launch keeps its worktree. It's reclaimed
automatically once the branch merges into trunk — the nightly `reset-workspace`
runs `work --prune-merged`, which removes only merged-into-trunk **and** clean
worktrees (in-flight/dirty ones are always kept). To prune on demand:
`cd <repo> && work --prune-merged`.

Slugs must be unique per repo (a taken slug fails loudly). v1 requires repos with
`origin/HEAD` set (mono has it); pass `work`'s trunk via the repo if needed.

## Auto-Attach to nvim+tmux

If you're on a host with `oc-auto-attach` installed (devbox, macOS — anywhere with
a graphical workflow), `opencode-launch` automatically opens the new session as a
new tab in the matching project's nvim, inside tmux. **No manual `opencode attach`
needed.**

How it picks the nvim:

- Reads the session's directory from `GET /session/<id>`.
- Collapses worktree paths: `~/projects/<P>/.worktrees/<W>/...` → `~/projects/<P>`.
  Sessions in worktrees land in the project-root nvim.
- Walks `tmux list-panes -a` and finds the pane running `nvim` whose
  `pane_current_path` matches the (collapsed) project key.
- If no match: creates a new tmux window in the (collapsed) project root,
  running `nvims`, and attaches the new session inside it.
- The new tab runs `opencode attach` with `cwd = session.directory` (the exact,
  un-collapsed path from `GET /session/<id>`) so opencode's session-cwd checks
  pass.

For this to work, **you must run nvim via `nvims` (not `nvim`) inside tmux.**
`nvims` is a tiny wrapper that injects `--listen /tmp/nvim-${TMUX_PANE#%}.sock`
so external tools can find your nvim. The socket goes away when nvim exits.

Cloudbox and other headless hosts skip auto-attach silently — `opencode-launch`
checks `command -v oc-auto-attach` and no-ops if missing. Pigeon's `/launch`
handler does the same.

If something goes wrong and you don't see a tab open, check
`/tmp/oc-auto-attach.log` for the per-invocation trace.

## Attaching to a Session

```bash
opencode attach http://127.0.0.1:4700 --session <session-id>
```

The session ID is printed by `opencode-launch`.

## Killing a Session

Through the front door (uncredentialed):

```bash
curl -sf -X DELETE http://127.0.0.1:4700/session/<session-id>
```

Or directly against a raw serve port (requires HTTP Basic Auth credentials):

```bash
curl -sf -u "opencode:$(cat /run/secrets/opencode_server_password)" \
  -X DELETE http://127.0.0.1:4096/session/<session-id>
```

Or from Telegram: `/kill <session-id>`

## Listing Sessions

```bash
curl -s http://127.0.0.1:4700/session | jq
```

## Environment

- `OPENCODE_URL` defaults to `http://127.0.0.1:4700` (front door)
- Override if opencode serve runs on a different port

## Prerequisites

The `opencode serve` service must be running:

```bash
# Linux (NixOS)
systemctl status opencode-serve

# macOS
launchctl list | grep opencode

# Direct health check (all platforms; /global/health is unauthenticated)
curl -s http://127.0.0.1:4096/global/health
```

## Troubleshooting

**"opencode serve is not reachable"**: The service isn't running. Start it:
- NixOS: `sudo systemctl start opencode-serve`
- macOS: `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/org.nix-community.home.opencode-serve.plist`

**Session created but no activity**: Check that the model provider API key is available
in the opencode serve environment (e.g. `GOOGLE_GENERATIVE_AI_API_KEY` for Gemini).
