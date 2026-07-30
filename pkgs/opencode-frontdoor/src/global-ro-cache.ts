import type { IncomingHttpHeaders } from "node:http";

/**
 * Single-flight coalescing (plus an OPTIONAL, default-off TTL) for a small
 * allowlist of `global-ro` routes.
 *
 * WHY THIS EXISTS
 * ---------------
 * Every session-less read is routed to the anchor by design, so one serve
 * fields all of them. On 2026-07-30 a burst of 33 TUI attaches produced 196
 * 503s at the door in a 7-second window; every one was class=global-ro,
 * target=anchor, durationMs pinned at the 5000ms cheap first-byte budget
 * (proxy.ts:148-156). The anchor sat at p50 904ms with 49% of requests over 1s
 * while a sibling serve was at 13ms p50 in the same minute -- the door was fine,
 * the anchor was saturated. See workstation-eon4 for the full forensics.
 *
 * The traffic was highly redundant: 554 global-ro requests over just 30 distinct
 * paths, and per path up to 17 were IN FLIGHT SIMULTANEOUSLY (/api/model and
 * /api/provider 42 requests each, max_in_flight 17). That is what makes
 * coalescing the right primitive: concurrent identical requests can share one
 * upstream call, collapsing ~42 calls per path to roughly one per wave, with NO
 * staleness window at all.
 *
 * WHY THE TTL DEFAULTS TO ZERO
 * ----------------------------
 * Coalescing alone captures the bulk of the win because the duplicates were
 * concurrent rather than merely nearby in time. A TTL buys only marginal further
 * reduction and costs real correctness: /config, /agent, /skill and /command all
 * derive from on-disk project config, so a stale read means a user edits a skill
 * file, reattaches, and is shown the old list. At the TTL boundary a client can
 * observe config up to ttlMs old; with ttlMs=0 that window does not exist and
 * every response a client sees was produced by an upstream call that was still
 * in flight when its own request arrived. Operators can raise it, but the
 * default is the zero-staleness behaviour the measurements support.
 */

/**
 * Routes eligible for coalescing. EXACT method+path only -- never a template,
 * never the whole `global-ro` class (61 routes carry that class; most must not
 * be shared).
 *
 * Sized to remain safe even with a TTL enabled, which is stricter than
 * coalescing alone requires. With ttlMs=0 correctness needs only same-instant
 * identity, so staticness would not matter; the allowlist is deliberately
 * conservative so that TURNING THE TTL ON cannot silently become unsafe.
 *
 * Every entry below was verified stable across repeated live reads.
 *
 * Deliberately EXCLUDED, and why:
 *   /api/health, /global/health   canaries depend on real per-request liveness;
 *                                 sharing a response could mask a failure
 *   /permission, /question,       PER-PROCESS in-memory reads (so flagged in
 *   /session/status,              routes.classification.ts); already semantically
 *   /api/permission/request,      questionable through the door, and sharing them
 *   /api/question/request         would deepen that
 *   /api/permission/saved         mutable user state
 *   /api/fs/*, /file*, /find*     filesystem + search state; changes constantly
 *   /vcs*                         git state; changes constantly, can be large
 *   /session, /api/session,       mutate as sessions are created -- exactly what
 *   /api/session/active,          a burst of attaches is doing
 *   /experimental/session
 *   /provider/auth                auth state
 *   templated paths               /api/provider/{providerID},
 *                                 /api/integration/{integrationID},
 *                                 /api/integration/attempt/{attemptID},
 *                                 /project/{projectID}/directories
 *   /lsp, /formatter, /doc,       staticness not established; left out rather
 *   /experimental/workspace*,     than guessed
 *   /experimental/worktree
 */
export const CACHEABLE_GLOBAL_RO: ReadonlySet<string> = new Set([
  "GET /config",
  "GET /config/providers",
  "GET /global/config",
  "GET /provider",
  "GET /agent",
  "GET /command",
  "GET /skill",
  "GET /path",
  "GET /project",
  "GET /project/current",
  "GET /experimental/capabilities",
  "GET /experimental/console",
  "GET /api/agent",
  "GET /api/command",
  "GET /api/skill",
  "GET /api/model",
  "GET /api/provider",
  "GET /api/integration",
  "GET /api/reference",
  "GET /api/location",
]);

/**
 * Headers that participate in the cache key.
 *
 * `x-opencode-directory` is the one that matters and the reason this list is not
 * empty. It was MEASURED to change the response body: on the live door, /config
 * with `x-opencode-directory: <pigeon>` returns the identical bytes to
 * `?directory=<pigeon>` and different bytes from the no-header form; /agent and
 * /api/location likewise. `opencode attach --dir <dir>` is exactly how these
 * TUIs are launched, and the incident traffic carried ZERO query strings on
 * global-ro (0 of 2283), so the HEADER is the channel in practice. Keying on
 * method+path+query alone would have served 33 TUIs in 33 different projects one
 * another's config, agents and skills -- strictly worse than the 503s this is
 * meant to prevent.
 *
 * `x-opencode-workspace` could not be shown to vary the response with the value
 * tried, but routes.dispositions.ts:191 documents that upstream `?workspace=`
 * OVERRIDES `?directory=` (middleware/workspace-routing.ts:154-157), so it is
 * included defensively. The asymmetry is deliberate and worth stating: including
 * a header that does not vary the response costs only hit rate, whereas omitting
 * one that does causes silent cross-project data bleed.
 *
 * `accept` / `accept-encoding` select the representation, so they must key.
 *
 * The remaining x-opencode-* headers the server binary knows -- ticket, title,
 * sync, session, request, project, client -- are deliberately NOT keyed. Each was
 * tested against /config and none varied the response, and they are per-request
 * metadata: `x-opencode-request` in particular is likely unique per request, and
 * keying on it would silently drive the hit rate to zero, producing a cache that
 * reports healthy while doing nothing. That choice is pinned by a test.
 */
