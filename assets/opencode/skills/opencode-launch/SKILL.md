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
