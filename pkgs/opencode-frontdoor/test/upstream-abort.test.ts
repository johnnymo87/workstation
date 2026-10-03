// workstation-27r8: the door's cheap first-byte timeout used to DESTROY the
// upstream request. opencode memoizes per-directory state (InstanceState ->
// ScopedCache, infinite TTL) and runs its first lazy init INSIDE the first
// caller's request fiber. Destroying the socket interrupts that fiber with a
// ClientAbort annotation; ScopedCache stores the interrupted Exit and replays it
// to every later caller for that directory, and the HTTP layer maps it to a bare
// 499. One door timeout therefore wedged GET /config/providers for ~/Code on the
// anchor until the serve was restarted (2026-10-02, 2.5h+), and the TUI crashed
// on startup.
//
// The fake serve below reproduces exactly that memoization: the FIRST request for
// a directory starts a slow init; if that request's socket closes before the init
// finishes, the directory is poisoned and every later request gets 499 forever.
import { describe, expect, test, afterEach, vi } from "vitest";
import http from "node:http";
import type { AddressInfo } from "node:net";
import { createFrontDoor } from "../src/server.js";
import { resetPoolCursor } from "../src/proxy.js";
import type { Config } from "../src/config.js";
import { createMetrics, type Metrics } from "../src/metrics.js";

type InitState = { status: "pending" | "ok" | "poisoned"; waiters: Array<() => void> };

interface FakeServe {
  server: http.Server;
  url: string;
  hits: number;
  closesBeforeResponse: number;
  init: Map<string, InitState>;
}

function sleep(ms: number) {
  return new Promise((r) => setTimeout(r, ms));
}

/**
 * A serve that memoizes a slow per-directory init the way opencode v1.18.18 does.
 * `initMs` is how long the first request for a directory takes to initialize.
 */
async function startMemoizingServe(initMs: number): Promise<FakeServe> {
  const fake: FakeServe = { server: null as any, url: "", hits: 0, closesBeforeResponse: 0, init: new Map() };
  fake.server = http.createServer((req, res) => {
    fake.hits++;
    const url = new URL(req.url || "", "http://x");
    const dir = url.searchParams.get("directory") ?? "/";

    const respond = () => {
      const st = fake.init.get(dir)!;
      if (st.status === "poisoned") {
        // opencode: interrupt-only cause carrying ClientAbort -> empty 499.
        res.writeHead(499);
        res.end();
        return;
      }
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ providers: [], dir }));
    };

    let st = fake.init.get(dir);
    if (!st) {
      // First caller: run init in THIS request's "fiber".
      st = { status: "pending", waiters: [] };
      fake.init.set(dir, st);
      const state = st;
      const timer = setTimeout(() => {
        state.status = "ok";
        respond();
        for (const w of state.waiters.splice(0)) w();
      }, initMs);
      res.on("close", () => {
        if (!res.writableEnded && state.status === "pending") {
          // Client aborted mid-init: the interruption is memoized.
          fake.closesBeforeResponse++;
          clearTimeout(timer);
          state.status = "poisoned";
          for (const w of state.waiters.splice(0)) w();
        }
      });
      return;
    }
    if (st.status === "pending") {
      st.waiters.push(respond);
      return;
    }
    respond();
  });
  await new Promise<void>((r) => fake.server.listen(0, "127.0.0.1", () => r()));
  fake.url = `http://127.0.0.1:${(fake.server.address() as AddressInfo).port}`;
  return fake;
}

async function startStaticServe(status: number, body = "{}"): Promise<FakeServe> {
  const fake: FakeServe = { server: null as any, url: "", hits: 0, closesBeforeResponse: 0, init: new Map() };
  fake.server = http.createServer((_req, res) => {
    fake.hits++;
    if (status === 499) {
      res.writeHead(499);
      res.end();
      return;
    }
    res.writeHead(status, { "Content-Type": "application/json" });
    res.end(body);
  });
  await new Promise<void>((r) => fake.server.listen(0, "127.0.0.1", () => r()));
  fake.url = `http://127.0.0.1:${(fake.server.address() as AddressInfo).port}`;
  return fake;
}

