import { describe, expect, test } from "bun:test"

import { stripAnthropicCacheMarkers } from "./request-shape"

describe("stripAnthropicCacheMarkers", () => {
  test("removes cache marker fields from nested message payloads", () => {
    const body = stripAnthropicCacheMarkers({
      system: [{ type: "text", text: "one", cache_control: { type: "ephemeral" } }],
      messages: [{ role: "user", content: [{ type: "text", text: "two", cacheControl: { type: "ephemeral" } }] }],
    })

    expect(body).toEqual({
      system: [{ type: "text", text: "one" }],
      messages: [{ role: "user", content: [{ type: "text", text: "two" }] }],
    })
  })
})
