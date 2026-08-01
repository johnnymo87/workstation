import type { ServerResponse } from "node:http";
import type { Config } from "./config.js";
import type { Metrics } from "./metrics.js";
import { boundedFetch, boundedPigeonFetch, stripTrailingSlashes, discardBody } from "./http.js";

export function isHealthzRequest(method: string, pathname: string): boolean {
  if (method !== "GET" && method !== "HEAD") {
    return false;
  }
  const normalized = pathname.replace(/\/+$/, "");
  return normalized === "/healthz";
}

export async function handleHealthz(
  res: ServerResponse,
  { config, method, deps, metrics }: { config: Config; method: string; deps?: any; metrics: Metrics }
): Promise<void> {
  const pigeonUrlClean = `${stripTrailingSlashes(config.pigeonUrl)}/route?session_id=__frontdoor_healthz__`;
  const anchorUrlClean = `${stripTrailingSlashes(config.anchorUrl)}/global/health`;

  const fetchImpl = deps?.fetch;
  const tokenFilePath = deps?.tokenFilePath;

  const [pigeonRes, anchorRes] = await Promise.all([
    boundedPigeonFetch(pigeonUrlClean, {
      method: "GET",
      timeoutMs: config.routeTimeoutMs,
      bearerToken: config.pigeonAuthToken,
      fetchImpl,
      tokenFilePath,
    }),
    // /global/health is planned to stay anonymous on serves, so it does not strictly
    // need the credential — but send serveAuthHeader anyway: it is ignored by an
    // anonymous route and keeps the probe working if that exemption ever changes.
    boundedFetch(anchorUrlClean, {
      method: "GET",
      timeoutMs: config.routeTimeoutMs,
      headers: config.serveAuthHeader ? { Authorization: config.serveAuthHeader } : undefined,
      fetchImpl,
    }),
  ]);

  const pigeonReachable = pigeonRes.ok;
  const anchorReachable = anchorRes.ok && anchorRes.response?.status === 200;

  discardBody(pigeonRes.response);
  discardBody(anchorRes.response);

  const healthy = pigeonReachable || anchorReachable;
  const statusCode = healthy ? 200 : 503;
  const degraded = healthy && !(pigeonReachable && anchorReachable);

  res.writeHead(statusCode, { "Content-Type": "application/json" });

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
    notRoutedMutationToAnchor: metrics.notRoutedMutationToAnchor,
    // Every counter in Metrics MUST be exposed here. /healthz is the only reader of
    // metrics that exists; a counter incremented in proxy.ts and absent from this
    // object is write-only, i.e. unobservable. htmlPoisonBlocked shipped that way in
    // the m3z2 deploy and the post-deploy check "htmlPoisonBlocked present and 0"
    // was therefore vacuous by construction. Same lesson as the drift canary: the
    // gap is never detection, it is delivery.
    htmlPoisonBlocked: metrics.htmlPoisonBlocked,
    poolFailover: metrics.poolFailover,
    version: config.version,
  };

  res.end(JSON.stringify(body));
}
