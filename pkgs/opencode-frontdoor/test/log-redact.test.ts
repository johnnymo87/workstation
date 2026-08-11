import { describe, it, expect } from "vitest";
import { redactQuery, QUERY_VALUE_ALLOWLIST } from "../src/log.js";

describe("redactQuery", () => {
  it("returns undefined when there is no query at all", () => {
    // Absence must stay distinguishable from an empty-but-present query.
    expect(redactQuery(undefined)).toBeUndefined();
    expect(redactQuery("")).toBeUndefined();
    expect(redactQuery("?")).toBeUndefined();
  });

  it("records the directory, which is the whole point", () => {
    // The gap this fixes: /config and /config?directory=<x> were indistinguishable
    // in the log, and a real client sends the latter on every request.
    expect(redactQuery("?directory=/home/dev/projects/workstation"))
      .toBe("directory=/home/dev/projects/workstation");
  });

  it("records location[directory], which is what the /api/* routes actually key on", () => {
    expect(redactQuery("?directory=/a&location%5Bdirectory%5D=/a"))
      .toBe("directory=/a&location[directory]=/a");
  });

  it("ELIDES auth_token, and does not rely on it having been stripped upstream", () => {
    // buildForwardSearch only strips auth_token when a serve credential is
    // configured, and the door currently runs without one -- so this value does
    // reach the log path.
    expect(redactQuery("?auth_token=supersecret")).toBe("auth_token=<elided>");
    expect(redactQuery("?directory=/a&auth_token=supersecret&limit=10"))
      .toBe("directory=/a&auth_token=<elided>&limit=10");
  });

  it("defaults to eliding an unknown parameter rather than logging it", () => {
    // A parameter added upstream must be elided by omission, not leaked by it.
    expect(redactQuery("?some_future_token=abc")).toBe("some_future_token=<elided>");
  });

  it("never emits a non-allowlisted value anywhere in its output", () => {
    const out = redactQuery("?auth_token=SECRET1&cookie=SECRET2&session=SECRET3&directory=/a")!;
    expect(out).not.toContain("SECRET1");
    expect(out).not.toContain("SECRET2");
    expect(out).not.toContain("SECRET3");
    expect(out).toContain("directory=/a");
  });

  it("keeps the key visible even when the value is elided", () => {
    // Knowing WHICH parameter was present is most of the forensic value.
    expect(redactQuery("?auth_token=x")).toContain("auth_token");
  });

  it("preserves order and duplicate keys", () => {
    expect(redactQuery("?b=1&directory=/a&b=2")).toBe("b=<elided>&directory=/a&b=<elided>");
  });

  it("decodes percent-encoding so the log is readable", () => {
    expect(redactQuery("?directory=%2Fhome%2Fdev%2Fprojects%2Fbaf-triage"))
      .toBe("directory=/home/dev/projects/baf-triage");
  });

  it("handles a valueless parameter without crashing", () => {
    expect(redactQuery("?directory")).toBe("directory=");
    expect(redactQuery("?weird")).toBe("weird=<elided>");
  });

  it("allowlist contains no obviously credential-shaped names", () => {
    for (const k of QUERY_VALUE_ALLOWLIST) {
      expect(/token|secret|auth|key|password|cookie/i.test(k), `${k} looks credential-shaped`).toBe(false);
    }
  });

  it("reproduces the real query strings captured from a live `opencode attach`", () => {
    // Captured 2026-07-30 from an actual attach via a logging proxy: 41/41 requests
    // carried ?directory=, 0/41 carried x-opencode-directory.
    expect(redactQuery("?start=1782834974068&path=home%2Fdev%2Fprojects%2Fbaf-triage&directory=%2Fhome%2Fdev%2Fprojects%2Fbaf-triage"))
      .toBe("start=1782834974068&path=home/dev/projects/baf-triage&directory=/home/dev/projects/baf-triage");
    expect(redactQuery("?session_ids=ses_04c620eb5ffeWqHLxUJdSdddJl&directory=%2Fhome%2Fdev%2Fprojects%2Fbaf-triage"))
      .toBe("session_ids=<elided>&directory=/home/dev/projects/baf-triage");
  });
});
