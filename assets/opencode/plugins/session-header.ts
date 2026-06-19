import type { Plugin } from "@opencode-ai/plugin"

/**
 * Injects opencode session-tracking headers into Claude-on-Vertex
 * (`google-vertex-anthropic`) requests via the `chat.headers` hook.
 *
 * Purpose: a downstream proxy can map each outbound request to its opencode
 * session, enabling sticky / idle-migration routing that preserves prompt
 * caches (move a session between backends only after it has gone idle).
 * Without a session id the proxy can only route stateless, per-request.
 *
 * Scope: gated to `google-vertex-anthropic` so Gemini (`google-vertex`) and
 * every other provider are left completely untouched. The header names are a
 * fixed contract with the proxy — `x-opencode-session` is the route key.
 */
const TARGET_PROVIDER = "google-vertex-anthropic"

const plugin: Plugin = async () => ({
  "chat.headers": async (input, output) => {
    if (input.model.providerID !== TARGET_PROVIDER) return

    output.headers["x-opencode-session"] = input.sessionID
    output.headers["x-opencode-request"] = input.message.id
  },
})

export default plugin
