// unwired-test(workstation-5m47): unhermetic (npm ci + loopback sockets); belongs in a ci.yml step, not a nix check
import { describe, expect, test } from "vitest";
import { isHtmlResponse, isHtmlGuardExempt, HTML_GUARD_EXEMPT_ROUTES } from "../src/poison.js";

describe("isHtmlGuardExempt", () => {
  test("returns true for matching raw-byte routes like GET /api/fs/read/*", () => {
    expect(isHtmlGuardExempt("GET", "/api/fs/read/file.html")).toBe(true);
    expect(isHtmlGuardExempt("get", "/api/fs/read/deep/nested/index.html")).toBe(true);
  });

  test("returns false for non-matching methods, path prefixes without slash, or non-exempt paths", () => {
    expect(isHtmlGuardExempt("GET", "/api/fs/readsomething")).toBe(false);
    expect(isHtmlGuardExempt("POST", "/api/fs/read/file.html")).toBe(false);
    expect(isHtmlGuardExempt("GET", "/session/ses_123")).toBe(false);
  });

  test("HTML_GUARD_EXEMPT_ROUTES contains GET /api/fs/read/*", () => {
    expect(HTML_GUARD_EXEMPT_ROUTES).toEqual(["GET /api/fs/read/*"]);
  });
});

describe("isHtmlResponse", () => {
  test("fires for exact text/html media types", () => {
    expect(isHtmlResponse("text/html")).toBe(true);
    expect(isHtmlResponse("text/html; charset=utf-8")).toBe(true);
    expect(isHtmlResponse("TEXT/HTML")).toBe(true);
    expect(isHtmlResponse("  text/html ; charset=utf-8 ")).toBe(true);
  });

  test("handles array input by using the first element", () => {
    expect(isHtmlResponse(["text/html; charset=utf-8", "text/plain"])).toBe(true);
    expect(isHtmlResponse(["application/json", "text/html"])).toBe(false);
  });

  test("does NOT fire for non-HTML or derivative media types (no prefix matching)", () => {
    expect(isHtmlResponse("text/htmlx")).toBe(false);
    expect(isHtmlResponse("application/xhtml+xml")).toBe(false);
    expect(isHtmlResponse("text/event-stream")).toBe(false);
    expect(isHtmlResponse("application/json")).toBe(false);
    expect(isHtmlResponse("text/x-diff; charset=utf-8")).toBe(false);
    expect(isHtmlResponse("application/octet-stream")).toBe(false);
  });

  test("does NOT fire for missing, empty, or non-string inputs", () => {
    expect(isHtmlResponse(undefined)).toBe(false);
    expect(isHtmlResponse("")).toBe(false);
    expect(isHtmlResponse([])).toBe(false);
  });
});
