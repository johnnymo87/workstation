import type { Config } from "./config.js";
import { boundedFetch, stripTrailingSlashes, isAbsoluteHttpUrl, discardBody } from "./http.js";
import { rootOf } from "./parent.js";

export type ResolveReason =
  | "active"              // 200, valid lease
  | "prospective"         // 200, prospective:true (idle HRW guess)
  | "not-routed"          // 404 from pigeon
  | "pigeon-unreachable"  // network error or timeout
  | "pigeon-error";       // non-200/404 (400/500/503/malformed body/missing apiBase)

export interface ResolvedOwner {
  url: string;          // base URL to forward to RIGHT NOW
  prospective: boolean; // true only for the 200-prospective case
  degraded: boolean;    // true whenever we fell back to the anchor
  reason: ResolveReason;
  /** sid that pigeon lease ops (place / lease renewal) MUST use = ROOT of the
   *  session tree. null => parentage UNKNOWN => caller MUST NOT place. */
  routingSid: string | null;
  /** owner came from an ancestor's route (logging/metrics only) */
  viaParent?: boolean;
  /** routingSid was confirmed to exist by the parent walk (200 from the anchor),
   *  so maybePromote can skip its own checkSidExists */
  rootExists?: boolean;
}

// deps injected for testability; default to real fetch.
export interface ResolveDeps {
  fetch?: typeof globalThis.fetch;
  now?: () => number;
}

async function fetchRoute(
  sid: string,
  config: Config,
  deps?: ResolveDeps,
): Promise<ResolvedOwner> {
  // Strip trailing slashes so a configured PIGEON_DAEMON_URL like
  // "http://127.0.0.1:4731/" doesn't produce "…//route".
  const pigeonBase = stripTrailingSlashes(config.pigeonUrl);
  const targetUrl = `${pigeonBase}/route?session_id=${encodeURIComponent(sid)}`;

  const result = await boundedFetch(targetUrl, {
    method: "GET",
    timeoutMs: config.routeTimeoutMs,
    bearerToken: config.pigeonAuthToken,
    fetchImpl: deps?.fetch,
  });

  if (!result.ok) {
    return {
      url: config.anchorUrl,
      prospective: false,
      degraded: true,
      reason: "pigeon-unreachable",
      routingSid: sid,
    };
  }

  const response = result.response!;

  if (response.status === 404) {
    // Never read the body on this branch — release the socket (this is the
    // hottest path: one /route call per single-sid request + drift every 5s).
    discardBody(response);
    return {
      url: config.anchorUrl,
      prospective: false,
      degraded: true,
      reason: "not-routed",
      routingSid: sid,
    };
  }

  if (response.status !== 200) {
    discardBody(response);
    return {
      url: config.anchorUrl,
      prospective: false,
      degraded: true,
      reason: "pigeon-error",
      routingSid: sid,
    };
  }

  try {
    const data = (await response.json()) as any;
    const url = data?.apiBase ?? data?.api_base;
    if (!url || typeof url !== "string" || !isAbsoluteHttpUrl(url)) {
      // A missing base, or a base that isn't an absolute http(s) URL, would
      // crash the forwarder (Task 1.7) on proxy init. Degrade instead of
      // returning a live owner we can't actually forward to.
      return {
        url: config.anchorUrl,
        prospective: false,
        degraded: true,
        reason: "pigeon-error",
        routingSid: sid,
      };
    }

    const isProspective = !!data?.prospective;
    return {
      url,
      prospective: isProspective,
      degraded: false,
      reason: isProspective ? "prospective" : "active",
      routingSid: sid,
    };
  } catch (err) {
    return {
      url: config.anchorUrl,
      prospective: false,
      degraded: true,
      reason: "pigeon-error",
      routingSid: sid,
    };
  }
}

export async function resolveOwner(
  sid: string,
  config: Config,
  deps?: ResolveDeps,
): Promise<ResolvedOwner> {
  const first = await fetchRoute(sid, config, deps);
  if (first.reason !== "not-routed") return first;

  // 404 path:
  const lookup = await rootOf(sid, config, { fetch: deps?.fetch, now: deps?.now });
  if (!lookup.confirmed) {
    return {
      url: config.anchorUrl,
      prospective: false,
      degraded: true,
      reason: "not-routed",
      routingSid: null,
    };
  }

  if (lookup.root === sid) {
    return {
      url: config.anchorUrl,
      prospective: false,
      degraded: true,
      reason: "not-routed",
      routingSid: sid,
      // Only a live 200 in THIS walk is an existence proof; a cached hit proves
      // parentage only, and the session may since have been deleted.
      rootExists: lookup.fetchedLive,
    };
  }

  // genuine child:
  const viaRoot = await fetchRoute(lookup.root, config, deps);
  return {
    ...viaRoot,
    routingSid: lookup.root,
    rootExists: lookup.fetchedLive,
    viaParent: true,
  };
}
