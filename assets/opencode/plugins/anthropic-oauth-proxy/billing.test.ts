import { describe, expect, test } from "bun:test"

import { buildBillingHeader } from "./billing"

describe("buildBillingHeader", () => {
  test("uses version 2.1.80 in the billing header", () => {
    const header = buildBillingHeader({
      messages: [{ role: "user", content: "hello world" }],
      version: "2.1.80",
      salt: "59cf53e54c78",
      entrypoint: "cli",
    })

    expect(header).toStartWith("x-anthropic-billing-header: cc_version=2.1.80.")
    expect(header).toContain("cc_entrypoint=cli")
    expect(header).toContain("cch=00000")
  })
})
