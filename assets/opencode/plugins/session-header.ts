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

/**
 * v1 plugin shape. `readV1Plugin` takes the default-export object and
 * `applyPlugin` returns before it ever reaches `getLegacyPlugins`, which throws
 * `Plugin export is not a function` on the first named export that is not a
 * function -- rejecting the WHOLE FILE, with one log line and an otherwise
 * healthy serve. This file has no named runtime exports today; the v1 shape is
 * what stops a future one from silently disabling the plugin. See the longer
 * rationale in shell-env.ts, which that failure actually hit.
 *
 * `id` is mandatory: resolvePluginId() throws `Path plugin ... must export id`
 * for file-sourced plugins without one (shared.ts:313-316).
 */
export default { id: "session-header", server: plugin }
