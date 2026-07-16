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

function isAbsoluteHttpUrl(value: string): boolean {
  try {
    const parsed = new URL(value);
    return parsed.protocol === "http:" || parsed.protocol === "https:";
  } catch {
    return false;
  }
}

export async function resolveOwner(
  sid: string,
  config: Config,
  deps?: ResolveDeps,
): Promise<ResolvedOwner> {
  const fetchFn = deps?.fetch ?? globalThis.fetch;
  // Strip trailing slashes so a configured PIGEON_DAEMON_URL like
  // "http://127.0.0.1:4731/" doesn't produce "…//route".
  const pigeonBase = config.pigeonUrl.replace(/\/+$/, "");
  const targetUrl = `${pigeonBase}/route?session_id=${encodeURIComponent(sid)}`;

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
      headers,
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
    if (!url || typeof url !== "string" || !isAbsoluteHttpUrl(url)) {
      // A missing base, or a base that isn't an absolute http(s) URL, would
      // crash the forwarder (Task 1.7) on proxy init. Degrade instead of
      // returning a live owner we can't actually forward to.
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
