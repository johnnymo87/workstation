---
name: opencode-launch
description: Launch headless opencode sessions from CLI. Use when you need to start a new opencode session in the background to work on a task in parallel, or when spawning work on a specific directory.
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
  `google-vertex-anthropic/claude-opus-4-8` is expanded to the unique registered
  id (`…/claude-opus-4-8@default`) and a `Note:` line is printed. This is why a
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
  cloudbox** (devbox/crostini have no slack block). `--mcp <server>` on a host
  where the server isn't configured fails with
  `Error: MCP server '<server>' is not configured on this host` (exit 1).
- **slack is read + write.** `--mcp slack` enables `slack_*`, which **includes
  the post-message tool** (`slack_conversations_add_message`). A session launched
  this way can post to Slack — grant it deliberately, especially for swarm
  workers.
- **Per-message scope.** The `tools` override applies to the launch prompt's full
  agent loop (multi-step tool use within that turn works). A *later, separate*
  prompt to the same session (e.g. via a `swarm_send` from another session) is
  **not** covered and would need its own enablement.

## Landing a Writable Session in a Worktree (`--worktree`)

`--worktree <slug>` lands the session in a fresh git worktree instead of at the
passed directory's root. Use it for **writable** sessions (anything that edits
code — swarm workers, implementation launches) so the session never starts in a
repo's primary root. In mono that root is the read-only trunk protected by the
worktree-guard; starting writable work there trips the guard by inertia.

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
opencode attach http://localhost:4096 --session <session-id>
```

The session ID is printed by `opencode-launch`.

## Killing a Session

```bash
curl -sf -X DELETE http://localhost:4096/session/<session-id>
```

Or from Telegram: `/kill <session-id>`

## Listing Sessions

```bash
curl -s http://localhost:4096/session | jq
```

## Environment

- `OPENCODE_URL` defaults to `http://127.0.0.1:4096`
- Override if opencode serve runs on a different port

## Prerequisites

The `opencode serve` service must be running:

```bash
# Linux (NixOS)
systemctl status opencode-serve

# Linux (Crostini)
systemctl --user status opencode-serve

# macOS
launchctl list | grep opencode

# Direct health check (all platforms)
curl -s http://localhost:4096/global/health
```

## Troubleshooting

**"opencode serve is not reachable"**: The service isn't running. Start it:
- NixOS: `sudo systemctl start opencode-serve`
- Crostini: `systemctl --user start opencode-serve`
- macOS: `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/org.nix-community.home.opencode-serve.plist`

**Session created but no activity**: Check that the model provider API key is available
in the opencode serve environment (e.g. `GOOGLE_GENERATIVE_AI_API_KEY` for Gemini).