export const KEY_HEADERS: readonly string[] = [
  "x-opencode-directory",
  "x-opencode-workspace",
  "accept",
  "accept-encoding",
];

export function isCacheableGlobalRo(method: string, pathname: string): boolean {
  const normalized = pathname.length > 1 ? pathname.replace(/\/+$/, "") : pathname;
  return CACHEABLE_GLOBAL_RO.has(`${method.toUpperCase()} ${normalized}`);
}

function headerValue(headers: IncomingHttpHeaders, name: string): string {
  const raw = headers[name];
  if (raw === undefined) return "";
  return Array.isArray(raw) ? raw.join(",") : String(raw);
}

/**
 * Build the cache key.
 *
 * `forwardedSearch` MUST be the search string the door will actually send
 * upstream (i.e. post `buildForwardSearch`, which strips `auth_token`), not the
 * raw client search. Two reasons, both load-bearing: the forwarded search is
 * what determines the upstream response, and keying on the raw search would
 * fragment the cache on a credential that is stripped before it ever reaches the
 * serve.
 */
export function buildCacheKey(
  method: string,
  pathname: string,
  forwardedSearch: string,
  headers: IncomingHttpHeaders
): string {
  const parts = [method.toUpperCase(), pathname, forwardedSearch];
  for (const h of KEY_HEADERS) {
    parts.push(`${h}=${headerValue(headers, h)}`);
  }
  // \u0000 cannot appear in a header value or a URL, so it is an unambiguous
  // separator -- no crafted value can forge a different key's encoding.
  return parts.join("\u0000");
}

export interface CachedResponse {
  status: number;
  headers: Record<string, string | string[]>;
  body: Buffer;
  /**
   * Set false by the fetcher to forbid RETENTION while still allowing
   * coalescing. Used for an html-poison body: it must be shared with waiters
   * already blocked on the same call (they would have got it anyway) but must
   * never be stored, or one stale-serve SPA fallback would become the cached
   * answer for the whole TTL.
   */
  cacheable?: boolean;
}

export type CacheOutcome = "miss" | "coalesced" | "fresh";

export interface GlobalRoCacheOptions {
  ttlMs: number;
  now: () => number;
  /**
   * Responses larger than this are passed through uncached. A cache that can be
   * grown without bound by an upstream response is a memory-exhaustion vector,
   * and the door is long-lived. The largest allowlisted response measured live
   * was /project at ~15KB, so the default leaves ample headroom.
   */
  maxBodyBytes: number;
}

interface StoredEntry {
  response: CachedResponse;
  storedAt: number;
}

export class GlobalRoCache {
  private readonly ttlMs: number;
  private readonly now: () => number;
  private readonly maxBodyBytes: number;
  private readonly fresh = new Map<string, StoredEntry>();
  private readonly inFlight = new Map<string, Promise<CachedResponse>>();

  constructor(opts: GlobalRoCacheOptions) {
    this.ttlMs = opts.ttlMs;
    this.now = opts.now;
    this.maxBodyBytes = opts.maxBodyBytes;
  }

  /**
   * Resolve `key`, issuing at most one concurrent `fetcher()` call per key.
   *
   * Ordering matters. A fresh entry is served first (only possible when
   * ttlMs > 0), then an already in-flight request is joined, and only then is a
   * new upstream call made. Joining an in-flight request is what makes this safe
   * with ttlMs=0: every waiter receives a response from a call that was still
   * outstanding when the waiter arrived, so nothing observes a stale world.
   *
   * A failed fetch is never stored and never leaves a poisoned in-flight entry:
   * the next caller retries. This matters because the failure being mitigated is
   * a timeout, and caching a timeout would convert a transient anchor stall into
   * a sticky outage.
   */
  async resolve(
    key: string,
    fetcher: () => Promise<CachedResponse>
  ): Promise<{ response: CachedResponse; outcome: CacheOutcome }> {
    if (this.ttlMs > 0) {
      const hit = this.fresh.get(key);
      if (hit && this.now() - hit.storedAt < this.ttlMs) {
        return { response: hit.response, outcome: "fresh" };
      }
      if (hit) this.fresh.delete(key);
    }

    const pending = this.inFlight.get(key);
    if (pending) {
      return { response: await pending, outcome: "coalesced" };
    }

    const promise = (async () => {
      const response = await fetcher();
      // Only 2xx is ever retained. Storing an error would let one bad moment on
      // the anchor become the answer every caller gets for the whole TTL --
      // precisely the sticky outage this is supposed to prevent. Non-2xx still
      // COALESCES (concurrent waiters share it), which is safe because they are
      // resolved from a call that was in flight at their own arrival.
      const cacheable =
        response.cacheable !== false && response.status >= 200 && response.status < 300;
      if (this.ttlMs > 0 && cacheable && response.body.byteLength <= this.maxBodyBytes) {
        this.fresh.set(key, { response, storedAt: this.now() });
      }
      return response;
    })();

    this.inFlight.set(key, promise);
    try {
      const response = await promise;
      return { response, outcome: "miss" };
    } finally {
      this.inFlight.delete(key);
    }
  }

  /** Test/introspection helper: number of entries currently held. */
  get size(): number {
    return this.fresh.size;
  }
}
