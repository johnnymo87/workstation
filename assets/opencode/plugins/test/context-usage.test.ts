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
})