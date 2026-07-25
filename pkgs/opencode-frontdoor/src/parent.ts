import type { Config } from "./config.js";
import { boundedFetch, discardBody, stripTrailingSlashes } from "./http.js";

export const FAILURE_TTL_MS = 30_000;
export const MAX_CACHE_SIZE = 2000;

export type RootLookup =
  | { root: string; confirmed: true }   // root identified AND confirmed to exist
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
      return { root: cached.root, confirmed: true };
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
      // currentSid IS the root!
      resolvedRoot = currentSid;
      break;
    }

    currentSid = parentID;
  }

  if (resolvedRoot !== null) {
    // Cache every sid visited during the walk as resolving to resolvedRoot
    for (const visitedSid of visitedChain) {
      setCacheEntry(visitedSid, { kind: "success", root: resolvedRoot });
    }
    return { root: resolvedRoot, confirmed: true };
  }

  // Failure: cache failure keyed by the queried sid only (with short TTL)
  setCacheEntry(sid, {
    kind: "failure",
    expiresAt: nowFn() + FAILURE_TTL_MS,
  });
  return { confirmed: false };
}
