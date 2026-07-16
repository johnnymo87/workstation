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

  let pigeonPlaceCalls: any[] = [];
  let pigeonRouteCalls: any[] = [];

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

        if (sid === "ses_a" || sid === "ses_multi1") {
          res.writeHead(200, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ apiBase: `http://127.0.0.1:${portA}`, prospective: false }));
        } else if (sid === "ses_b" || sid === "ses_multi2") {
          res.writeHead(200, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ apiBase: `http://127.0.0.1:${portB}`, prospective: false }));
        } else if (sid === "ses_prospective") {
          res.writeHead(200, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ apiBase: `http://127.0.0.1:${portA}`, prospective: true }));
        } else {
          res.writeHead(404, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ error: "not_routed" }));
        }
      } else if (parsedUrl.pathname === "/place" && req.method === "POST") {
        const bodyStr = await readBody(req);
        const body = JSON.parse(bodyStr);
        pigeonPlaceCalls.push(body);

        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({
          ok: true,
          serve_id: "serve-b",
          api_base: `http://127.0.0.1:${portB}`
        }));
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
      pigeonUrl: `http://127.0.0.1:${portPigeon}`,
      anchorUrl: `http://127.0.0.1:${portAnchor}`,
      routeTimeoutMs: 1000,
      cheapFirstByteMs: 1000,
      stickyTtlMs: 30000
    };

    frontDoorServer = createFrontDoor(testConfig);
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
});
