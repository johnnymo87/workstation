import { describe, it, expect, vi } from "vitest"
import { fetchLatestAssistantUsage } from "../context-usage-impl"

describe("fetchLatestAssistantUsage", () => {
  it("returns tokens.total from the latest assistant message", async () => {
    const mockFetch = vi.fn().mockResolvedValue(
      new Response(
        JSON.stringify([
          { info: { role: "user" } },
          {
            info: {
              role: "assistant",
              tokens: {
                total: 187234,
                input: 0,
                output: 0,
                cache: { read: 0, write: 0 },
              },
            },
          },
        ]),
        { status: 200 },
      ),
    )
    const result = await fetchLatestAssistantUsage({
      fetch: mockFetch,
      serverUrl: new URL("http://localhost:4096"),
      sessionID: "s1",
    })
    expect(result).toBe(187234)
    const req = mockFetch.mock.calls[0][0] as Request
    expect(req.url).toBe("http://localhost:4096/session/s1/message")
    expect(req.method).toBe("GET")
  })

  it("falls back to summing input/output/cache when total is absent", async () => {
    const mockFetch = vi.fn().mockResolvedValue(
      new Response(
        JSON.stringify([
          {
            info: {
              role: "assistant",
              tokens: {
                input: 100_000,
                output: 5_000,
                cache: { read: 80_000, write: 2_000 },
              },
            },
          },
        ]),
        { status: 200 },
      ),
    )
    const result = await fetchLatestAssistantUsage({
      fetch: mockFetch,
      serverUrl: new URL("http://localhost:4096"),
      sessionID: "s1",
    })
    expect(result).toBe(187_000)
  })

  it("walks past zero-token placeholder messages to find one with real numbers", async () => {
    const zeroTokens = { input: 0, output: 0, cache: { read: 0, write: 0 } }
    const mockFetch = vi.fn().mockResolvedValue(
      new Response(
        JSON.stringify([
          { info: { role: "user" } },
          { info: { role: "assistant", tokens: { total: 50_000, ...zeroTokens } } },
          { info: { role: "user" } },
          { info: { role: "assistant", tokens: zeroTokens } }, // placeholder
        ]),
        { status: 200 },
      ),
    )
    const result = await fetchLatestAssistantUsage({
      fetch: mockFetch,
      serverUrl: new URL("http://localhost:4096"),
      sessionID: "s1",
    })
    expect(result).toBe(50_000)
  })

  it("returns null when there is no assistant message yet (turn 1)", async () => {
    const mockFetch = vi.fn().mockResolvedValue(
      new Response(JSON.stringify([{ info: { role: "user" } }]), { status: 200 }),
    )
    const result = await fetchLatestAssistantUsage({
      fetch: mockFetch,
      serverUrl: new URL("http://localhost:4096"),
      sessionID: "s1",
    })
    expect(result).toBeNull()
  })

  it("returns null when the message list is empty", async () => {
    const mockFetch = vi.fn().mockResolvedValue(
      new Response(JSON.stringify([]), { status: 200 }),
    )
    const result = await fetchLatestAssistantUsage({
      fetch: mockFetch,
      serverUrl: new URL("http://localhost:4096"),
      sessionID: "s1",
    })
    expect(result).toBeNull()
  })

  it("returns null on a non-OK HTTP response", async () => {
    const mockFetch = vi.fn().mockResolvedValue(new Response("err", { status: 500 }))
    const result = await fetchLatestAssistantUsage({
      fetch: mockFetch,
      serverUrl: new URL("http://localhost:4096"),
      sessionID: "s1",
    })
    expect(result).toBeNull()
  })

  it("returns null when fetch itself throws (network error)", async () => {
    const mockFetch = vi.fn().mockRejectedValue(new Error("network down"))
    const result = await fetchLatestAssistantUsage({
      fetch: mockFetch,
      serverUrl: new URL("http://localhost:4096"),
      sessionID: "s1",
    })
    expect(result).toBeNull()
  })

  it("returns null when the response body is not valid JSON", async () => {
    const mockFetch = vi.fn().mockResolvedValue(
      new Response("not json at all", { status: 200 }),
    )
    const result = await fetchLatestAssistantUsage({
      fetch: mockFetch,
      serverUrl: new URL("http://localhost:4096"),
      sessionID: "s1",
    })
    expect(result).toBeNull()
  })

  it("returns null when the parsed body is not an array", async () => {
    const mockFetch = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({ unexpected: "shape" }), { status: 200 }),
    )
    const result = await fetchLatestAssistantUsage({
      fetch: mockFetch,
      serverUrl: new URL("http://localhost:4096"),
      sessionID: "s1",
    })
    expect(result).toBeNull()
  })

  it("URL-encodes the sessionID in the request path", async () => {
    const mockFetch = vi.fn().mockResolvedValue(
      new Response(JSON.stringify([]), { status: 200 }),
    )
    await fetchLatestAssistantUsage({
      fetch: mockFetch,
      serverUrl: new URL("http://localhost:4096"),
      sessionID: "ses/with slashes?",
    })
    const req = mockFetch.mock.calls[0][0] as Request
    expect(req.url).toBe(
      "http://localhost:4096/session/ses%2Fwith%20slashes%3F/message",
    )
  })
})