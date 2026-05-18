import type { Plugin } from "@opencode-ai/plugin"
import { fetchLatestAssistantUsage } from "./lib/context-usage-impl"

/**
 * Injects a single synthetic "Context usage" user message at the very end
 * of the chat history, so the model has situational awareness about its own
 * working memory.
 *
 * This message is marked with cache: "never" and kind: "opencode_context_usage"
 * so that opencode's cache breakpoint selection specifically ignores it.
 * This prevents the dynamic counter from busting the prompt cache for the
 * entire chat history.
 */
const plugin: Plugin = async (ctx) => {
  const sdkClientConfig = (ctx.client as any)._client?.getConfig?.() as
    | { fetch?: typeof fetch }
    | undefined
  const internalFetch: typeof fetch =
    sdkClientConfig?.fetch ?? globalThis.fetch

  return {
    "experimental.chat.messages.transform": async (input, output) => {
      try {
        const inContext = input as { sessionID?: string; model?: any }
        const contextLimit = inContext.model?.limit?.context
        if (!contextLimit || contextLimit === 0) return

        const used = await fetchLatestAssistantUsage({
          fetch: internalFetch,
          serverUrl: ctx.serverUrl,
          sessionID: inContext.sessionID || ctx.sessionID,
        })
        if (used === null) return

        const pct = ((used / contextLimit) * 100).toFixed(1)
        
        output.messages.push({
          info: { role: "user" } as any,
          parts: [{ 
            type: "text", 
            text: `<context_usage>\nContext usage as of the previous turn: ${used.toLocaleString("en-US")} / ${contextLimit.toLocaleString("en-US")} tokens (${pct}%).\nIf usage is high, proactively compact or summarize before continuing.\n</context_usage>`,
            metadata: {
              cache: "never",
              kind: "opencode_context_usage"
            }
          }]
        })
      } catch {
        // Plugin must never break a session.
      }
    },
  }
}

export default plugin
