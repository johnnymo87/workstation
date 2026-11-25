import { describe, it, expect } from "vitest"
import plugin, { internals } from "../slack-signature"

describe("slack-signature helpers", () => {
  it("classifies Claude, Gemini, and GPT model IDs", () => {
    expect(internals.classifyModelFamily("claude-opus-5-5@default")).toBe("Claude")
    expect(internals.classifyModelFamily("google-vertex-anthropic/claude-fable-5-2")).toBe("Claude")
    expect(internals.classifyModelFamily("gemini-4-neon")).toBe("Gemini")
    expect(internals.classifyModelFamily("google-vertex/gemini-3.8-flash@default")).toBe("Gemini")
    expect(internals.classifyModelFamily("codex_lb/gpt-6-astra")).toBe("GPT")
    expect(internals.classifyModelFamily("o3-mini")).toBe("GPT")
    expect(internals.classifyModelFamily("unknown-model")).toBeUndefined()
    expect(internals.classifyModelFamily("")).toBeUndefined()
  })

  it("rewrites only a standalone trailing signature line and preserves style", () => {
    expect(internals.rewriteSignature("Done.\n\n--Claude", "Gemini")).toBe("Done.\n\n--Gemini")
    expect(internals.rewriteSignature("Done.\n\n— Claude\n", "Gemini")).toBe("Done.\n\n— Gemini\n")
    expect(internals.rewriteSignature("Done.\n– Claude\r\n", "GPT")).toBe("Done.\n– GPT\r\n")
    expect(internals.rewriteSignature("Done.\n\n--Claude\n\n", "Gemini")).toBe("Done.\n\n--Gemini\n\n")
  })

  it("is idempotent and leaves unsigned or non-signature lines untouched", () => {
    const once = internals.rewriteSignature("Done.\n\n--Claude", "Gemini")
    expect(internals.rewriteSignature(once, "Gemini")).toBe("Done.\n\n--Gemini")

    const unsigned = "Jonathan's dictated message."
    expect(internals.rewriteSignature(unsigned, "Gemini")).toBe(unsigned)

    const midMessage = "Example:\n--Claude\nThat was the old signature."
    expect(internals.rewriteSignature(midMessage, "Gemini")).toBe(midMessage)

    const prose = "Notes:\n-- Claude suggested reverting this."
    expect(internals.rewriteSignature(prose, "Gemini")).toBe(prose)
  })
})

describe("slack-signature plugin hooks", () => {
  it("tracks model per session (including mid-session switches) and mutates Slack tool args in place", async () => {
    const hooks = await plugin.server({} as never)
    const chatParams = hooks["chat.params"]!
    const before = hooks["tool.execute.before"]!

    await chatParams(
      { sessionID: "ses_1", model: { id: "gemini-4-neon@default", providerID: "google-vertex" } } as never,
      {} as never,
    )

    const postOut = { args: { channel_id: "C123", text: "Update ready.\n\n--Claude" } }
    await before(
      { tool: "slack_conversations_add_message", sessionID: "ses_1", callID: "c1" },
      postOut,
    )
    expect(postOut.args.text).toBe("Update ready.\n\n--Gemini")

    const uploadOut = { args: { channel_id: "C123", initial_comment: "Log attached.\n\n— Claude" } }
    await before(
      { tool: "slack_file_upload", sessionID: "ses_1", callID: "c2" },
      uploadOut,
    )
    expect(uploadOut.args.initial_comment).toBe("Log attached.\n\n— Gemini")

    // Mid-session switch to Claude updates subsequent posts.
    await chatParams(
      { sessionID: "ses_1", model: { id: "claude-opus-5-5@default", providerID: "google-vertex-anthropic" } } as never,
      {} as never,
    )
    const postOut2 = { args: { channel_id: "C123", text: "Follow-up.\n\n--Gemini" } }
    await before(
      { tool: "slack_conversations_add_message", sessionID: "ses_1", callID: "c3" },
      postOut2,
    )
    expect(postOut2.args.text).toBe("Follow-up.\n\n--Claude")
  })

  it("ignores non-Slack tools, unknown sessions, and unsigned messages", async () => {
    const hooks = await plugin.server({} as never)
    const chatParams = hooks["chat.params"]!
    const before = hooks["tool.execute.before"]!

    await chatParams(
      { sessionID: "ses_2", model: { id: "gemini-4-neon" } } as never,
      {} as never,
    )

    const bashOut = { args: { command: "echo '--Claude'" } }
    await before({ tool: "bash", sessionID: "ses_2", callID: "c1" }, bashOut)
    expect(bashOut.args.command).toBe("echo '--Claude'")

    const unsignedOut = { args: { channel_id: "C123", text: "Verbatim text." } }
    await before(
      { tool: "slack_conversations_add_message", sessionID: "ses_2", callID: "c2" },
      unsignedOut,
    )
    expect(unsignedOut.args.text).toBe("Verbatim text.")

    const unknownSesOut = { args: { channel_id: "C123", text: "Hi.\n\n--Claude" } }
    await before(
      { tool: "slack_conversations_add_message", sessionID: "ses_unknown", callID: "c3" },
      unknownSesOut,
    )
    expect(unknownSesOut.args.text).toBe("Hi.\n\n--Claude")
  })

  it("ignores auxiliary title/compaction/summary agents so small_model cannot clobber the session family", async () => {
    const hooks = await plugin.server({} as never)
    const chatParams = hooks["chat.params"]!
    const before = hooks["tool.execute.before"]!

    await chatParams(
      { sessionID: "ses_3", agent: "build", model: { id: "gemini-4-neon@default" } } as never,
      {} as never,
    )
    // Title generation runs on claude-haiku-5-5 under the same sessionID.
    await chatParams(
      { sessionID: "ses_3", agent: "title", model: { id: "claude-haiku-5-5@default" } } as never,
      {} as never,
    )
    await chatParams(
      { sessionID: "ses_3", agent: "compaction", model: { id: "claude-haiku-5-5@default" } } as never,
      {} as never,
    )

    const postOut = { args: { channel_id: "C123", text: "Update.\n\n--Gemini" } }
    await before(
      { tool: "slack_conversations_add_message", sessionID: "ses_3", callID: "c1" },
      postOut,
    )
    expect(postOut.args.text).toBe("Update.\n\n--Gemini")
  })
})