function makeConfig(anchorUrl: string, poolUrls: string[], overrides: Partial<Config> = {}): Config {
  return {
    port: 0,
    version: "test",
    pigeonUrl: "http://127.0.0.1:9", // unused by global-ro routes
    anchorUrl,
    poolUrls,
    routeTimeoutMs: 1000,
    cheapFirstByteMs: 100,
    stickyTtlMs: 30000,
    driftCheckMs: 10000,
    wedgeProbeIntervalMs: 5000,
    mintTimeoutMs: 1000,
    logSampleN: 1,
    logSummaryIntervalMs: 300000,
    ...overrides,
  };
}

async function startDoor(config: Config, metrics: Metrics) {
  const door = createFrontDoor(config, { logger: { sink: () => {} }, metrics });
  await new Promise<void>((r) => door.listen(0, "127.0.0.1", () => r()));
  return { door, port: (door.address() as AddressInfo).port };
}

function get(port: number, path: string, opts: { abortAfterMs?: number } = {}): Promise<{ status: number; body: string } | "aborted"> {
  return new Promise((resolve, reject) => {
    const req = http.get({ hostname: "127.0.0.1", port, path, agent: false }, (res) => {
      let body = "";
      res.on("data", (c) => (body += c));
      res.on("end", () => resolve({ status: res.statusCode || 0, body }));
    });
    req.on("error", (err: any) => {
      if (opts.abortAfterMs !== undefined) resolve("aborted");
      else reject(err);
    });
    if (opts.abortAfterMs !== undefined) {
      setTimeout(() => req.destroy(), opts.abortAfterMs);
    }
  });
}

const PROVIDERS = "/config/providers?directory=%2FUsers%2Fx%2FCode";

const cleanups: Array<() => Promise<void> | void> = [];
afterEach(async () => {
  vi.restoreAllMocks();
  for (const c of cleanups.splice(0).reverse()) await c();
});

function closeServer(s: http.Server) {
  return new Promise<void>((r) => {
    s.closeAllConnections();
    s.close(() => r());
  });
}

