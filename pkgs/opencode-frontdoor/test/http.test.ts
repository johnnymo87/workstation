import * as fs from "node:fs";
import { describe, test, expect, vi, beforeEach, afterEach } from "vitest";
import { boundedFetch, boundedPigeonFetch, resolveDaemonToken, invalidateDaemonToken, stripTrailingSlashes, isAbsoluteHttpUrl } from "../src/http.js";

describe("isAbsoluteHttpUrl", () => {
  test("validates absolute http and https URLs", () => {
    expect(isAbsoluteHttpUrl("http://example.com")).toBe(true);
    expect(isAbsoluteHttpUrl("https://example.com/foo")).toBe(true);
    expect(isAbsoluteHttpUrl("ftp://example.com")).toBe(false);
    expect(isAbsoluteHttpUrl("invalid")).toBe(false);
    expect(isAbsoluteHttpUrl("/foo/bar")).toBe(false);
  });
});

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

describe("resolveDaemonToken and boundedPigeonFetch", () => {
  let originalEnv: NodeJS.ProcessEnv;

  beforeEach(() => {
    originalEnv = { ...process.env };
    delete process.env.PIGEON_DAEMON_AUTH_TOKEN;
    delete process.env.PIGEON_DAEMON_AUTH_TOKEN_FILE;
  });

  afterEach(() => {
    for (const key of Object.keys(process.env)) {
      if (!(key in originalEnv)) {
        delete process.env[key];
      }
    }
    Object.assign(process.env, originalEnv);
  });

  test("token from env", () => {
    process.env.PIGEON_DAEMON_AUTH_TOKEN = " env-token-123  ";
    invalidateDaemonToken();
    expect(resolveDaemonToken()).toBe("env-token-123");
  });

  test("token from FILE when env unset", () => {
    delete process.env.PIGEON_DAEMON_AUTH_TOKEN;
    invalidateDaemonToken();
    const testFilePath = "/tmp/fake_pigeon_token_test.txt";
    fs.writeFileSync(testFilePath, "  file-token-456\n  ");
    try {
      const token = resolveDaemonToken({ tokenFilePath: testFilePath });
      expect(token).toBe("file-token-456");
    } finally {
      fs.unlinkSync(testFilePath);
    }
  });

  test("env precedence over file", () => {
    process.env.PIGEON_DAEMON_AUTH_TOKEN = "env-token-789";
    invalidateDaemonToken();
    const testFilePath = "/tmp/fake_pigeon_token_test.txt";
    fs.writeFileSync(testFilePath, "file-token-456");
    try {
      const token = resolveDaemonToken({ tokenFilePath: testFilePath });
      expect(token).toBe("env-token-789");
    } finally {
      fs.unlinkSync(testFilePath);
    }
  });

  test("neither -> undefined", () => {
    delete process.env.PIGEON_DAEMON_AUTH_TOKEN;
    invalidateDaemonToken();
    const token = resolveDaemonToken({ tokenFilePath: "/tmp/non_existent_token_file.txt" });
    expect(token).toBeUndefined();
  });

  test("boundedPigeonFetch: 401 invalidates cache, re-resolves token, retries ONCE, succeeds", async () => {
    delete process.env.PIGEON_DAEMON_AUTH_TOKEN;
    invalidateDaemonToken();

    let callCount = 0;
    const fakeFetch = vi.fn().mockImplementation((_url, options) => {
      callCount++;
      const auth = (options?.headers as any)?.["Authorization"];
      if (callCount === 1) {
        expect(auth).toBe("Bearer old-token");
        return Promise.resolve({ status: 401, body: null } as Response);
      }
      expect(auth).toBe("Bearer new-token");
      return Promise.resolve({ status: 200, json: async () => ({ ok: true }) } as Response);
    });

    process.env.PIGEON_DAEMON_AUTH_TOKEN = "old-token";

    // Call fetch; after first attempt fails with 401, change env to new-token
    const fetchPromise = boundedPigeonFetch("http://example.com/route", {
      method: "GET",
      timeoutMs: 1000,
      fetchImpl: (url, opts) => {
        if (callCount === 0) {
          process.env.PIGEON_DAEMON_AUTH_TOKEN = "new-token";
        }
        return fakeFetch(url, opts);
      },
    });

    const result = await fetchPromise;
    expect(result.ok).toBe(true);
    expect(result.response?.status).toBe(200);
    expect(fakeFetch).toHaveBeenCalledTimes(2);
  });

  test("boundedPigeonFetch: persistent 401 does NOT loop and returns 401 after 1 retry", async () => {
    delete process.env.PIGEON_DAEMON_AUTH_TOKEN;
    invalidateDaemonToken();

    const fakeFetch = vi.fn().mockResolvedValue({ status: 401, body: null } as Response);

    process.env.PIGEON_DAEMON_AUTH_TOKEN = "bad-token";

    const result = await boundedPigeonFetch("http://example.com/route", {
      method: "GET",
      timeoutMs: 1000,
      fetchImpl: fakeFetch,
    });

    expect(result.ok).toBe(true);
    expect(result.response?.status).toBe(401);
    expect(fakeFetch).toHaveBeenCalledTimes(2);
  });
});
