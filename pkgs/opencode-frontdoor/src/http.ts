import * as fs from "node:fs";

export interface BoundedFetchOptions {
  method: string;
  timeoutMs: number;
  headers?: Record<string, string>;
  body?: string;                       // JSON string body for POST /place; omit for GETs
  bearerToken?: string;                // adds Authorization: Bearer <token> when set
  fetchImpl?: typeof globalThis.fetch; // injectable for tests; default globalThis.fetch
}

export interface BoundedPigeonFetchOptions extends BoundedFetchOptions {
  tokenFilePath?: string;
}

let cachedToken: string | undefined | null = null;

/**
 * Resolve pigeon daemon bearer token at call time using contract:
 * 1. process.env.PIGEON_DAEMON_AUTH_TOKEN (trimmed)
 * 2. secret file (e.g. /run/secrets/pigeon_daemon_auth_token or process.env.PIGEON_DAEMON_AUTH_TOKEN_FILE) (trimmed)
 * 3. undefined
 *
 * Lazily caches resolved value until invalidateDaemonToken() is called.
 */
export function resolveDaemonToken(opts?: {
  forceRefresh?: boolean;
  tokenFilePath?: string;
}): string | undefined {
  if (opts?.forceRefresh) {
    cachedToken = null;
  }

  if (cachedToken !== null) {
    return cachedToken;
  }

  // 1. process.env.PIGEON_DAEMON_AUTH_TOKEN
  const envToken = process.env.PIGEON_DAEMON_AUTH_TOKEN?.trim();
  if (envToken) {
    cachedToken = envToken;
    return cachedToken;
  }

  // 2. Secret file
  const filePath =
    opts?.tokenFilePath ??
    process.env.PIGEON_DAEMON_AUTH_TOKEN_FILE ??
    "/run/secrets/pigeon_daemon_auth_token";

  try {
    if (fs.existsSync(filePath)) {
      const fileContent = fs.readFileSync(filePath, "utf8").trim();
      if (fileContent) {
        cachedToken = fileContent;
        return cachedToken;
      }
    }
  } catch {
    // Ignore unreadable file / permission errors
  }

  // 3. Fallback
  cachedToken = undefined;
  return cachedToken;
}

/**
 * Invalidate cached daemon token (e.g. on 401 response).
 * Next call to resolveDaemonToken will re-check env and secret file.
 */
export function invalidateDaemonToken(): void {
  cachedToken = null;
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

// Release an unconsumed fetch Response body back to the connection pool. An
// undici body left unread pins its socket until GC, so probes that only care
// about status/headers (wedge, healthz) must discard it. Guarded against
// mocks/polyfills whose body lacks cancel(); never throws.
export function discardBody(response: Response | undefined): void {
  const body = response?.body as { cancel?: () => Promise<unknown> } | null | undefined;
  if (body && typeof body.cancel === "function") {
    body.cancel().catch(() => {});
  }
}

export function isAbsoluteHttpUrl(value: string): boolean {
  try {
    const parsed = new URL(value);
    return parsed.protocol === "http:" || parsed.protocol === "https:";
  } catch {
    return false;
  }
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

// boundedPigeonFetch resolves daemon token at call time and retries once on 401.
export async function boundedPigeonFetch(
  url: string,
  opts: BoundedPigeonFetchOptions,
): Promise<BoundedFetchResult> {
  const token = opts.bearerToken ?? resolveDaemonToken({ tokenFilePath: opts.tokenFilePath });

  const firstResult = await boundedFetch(url, {
    ...opts,
    bearerToken: token,
  });

  if (!firstResult.ok || firstResult.response?.status !== 401) {
    return firstResult;
  }

  // Handle 401: discard body, invalidate token, re-resolve, and retry ONCE
  discardBody(firstResult.response);
  invalidateDaemonToken();

  const newToken = opts.bearerToken ?? resolveDaemonToken({ forceRefresh: true, tokenFilePath: opts.tokenFilePath });

  return boundedFetch(url, {
    ...opts,
    bearerToken: newToken,
  });
}
