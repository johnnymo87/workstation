import { describe, expect, test } from "bun:test"

import { rewriteAnthropicSystemPrompt } from "./request-shape"

describe("rewriteAnthropicSystemPrompt", () => {
  test("rewrites text system blocks", () => {
    const body = rewriteAnthropicSystemPrompt({
      system: [
        { type: "text", text: "You are OpenCode. Use opencode tools." },
      ],
    })

    expect(body.system[0].text).toBe("You are Claude Code. Use Claude tools.")
  })

  test("leaves non-text blocks unchanged", () => {
    const body = rewriteAnthropicSystemPrompt({
      system: [
        { type: "image", data: "OpenCode" },
      ],
    })

    expect(body.system[0]).toEqual({ type: "image", data: "OpenCode" })
  })
})
