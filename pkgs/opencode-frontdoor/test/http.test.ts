import { describe, test, expect, vi } from "vitest";
import { boundedFetch, stripTrailingSlashes } from "../src/http.js";

describe("stripTrailingSlashes", () => {
  test("strips trailing slashes from a URL or base string", () => {
    expect(stripTrailingSlashes("http://example.com/")).toBe("http://example.com");
    expect(stripTrailingSlashes("http://example.com///")).toBe("http://example.com");
    expect(stripTrailingSlashes("http://example.com")).toBe("http://example.com");
  });
});

describe("boundedFetch", () => {
  test("success (returns response, ok:true)", async () => {
    const fakeResponse = {
      status: 200,
      json: async () => ({ value: 42 }),
    } as Response;
    const fakeFetch = vi.fn().mockResolvedValue(fakeResponse);

    const result = await boundedFetch("http://example.com", {
      method: "GET",
      timeoutMs: 1000,
      fetchImpl: fakeFetch,
    });

    expect(result).toEqual({
      ok: true,
      timedOut: false,
      networkError: false,
      response: fakeResponse,
    });
    expect(fakeFetch).toHaveBeenCalledTimes(1);
  });

  test("non-2xx still ok:true with response", async () => {
    const fakeResponse = {
      status: 404,
      json: async () => ({ error: "not found" }),
    } as Response;
    const fakeFetch = vi.fn().mockResolvedValue(fakeResponse);

    const result = await boundedFetch("http://example.com", {
      method: "GET",
      timeoutMs: 1000,
      fetchImpl: fakeFetch,
    });

    expect(result).toEqual({
      ok: true,
      timedOut: false,
      networkError: false,
      response: fakeResponse,
    });
  });

  test("timeout -> timedOut:true/ok:false (no leak, clears timer)", async () => {
    // Return a promise that never resolves
    const fakeFetch = vi.fn().mockImplementation((_url, options) => {
      return new Promise((_resolve, reject) => {
        const signal = options?.signal as AbortSignal | undefined;
        if (signal?.aborted) {
          reject(new DOMException("The user aborted a request.", "AbortError"));
          return;
        }
        signal?.addEventListener("abort", () => {
          reject(new DOMException("The user aborted a request.", "AbortError"));
        });
      });
    });

    const result = await boundedFetch("http://example.com", {
      method: "GET",
      timeoutMs: 10,
      fetchImpl: fakeFetch,
    });

    expect(result).toEqual({
      ok: false,
      timedOut: true,
      networkError: false,
    });
  });

  test("network throw -> networkError:true/ok:false", async () => {
    const fakeFetch = vi.fn().mockRejectedValue(new Error("DNS resolution failed"));

    const result = await boundedFetch("http://example.com", {
      method: "GET",
      timeoutMs: 1000,
      fetchImpl: fakeFetch,
    });

    expect(result).toEqual({
      ok: false,
      timedOut: false,
      networkError: true,
    });
  });

  test("bearer header added only when token set", async () => {
    const fakeResponse = { status: 200 } as Response;
    const fakeFetch = vi.fn().mockResolvedValue(fakeResponse);

    // Case 1: with token
    await boundedFetch("http://example.com", {
      method: "GET",
      timeoutMs: 1000,
      bearerToken: "secret-token",
      fetchImpl: fakeFetch,
    });
    const [, init1] = fakeFetch.mock.calls[0] as [string, RequestInit];
    expect(init1.headers).toEqual({
      "Authorization": "Bearer secret-token",
    });

    // Case 2: without token
    await boundedFetch("http://example.com", {
      method: "GET",
      timeoutMs: 1000,
      fetchImpl: fakeFetch,
    });
    const [, init2] = fakeFetch.mock.calls[1] as [string, RequestInit];
    expect(init2.headers).toEqual({});
  });

  test("body+Content-Type passed through", async () => {
    const fakeResponse = { status: 200 } as Response;
    const fakeFetch = vi.fn().mockResolvedValue(fakeResponse);

    await boundedFetch("http://example.com", {
      method: "POST",
      timeoutMs: 1000,
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ key: "val" }),
      fetchImpl: fakeFetch,
    });

    const [, init] = fakeFetch.mock.calls[0] as [string, RequestInit];
    expect(init.method).toBe("POST");
    expect(init.body).toBe(JSON.stringify({ key: "val" }));
    expect(init.headers).toEqual({
      "Content-Type": "application/json",
    });
  });

  test("GET has no body", async () => {
    const fakeResponse = { status: 200 } as Response;
    const fakeFetch = vi.fn().mockResolvedValue(fakeResponse);

    await boundedFetch("http://example.com", {
      method: "GET",
      timeoutMs: 1000,
      fetchImpl: fakeFetch,
    });

    const [, init] = fakeFetch.mock.calls[0] as [string, RequestInit];
    expect(init.method).toBe("GET");
    expect(init.body).toBeUndefined();
  });
});
