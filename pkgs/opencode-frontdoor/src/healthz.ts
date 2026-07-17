import type { ServerResponse } from "node:http";
import type { Config } from "./config.js";
import type { Metrics } from "./metrics.js";
import { boundedFetch, stripTrailingSlashes } from "./http.js";

export function isHealthzRequest(method: string, pathname: string): boolean {
  if (method !== "GET" && method !== "HEAD") {
    return false;
  }
  const normalized = pathname.replace(/\/+$/, "");
  return normalized === "/healthz";
}

export async function handleHealthz(
  res: ServerResponse,
  { config, deps, metrics }: { config: Config; deps?: any; metrics: Metrics }
): Promise<void> {
  const pigeonUrlClean = `${stripTrailingSlashes(config.pigeonUrl)}/route?session_id=__frontdoor_healthz__`;
  const anchorUrlClean = `${stripTrailingSlashes(config.anchorUrl)}/global/health`;

  const fetchImpl = deps?.fetch;

  const [pigeonRes, anchorRes] = await Promise.all([
    boundedFetch(pigeonUrlClean, {
      method: "GET",
      timeoutMs: config.routeTimeoutMs,
      bearerToken: config.pigeonAuthToken,
      fetchImpl,
    }),
    boundedFetch(anchorUrlClean, {
      method: "GET",
      timeoutMs: config.routeTimeoutMs,
      fetchImpl,
    }),
  ]);

  const pigeonReachable = pigeonRes.ok;
  const anchorReachable = anchorRes.ok && anchorRes.response?.status === 200;

  if (pigeonRes.response?.body) {
    pigeonRes.response.body.cancel().catch(() => {});
  }
  if (anchorRes.response?.body) {
    anchorRes.response.body.cancel().catch(() => {});
  }

  const healthy = pigeonReachable || anchorReachable;
  const statusCode = healthy ? 200 : 503;
  const degraded = healthy && !(pigeonReachable && anchorReachable);

  res.writeHead(statusCode, { "Content-Type": "application/json" });

  const method = res.req?.method || "GET";
  if (method === "HEAD") {
    res.end();
    return;
  }

  const body = {
    status: healthy ? "ok" : "unavailable",
    degraded,
    pigeon: pigeonReachable,
    anchor: anchorReachable,
    degradedRequests: metrics.degradedRequests,
    version: config.version,
  };

  res.end(JSON.stringify(body));
}