describe("workstation-27r8: door must not poison a serve's memoized per-directory init", () => {
  test("slow first init -> door 503 -> later requests for the same directory succeed (not a permanent 499)", async () => {
    vi.spyOn(console, "warn").mockImplementation(() => {});
    const serve = await startMemoizingServe(300);
    cleanups.push(() => closeServer(serve.server));
    const metrics = createMetrics();
    const { door, port } = await startDoor(makeConfig(serve.url, [serve.url], { cheapFirstByteMs: 100 }), metrics);
    cleanups.push(() => closeServer(door));

    // 1. The incident's first request: init is slower than the door's budget.
    const first = await get(port, PROVIDERS);
    expect(first).not.toBe("aborted");
    expect((first as any).status).toBe(503);

    // 2. The door must NOT have aborted the upstream request mid-init.
    await sleep(400);
    expect(serve.closesBeforeResponse).toBe(0);
    expect(serve.init.get("/Users/x/Code")?.status).toBe("ok");

    // 3. Every later request (the TUI's retry, the next launch) must succeed.
    for (let i = 0; i < 3; i++) {
      const later = await get(port, PROVIDERS);
      expect(later).not.toBe("aborted");
      expect((later as any).status).toBe(200);
    }
    expect(metrics.upstreamAbandoned).toBe(1);
    expect(metrics.upstreamAbandonedKilled).toBe(0);
  });

  test("a client that hangs up mid-init does not poison the directory either", async () => {
    vi.spyOn(console, "warn").mockImplementation(() => {});
    const serve = await startMemoizingServe(250);
    cleanups.push(() => closeServer(serve.server));
    const metrics = createMetrics();
    // Budget comfortably above init, so only the CLIENT abort is in play.
    const { door, port } = await startDoor(makeConfig(serve.url, [serve.url], { cheapFirstByteMs: 2000 }), metrics);
    cleanups.push(() => closeServer(door));

    expect(await get(port, PROVIDERS, { abortAfterMs: 50 })).toBe("aborted");
    await sleep(350);
    expect(serve.closesBeforeResponse).toBe(0);

    const later = await get(port, PROVIDERS);
    expect((later as any).status).toBe(200);
  });

  test("after a client hang-up, a large late upstream body is drained, not left pinned on a dead response", async () => {
    vi.spyOn(console, "warn").mockImplementation(() => {});
    let finished = false;
    const big = Buffer.alloc(4 * 1024 * 1024, "x");
    const serve = http.createServer((_req, res) => {
      setTimeout(() => {
        res.writeHead(200, { "Content-Type": "application/json" });
        res.on("finish", () => (finished = true));
        res.end(big);
      }, 150);
    });
    await new Promise<void>((r) => serve.listen(0, "127.0.0.1", () => r()));
    cleanups.push(() => closeServer(serve));
    const url = `http://127.0.0.1:${(serve.address() as AddressInfo).port}`;
    const metrics = createMetrics();
    const { door, port } = await startDoor(makeConfig(url, [url], { cheapFirstByteMs: 2000 }), metrics);
    cleanups.push(() => closeServer(door));

    expect(await get(port, PROVIDERS, { abortAfterMs: 50 })).toBe("aborted");
    await sleep(700);
    expect(metrics.upstreamAbandoned).toBe(1);
    expect(finished).toBe(true);
  });

  test("detaching is capped: past the cap, abandoned GETs are destroyed as before", async () => {
    vi.spyOn(console, "warn").mockImplementation(() => {});
    const serve = await startMemoizingServe(10_000);
    cleanups.push(() => closeServer(serve.server));
    const metrics = createMetrics();
    const { door, port } = await startDoor(
      makeConfig(serve.url, [serve.url], { cheapFirstByteMs: 50, abandonedUpstreamMaxConcurrent: 2 }),
      metrics
    );
    cleanups.push(() => closeServer(door));

    // Three distinct directories so each is its own first-caller init.
    await Promise.all([1, 2, 3].map((i) => get(port, `/config/providers?directory=%2Fd${i}`)));
    await sleep(100);
    expect(metrics.upstreamAbandoned).toBe(2);
    expect(metrics.upstreamAbandonedKilled).toBe(1);
    expect(serve.closesBeforeResponse).toBe(1);
  });

  test("an abandoned upstream is still torn down at the abandon ceiling (bounded, not leaked)", async () => {
    vi.spyOn(console, "warn").mockImplementation(() => {});
    const serve = await startMemoizingServe(10_000); // never finishes within the test
    cleanups.push(() => closeServer(serve.server));
    const metrics = createMetrics();
    const { door, port } = await startDoor(
      makeConfig(serve.url, [serve.url], { cheapFirstByteMs: 50, abandonedUpstreamMaxMs: 200 }),
      metrics
    );
    cleanups.push(() => closeServer(door));

    const first = await get(port, PROVIDERS);
    expect((first as any).status).toBe(503);
    await sleep(80);
    expect(serve.closesBeforeResponse).toBe(0); // still detached, not destroyed
    await sleep(250);
    expect(serve.closesBeforeResponse).toBe(1); // ceiling fired
    expect(metrics.upstreamAbandonedKilled).toBe(1);
  });

  test("non-GET requests keep the old destroy-on-timeout behaviour", async () => {
    vi.spyOn(console, "warn").mockImplementation(() => {});
    let closed = 0;
    const serve = http.createServer((req, res) => {
      req.resume();
      res.on("close", () => {
        if (!res.writableEnded) closed++;
      });
    });
    await new Promise<void>((r) => serve.listen(0, "127.0.0.1", () => r()));
    cleanups.push(() => closeServer(serve));
    const url = `http://127.0.0.1:${(serve.address() as AddressInfo).port}`;
    // A mutating session request needs a live pigeon, or the door 503s it before
    // ever forwarding (FABLE-S2). Route every sid to the serve.
    const pigeon = http.createServer((_req, res) => {
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ apiBase: url }));
    });
    await new Promise<void>((r) => pigeon.listen(0, "127.0.0.1", () => r()));
    cleanups.push(() => closeServer(pigeon));
    const pigeonUrl = `http://127.0.0.1:${(pigeon.address() as AddressInfo).port}`;
    const metrics = createMetrics();
    const { door, port } = await startDoor(makeConfig(url, [url], { cheapFirstByteMs: 50, pigeonUrl }), metrics);
    cleanups.push(() => closeServer(door));

    const res = await new Promise<{ status: number }>((resolve, reject) => {
      const r = http.request(
        { hostname: "127.0.0.1", port, path: "/api/session/ses_timeout/permission", method: "POST", agent: false },
        (resp) => {
          resp.resume();
          resp.on("end", () => resolve({ status: resp.statusCode || 0 }));
        }
      );
      r.on("error", reject);
      r.end("{}");
    });
    expect(res.status).toBe(503);
    await sleep(100);
    expect(closed).toBe(1);
    expect(metrics.upstreamAbandoned).toBe(0);
  });
});

