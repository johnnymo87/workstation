import { describe, expect, test } from "vitest";
import { isExemptFromFirstByteTimeout } from "../src/timeouts.js";
import type { SidExtraction } from "../src/sid.js";

describe("timeouts exemption classifier", () => {
  const singleSid: SidExtraction = { kind: "single", sid: "ses_123" };
  const multiSid: SidExtraction = { kind: "multi", sids: ["ses_123", "ses_456"] };
  const malformedSid: SidExtraction = { kind: "malformed" };
  const noSid: SidExtraction = { kind: "none" };

  test("exempts streaming/turn-starting POSTs with correct single extraction", () => {
    const streamingSuffixes = [
      "message",
      "prompt",
      "prompt_async",
      "compact",
      "shell",
      "command",
      "summarize",
      "init"
    ];

    for (const suffix of streamingSuffixes) {
      expect(isExemptFromFirstByteTimeout("POST", `/session/ses_123/${suffix}`, singleSid)).toBe(true);
      expect(isExemptFromFirstByteTimeout("POST", `/api/session/ses_123/${suffix}`, singleSid)).toBe(true);
      // Case insensitivity of method
      expect(isExemptFromFirstByteTimeout("post", `/session/ses_123/${suffix}`, singleSid)).toBe(true);
    }
  });

  test("exempts POST wait", () => {
    expect(isExemptFromFirstByteTimeout("POST", "/session/ses_123/wait", singleSid)).toBe(true);
    expect(isExemptFromFirstByteTimeout("POST", "/api/session/ses_123/wait", singleSid)).toBe(true);
    expect(isExemptFromFirstByteTimeout("POST", "/session/ses_123/wait/", singleSid)).toBe(true);
  });

  test("does NOT exempt cheap GETs on session", () => {
    expect(isExemptFromFirstByteTimeout("GET", "/session/ses_123", singleSid)).toBe(false);
    expect(isExemptFromFirstByteTimeout("GET", "/api/session/ses_123", singleSid)).toBe(false);
  });

  test("does NOT exempt SSE handshakes (expected fast first byte)", () => {
    expect(isExemptFromFirstByteTimeout("GET", "/event", singleSid)).toBe(false);
    expect(isExemptFromFirstByteTimeout("GET", "/api/event", singleSid)).toBe(false);
    expect(isExemptFromFirstByteTimeout("GET", "/session/ses_123/event", singleSid)).toBe(false);
    expect(isExemptFromFirstByteTimeout("GET", "/api/session/ses_123/event", singleSid)).toBe(false);
  });

  test("does NOT exempt random side-effect POSTs", () => {
    expect(isExemptFromFirstByteTimeout("POST", "/session/ses_123/dispose", singleSid)).toBe(false);
    expect(isExemptFromFirstByteTimeout("POST", "/api/session/ses_123/random-action", singleSid)).toBe(false);
  });

  test("does NOT exempt requests with multi, malformed, none, or null extraction", () => {
    expect(isExemptFromFirstByteTimeout("POST", "/session/ses_123/wait", multiSid)).toBe(false);
    expect(isExemptFromFirstByteTimeout("POST", "/session/ses_123/wait", malformedSid)).toBe(false);
    expect(isExemptFromFirstByteTimeout("POST", "/session/ses_123/wait", noSid)).toBe(false);
    expect(isExemptFromFirstByteTimeout("POST", "/session/ses_123/wait", null)).toBe(false);
  });

  test("does NOT exempt GET /tui/control/next", () => {
    expect(isExemptFromFirstByteTimeout("GET", "/tui/control/next", singleSid)).toBe(false);
  });
});
