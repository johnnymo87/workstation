import type { Config } from "./config.js";
import { boundedFetch, stripTrailingSlashes, discardBody } from "./http.js";
import type { ResolvedOwner } from "./resolve.js";
import { extractSessionIdFromPath, type SidExtraction } from "./sid.js";

// Callers MUST NOT invoke `maybePromote` from the Task 2.2 drift-timer re-resolve
// or from casual reads. Those paths must stay read-only via `resolveOwner`.
// Only `place.ts` issues `POST /place`.

export interface PlaceDeps {
  fetch?: typeof globalThis.fetch;
  now?: () => number;
}

export interface PlaceResult {
  ok: boolean;
  status: number;
  serveId?: string;
  apiBase?: string;
}

export async function placeSession(
  sid: string,
  config: Config,
  deps?: PlaceDeps,
): Promise<PlaceResult> {
  const pigeonBase = stripTrailingSlashes(config.pigeonUrl);
  const targetUrl = `${pigeonBase}/place`;

  const result = await boundedFetch(targetUrl, {
    method: "POST",
    timeoutMs: config.routeTimeoutMs,
    headers: {
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ session_id: sid }),
    bearerToken: config.pigeonAuthToken,
    fetchImpl: deps?.fetch,
  });

  if (!result.ok) {
    return {
      ok: false,
      status: 0,
    };
  }

  const response = result.response!;
  if (response.status === 200) {
    try {
      const data = await response.json() as any;
      return {
        ok: true,
        status: 200,
        serveId: data?.serve_id ?? data?.serveId,
        apiBase: data?.api_base ?? data?.apiBase,
      };
    } catch (err) {
      return {
        ok: false,
        status: 0,
      };
    }
  }

  // Non-200 place-fail: body never read → release the socket.
  discardBody(response);
  return {
    ok: false,
    status: response.status,
  };
}

const PROMOTING_SUFFIXES = new Set([
  "message",
  "prompt",
  "prompt_async",
  "compact",
  "shell",
  "command",
  "summarize",
  "init"
]);

export function isPromotingRequest(
  method: string,
  pathname: string,
  extraction: SidExtraction,
): boolean {
  if (extraction.kind !== "single") {
    return false;
  }

  const upperMethod = method.toUpperCase();

  if (upperMethod === "GET") {
    const normalizedPath = pathname.replace(/\/$/, "");
    
    // Query-based: /event or /api/event
    if (normalizedPath === "/event" || normalizedPath === "/api/event") {
      return true;
    }

    // Path-based: /session/{sid}/event or /api/session/{sid}/event
    if (
      normalizedPath === `/session/${extraction.sid}/event` ||
      normalizedPath === `/api/session/${extraction.sid}/event`
    ) {
      return true;
    }

    return false;
  }

  if (upperMethod === "POST") {
    // Turn-starting POST
    // Must be a session-path with the sid in the path
    const pathCandidate = extractSessionIdFromPath(pathname);

    if (pathCandidate && pathCandidate === extraction.sid) {
      const normalizedPath = pathname.replace(/\/$/, "");
      const segments = normalizedPath.split("/").filter(Boolean);
      const lastSegment = segments[segments.length - 1];
      if (lastSegment && PROMOTING_SUFFIXES.has(lastSegment)) {
        return true;
      }
    }
    return false;
  }

  return false;
}

export class PromotionGate {
  private attempts = new Map<string, number>();
  private lastSweep = 0;

  constructor(private stickyTtlMs: number) {}

  shouldAttempt(sid: string, now: number): boolean {
    const last = this.attempts.get(sid);
    if (last === undefined) {
      return true;
    }
    return now - last >= this.stickyTtlMs;
  }

  record(sid: string, now: number): void {
    this.attempts.set(sid, now);
    if (now - this.lastSweep >= this.stickyTtlMs) {
      for (const [key, timestamp] of this.attempts.entries()) {
        if (now - timestamp >= this.stickyTtlMs) {
          this.attempts.delete(key);
        }
      }
      this.lastSweep = now;
    }
  }
}

export interface PromoteOutcome {
  placed: boolean;
  reason: "placed" | "not-promoting" | "already-active" | "pigeon-degraded" | "ttl-guarded" | "unknown-sid" | "place-failed";
  serveId?: string;
  apiBase?: string;
  status?: number;
}

async function checkSidExists(
  sid: string,
  config: Config,
  deps?: PlaceDeps,
): Promise<boolean> {
  const anchorBase = stripTrailingSlashes(config.anchorUrl);
  const targetUrl = `${anchorBase}/session/${encodeURIComponent(sid)}`;

  const result = await boundedFetch(targetUrl, {
    method: "GET",
    timeoutMs: config.routeTimeoutMs,
    fetchImpl: deps?.fetch,
  });

  if (!result.ok) {
    return false;
  }

  const exists = result.response!.status === 200;
  discardBody(result.response); // status-only check; release the socket
  return exists;
}

export async function maybePromote(
  params: {
    sid: string;
    method: string;
    pathname: string;
    extraction: SidExtraction;
    resolved: ResolvedOwner;
    gate: PromotionGate;
  },
  config: Config,
  deps?: PlaceDeps,
): Promise<PromoteOutcome> {
  const { sid, method, pathname, extraction, resolved, gate } = params;
  const now = deps?.now?.() ?? Date.now();

  // Step 2: If !isPromotingRequest(...)
  if (!isPromotingRequest(method, pathname, extraction)) {
    return { placed: false, reason: "not-promoting" };
  }

  // Step 3: Based on resolved.reason
  if (resolved.reason === "active") {
    return { placed: false, reason: "already-active" };
  }
  if (resolved.reason === "pigeon-unreachable" || resolved.reason === "pigeon-error") {
    return { placed: false, reason: "pigeon-degraded" };
  }

  // Step 4: If !gate.shouldAttempt(...)
  if (!gate.shouldAttempt(sid, now)) {
    return { placed: false, reason: "ttl-guarded" };
  }

  // Step 5: If resolved.reason === "not-routed"
  if (resolved.reason === "not-routed") {
    // Note: two concurrent promoting requests for the same not-yet-routed sid
    // can both pass shouldAttempt before either calls record (async gap across checkSidExists),
    // so both may POST /place — which is safe because pigeon's ensureRouted is idempotent.
    const exists = await checkSidExists(sid, config, deps);
    if (!exists) {
      return { placed: false, reason: "unknown-sid" };
    }
  }

  // Step 6: gate.record(sid, now) then placeSession
  gate.record(sid, now);

  const placeResult = await placeSession(sid, config, deps);
  if (placeResult.ok) {
    return {
      placed: true,
      reason: "placed",
      serveId: placeResult.serveId,
      apiBase: placeResult.apiBase,
      status: 200,
    };
  }

  return {
    placed: false,
    reason: "place-failed",
    status: placeResult.status,
  };
}
