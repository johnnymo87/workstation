import { describe, it, expect } from "vitest";
import {
  CACHEABLE_GLOBAL_RO,
  KEY_HEADERS,
  isCacheableGlobalRo,
  buildCacheKey,
  GlobalRoCache,
  type CachedResponse,
} from "../src/global-ro-cache.js";
import { ROUTE_CLASSIFICATION_TABLE } from "../src/routes.classification.js";

function resp(body: string, status = 200): CachedResponse {
  return { status, headers: { "content-type": "application/json" }, body: Buffer.from(body) };
}

function makeCache(ttlMs: number, nowRef: { t: number }, maxBodyBytes = 1_000_000) {
  return new GlobalRoCache({ ttlMs, now: () => nowRef.t, maxBodyBytes });
}

describe("allowlist", () => {
  it("matches the routes that actually caused the incident", () => {
    // The 503 paths from 2026-07-30 14:06 UTC.
    for (const p of [
      "/api/location", "/api/agent", "/api/integration", "/api/model",
      "/api/provider", "/api/reference", "/api/command", "/api/skill",
      "/config/providers", "/provider", "/path", "/project/current",
      "/experimental/capabilities", "/experimental/console", "/agent", "/config",
    ]) {
      expect(isCacheableGlobalRo("GET", p), `${p} should be cacheable`).toBe(true);
    }
  });

  it("NEVER caches health -- canaries depend on real per-request liveness", () => {
    expect(isCacheableGlobalRo("GET", "/global/health")).toBe(false);
    expect(isCacheableGlobalRo("GET", "/api/health")).toBe(false);
  });

  it("NEVER caches the per-process in-memory reads", () => {
    for (const p of [
      "/permission", "/question", "/session/status",
      "/api/permission/request", "/api/question/request", "/api/permission/saved",
    ]) {
      expect(isCacheableGlobalRo("GET", p), `${p} must be excluded`).toBe(false);
    }
  });

  it("NEVER caches filesystem, search, vcs or session-list state", () => {
    for (const p of [
      "/api/fs/find", "/api/fs/list", "/api/fs/read/x",
      "/file", "/file/content", "/file/status",
      "/find", "/find/file", "/find/symbol",
      "/vcs", "/vcs/diff", "/vcs/diff/raw", "/vcs/status",
      "/session", "/api/session", "/api/session/active", "/experimental/session",
      "/provider/auth",
    ]) {
      expect(isCacheableGlobalRo("GET", p), `${p} must be excluded`).toBe(false);
    }
  });

  it("is a strict subset of class global-ro, and contains no templated paths", () => {
    const globalRo = new Set(
      ROUTE_CLASSIFICATION_TABLE
        .filter((r: any) => r.class === "global-ro")
        .map((r: any) => `${r.method} ${r.path}`)
    );
    for (const entry of CACHEABLE_GLOBAL_RO) {
      expect(globalRo.has(entry), `${entry} must be a real global-ro route`).toBe(true);
      expect(entry).not.toContain("{");
      expect(entry).not.toContain("*");
    }
    // Guard against someone "helpfully" widening this to the whole class.
    expect(CACHEABLE_GLOBAL_RO.size).toBeLessThan(globalRo.size);
  });

  it("only ever caches GET", () => {
    for (const entry of CACHEABLE_GLOBAL_RO) expect(entry.startsWith("GET ")).toBe(true);
    expect(isCacheableGlobalRo("POST", "/config")).toBe(false);
    expect(isCacheableGlobalRo("DELETE", "/config")).toBe(false);
  });

  it("normalises a trailing slash so /config/ cannot bypass the allowlist check", () => {
    expect(isCacheableGlobalRo("GET", "/config/")).toBe(true);
    expect(isCacheableGlobalRo("get", "/config")).toBe(true);
  });
});

