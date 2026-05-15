import type { Plugin } from "@opencode-ai/plugin"
import { fetchLatestAssistantUsage } from "./context-usage-impl"

/**
 * Injects a single "Context usage: X / Y tokens (Z%) as of last turn." line
 * into the system prompt on every LLM call, so the model has situational
 * awareness about its own working memory.
 *
 * Silent on turn 1 (no prior assistant message to read tokens from), silent
 * on fetch errors (returns without modifying output.system), and silent
 * when the model has no usable `limit.context` (some local providers).
 *
 * The actual judgment about *when* to act on the number lives in the
 * "Managing Your Own Context" section of ~/.config/opencode/AGENTS.md.
 *
 * See docs/plans/2026-05-15-context-usage-nudge-design.md.
 */
const plugin: Plugin = async (ctx) => {
  // Same trick as self-compact.ts: capture the in-process Hono fetch when
  // the SDK client is running in TUI mode; fall back to the global fetch.
  const sdkClientConfig = (ctx.client as any)._client?.getConfig?.() as
    | { fetch?: typeof fetch }
    | undefined
  const internalFetch: typeof fetch =
    sdkClientConfig?.fetch ?? globalThis.fetch

  return {
    "experimental.chat.system.transform": async (input, output) => {
      try {
        const contextLimit = input.model?.limit?.context
        if (!contextLimit || contextLimit === 0) return

        const used = await fetchLatestAssistantUsage({
          fetch: internalFetch,
          serverUrl: ctx.serverUrl,
          sessionID: input.sessionID,
        })
        if (used === null) return

        const pct = ((used / contextLimit) * 100).toFixed(1)
        const line =
          `Context usage: ${used.toLocaleString("en-US")} / ${contextLimit.toLocaleString("en-US")} ` +
          `tokens (${pct}%) as of last turn.`

        // Push AFTER the existing first element (the cacheable header) so
        // llm.ts:120-124's 2-part rejoin keeps the header byte-identical
        // across turns.
        output.system.push(line)
      } catch {
        // Plugin must never break a session.
      }
    },
  }
}

export default plugin
