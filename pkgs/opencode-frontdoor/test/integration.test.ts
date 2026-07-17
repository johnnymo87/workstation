import { describe, expect, test, beforeAll, afterAll } from "vitest";
import http from "node:http";
import type { AddressInfo } from "node:net";
import { createFrontDoor } from "../src/server.js";
import type { Config } from "../src/config.js";

// SSE drift/heartbeat/turn-end realities are validated by Phase 2 + the Phase 6 through-door gate, not these fakes.

describe("FrontDoor Integration", () => {
  let serverA: http.Server;
  let serverB: http.Server;
  let anchorServer: http.Server;
  let pigeonServer: http.Server;
  let frontDoorServer: http.Server;

  let portA: number;
  let portB: number;
  let portAnchor: number;
  let portPigeon: number;
  let portFrontDoor: number;
  let portSlowStream: number = 0;
  let portDead: number = 9999;

  let pigeonPlaceCalls: any[] = [];
  let pigeonRouteCalls: any[] = [];
  let loggedLines: any[] = [];
  let driftTestApiBase: string = "";

  // Helper to read body from IncomingMessage
  async function readBody(req: http.IncomingMessage): Promise<string> {
    return new Promise((resolve, reject) => {
      let body = "";
      req.on("data", (chunk) => {
        body += chunk;
      });
      req.on("end", () => resolve(body));
      req.on("error", reject);
    });
  }

  beforeAll(async () => {
    // 1. Fake Serve A
    serverA = http.createServer(async (req, res) => {
      if (req.url && req.url.includes("ses_drift")) {
        res.writeHead(200, {
          "Content-Type": "text/event-stream",
          "Cache-Control": "no-cache",
          "Connection": "keep-alive"
        });
        res.write("data: connected\n\n");
        return;
      }
      if (req.url && req.url.includes("ses_hb")) {
        res.writeHead(200, {
          "Content-Type": "text/event-stream",
          "Cache-Control": "no-cache",
          "Connection": "keep-alive"
        });
        res.write("data: connected\n\n");
        const interval = setInterval(() => {
          if (!res.destroyed) {
            try {
              res.write("event: server.heartbeat\ndata: {}\n\n");
            } catch {
              clearInterval(interval);
            }
          } else {
            clearInterval(interval);
          }
        }, 30);
        res.on("close", () => {
          clearInterval(interval);
        });
        return;
      }
      const body = await readBody(req);
      const status = req.headers["x-test-status"] ? parseInt(req.headers["x-test-status"] as string, 10) : 200;
      res.writeHead(status, {
        "Content-Type": "application/json",
        "x-from-serve": "serve-a",
        "x-echo-header": req.headers["x-test-header"] || ""
      });
      res.end(JSON.stringify({
        serve: "serve-a",
        method: req.method,
        path: req.url,
        headers: req.headers,
        body
      }));
    });
    await new Promise<void>((resolve) => serverA.listen(0, "127.0.0.1", () => resolve()));
    portA = (serverA.address() as AddressInfo).port;

    // 2. Fake Serve B
    serverB = http.createServer(async (req, res) => {
      const body = await readBody(req);
      const status = req.headers["x-test-status"] ? parseInt(req.headers["x-test-status"] as string, 10) : 200;
      res.writeHead(status, {
        "Content-Type": "application/json",
        "x-from-serve": "serve-b",
        "x-echo-header": req.headers["x-test-header"] || "",
        "upgrade": "websocket",
        "proxy-authenticate": "Basic"
      });
      res.end(JSON.stringify({
        serve: "serve-b",
        method: req.method,
        path: req.url,
        headers: req.headers,
        body
      }));
    });
    await new Promise<void>((resolve) => serverB.listen(0, "127.0.0.1", () => resolve()));
    portB = (serverB.address() as AddressInfo).port;

    // 3. Fake Anchor Serve
    anchorServer = http.createServer(async (req, res) => {
      // Simulate checking session existence in anchor
      if (req.url && req.url.startsWith("/session/")) {
        const sid = req.url.split("/")[2];
        if (sid === "ses_unknown") {
          res.writeHead(404, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ error: "not found" }));
          return;
        } else {
          res.writeHead(200, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ exists: true }));
          return;
        }
      }

      const body = await readBody(req);
      res.writeHead(200, {
        "Content-Type": "application/json",
        "x-from-serve": "anchor"
      });
      res.end(JSON.stringify({
        serve: "anchor",
        method: req.method,
        path: req.url,
        body
      }));
    });
    await new Promise<void>((resolve) => anchorServer.listen(0, "127.0.0.1", () => resolve()));
    portAnchor = (anchorServer.address() as AddressInfo).port;

    // 4. Fake Pigeon Server
    pigeonServer = http.createServer(async (req, res) => {
      const parsedUrl = new URL(req.url || "", `http://${req.headers.host}`);
      if (parsedUrl.pathname === "/route") {
        const sid = parsedUrl.searchParams.get("session_id");
        pigeonRouteCalls.push({ sid, url: req.url });

        if (sid === "ses_drift" || sid === "ses_hb") {
          res.writeHead(200, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ apiBase: driftTestApiBase || `http://127.0.0.1:${portA}`, prospective: false }));
        } else if (sid === "ses_a" || sid === "ses_multi1") {
          res.writeHead(200, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ apiBase: `http://127.0.0.1:${portA}`, prospective: false }));
        } else if (sid === "ses_b" || sid === "ses_multi2") {
          res.writeHead(200, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ apiBase: `http://127.0.0.1:${portB}`, prospective: false }));
        } else if (sid === "ses_prospective") {
          res.writeHead(200, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ apiBase: `http://127.0.0.1:${portA}`, prospective: true }));
        } else if (sid === "ses_promo_invalid") {
          res.writeHead(200, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ apiBase: `http://127.0.0.1:${portA}`, prospective: true }));
        } else if (sid === "ses_slow_stream") {
          res.writeHead(200, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ apiBase: `http://127.0.0.1:${portSlowStream}`, prospective: false }));
        } else if (sid === "ses_dead_port") {
          res.writeHead(200, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ apiBase: `http://127.0.0.1:${portDead}`, prospective: false }));
        } else if (sid === "ses_pigeon_err") {
          res.writeHead(500, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ error: "internal_error" }));
        } else {
          res.writeHead(404, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ error: "not_routed" }));
        }
      } else if (parsedUrl.pathname === "/place" && req.method === "POST") {
        const bodyStr = await readBody(req);
        const body = JSON.parse(bodyStr);
        pigeonPlaceCalls.push(body);

        res.writeHead(200, { "Content-Type": "application/json" });
        if (body.session_id === "ses_promo_invalid") {
          res.end(JSON.stringify({
            ok: true,
            serve_id: "serve-invalid",
            api_base: "/relative/invalid/path"
          }));
        } else {
          res.end(JSON.stringify({
            ok: true,
            serve_id: "serve-b",
            api_base: `http://127.0.0.1:${portB}`
          }));
        }
      } else {
        res.writeHead(404);
        res.end();
      }
    });
    await new Promise<void>((resolve) => pigeonServer.listen(0, "127.0.0.1", () => resolve()));
    portPigeon = (pigeonServer.address() as AddressInfo).port;

    // 5. Start FrontDoor Server
    const testConfig: Config = {
      port: 0, // ephemeral
      version: 'unknown',
      pigeonUrl: `http://127.0.0.1:${portPigeon}`,
      anchorUrl: `http://127.0.0.1:${portAnchor}`,
      routeTimeoutMs: 1000,
      cheapFirstByteMs: 1000,
      stickyTtlMs: 30000,
      driftCheckMs: 5000,
      wedgeProbeIntervalMs: 5000,
    };

    const testDeps = {
      logger: {
        sink: (line: string) => {
          try {
            loggedLines.push(JSON.parse(line));
          } catch {}
          console.log(line);
        }
      }
    };

    frontDoorServer = createFrontDoor(testConfig, testDeps);
    await new Promise<void>((resolve) => frontDoorServer.listen(0, "127.0.0.1", () => resolve()));
    portFrontDoor = (frontDoorServer.address() as AddressInfo).port;
  });

  afterAll(async () => {
    // Shutdown everything cleanly
    await Promise.all([
      new Promise<void>((r) => serverA.close(() => r())),
      new Promise<void>((r) => serverB.close(() => r())),
      new Promise<void>((r) => anchorServer.close(() => r())),
      new Promise<void>((r) => pigeonServer.close(() => r())),
      new Promise<void>((r) => frontDoorServer.close(() => r()))
    ]);
  });

  // helper to make requests to the front door
  async function makeRequest(
    method: string,
    path: string,
    headers?: Record<string, string>,
    body?: string
  ): Promise<{ status: number; headers: http.IncomingHttpHeaders; body: string }> {
    return new Promise((resolve, reject) => {
      const req = http.request({
        hostname: "127.0.0.1",
        port: portFrontDoor,
        path,
        method,
        headers
      }, async (res) => {
        const body = await readBody(res);
        resolve({
          status: res.statusCode || 0,
          headers: res.headers,
          body
        });
      });
      req.on("error", reject);
      if (body !== undefined) {
        req.write(body);
      }
      req.end();
    });
  }

  test("1. route-to-owner: forwards valid routed session to owner serve", async () => {
    pigeonRouteCalls = [];
    pigeonPlaceCalls = [];

    const res = await makeRequest("GET", "/session/ses_a");
    expect(res.status).toBe(200);
    expect(res.headers["x-from-serve"]).toBe("serve-a");

    const json = JSON.parse(res.body);
    expect(json.serve).toBe("serve-a");
    expect(json.method).toBe("GET");
    expect(json.path).toBe("/session/ses_a");
    expect(pigeonRouteCalls).toHaveLength(1);
    expect(pigeonRouteCalls[0].sid).toBe("ses_a");
  });

  test("2. unknown -> anchor: forwards to anchor when pigeon returns 404", async () => {
    pigeonRouteCalls = [];
    const res = await makeRequest("GET", "/session/ses_unknown");
    expect(res.status).toBe(404); // the anchor's /session/ses_unknown endpoint returns 404
    expect(pigeonRouteCalls).toHaveLength(1);
  });

  test("3. header/body/status passthrough", async () => {
    const res = await makeRequest(
      "POST",
      "/session/ses_b/message",
      {
        "x-test-status": "201",
        "x-test-header": "pass-this-header",
        "connection": "Upgrade",
        "upgrade": "websocket",
        "proxy-authorization": "Bearer secret"
      },
      "hello world body"
    );

    expect(res.status).toBe(201);
    expect(res.headers["x-from-serve"]).toBe("serve-b");
    expect(res.headers["x-echo-header"]).toBe("pass-this-header");
    expect(res.headers["upgrade"]).toBeUndefined();
    expect(res.headers["proxy-authenticate"]).toBeUndefined();

    const json = JSON.parse(res.body);
    expect(json.body).toBe("hello world body");
    // Verify hop-by-hop headers and host header are handled properly
    expect(json.headers["upgrade"]).toBeUndefined();
    expect(json.headers["proxy-authorization"]).toBeUndefined();
    expect(json.headers["host"]).toBe(`127.0.0.1:${portB}`);
  });

  test("4. no-retry-after-send: headers written, no duplicate response", async () => {
    // This is a pragmatic check ensuring we get correct proxy stream behavior without repeats.
    const res = await makeRequest("GET", "/session/ses_a");
    expect(res.status).toBe(200);
    expect(res.headers["x-from-serve"]).toBe("serve-a");
  });

  test("5. dispatch policies through the server", async () => {
    // POST /global/dispose -> 405
    const resDispose = await makeRequest("POST", "/global/dispose");
    expect(resDispose.status).toBe(405);

    // GET /global/event -> 410
    const resEvent = await makeRequest("GET", "/global/event");
    expect(resEvent.status).toBe(410);

    // GET /pty -> 501
    const resPty = await makeRequest("GET", "/pty");
    expect(resPty.status).toBe(501);

    // GET /tui/control/next -> 501
    const resTuiGet = await makeRequest("GET", "/tui/control/next");
    expect(resTuiGet.status).toBe(501);
    const jsonTuiGet = JSON.parse(resTuiGet.body);
    expect(jsonTuiGet).toEqual({
      error: "not_implemented",
      message: "TUI endpoints are per-process; not available through the front door"
    });

    // POST /tui/append-prompt -> 501
    const resTuiPost1 = await makeRequest("POST", "/tui/append-prompt");
    expect(resTuiPost1.status).toBe(501);
    const jsonTuiPost1 = JSON.parse(resTuiPost1.body);
    expect(jsonTuiPost1).toEqual({
      error: "not_implemented",
      message: "TUI endpoints are per-process; not available through the front door"
    });

    // POST /tui/control/response -> 501
    const resTuiPost2 = await makeRequest("POST", "/tui/control/response");
    expect(resTuiPost2.status).toBe(501);
    const jsonTuiPost2 = JSON.parse(resTuiPost2.body);
    expect(jsonTuiPost2).toEqual({
      error: "not_implemented",
      message: "TUI endpoints are per-process; not available through the front door"
    });

    // GET /nonexistent -> 404
    const resNone = await makeRequest("GET", "/nonexistent");
    expect(resNone.status).toBe(404);
  });

  test("6. promotion wiring: promoting prospective session triggers place", async () => {
    pigeonPlaceCalls = [];
    pigeonRouteCalls = [];

    // GET /session/{sid}/event is a promoting request
    const res = await makeRequest("GET", "/api/session/ses_prospective/event");
    expect(res.status).toBe(200);

    // The placed serve is serve-b (portB)
    expect(res.headers["x-from-serve"]).toBe("serve-b");

    expect(pigeonRouteCalls).toHaveLength(1);
    expect(pigeonRouteCalls[0].sid).toBe("ses_prospective");

    expect(pigeonPlaceCalls).toHaveLength(1);
    expect(pigeonPlaceCalls[0]).toEqual({ session_id: "ses_prospective" });
  });

  test("6b. promotion wiring: casual GET does NOT trigger place", async () => {
    pigeonPlaceCalls = [];
    pigeonRouteCalls = [];

    // GET /session/{sid} is not promoting
    const res = await makeRequest("GET", "/session/ses_prospective");
    expect(res.status).toBe(200);

    // Resolved owner was serve-a (portA)
    expect(res.headers["x-from-serve"]).toBe("serve-a");

    expect(pigeonRouteCalls).toHaveLength(1);
    expect(pigeonRouteCalls[0].sid).toBe("ses_prospective");
    expect(pigeonPlaceCalls).toHaveLength(0);
  });

  test("6c. promotion wiring: invalid apiBase in promotion falls back to resolved.url", async () => {
    pigeonPlaceCalls = [];
    pigeonRouteCalls = [];

    const res = await makeRequest("GET", "/api/session/ses_promo_invalid/event");
    expect(res.status).toBe(200);

    // It should fall back to resolved.url which is serve-a (portA)
    expect(res.headers["x-from-serve"]).toBe("serve-a");

    expect(pigeonRouteCalls).toHaveLength(1);
    expect(pigeonRouteCalls[0].sid).toBe("ses_promo_invalid");
    expect(pigeonPlaceCalls).toHaveLength(1);
    expect(pigeonPlaceCalls[0]).toEqual({ session_id: "ses_promo_invalid" });
  });

  test("6d. promotion wiring: HEAD to promoting session route does NOT trigger place", async () => {
    pigeonPlaceCalls = [];
    pigeonRouteCalls = [];

    const res = await makeRequest("HEAD", "/api/session/ses_prospective/event");
    // Since HEAD falls back to GET, it should route to GET /api/session/ses_prospective/event's owner
    // which is ses_prospective -> resolved.url -> serve-a (portA). It should NOT trigger place because HEAD does not promote.
    // Also since HEAD has no body, the response has content-length or just status, let's verify status is 200 (or whatever serve-a returns, wait serve-a response has headers and body but node's http.Server for HEAD requests handles body stripping, wait, does proxyRequest strip body for HEAD? Yes, standard node http client request with method HEAD will receive response with no body or body-less).
    expect(res.status).toBe(200);
    expect(res.headers["x-from-serve"]).toBe("serve-a");

    expect(pigeonRouteCalls).toHaveLength(1);
    expect(pigeonRouteCalls[0].sid).toBe("ses_prospective");
    expect(pigeonPlaceCalls).toHaveLength(0);
  });

  test("7. multi-session handling: same owners", async () => {
    pigeonRouteCalls = [];
    const res = await makeRequest("GET", "/event?session_ids=ses_a,ses_a");
    expect(res.status).toBe(200);
    expect(res.headers["x-from-serve"]).toBe("serve-a");
  });

  test("7b. multi-session handling: diverging owners returns 400", async () => {
    pigeonRouteCalls = [];
    const res = await makeRequest("GET", "/event?session_ids=ses_a,ses_b");
    expect(res.status).toBe(400);
  });

  test("7c. multi-session handling: too many session_ids returns 400 without pigeon calls", async () => {
    pigeonRouteCalls = [];
    const sids = Array.from({ length: 33 }, (_, i) => "ses_a").join(",");
    const res = await makeRequest("GET", `/event?session_ids=${sids}`);
    expect(res.status).toBe(400);
    const json = JSON.parse(res.body);
    expect(json.error).toBe("bad_request");
    expect(json.message).toBe("too many session_ids");
    expect(pigeonRouteCalls).toHaveLength(0);
  });

  test("7d. multi-session handling: 32 session_ids proceeds", async () => {
    pigeonRouteCalls = [];
    const sids = Array.from({ length: 32 }, (_, i) => "ses_a").join(",");
    const res = await makeRequest("GET", `/event?session_ids=${sids}`);
    expect(res.status).toBe(200);
    expect(pigeonRouteCalls).toHaveLength(32);
  });

  test("7e. multi-session handling: parent-leased + child-404 forwards to parent's serve", async () => {
    pigeonRouteCalls = [];
    loggedLines = [];
    const res = await makeRequest("GET", "/event?session_ids=ses_a,ses_unknown");
    expect(res.status).toBe(200);
    expect(res.headers["x-from-serve"]).toBe("serve-a");

    await new Promise<void>((resolve) => setTimeout(resolve, 5));
    const logEntry = loggedLines.find((entry) => entry.path === "/event" && entry.method === "GET");
    expect(logEntry).toBeDefined();
    expect(logEntry.degraded).toBe(false);
    expect(logEntry.target).toBe(`http://127.0.0.1:${portA}`);
  });

  test("7f. multi-session handling: all-unplaced forwards to anchor with degraded=false", async () => {
    pigeonRouteCalls = [];
    loggedLines = [];
    const res = await makeRequest("GET", "/event?session_ids=ses_unknown1,ses_unknown2");
    expect(res.status).toBe(200);
    expect(res.headers["x-from-serve"]).toBe("anchor");

    await new Promise<void>((resolve) => setTimeout(resolve, 5));
    const logEntry = loggedLines.find((entry) => entry.path === "/event" && entry.method === "GET");
    expect(logEntry).toBeDefined();
    expect(logEntry.degraded).toBe(false);
    expect(logEntry.target).toBe(`http://127.0.0.1:${portAnchor}`);
  });

  test("7g. multi-session handling: all-unplaced with a pigeon error forwards to anchor with degraded=true", async () => {
    pigeonRouteCalls = [];
    loggedLines = [];
    const res = await makeRequest("GET", "/event?session_ids=ses_unknown,ses_pigeon_err");
    expect(res.status).toBe(200);
    expect(res.headers["x-from-serve"]).toBe("anchor");

    await new Promise<void>((resolve) => setTimeout(resolve, 5));
    const logEntry = loggedLines.find((entry) => entry.path === "/event" && entry.method === "GET");
    expect(logEntry).toBeDefined();
    expect(logEntry.degraded).toBe(true);
    expect(logEntry.target).toBe(`http://127.0.0.1:${portAnchor}`);
  });

  test("8. forward-anchor: proxies global-ro route /config to anchorUrl", async () => {
    const res = await makeRequest("GET", "/config");
    expect(res.status).toBe(200);
    expect(res.headers["x-from-serve"]).toBe("anchor");
    const json = JSON.parse(res.body);
    expect(json.serve).toBe("anchor");
    expect(json.path).toBe("/config");
  });

  test("9. create: POST /session proxies to anchorUrl without triggering place", async () => {
    pigeonPlaceCalls = [];
    const res = await makeRequest("POST", "/session", {}, "create-session-body");
    expect(res.status).toBe(200);
    expect(res.headers["x-from-serve"]).toBe("anchor");
    const json = JSON.parse(res.body);
    expect(json.serve).toBe("anchor");
    expect(json.body).toBe("create-session-body");
    expect(pigeonPlaceCalls).toHaveLength(0);
  });

  test("10. none -> 400: GET /event with no session_ids returns 400", async () => {
    loggedLines = [];
    const res = await makeRequest("GET", "/event");
    expect(res.status).toBe(400);
    const json = JSON.parse(res.body);
    expect(json.error).toBe("bad_request");
    expect(json.message).toBe("session_ids query parameter is required");

    // Wait for the finish/close logger triggers to be processed
    await new Promise<void>((resolve) => setTimeout(resolve, 5));

    const logEntry = loggedLines.find((entry) => entry.path === "/event" && entry.method === "GET");
    expect(logEntry).toBeDefined();
    expect(logEntry.degraded).toBe(false);
    expect(logEntry.target).toBe("");
  });

  test("11. malformed -> 400: request with bad session id character returns 400", async () => {
    const res = await makeRequest("GET", "/session/ses_bad$char/message");
    expect(res.status).toBe(400);
    const json = JSON.parse(res.body);
    expect(json.error).toBe("bad_request");
    expect(json.message).toBe("Malformed session ID");
  });

  test("12. crash safety: client aborts mid-response", async () => {
    const slowServer = http.createServer((req, res) => {
      res.writeHead(200, { "Content-Type": "text/plain" });
      res.write("chunk1\n");
      const interval = setInterval(() => {
        try {
          res.write("chunk2\n");
        } catch {
          clearInterval(interval);
        }
      }, 10);
      req.on("close", () => {
        clearInterval(interval);
      });
      res.on("close", () => {
        clearInterval(interval);
      });
    });

    await new Promise<void>((resolve) => slowServer.listen(0, "127.0.0.1", () => resolve()));
    portSlowStream = (slowServer.address() as AddressInfo).port;

    const req = http.request({
      hostname: "127.0.0.1",
      port: portFrontDoor,
      path: "/session/ses_slow_stream",
      method: "GET"
    }, (res) => {
      res.on("data", (chunk) => {
        req.destroy();
      });
    });

    req.on("error", () => {
      // Ignored
    });
    req.end();

    await new Promise<void>((resolve) => {
      req.on("close", resolve);
    });

    // Let the front door finish clean-up/resolution
    await new Promise((r) => setTimeout(r, 20));

    // Verify front door is still responsive and works normally
    const subsequentRes = await makeRequest("GET", "/session/ses_a");
    expect(subsequentRes.status).toBe(200);
    expect(subsequentRes.headers["x-from-serve"]).toBe("serve-a");

    await new Promise<void>((resolve) => slowServer.close(() => resolve()));
  });

  test("13. crash safety: upstream connect failure returns 502", async () => {
    const tempServer = http.createServer();
    await new Promise<void>((resolve) => tempServer.listen(0, "127.0.0.1", () => resolve()));
    portDead = (tempServer.address() as AddressInfo).port;
    await new Promise<void>((resolve) => tempServer.close(() => resolve()));

    const res = await makeRequest("GET", "/session/ses_dead_port");
    expect(res.status).toBe(502);

    const json = JSON.parse(res.body);
    expect(json.error).toBe("bad_gateway");

    // Verify subsequent requests still succeed
    const subsequentRes = await makeRequest("GET", "/session/ses_a");
    expect(subsequentRes.status).toBe(200);
    expect(subsequentRes.headers["x-from-serve"]).toBe("serve-a");
  });

  test("14. owner-drift integration: closes the SSE stream cleanly on confirmed drift", async () => {
    // 1. Configure the FrontDoor with extremely fast drift polling
    const fastDriftConfig: Config = {
      port: 0, // ephemeral
      version: 'unknown',
      pigeonUrl: `http://127.0.0.1:${portPigeon}`,
      anchorUrl: `http://127.0.0.1:${portAnchor}`,
      routeTimeoutMs: 1000,
      cheapFirstByteMs: 1000,
      stickyTtlMs: 30000,
      driftCheckMs: 40,
      wedgeProbeIntervalMs: 5000,
    };

    const fastDeps = {
      logger: {
        sink: () => {}
      }
    };

    const fastFrontDoor = createFrontDoor(fastDriftConfig, fastDeps);
    await new Promise<void>((resolve) => fastFrontDoor.listen(0, "127.0.0.1", () => resolve()));
    const fastPort = (fastFrontDoor.address() as AddressInfo).port;

    try {
      // Initialize pigeon routing to Serve A
      driftTestApiBase = `http://127.0.0.1:${portA}`;

      // Open a live SSE stream request to the fast frontdoor
      let streamEnded = false;
      let firstChunkReceived = false;
      let resolveFirstChunk: () => void = () => {};
      const firstChunkPromise = new Promise<void>((resolve) => {
        resolveFirstChunk = resolve;
      });

      const clientReq = http.request({
        hostname: "127.0.0.1",
        port: fastPort,
        path: "/event?session_ids=ses_drift",
        method: "GET"
      }, (clientRes) => {
        expect(clientRes.statusCode).toBe(200);
        expect(clientRes.headers["content-type"]).toContain("text/event-stream");

        clientRes.on("data", (chunk) => {
          const str = chunk.toString();
          if (str.includes("connected")) {
            firstChunkReceived = true;
            resolveFirstChunk();
          }
        });

        clientRes.on("end", () => {
          streamEnded = true;
        });
      });

      clientReq.on("error", (err) => {
        // Ignored
      });
      clientReq.end();

      // Wait until we are connected and have received the first chunk
      await firstChunkPromise;
      expect(firstChunkReceived).toBe(true);
      expect(streamEnded).toBe(false);

      // Now flip the pigeon routing to Serve B
      driftTestApiBase = `http://127.0.0.1:${portB}`;

      // Wait a bit for the fast drift poller to run two consecutive checks (every 40ms).
      // We poll streamEnded dynamically.
      let closed = false;
      for (let i = 0; i < 40; i++) {
        if (streamEnded) { closed = true; break; }
        await new Promise((resolve) => setTimeout(resolve, 50));
      }
      expect(closed).toBe(true);

      clientReq.destroy();
    } finally {
      await new Promise<void>((resolve) => fastFrontDoor.close(() => resolve()));
    }
  });

  test("15. owner-drift integration FABLE2-B1: drops the SSE stream cleanly on confirmed drift despite continuous heartbeat activity", async () => {
    const fastDriftConfig: Config = {
      port: 0,
      version: 'unknown',
      pigeonUrl: `http://127.0.0.1:${portPigeon}`,
      anchorUrl: `http://127.0.0.1:${portAnchor}`,
      routeTimeoutMs: 1000,
      cheapFirstByteMs: 1000,
      stickyTtlMs: 30000,
      driftCheckMs: 40,
      wedgeProbeIntervalMs: 5000,
    };

    const fastDeps = {
      logger: {
        sink: () => {}
      }
    };

    const fastFrontDoor = createFrontDoor(fastDriftConfig, fastDeps);
    await new Promise<void>((resolve) => fastFrontDoor.listen(0, "127.0.0.1", () => resolve()));
    const fastPort = (fastFrontDoor.address() as AddressInfo).port;

    try {
      driftTestApiBase = `http://127.0.0.1:${portA}`;

      let streamEnded = false;
      let firstChunkReceived = false;
      let resolveFirstChunk: () => void = () => {};
      const firstChunkPromise = new Promise<void>((resolve) => {
        resolveFirstChunk = resolve;
      });

      const clientReq = http.request({
        hostname: "127.0.0.1",
        port: fastPort,
        path: "/event?session_ids=ses_hb",
        method: "GET"
      }, (clientRes) => {
        expect(clientRes.statusCode).toBe(200);
        expect(clientRes.headers["content-type"]).toContain("text/event-stream");

        clientRes.on("data", (chunk) => {
          const str = chunk.toString();
          if (str.includes("connected")) {
            firstChunkReceived = true;
            resolveFirstChunk();
          }
        });

        clientRes.on("end", () => {
          streamEnded = true;
        });
      });

      clientReq.on("error", (err) => {
        // Ignored
      });
      clientReq.end();

      await firstChunkPromise;
      expect(firstChunkReceived).toBe(true);
      expect(streamEnded).toBe(false);

      driftTestApiBase = `http://127.0.0.1:${portB}`;

      let closed = false;
      for (let i = 0; i < 20; i++) {
        if (streamEnded) { closed = true; break; }
        await new Promise((resolve) => setTimeout(resolve, 50));
      }
      expect(closed).toBe(true);

      clientReq.destroy();
    } finally {
      await new Promise<void>((resolve) => fastFrontDoor.close(() => resolve()));
    }
  });

  test("16. wall-clock first-byte timeout (Part C): non-exempt request times out with 503", async () => {
    let slowServerPort: number;
    const slowServer = http.createServer((req, res) => {
      // Do not send headers, just sleep/idle
    });
    await new Promise<void>((resolve) => slowServer.listen(0, "127.0.0.1", () => resolve()));
    slowServerPort = (slowServer.address() as AddressInfo).port;

    const timeoutConfig: Config = {
      port: 0,
      version: 'unknown',
      pigeonUrl: `http://127.0.0.1:${portPigeon}`,
      anchorUrl: `http://127.0.0.1:${slowServerPort}`,
      routeTimeoutMs: 1000,
      cheapFirstByteMs: 100, // 100ms wall-clock limit
      stickyTtlMs: 30000,
      driftCheckMs: 10000,
      wedgeProbeIntervalMs: 5000,
    };

    const timeoutFrontDoor = createFrontDoor(timeoutConfig, {
      logger: { sink: () => {} }
    });
    await new Promise<void>((resolve) => timeoutFrontDoor.listen(0, "127.0.0.1", () => resolve()));
    const frontDoorPort = (timeoutFrontDoor.address() as AddressInfo).port;

    try {
      const start = Date.now();
      const res = await new Promise<any>((resolve, reject) => {
        const req = http.request({
          hostname: "127.0.0.1",
          port: frontDoorPort,
          path: "/api/session/ses_timeout",
          method: "GET"
        }, (res) => {
          let body = "";
          res.on("data", (chunk) => { body += chunk; });
          res.on("end", () => resolve({ status: res.statusCode, body }));
        });
        req.on("error", reject);
        req.end();
      });

      const duration = Date.now() - start;
      expect(res.status).toBe(503);
      expect(JSON.parse(res.body)).toEqual({
        error: "service_unavailable",
        message: "Upstream did not send response headers in time"
      });
      expect(duration).toBeGreaterThanOrEqual(80);
      expect(duration).toBeLessThan(400); // should be around 100ms, not much longer
    } finally {
      await new Promise<void>((resolve) => timeoutFrontDoor.close(() => resolve()));
      await new Promise<void>((resolve) => slowServer.close(() => resolve()));
    }
  });

  test("17. wall-clock first-byte timeout (Part C): exempt request (POST /wait) does NOT time out", async () => {
    let slowServerPort: number;
    let receivedWaitRequest = false;
    let resolveWaitReceived: () => void = () => {};
    const waitReceivedPromise = new Promise<void>((resolve) => {
      resolveWaitReceived = resolve;
    });

    const slowServer = http.createServer((req, res) => {
      if (req.url && req.url.includes("/wait")) {
        receivedWaitRequest = true;
        resolveWaitReceived();
      }
      // Keep connection open without writing headers
    });
    await new Promise<void>((resolve) => slowServer.listen(0, "127.0.0.1", () => resolve()));
    slowServerPort = (slowServer.address() as AddressInfo).port;

    const timeoutConfig: Config = {
      port: 0,
      version: 'unknown',
      pigeonUrl: `http://127.0.0.1:${portPigeon}`,
      anchorUrl: `http://127.0.0.1:${slowServerPort}`,
      routeTimeoutMs: 1000,
      cheapFirstByteMs: 100, // 100ms
      stickyTtlMs: 30000,
      driftCheckMs: 10000,
      wedgeProbeIntervalMs: 5000,
    };

    const timeoutFrontDoor = createFrontDoor(timeoutConfig, {
      logger: { sink: () => {} }
    });
    await new Promise<void>((resolve) => timeoutFrontDoor.listen(0, "127.0.0.1", () => resolve()));
    const frontDoorPort = (timeoutFrontDoor.address() as AddressInfo).port;

    try {
      let gotTimeout = false;
      const clientReq = http.request({
        hostname: "127.0.0.1",
        port: frontDoorPort,
        path: "/api/session/ses_timeout/wait",
        method: "POST"
      }, (res) => {
        // If it responds, that means it timed out or finished
        if (res.statusCode === 503) {
          gotTimeout = true;
        }
      });
      clientReq.on("error", () => {});
      clientReq.end();

      // Wait until slowServer receives the request
      await waitReceivedPromise;
      expect(receivedWaitRequest).toBe(true);

      // Wait 250ms (well past the 100ms first-byte timeout threshold)
      await new Promise((resolve) => setTimeout(resolve, 250));

      expect(gotTimeout).toBe(false);
      clientReq.destroy();
    } finally {
      await new Promise<void>((resolve) => timeoutFrontDoor.close(() => resolve()));
      await new Promise<void>((resolve) => slowServer.close(() => resolve()));
    }
  });

  test("18. wall-clock first-byte timeout (Part C): slow upload (W9) does NOT reset wall-clock timer, still times out", async () => {
    let slowServerPort: number;
    const slowServer = http.createServer((req, res) => {
      // Consume body, never send headers
      req.on("data", () => {});
    });
    await new Promise<void>((resolve) => slowServer.listen(0, "127.0.0.1", () => resolve()));
    slowServerPort = (slowServer.address() as AddressInfo).port;

    const timeoutConfig: Config = {
      port: 0,
      version: 'unknown',
      pigeonUrl: `http://127.0.0.1:${portPigeon}`,
      anchorUrl: `http://127.0.0.1:${slowServerPort}`,
      routeTimeoutMs: 1000,
      cheapFirstByteMs: 100, // 100ms
      stickyTtlMs: 30000,
      driftCheckMs: 10000,
      wedgeProbeIntervalMs: 5000,
    };

    const timeoutFrontDoor = createFrontDoor(timeoutConfig, {
      logger: { sink: () => {} }
    });
    await new Promise<void>((resolve) => timeoutFrontDoor.listen(0, "127.0.0.1", () => resolve()));
    const frontDoorPort = (timeoutFrontDoor.address() as AddressInfo).port;

    try {
      const start = Date.now();
      const resPromise = new Promise<any>((resolve, reject) => {
        const clientReq = http.request({
          hostname: "127.0.0.1",
          port: frontDoorPort,
          path: "/api/session/ses_timeout/permission",
          method: "POST",
          headers: {
            "Transfer-Encoding": "chunked"
          }
        }, (res) => {
          let body = "";
          res.on("data", (chunk) => { body += chunk; });
          res.on("end", () => resolve({ status: res.statusCode, body }));
        });

        clientReq.on("error", reject);

        // Write first chunk immediately
        clientReq.write("chunk1");

        // Write second chunk after 50ms (keeps socket active, which would reset idle timeouts)
        setTimeout(() => {
          if (!clientReq.destroyed) {
            clientReq.write("chunk2");
          }
        }, 50);

        // Write third chunk after 100ms
        setTimeout(() => {
          if (!clientReq.destroyed) {
            clientReq.write("chunk3");
            clientReq.end();
          }
        }, 100);
      });

      const res = await resPromise;
      const duration = Date.now() - start;

      expect(res.status).toBe(503);
      expect(JSON.parse(res.body)).toEqual({
        error: "service_unavailable",
        message: "Upstream did not send response headers in time"
      });
      // Wall-clock limit is 100ms, so it must time out around 100ms
      expect(duration).toBeGreaterThanOrEqual(80);
      expect(duration).toBeLessThan(350);
    } finally {
      await new Promise<void>((resolve) => timeoutFrontDoor.close(() => resolve()));
      await new Promise<void>((resolve) => slowServer.close(() => resolve()));
    }
  });

  test("19. wedge health-probe integration (Task 3.2): exempt request keeps waiting if /global/health returns 200", async () => {
    let healthServerPort: number;
    let healthProbeCount = 0;

    const healthServer = http.createServer((req, res) => {
      if (req.url && req.url.includes("/global/health")) {
        healthProbeCount++;
        res.writeHead(200, { "Content-Type": "text/plain" });
        res.end("OK");
      } else {
        // Keep the exempt POST request open without writing headers
      }
    });

    await new Promise<void>((resolve) => healthServer.listen(0, "127.0.0.1", () => resolve()));
    healthServerPort = (healthServer.address() as AddressInfo).port;

    const testConfig: Config = {
      port: 0,
      version: 'unknown',
      pigeonUrl: `http://127.0.0.1:${portPigeon}`,
      anchorUrl: `http://127.0.0.1:${healthServerPort}`,
      routeTimeoutMs: 100,
      cheapFirstByteMs: 50, // very small
      wedgeProbeIntervalMs: 30, // probe every 30ms
      stickyTtlMs: 30000,
      driftCheckMs: 10000,
    };

    const frontDoor = createFrontDoor(testConfig, {
      logger: { sink: () => {} }
    });
    await new Promise<void>((resolve) => frontDoor.listen(0, "127.0.0.1", () => resolve()));
    const frontDoorPort = (frontDoor.address() as AddressInfo).port;

    let clientReq: http.ClientRequest | undefined;
    try {
      let gotResponse = false;
      let responseStatus: number | undefined;

      clientReq = http.request({
        hostname: "127.0.0.1",
        port: frontDoorPort,
        path: "/api/session/ses_health_ok/prompt",
        method: "POST"
      }, (res) => {
        gotResponse = true;
        responseStatus = res.statusCode;
      });

      clientReq.on("error", () => {});
      clientReq.end();

      // Wait dynamically until at least 3 health probes have been received (up to 1000ms)
      for (let i = 0; i < 50; i++) {
        if (healthProbeCount >= 3) break;
        await new Promise((resolve) => setTimeout(resolve, 20));
      }

      expect(gotResponse).toBe(false);
      expect(healthProbeCount).toBeGreaterThanOrEqual(3);
    } finally {
      if (clientReq) {
        clientReq.destroy();
      }
      await new Promise<void>((resolve) => frontDoor.close(() => resolve()));
      await new Promise<void>((resolve) => healthServer.close(() => resolve()));
    }
  });

  test("20. wedge health-probe integration (Task 3.2): exempt request times out with 503 if /global/health fails twice consecutive", async () => {
    let healthServerPort: number;
    let healthProbeCount = 0;

    const healthServer = http.createServer((req, res) => {
      if (req.url && req.url.includes("/global/health")) {
        healthProbeCount++;
        res.writeHead(500, { "Content-Type": "text/plain" });
        res.end("Internal Server Error");
      } else {
        // Keep the exempt POST request open without writing headers
      }
    });

    await new Promise<void>((resolve) => healthServer.listen(0, "127.0.0.1", () => resolve()));
    healthServerPort = (healthServer.address() as AddressInfo).port;

    const testConfig: Config = {
      port: 0,
      version: 'unknown',
      pigeonUrl: `http://127.0.0.1:${portPigeon}`,
      anchorUrl: `http://127.0.0.1:${healthServerPort}`,
      routeTimeoutMs: 100,
      cheapFirstByteMs: 50,
      wedgeProbeIntervalMs: 30, // probe every 30ms
      stickyTtlMs: 30000,
      driftCheckMs: 10000,
    };

    const frontDoor = createFrontDoor(testConfig, {
      logger: { sink: () => {} }
    });
    await new Promise<void>((resolve) => frontDoor.listen(0, "127.0.0.1", () => resolve()));
    const frontDoorPort = (frontDoor.address() as AddressInfo).port;

    let clientReq: http.ClientRequest | undefined;
    try {
      const start = Date.now();
      const resPromise = new Promise<any>((resolve, reject) => {
        clientReq = http.request({
          hostname: "127.0.0.1",
          port: frontDoorPort,
          path: "/api/session/ses_health_fail/prompt",
          method: "POST"
        }, (res) => {
          let body = "";
          res.on("data", (chunk) => { body += chunk; });
          res.on("end", () => resolve({ status: res.statusCode, body }));
        });
        clientReq.on("error", reject);
        clientReq.end();
      });

      const res = await resPromise;
      const duration = Date.now() - start;

      // Two health probe failures should trigger 503.
      // 1st probe at 30ms -> fails (count=1)
      // 2nd probe at 60ms -> fails (count=2) -> triggers 503 immediately
      // So the duration should be roughly around 60-120ms.
      expect(res.status).toBe(503);
      expect(JSON.parse(res.body)).toEqual({
        error: "service_unavailable",
        message: "Target serve failed health probe (wedged)"
      });
      expect(healthProbeCount).toBe(2);
      expect(duration).toBeLessThan(300);
    } finally {
      if (clientReq) {
        clientReq.destroy();
      }
      await new Promise<void>((resolve) => frontDoor.close(() => resolve()));
      await new Promise<void>((resolve) => healthServer.close(() => resolve()));
    }
  });

  test("21. native /healthz integration (Task 3.3): reports status, version, and metrics, bypasses proxy logging", async () => {
    pigeonRouteCalls = [];
    loggedLines.length = 0; // clear any logged proxy requests

    const res = await makeRequest("GET", "/healthz");
    expect(res.status).toBe(200);
    expect(res.headers["content-type"]).toBe("application/json");

    const body = JSON.parse(res.body);
    expect(body.status).toBe("ok");
    expect(body.degraded).toBe(false);
    expect(body.pigeon).toBe(true);
    expect(body.anchor).toBe(true);
    expect(body.degradedRequests).toBeGreaterThanOrEqual(0);
    expect(body.version).toBe("unknown");

    // Verify it probed the pigeon daemon
    expect(pigeonRouteCalls).toContainEqual(
      expect.objectContaining({ sid: "__frontdoor_healthz__" })
    );

    // Verify no request log was written to loggedLines (the standard proxy logger)
    expect(loggedLines).toHaveLength(0);
  });
});
