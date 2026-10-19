---
name: enabling-mcp-servers
description: Use when a task needs tools from an MCP server (slack, slack-ro, atlassian, pagerduty, rollbar, figma, devcycle, chrome-devtools, ...) that the current opencode or goose session does not have, or when the user asks how to turn an MCP server on or off for a session.
---

# Enabling MCP Servers for a Session

Every MCP server is **off by default**, in opencode and goose alike. A server is turned on
**per session**, deliberately, by the human. Both harnesses read the same list of servers:
opencode's generated `~/.config/opencode/opencode.json` `mcp` block.

If a tool you need does not exist in your tool list, the server is off. Do not hunt for a
workaround. Ask the human to turn the server on, and say which one and why.

## Which harness am I in?

- **opencode:** `$OPENCODE_SESSION_ID` is set in your shell. Use the `opencode-launch` skill.
  Its `--mcp` flag works at launch; for a running session use `oc-mcp-enable <session> <server>`.
  The grant takes effect on your next step.
- **goose (through honk):** your tools are named `<extension>__<tool>`, for example
  `developer__shell`. Read on.

## goose: ask the human to type `/mcp` in honk chat

In honk chat (goose-serve → honkd → `honk chat`), the human controls servers for the attached
session:

| They type | Effect |
|---|---|
| `/mcp` | lists the servers: on/off, `!` = needs confirmation, unsupported ones with a reason |
| `/mcp on slack-ro` | turns a server on |
| `/mcp on! slack` | turns on a server marked `!` (it can write or act) |
| `/mcp off slack-ro` | turns it off |
| `honk chat --new --mcp atlassian!` | starts a new session with a server on (`!` confirms) |

Things to tell the human, and to plan around:

- **Changes are refused while a turn runs.** honk chat queues the command and runs it after
  your turn ends. So **end your turn** after asking. Do not wait in a loop for the tools to
  appear. The tools are there on your next turn, named `<server>__<tool>`
  (for example `slack-ro__channels_list`).
- **Prefer `slack-ro`.** `slack` can post messages, under the human's own name. Ask for it only
  when posting is the task, and load `formatting-slack-messages` before you post. Turning one
  on replaces the other.
- **`!` servers** (anything not on honkd's `--mcp-no-confirm` list) can change things:
  Jira (atlassian), feature flags (devcycle), incidents (pagerduty), rollbar items, or a
  browser (chrome-devtools). Say what you will do with one before asking for it.
- **Remote servers (datadog, notion) are not supported in goose yet.** `/mcp` lists them as
  unsupported. Use their CLIs or ask the human.
- The setting is **per session and persistent**. It survives honkd and goose-serve restarts,
  and every client of the session sees it (status bar `mcp:slack-ro,...`). Suggest
  `/mcp off <server>` when the work is done.
- If `/mcp` answers "MCP catalog not configured", honkd runs without `--mcp-catalog`. That is a
  workstation deploy matter for the human, not something you can fix from the session.

**Never grant yourself a server.** You can reach honkd and goose on loopback, so you could call
`_honk/mcp/enable` or goose's `extensions/add` from a shell. Don't. The point of the design is
that the human decides, the same discipline `opencode-launch` describes for `oc-mcp-enable`.
