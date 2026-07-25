import { describe, expect, test } from "vitest";
import { isHtmlResponse } from "../src/poison.js";

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
