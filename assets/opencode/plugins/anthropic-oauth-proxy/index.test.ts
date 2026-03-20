import { describe, expect, test } from "bun:test"

import { createProxyHandler } from "./index"

async function captureUpstream(request: Request) {
  let captured: Request | undefined
  const handler = createProxyHandler(undefined, async (upstream) => {
    captured = upstream
    return new Response(JSON.stringify({ ok: true }), {
      status: 200,
      headers: { "content-type": "application/json" },
    })
  })

  const response = await handler(request)
  expect(response.status).toBe(200)
  expect(captured).toBeDefined()
  return captured!
}

describe("createProxyHandler", () => {
  test("uses axios user-agent for oauth exchange", async () => {
    const upstream = await captureUpstream(
      new Request("http://127.0.0.1:4318/oauth/exchange", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          code: "abc",
          state: "xyz",
          code_verifier: "verifier",
        }),
      }),
    )

    expect(upstream.url).toBe("https://platform.claude.com/v1/oauth/token")
    expect(upstream.headers.get("user-agent")).toBe("axios/1.13.6")
  })

  test("uses axios user-agent for oauth refresh", async () => {
    const upstream = await captureUpstream(
      new Request("http://127.0.0.1:4318/oauth/refresh", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ refresh_token: "refresh" }),
      }),
    )

    expect(upstream.url).toBe("https://platform.claude.com/v1/oauth/token")
    expect(upstream.headers.get("user-agent")).toBe("axios/1.13.6")
  })

  test("uses claude-code user-agent for messages", async () => {
    const upstream = await captureUpstream(
      new Request("http://127.0.0.1:4318/v1/messages", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          system: [{ type: "text", text: "You are OpenCode." }],
          messages: [{ role: "user", content: "hello world" }],
        }),
      }),
    )

    expect(upstream.url).toBe("https://api.anthropic.com/v1/messages")
    expect(upstream.headers.get("user-agent")).toBe("claude-code/2.1.80")
    const parsed = JSON.parse(await upstream.text())
    expect(parsed.system[0].text).toStartWith("x-anthropic-billing-header: cc_version=2.1.80.")
    expect(parsed.system[1].text).toBe("You are Claude Code.")
  })

  test("does not inject billing on non-message routes", async () => {
    const upstream = await captureUpstream(
      new Request("http://127.0.0.1:4318/api/oauth/usage", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          system: [{ type: "text", text: "You are OpenCode." }],
          messages: [{ role: "user", content: "hello world" }],
        }),
      }),
    )

    const parsed = JSON.parse(await upstream.text())
    expect(parsed.system[0].text).toBe("You are OpenCode.")
  })
})