describe("cache key isolation", () => {
  const H = (extra: Record<string, string> = {}) => ({ accept: "application/json", ...extra });

  it("SEPARATES requests differing only by x-opencode-directory", () => {
    // The whole reason KEY_HEADERS exists. Measured live: /config returns
    // different bytes per directory, and the TUIs pass it as a HEADER.
    const a = buildCacheKey("GET", "/config", "", H({ "x-opencode-directory": "/home/dev/projects/workstation" }));
    const b = buildCacheKey("GET", "/config", "", H({ "x-opencode-directory": "/home/dev/projects/pigeon" }));
    expect(a).not.toBe(b);
  });

  it("SEPARATES a directory-bearing request from one with no directory at all", () => {
    const a = buildCacheKey("GET", "/config", "", H({ "x-opencode-directory": "/home/dev/projects/pigeon" }));
    const b = buildCacheKey("GET", "/config", "", H());
    expect(a).not.toBe(b);
  });

  it("SEPARATES requests differing only by x-opencode-workspace", () => {
    const a = buildCacheKey("GET", "/config", "", H({ "x-opencode-workspace": "ws-1" }));
    const b = buildCacheKey("GET", "/config", "", H({ "x-opencode-workspace": "ws-2" }));
    expect(a).not.toBe(b);
  });

  it("SEPARATES requests differing only by forwarded query", () => {
    const a = buildCacheKey("GET", "/config", "?directory=/a", H());
    const b = buildCacheKey("GET", "/config", "?directory=/b", H());
    expect(a).not.toBe(b);
  });

  it("SEPARATES requests differing only by accept-encoding (different representation)", () => {
    const a = buildCacheKey("GET", "/config", "", H({ "accept-encoding": "gzip" }));
    const b = buildCacheKey("GET", "/config", "", H({ "accept-encoding": "identity" }));
    expect(a).not.toBe(b);
  });

  it("SHARES requests differing only by per-request metadata headers", () => {
    // Deliberate. x-opencode-request is likely unique per request; keying on it
    // would drive the hit rate to zero and yield a cache that does nothing while
    // looking healthy. None of these varied the response when tested live.
    const a = buildCacheKey("GET", "/config", "", H({ "x-opencode-request": "req-1", "x-opencode-ticket": "t1" }));
    const b = buildCacheKey("GET", "/config", "", H({ "x-opencode-request": "req-2", "x-opencode-ticket": "t2" }));
    expect(a).toBe(b);
  });

  it("keys every header in KEY_HEADERS", () => {
    for (const h of KEY_HEADERS) {
      const a = buildCacheKey("GET", "/config", "", { [h]: "one" });
      const b = buildCacheKey("GET", "/config", "", { [h]: "two" });
      expect(a, `${h} must participate in the key`).not.toBe(b);
    }
  });

  it("cannot be forged by a crafted header value that mimics the separator", () => {
    const a = buildCacheKey("GET", "/config", "", { "x-opencode-directory": "/a=x&accept=y" });
    const b = buildCacheKey("GET", "/config", "", { "x-opencode-directory": "/a", accept: "y" });
    expect(a).not.toBe(b);
  });

  it("treats a repeated header the same as its joined value, not as absent", () => {
    const a = buildCacheKey("GET", "/config", "", { "x-opencode-directory": ["/a", "/b"] as any });
    const b = buildCacheKey("GET", "/config", "", { "x-opencode-directory": "/a,/b" });
    const absent = buildCacheKey("GET", "/config", "", {});
    expect(a).toBe(b);
    expect(a).not.toBe(absent);
  });

  it("separates different paths and methods", () => {
    expect(buildCacheKey("GET", "/config", "", {})).not.toBe(buildCacheKey("GET", "/agent", "", {}));
    expect(buildCacheKey("GET", "/config", "", {})).not.toBe(buildCacheKey("HEAD", "/config", "", {}));
  });
});

describe("single-flight coalescing (the ttlMs=0 default)", () => {
  it("collapses concurrent identical requests to ONE upstream call", async () => {
    const now = { t: 1000 };
    const cache = makeCache(0, now);
    let calls = 0;
    let release!: () => void;
    const gate = new Promise<void>((r) => { release = r; });
    const fetcher = async () => { calls++; await gate; return resp('{"ok":true}'); };

    // 17 was the measured peak in-flight count per path during the incident.
    const inflight = Array.from({ length: 17 }, () => cache.resolve("k", fetcher));
    await Promise.resolve();
    release();
    const results = await Promise.all(inflight);

    expect(calls).toBe(1);
    expect(results.every((r) => r.response.body.toString() === '{"ok":true}')).toBe(true);
    expect(results.filter((r) => r.outcome === "miss")).toHaveLength(1);
    expect(results.filter((r) => r.outcome === "coalesced")).toHaveLength(16);
  });

  it("does NOT coalesce across different keys", async () => {
    const now = { t: 1000 };
    const cache = makeCache(0, now);
    let calls = 0;
    const fetcher = async () => { calls++; return resp("x"); };
    await Promise.all([cache.resolve("a", fetcher), cache.resolve("b", fetcher)]);
    expect(calls).toBe(2);
  });

  it("introduces NO staleness: sequential requests each hit upstream", async () => {
    const now = { t: 1000 };
    const cache = makeCache(0, now);
    let calls = 0;
    const fetcher = async () => { calls++; return resp(`call-${calls}`); };

    const a = await cache.resolve("k", fetcher);
    const b = await cache.resolve("k", fetcher);

    expect(calls).toBe(2);
    expect(a.response.body.toString()).toBe("call-1");
    expect(b.response.body.toString()).toBe("call-2");
    expect(cache.size).toBe(0); // nothing retained at all
  });
});

