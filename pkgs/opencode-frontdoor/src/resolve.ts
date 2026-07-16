import type { Config } from "./config.js";

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
}

// deps injected for testability; default to real fetch.
export interface ResolveDeps { fetch?: typeof globalThis.fetch; }

export async function resolveOwner(
  sid: string,
  config: Config,
  deps?: ResolveDeps,
): Promise<ResolvedOwner> {
  const fetchFn = deps?.fetch ?? globalThis.fetch;
  const targetUrl = `${config.pigeonUrl}/route?session_id=${encodeURIComponent(sid)}`;
  
  const headers: Record<string, string> = {};
  if (config.pigeonAuthToken) {
    headers["Authorization"] = `Bearer ${config.pigeonAuthToken}`;
  }

  const controller = new AbortController();
  const timeoutId = setTimeout(() => {
    controller.abort();
  }, config.routeTimeoutMs);

  let response: Response;
  try {
    response = await fetchFn(targetUrl, {
      method: "GET",
      signal: controller.signal,
      ...(config.pigeonAuthToken ? { headers } : {}),
    });
  } catch (err) {
    return {
      url: config.anchorUrl,
      prospective: false,
      degraded: true,
      reason: "pigeon-unreachable",
    };
  } finally {
    clearTimeout(timeoutId);
  }

  if (response.status === 404) {
    return {
      url: config.anchorUrl,
      prospective: false,
      degraded: true,
      reason: "not-routed",
    };
  }

  if (response.status !== 200) {
    return {
      url: config.anchorUrl,
      prospective: false,
      degraded: true,
      reason: "pigeon-error",
    };
  }

  try {
    const data = await response.json() as any;
    const url = data?.apiBase ?? data?.api_base;
    if (!url || typeof url !== "string") {
      return {
        url: config.anchorUrl,
        prospective: false,
        degraded: true,
        reason: "pigeon-error",
      };
    }

    const isProspective = !!data?.prospective;
    return {
      url,
      prospective: isProspective,
      degraded: false,
      reason: isProspective ? "prospective" : "active",
    };
  } catch (err) {
    return {
      url: config.anchorUrl,
      prospective: false,
      degraded: true,
      reason: "pigeon-error",
    };
  }
}
