import { describe, test, expect, vi, beforeEach, afterEach } from "vitest";
import http from "node:http";
import type { AddressInfo } from "node:net";
import { createFrontDoor } from "../src/server.js";
import { loadConfig, type Config } from "../src/config.js";
import { buildForwardSearch } from "../src/proxy.js";
import { checkSidExists } from "../src/place.js";
import { rootOf, clearRootCache } from "../src/parent.js";
import { probeServeHealth } from "../src/health.js";
import { handleHealthz } from "../src/healthz.js";
import { createMetrics } from "../src/metrics.js";

describe("buildForwardSearch", () => {
  test("returns original search if serveAuthHeader is undefined", () => {
    expect(buildForwardSearch("?auth_token=secret&a=1", undefined)).toBe("?auth_token=secret&a=1");
    expect(buildForwardSearch("?auth_token=secret", undefined)).toBe("?auth_token=secret");
    expect(buildForwardSearch("", undefined)).toBe("");
  });

  test("strips auth_token parameter when serveAuthHeader is defined while preserving other params in order", () => {
    const auth = "Basic b3BlbmNvZGU6c2VjcmV0";
    expect(buildForwardSearch("?auth_token=secret", auth)).toBe("");
    expect(buildForwardSearch("?auth_token=secret&foo=bar&baz=1", auth)).toBe("?foo=bar&baz=1");
    expect(buildForwardSearch("?foo=bar&auth_token=secret&baz=1", auth)).toBe("?foo=bar&baz=1");
    expect(buildForwardSearch("?foo=bar&baz=1", auth)).toBe("?foo=bar&baz=1");
    expect(buildForwardSearch("", auth)).toBe("");
  });
});

