export interface BoundedFetchOptions {
  method: string;
  timeoutMs: number;
  headers?: Record<string, string>;
  body?: string;                       // JSON string body for POST /place; omit for GETs
  bearerToken?: string;                // adds Authorization: Bearer <token> when set
  fetchImpl?: typeof globalThis.fetch; // injectable for tests; default globalThis.fetch
}

export interface BoundedFetchResult {
  ok: boolean;            // network/timeout success (a Response was received); NOT the HTTP status
  timedOut: boolean;      // aborted by the timeout
  networkError: boolean;  // fetch threw for another reason
  response?: Response;    // present iff a Response came back
}

export function stripTrailingSlashes(base: string): string {
  return base.replace(/\/+$/, "");
}

// Never throws. Always clears the timer. Bounds via AbortController+timeoutMs.
export async function boundedFetch(
  url: string,
  opts: BoundedFetchOptions,
): Promise<BoundedFetchResult> {
  const fetchFn = opts.fetchImpl ?? globalThis.fetch;

  const headers: Record<string, string> = { ...(opts.headers ?? {}) };
  if (opts.bearerToken) {
    headers["Authorization"] = `Bearer ${opts.bearerToken}`;
  }

  const controller = new AbortController();
  const timeoutId = setTimeout(() => {
    controller.abort();
  }, opts.timeoutMs);

  try {
    const response = await fetchFn(url, {
      method: opts.method,
      headers,
      body: opts.body,
      signal: controller.signal,
    });

    return {
      ok: true,
      timedOut: false,
      networkError: false,
      response,
    };
  } catch (err: any) {
    const isTimeout =
      err?.name === "AbortError" ||
      controller.signal.aborted;

    return {
      ok: false,
      timedOut: isTimeout,
      networkError: !isTimeout,
    };
  } finally {
    clearTimeout(timeoutId);
  }
}