describe("workstation-27r8: an upstream 499 through the door is always spurious", () => {
  test("forward-anchor: a replayed 499 becomes an explanatory 503, counted and logged", async () => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    const serve = await startStaticServe(499);
    cleanups.push(() => closeServer(serve.server));
    const metrics = createMetrics();
    const { door, port } = await startDoor(makeConfig(serve.url, [serve.url]), metrics);
    cleanups.push(() => closeServer(door));

    const res = await get(port, PROVIDERS);
    expect((res as any).status).toBe(503);
    const body = JSON.parse((res as any).body);
    expect(body.error).toBe("service_unavailable");
    expect(body.message).toMatch(/499/);
    // Opacity: the client-visible body must not name the serve.
    expect((res as any).body).not.toContain(serve.url);
    expect(metrics.upstreamSpurious499).toBe(1);
    // The operator log DOES name it, so the poisoned member is findable.
    expect(warn.mock.calls.some((c) => String(c[0]).includes("499") && String(c[0]).includes(serve.url))).toBe(true);
  });

  test("forward-pool: a member answering 499 is failed over to the next member", async () => {
    vi.spyOn(console, "warn").mockImplementation(() => {});
    const poisoned = await startStaticServe(499);
    const healthy = await startStaticServe(200, JSON.stringify({ ok: true }));
    cleanups.push(() => closeServer(poisoned.server));
    cleanups.push(() => closeServer(healthy.server));
    const metrics = createMetrics();
    // Anchor = healthy so it is tried last; cursor 0 selects the poisoned member first.
    const { door, port } = await startDoor(makeConfig(healthy.url, [poisoned.url, healthy.url]), metrics);
    cleanups.push(() => closeServer(door));
    resetPoolCursor();

    const res = await get(port, "/api/provider?directory=%2FUsers%2Fx%2FCode");
    expect((res as any).status).toBe(200);
    expect(poisoned.hits).toBe(1);
    expect(healthy.hits).toBe(1);
    expect(metrics.upstreamSpurious499).toBe(1);
  });

  test("forward-pool: when the last member also answers 499 the client gets the 503, never a bare 499", async () => {
    vi.spyOn(console, "warn").mockImplementation(() => {});
    const a = await startStaticServe(499);
    const b = await startStaticServe(499);
    cleanups.push(() => closeServer(a.server));
    cleanups.push(() => closeServer(b.server));
    const metrics = createMetrics();
    const { door, port } = await startDoor(makeConfig(b.url, [a.url, b.url]), metrics);
    cleanups.push(() => closeServer(door));
    resetPoolCursor();

    const res = await get(port, "/api/provider");
    expect((res as any).status).toBe(503);
    expect(metrics.upstreamSpurious499).toBe(2);
  });
});