describe("Serve HTTP Basic Auth Injection", () => {
  let anchorServer: http.Server;
  let pigeonServer: http.Server;
  let frontDoorServer: http.Server;

  let portAnchor: number;
  let portPigeon: number;
  let portFrontDoor: number;

  let lastAnchorReqHeaders: http.IncomingHttpHeaders = {};
  let lastAnchorReqUrl: string = "";
  let lastAnchorReqMethod: string = "";

  beforeEach(() => {
    lastAnchorReqHeaders = {};
    lastAnchorReqUrl = "";
    lastAnchorReqMethod = "";
    clearRootCache();
  });

  afterEach(async () => {
    if (frontDoorServer) await new Promise((r) => frontDoorServer.close(r));
    if (anchorServer) await new Promise((r) => anchorServer.close(r));
    if (pigeonServer) await new Promise((r) => pigeonServer.close(r));
  });

  async function setupServers(customConfigOverrides: Partial<Config> = {}) {
    anchorServer = http.createServer((req, res) => {
      lastAnchorReqHeaders = req.headers;
      lastAnchorReqUrl = req.url || "";
      lastAnchorReqMethod = req.method || "";

      if (req.url?.startsWith("/session") && req.method === "POST") {
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ id: "ses_minted123" }));
        return;
      }

      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ ok: true }));
    });

    await new Promise<void>((resolve) => anchorServer.listen(0, "127.0.0.1", resolve));
    portAnchor = (anchorServer.address() as AddressInfo).port;

    pigeonServer = http.createServer((req, res) => {
      if (req.url?.startsWith("/route")) {
        res.writeHead(404, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ error: "not_found" }));
        return;
      }
      if (req.url?.startsWith("/place")) {
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ serve_id: "serve-1", apiBase: `http://127.0.0.1:${portAnchor}` }));
        return;
      }
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ ok: true }));
    });

    await new Promise<void>((resolve) => pigeonServer.listen(0, "127.0.0.1", resolve));
    portPigeon = (pigeonServer.address() as AddressInfo).port;

    const baseConfig = loadConfig();
    const config: Config = {
      ...baseConfig,
      pigeonUrl: `http://127.0.0.1:${portPigeon}`,
      anchorUrl: `http://127.0.0.1:${portAnchor}`,
      ...customConfigOverrides,
    };

    frontDoorServer = createFrontDoor(config);
    await new Promise<void>((resolve) => frontDoorServer.listen(0, "127.0.0.1", resolve));
    portFrontDoor = (frontDoorServer.address() as AddressInfo).port;
  }

  test("1. Streaming path (proxyRequest): injects Authorization header when serveAuthHeader is set", async () => {
    const serveAuthHeader = "Basic " + Buffer.from("opencode:pass123").toString("base64");
    await setupServers({ serveAuthHeader });

    const res = await fetch(`http://127.0.0.1:${portFrontDoor}/config`);
    expect(res.status).toBe(200);
    expect(lastAnchorReqHeaders["authorization"]).toBe(serveAuthHeader);
  });

  test("2. Streaming path (proxyRequest): overwrites client-supplied Authorization header", async () => {
    const serveAuthHeader = "Basic " + Buffer.from("opencode:pass123").toString("base64");
    await setupServers({ serveAuthHeader });

    const res = await fetch(`http://127.0.0.1:${portFrontDoor}/config`, {
      headers: {
        Authorization: "Bearer client-secret-token",
      },
    });
    expect(res.status).toBe(200);
    expect(lastAnchorReqHeaders["authorization"]).toBe(serveAuthHeader);
  });

  test("3. Streaming path (proxyRequest): strips ?auth_token= from forwarded URL while preserving other params", async () => {
    const serveAuthHeader = "Basic " + Buffer.from("opencode:pass123").toString("base64");
    await setupServers({ serveAuthHeader });

    const res = await fetch(`http://127.0.0.1:${portFrontDoor}/config?auth_token=supersecret&foo=bar&baz=123`);
    expect(res.status).toBe(200);
    expect(lastAnchorReqUrl).toBe("/config?foo=bar&baz=123");
    expect(lastAnchorReqHeaders["authorization"]).toBe(serveAuthHeader);
  });

  test("4. Create/Fork path (placeAfterCreate): injects Authorization header when serveAuthHeader is set", async () => {
    const serveAuthHeader = "Basic " + Buffer.from("opencode:pass123").toString("base64");
    await setupServers({ serveAuthHeader });

    const res = await fetch(`http://127.0.0.1:${portFrontDoor}/session`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ title: "test session" }),
    });
    expect(res.status).toBe(200);
    expect(lastAnchorReqHeaders["authorization"]).toBe(serveAuthHeader);
  });

  test("5. Create/Fork path (placeAfterCreate): overwrites client-supplied Authorization header and strips ?auth_token=", async () => {
    const serveAuthHeader = "Basic " + Buffer.from("opencode:pass123").toString("base64");
    await setupServers({ serveAuthHeader });

    const res = await fetch(`http://127.0.0.1:${portFrontDoor}/session?auth_token=badtoken&mode=cli`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": "Bearer client-bearer-token",
      },
      body: JSON.stringify({ title: "test session" }),
    });
    expect(res.status).toBe(200);
    expect(lastAnchorReqUrl).toBe("/session?mode=cli");
    expect(lastAnchorReqHeaders["authorization"]).toBe(serveAuthHeader);
  });

  test("5b. Fork entry point (handleFork -> placeAfterCreate): injects Authorization header, overwrites client Authorization, and strips ?auth_token=", async () => {
    const serveAuthHeader = "Basic " + Buffer.from("opencode:pass123").toString("base64");
    await setupServers({ serveAuthHeader });

    const res = await fetch(`http://127.0.0.1:${portFrontDoor}/session/ses_parent123/fork?auth_token=badtoken&variant=a`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": "Bearer client-bearer-token",
      },
      body: JSON.stringify({}),
    });
    expect(res.status).toBe(200);
    expect(lastAnchorReqUrl).toBe("/session/ses_parent123/fork?variant=a");
    expect(lastAnchorReqHeaders["authorization"]).toBe(serveAuthHeader);
  });

  test("6. Safety property: password unset => no Authorization header added and query string untouched", async () => {
    await setupServers({ serveAuthHeader: undefined });

    // a) Normal request with auth_token and custom Authorization
    const res1 = await fetch(`http://127.0.0.1:${portFrontDoor}/config?auth_token=clientauth&x=1`, {
      headers: {
        Authorization: "Bearer original-token",
      },
    });
    expect(res1.status).toBe(200);
    expect(lastAnchorReqUrl).toBe("/config?auth_token=clientauth&x=1");
    expect(lastAnchorReqHeaders["authorization"]).toBe("Bearer original-token");

    // b) Create request with auth_token
    const res2 = await fetch(`http://127.0.0.1:${portFrontDoor}/session?auth_token=clientauth&y=2`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ title: "test" }),
    });
    expect(res2.status).toBe(200);
    expect(lastAnchorReqUrl).toBe("/session?auth_token=clientauth&y=2");
  });
});

