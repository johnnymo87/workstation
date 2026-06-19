import { describe, it, expect } from "vitest"
import plugin from "../session-header"

// Resolve the chat.headers hook the plugin registers.
async function getChatHeadersHook() {
  const hooks = await plugin({} as never)
  const hook = hooks["chat.headers"]
  if (!hook) throw new Error("plugin did not register a chat.headers hook")
  return hook
}

// Minimal stand-in for the chat.headers hook input. Only the fields the
// plugin reads (model.providerID, sessionID, message.id) need to be real.
function makeInput(providerID: string) {
  return {
    sessionID: "ses_abc123",
    agent: "build",
    model: { providerID, modelID: "claude-opus-4-8" },
    provider: {},
    message: { id: "msg_req789" },
  } as never
}

describe("session-header plugin", () => {
  it("injects session + request headers for google-vertex-anthropic", async () => {
    const hook = await getChatHeadersHook()
    const output = { headers: {} as Record<string, string> }

    await hook(makeInput("google-vertex-anthropic"), output)

    expect(output.headers["x-opencode-session"]).toBe("ses_abc123")
    expect(output.headers["x-opencode-request"]).toBe("msg_req789")
  })

  it("leaves google-vertex (gemini) requests untouched", async () => {
    const hook = await getChatHeadersHook()
    const output = { headers: {} as Record<string, string> }

    await hook(makeInput("google-vertex"), output)

    expect(output.headers).toEqual({})
  })

  it("leaves first-party anthropic requests untouched", async () => {
    const hook = await getChatHeadersHook()
    const output = { headers: {} as Record<string, string> }

    await hook(makeInput("anthropic"), output)

    expect(output.headers).toEqual({})
  })

  it("preserves headers set by other plugins", async () => {
    const hook = await getChatHeadersHook()
    const output = { headers: { "x-existing": "keep-me" } as Record<string, string> }

    await hook(makeInput("google-vertex-anthropic"), output)

    expect(output.headers["x-existing"]).toBe("keep-me")
    expect(output.headers["x-opencode-session"]).toBe("ses_abc123")
  })
})
