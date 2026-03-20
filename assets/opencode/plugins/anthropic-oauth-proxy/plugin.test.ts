import { afterEach, describe, expect, test } from "bun:test"

import AnthropicProxyPlugin from "./plugin"

const originalFetch = globalThis.fetch

afterEach(() => {
  globalThis.fetch = originalFetch
})

async function loadPlugin() {
  return AnthropicProxyPlugin({
    client: {
      auth: {
        set: async () => {},
      },
    },
  })
}

describe("AnthropicProxyPlugin auth methods", () => {
  test("uses platform.claude.com callback and expanded scopes for console authorize", async () => {
    const plugin = await loadPlugin()
    const method = plugin.auth.methods[1]
    const result = await method.authorize()
    const url = new URL(result.url)

    expect(url.origin).toBe("https://platform.claude.com")
    expect(url.pathname).toBe("/oauth/authorize")
    expect(url.searchParams.get("redirect_uri")).toBe("https://platform.claude.com/oauth/code/callback")
    expect(url.searchParams.get("scope")).toBe(
      "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload",
    )
  })

  test("deduplicates concurrent exchange calls", async () => {
    let callCount = 0
    globalThis.fetch = (async () => {
      callCount += 1
      return new Response(
        JSON.stringify({
          refresh_token: "refresh-token",
          access_token: "access-token",
          expires_in: 3600,
        }),
        { status: 200, headers: { "content-type": "application/json" } },
      )
    }) as typeof fetch

    const plugin = await loadPlugin()
    const method = plugin.auth.methods[0]
    const auth = await method.authorize()
    const [left, right] = await Promise.all([auth.callback("code#state"), auth.callback("code#state")])

    expect(callCount).toBe(1)
    expect(left.type).toBe("success")
    expect(right.type).toBe("success")
  })
})
