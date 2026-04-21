import type { Plugin } from "@opencode-ai/plugin"

/**
 * Injects environment variables into every bash tool invocation via the
 * `shell.env` hook (see opencode/packages/opencode/src/tool/bash.ts).
 *
 * Two purposes:
 * 1. Force non-interactive defaults so commands never wait on a TTY.
 * 2. Expose session metadata (OPENCODE_SESSION_ID) so an agent can discover
 *    its own session ID — needed for opencode-to-opencode handoffs via
 *    `opencode-send <id> "msg"`.
 */
const plugin: Plugin = async () => ({
  "shell.env": async (input, output) => {
    // Non-interactive defaults
    output.env.GIT_EDITOR = ":"
    output.env.EDITOR = ":"
    output.env.GIT_SEQUENCE_EDITOR = ":"
    output.env.GIT_PAGER = "cat"

    // Session self-awareness: lets agents tell peers their own session ID.
    if (input.sessionID) output.env.OPENCODE_SESSION_ID = input.sessionID
  },
})

export default plugin