describe("Ancillary Outbound Serve Calls", () => {
  const dummyConfigWithAuth: Config = {
    port: 4700,
    version: "unknown",
    pigeonUrl: "http://pigeon.local",
    anchorUrl: "http://anchor.local",
    poolUrls: ["http://anchor.local"],
    pigeonAuthToken: undefined,
    serveAuthHeader: "Basic " + Buffer.from("opencode:secret").toString("base64"),
    routeTimeoutMs: 3000,
    cheapFirstByteMs: 5000,
    stickyTtlMs: 30000,
    driftCheckMs: 5000,
    wedgeProbeIntervalMs: 5000,
    mintTimeoutMs: 60000,
    logSampleN: 1,
    logSummaryIntervalMs: 300000,
  };

  test("checkSidExists sends serveAuthHeader in headers", async () => {
    const fakeFetch = vi.fn().mockResolvedValue({
      status: 200,
      ok: true,
      json: async () => ({}),
    });

    await checkSidExists("ses_123", dummyConfigWithAuth, { fetch: fakeFetch });
    expect(fakeFetch).toHaveBeenCalledTimes(1);
    const [, init] = fakeFetch.mock.calls[0] as [string, RequestInit];
    expect(init.headers).toEqual({
      Authorization: dummyConfigWithAuth.serveAuthHeader,
    });
  });

  test("rootOf sends serveAuthHeader in headers", async () => {
    const fakeFetch = vi.fn().mockResolvedValue({
      status: 200,
      ok: true,
      json: async () => ({ parentID: null }),
    });

    await rootOf("ses_123", dummyConfigWithAuth, { fetch: fakeFetch });
    expect(fakeFetch).toHaveBeenCalledTimes(1);
    const [, init] = fakeFetch.mock.calls[0] as [string, RequestInit];
    expect(init.headers).toEqual({
      Authorization: dummyConfigWithAuth.serveAuthHeader,
    });
  });

  test("probeServeHealth sends serveAuthHeader in headers", async () => {
    const fakeFetch = vi.fn().mockResolvedValue({
      status: 200,
      ok: true,
    });

    await probeServeHealth("http://serve.local", dummyConfigWithAuth, { fetch: fakeFetch });
    expect(fakeFetch).toHaveBeenCalledTimes(1);
    const [, init] = fakeFetch.mock.calls[0] as [string, RequestInit];
    expect(init.headers).toEqual({
      Authorization: dummyConfigWithAuth.serveAuthHeader,
    });
  });

  test("handleHealthz sends serveAuthHeader to anchor probe", async () => {
    const fakeFetch = vi.fn().mockResolvedValue({
      status: 200,
      ok: true,
      json: async () => ({}),
    });

    const res = {
      writeHead: vi.fn(),
      end: vi.fn(),
    } as any;

    await handleHealthz(res, {
      config: dummyConfigWithAuth,
      method: "GET",
      metrics: createMetrics(),
      deps: { fetch: fakeFetch },
    });

    // fakeFetch called twice: 1 for pigeon, 1 for anchor
    expect(fakeFetch).toHaveBeenCalledTimes(2);
    const anchorCall = fakeFetch.mock.calls.find(([url]) => url.includes("anchor.local"));
    expect(anchorCall).toBeDefined();
    const [, init] = anchorCall as [string, RequestInit];
    expect(init.headers).toEqual({
      Authorization: dummyConfigWithAuth.serveAuthHeader,
    });
  });
});
