import type { Plugin } from "@opencode-ai/plugin"
import { tool } from "@opencode-ai/plugin"
import {
  type CallContext,
  type PendingResume,
  callPromptAsyncHttp,
  callSummarizeHttp,
  createOnCompacted,
  createOnStatus,
  createSelfCompactTool,
  findActiveModel,
} from "./self-compact-impl"

// IMPORTANT: only the default export should be a plugin factory.
// opencode's plugin loader iterates `Object.entries(mod)` and invokes EVERY
// exported function as a plugin factory (see packages/opencode/src/plugin/index.ts).
// Test-only helpers must therefore live in `self-compact-impl.ts`, not here.
const plugin: Plugin = async (ctx) => {
  // Verified path: pigeon's `_client.getConfig().fetch` — captures the in-process
  // Hono transport in TUI mode while bypassing unreliable generated SDK wrappers.
  const sdkClientConfig: any = (ctx.client as any)._client?.getConfig?.()
  const internalFetch: typeof fetch = sdkClientConfig?.fetch ?? globalThis.fetch
  const callCtx: CallContext = { fetch: internalFetch, serverUrl: ctx.serverUrl }
  const pending = new Map<string, PendingResume>()

  const toolImpl = createSelfCompactTool({ pending })

  // v2 split-phase architecture:
  //   1. Tool execute → stash entry, return instantly (no deadlock).
  //   2. onStatus (idle) → fire POST /summarize from outside the turn.
  //   3. onCompacted → enqueue resumption prompt via POST /prompt_async.
  // The plugin SDK accepts a single `event` hook per plugin; we dispatch
  // internally by event type. Each handler filters its own events.
  const onStatus = createOnStatus({
    pending,
    callSummarize: (input) => callSummarizeHttp(callCtx, input),
    findActiveModel: ({ sessionID }) =>
      findActiveModel({ fetch: internalFetch, serverUrl: ctx.serverUrl, sessionID }),
  })

  const onCompacted = createOnCompacted({
    pending,
    callPromptAsync: (input) => callPromptAsyncHttp(callCtx, input),
  })

  return {
    tool: {
      self_compact_and_resume: tool({
        description:
          "Compact the current session and queue a resumption prompt that will be processed " +
          "as the first user message of the post-compaction turn. The tool returns immediately; " +
          "compaction runs after this turn closes (you don't need to wait or follow up). Use as " +
          "the final step of the preparing-for-compaction skill, after persisting durable context.",
        args: {
          prompt: tool.schema
            .string()
            .describe("The resumption prompt to send after compaction completes."),
        },
        async execute(args, toolCtx) {
          return toolImpl.execute(args, { sessionID: toolCtx.sessionID })
        },
      }),
    },
    event: async (input) => {
      // Both handlers filter internally on event.type; safe to call both
      // for every event. Order doesn't matter — they cover disjoint event
      // types (session.status vs session.compacted).
      await onStatus(input)
      await onCompacted(input)
    },
  }
}

export default plugin
