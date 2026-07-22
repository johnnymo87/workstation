import type { Config } from "./config.js";
import { boundedFetch, stripTrailingSlashes, discardBody } from "./http.js";

export async function probeServeHealth(
  target: string,
  config: Config,
  deps?: { fetch?: typeof fetch },
): Promise<boolean> {
  const url = `${stripTrailingSlashes(target)}/global/health`;
  const result = await boundedFetch(url, {
    method: "GET",
    timeoutMs: config.routeTimeoutMs,
    fetchImpl: deps?.fetch,
  });

  // We only care about liveness (status), never the payload. Release the
  // socket back to the pool immediately — an unconsumed undici body pins the
  // connection until GC. (status/ok stay readable after discarding the body stream.)
  discardBody(result.response);

  return result.ok && result.response?.status === 200;
}