describe("optional TTL (opt-in)", () => {
  it("serves a fresh entry without an upstream call", async () => {
    const now = { t: 1000 };
    const cache = makeCache(3000, now);
    let calls = 0;
    const fetcher = async () => { calls++; return resp(`call-${calls}`); };

    await cache.resolve("k", fetcher);
    now.t += 2999;
    const second = await cache.resolve("k", fetcher);

    expect(calls).toBe(1);
    expect(second.outcome).toBe("fresh");
    expect(second.response.body.toString()).toBe("call-1");
  });

  it("refetches once the TTL boundary is crossed", async () => {
    const now = { t: 1000 };
    const cache = makeCache(3000, now);
    let calls = 0;
    const fetcher = async () => { calls++; return resp(`call-${calls}`); };

    await cache.resolve("k", fetcher);
    now.t += 3000; // exactly at the boundary -> expired
    const second = await cache.resolve("k", fetcher);

    expect(calls).toBe(2);
    expect(second.response.body.toString()).toBe("call-2");
  });

  it("does not retain a response larger than maxBodyBytes", async () => {
    const now = { t: 1000 };
    const cache = makeCache(3000, now, 8);
    const fetcher = async () => resp("way longer than eight bytes");
    await cache.resolve("k", fetcher);
    expect(cache.size).toBe(0);
  });
});

describe("failure handling", () => {
  it("never caches a failure and leaves no poisoned in-flight entry", async () => {
    // The failure being mitigated is a timeout. Caching one would turn a
    // transient anchor stall into a sticky outage.
    const now = { t: 1000 };
    const cache = makeCache(5000, now);
    let calls = 0;
    const fetcher = async () => {
      calls++;
      if (calls === 1) throw new Error("upstream timeout");
      return resp("recovered");
    };

    await expect(cache.resolve("k", fetcher)).rejects.toThrow("upstream timeout");
    expect(cache.size).toBe(0);

    const second = await cache.resolve("k", fetcher);
    expect(second.response.body.toString()).toBe("recovered");
    expect(calls).toBe(2);
  });

  it("propagates one rejection to every coalesced waiter", async () => {
    const now = { t: 1000 };
    const cache = makeCache(0, now);
    let calls = 0;
    const fetcher = async () => { calls++; throw new Error("boom"); };
    const rs = await Promise.allSettled([
      cache.resolve("k", fetcher), cache.resolve("k", fetcher), cache.resolve("k", fetcher),
    ]);
    expect(calls).toBe(1);
    expect(rs.every((r) => r.status === "rejected")).toBe(true);
  });

  it("NEVER retains a non-2xx response, even with a TTL enabled", async () => {
    // A 503 body must not become the cached answer for a healthy route: that
    // would turn one bad moment on the anchor into a sticky outage.
    const now = { t: 1000 };
    const cache = makeCache(5000, now);
    let calls = 0;
    const fetcher = async () => { calls++; return calls === 1 ? resp("nope", 503) : resp("good", 200); };

    const first = await cache.resolve("k", fetcher);
    expect(first.response.status).toBe(503);
    expect(cache.size).toBe(0);

    const second = await cache.resolve("k", fetcher);
    expect(second.response.status).toBe(200);
    expect(second.outcome).toBe("miss");
    expect(cache.size).toBe(1);
  });

  it("still COALESCES a non-2xx among concurrent waiters", async () => {
    const now = { t: 1000 };
    const cache = makeCache(5000, now);
    let calls = 0;
    let release!: () => void;
    const gate = new Promise<void>((r) => { release = r; });
    const fetcher = async () => { calls++; await gate; return resp("nope", 503); };
    const inflight = [cache.resolve("k", fetcher), cache.resolve("k", fetcher)];
    await Promise.resolve();
    release();
    const rs = await Promise.all(inflight);
    expect(calls).toBe(1);
    expect(rs.every((r) => r.response.status === 503)).toBe(true);
    expect(cache.size).toBe(0);
  });
});

describe("retention veto", () => {
  it("honours cacheable:false -- shares with waiters but never retains", async () => {
    // The html-poison case: a stale serve's SPA fallback must not become the
    // cached answer for the whole TTL.
    const now = { t: 1000 };
    const cache = makeCache(5000, now);
    let calls = 0;
    let release!: () => void;
    const gate = new Promise<void>((r) => { release = r; });
    const fetcher = async () => {
      calls++; await gate;
      return { status: 200, headers: { "content-type": "text/html" }, body: Buffer.from("<html>"), cacheable: false };
    };

    const inflight = [cache.resolve("k", fetcher), cache.resolve("k", fetcher)];
    await Promise.resolve();
    release();
    const rs = await Promise.all(inflight);

    expect(calls).toBe(1);                       // still coalesced
    expect(rs.every((r) => r.response.body.toString() === "<html>")).toBe(true);
    expect(cache.size).toBe(0);                  // but never retained
  });
});
