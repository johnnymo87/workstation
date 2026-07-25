import type { Config } from "./config.js";
import { boundedFetch, discardBody, stripTrailingSlashes } from "./http.js";

/**
 * A network error or timeout is a property of the ANCHOR, not of the session, so
 * it is worth remembering for a while. A 404 is different: it is the expected
 * transient answer while a just-minted subagent session's row becomes visible to
 * another process through the shared DB, and caching that for 30s would pin the
 * child's permission traffic to the wrong process for exactly the window this
 * whole change exists to fix. Keep the 404 window short.
 */
export const FAILURE_TTL_MS = 30_000;
export const NOT_FOUND_TTL_MS = 5_000;
export const MAX_CACHE_SIZE = 2000;

export type RootLookup =
  // `fetchedLive` = the root's 200 came from THIS call, so it is a fresh existence
  // proof. A cached hit proves only PARENTAGE (immutable); the session may since
  // have been deleted, so callers must not treat it as an existence check.
  | { root: string; confirmed: true; fetchedLive: boolean }
  | { confirmed: false };               // parentage unknown -> caller must treat as NON-PLACEABLE

type CacheEntry =
  | { kind: "success"; root: string }
  | { kind: "failure"; expiresAt: number };

const rootCache = new Map<string, CacheEntry>();

/** Internal seam: clears the process-wide root cache. Exposed for deterministic tests. */
export function clearRootCache(): void {
  rootCache.clear();
}

function setCacheEntry(key: string, entry: CacheEntry): void {
  // Max 2000 entries, FIFO insertion-order eviction (evict oldest first when exceeding the cap).
  // Map.set on an existing key does not refresh insertion order.
  if (!rootCache.has(key) && rootCache.size >= MAX_CACHE_SIZE) {
    const oldestKey = rootCache.keys().next().value;
    if (oldestKey !== undefined) {
      rootCache.delete(oldestKey);
    }
  }
  rootCache.set(key, entry);
}

export async function rootOf(
  sid: string,
  config: Config,
  deps?: { fetch?: typeof globalThis.fetch; now?: () => number },
): Promise<RootLookup> {
  const nowFn = deps?.now ?? Date.now;

  // Check initial cache
  const cached = rootCache.get(sid);
  if (cached) {
    if (cached.kind === "success") {
      return { root: cached.root, confirmed: true, fetchedLive: false };
    }
    if (nowFn() < cached.expiresAt) {
      return { confirmed: false };
    }
    rootCache.delete(sid);
  }

  const startTime = nowFn();
  const deadline = startTime + config.routeTimeoutMs;
  const anchorBase = stripTrailingSlashes(config.anchorUrl);

  const visitedChain: string[] = [];
  const visitedSet = new Set<string>();

  let currentSid = sid;
  let resolvedRoot: string | null = null;
  // Whether resolvedRoot was established by a live 200 in THIS walk (fresh
  // existence proof) rather than inherited from the parentage cache.
  let rootFetchedLive = false;
  let sawNotFound = false;

  while (visitedChain.length < 8) {
    if (visitedSet.has(currentSid)) {
      // Cycle detected
      break;
    }

    // Check intermediate cache
    const hopCached = rootCache.get(currentSid);
    if (hopCached) {
      if (hopCached.kind === "success") {
        resolvedRoot = hopCached.root;
        rootFetchedLive = false;
        break;
      }
      if (nowFn() < hopCached.expiresAt) {
        break;
      }
      rootCache.delete(currentSid);
    }

    const remainingMs = deadline - nowFn();
    if (remainingMs <= 0) {
      break;
    }

    visitedSet.add(currentSid);
    visitedChain.push(currentSid);

    const url = `${anchorBase}/session/${encodeURIComponent(currentSid)}`;
    const result = await boundedFetch(url, {
      method: "GET",
      timeoutMs: remainingMs,
      fetchImpl: deps?.fetch,
    });

    if (!result.ok || !result.response) {
      break;
    }

    const res = result.response;
    if (res.status !== 200) {
      discardBody(res);
      // A 404 is the "session not visible (yet)" answer and gets a short TTL;
      // any other status is treated like an anchor fault.
      if (res.status === 404) sawNotFound = true;
      break;
    }

    let body: unknown;
    try {
      body = await res.json();
    } catch {
      discardBody(res);
      break;
    }

    if (!body || typeof body !== "object" || Array.isArray(body)) {
      break;
    }

    const rawParent = (body as Record<string, unknown>).parentID;
    const parentID =
      typeof rawParent === "string" && rawParent.trim().length > 0
        ? rawParent.trim()
        : null;

    if (parentID === null) {
      // currentSid IS the root, and we just got a live 200 for it.
      resolvedRoot = currentSid;
      rootFetchedLive = true;
      break;
    }

    currentSid = parentID;
  }

  if (resolvedRoot !== null) {
    // Cache every sid visited during the walk as resolving to resolvedRoot
    for (const visitedSid of visitedChain) {
      setCacheEntry(visitedSid, { kind: "success", root: resolvedRoot });
    }
    return { root: resolvedRoot, confirmed: true, fetchedLive: rootFetchedLive };
  }

  // Failure: cache keyed by the queried sid only. Never stamp a failure over a
  // success a CONCURRENT walk just proved — parentage is immutable, so a known
  // root outranks this walk's transient fault.
  const existing = rootCache.get(sid);
  if (!existing || existing.kind !== "success") {
    setCacheEntry(sid, {
      kind: "failure",
      expiresAt: nowFn() + (sawNotFound ? NOT_FOUND_TTL_MS : FAILURE_TTL_MS),
    });
  }
  return { confirmed: false };
}
