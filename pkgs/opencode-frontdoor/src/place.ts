import type { Config } from "./config.js";
import type { ResolvedOwner } from "./resolve.js";
import type { SidExtraction } from "./sid.js";

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
  const fetchFn = deps?.fetch ?? globalThis.fetch;
  const pigeonBase = config.pigeonUrl.replace(/\/+$/, "");
  const targetUrl = `${pigeonBase}/place`;

  const headers: Record<string, string> = {
    "Content-Type": "application/json",
  };
  if (config.pigeonAuthToken) {
    headers["Authorization"] = `Bearer ${config.pigeonAuthToken}`;
  }

  const controller = new AbortController();
  const timeoutId = setTimeout(() => {
    controller.abort();
  }, config.routeTimeoutMs);

  try {
    const response = await fetchFn(targetUrl, {
      method: "POST",
      signal: controller.signal,
      headers,
      body: JSON.stringify({ session_id: sid }),
    });

    if (response.status === 200) {
      const data = await response.json() as any;
      return {
        ok: true,
        status: 200,
        serveId: data?.serve_id ?? data?.serveId,
        apiBase: data?.api_base ?? data?.apiBase,
      };
    }

    return {
      ok: false,
      status: response.status,
    };
  } catch (err) {
    return {
      ok: false,
      status: 0,
    };
  } finally {
    clearTimeout(timeoutId);
  }
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
    // Single-session event stream
    // either session-path event route (/api)?/session/{id}/event OR (/api)?/event?session_ids=<one sid>
    const normalizedPath = pathname.replace(/\/$/, "");
    if (normalizedPath.endsWith("/event") && !normalizedPath.endsWith("/global/event")) {
      return true;
    }
    return false;
  }

  if (upperMethod === "POST") {
    // Turn-starting POST
    // Must be a session-path with the sid in the path
    const normalizedPath = pathname.replace(/\/$/, "");
    const sessionPathMatch = normalizedPath.match(/^\/(?:api\/)?session\/([^/]+)(?:\/|$)/);
    const experimentalMatch = normalizedPath.match(/^\/(?:api\/)?experimental\/session\/([^/]+)\/background$/);
    const pathCandidate = sessionPathMatch?.[1] || experimentalMatch?.[1];

    if (pathCandidate && pathCandidate === extraction.sid) {
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
  const fetchFn = deps?.fetch ?? globalThis.fetch;
  const anchorBase = config.anchorUrl.replace(/\/+$/, "");
  const targetUrl = `${anchorBase}/session/${encodeURIComponent(sid)}`;

  const controller = new AbortController();
  const timeoutId = setTimeout(() => {
    controller.abort();
  }, config.routeTimeoutMs);

  try {
    const response = await fetchFn(targetUrl, {
      method: "GET",
      signal: controller.signal,
    });
    return response.status === 200;
  } catch (err) {
    return false;
  } finally {
    clearTimeout(timeoutId);
  }
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

  // TASK 3.4 STICKY SEAM
  // Right here, before checking the gate, Task 3.4 will add a sticky-map check.
  // This will check if there is an active sticky session lease to prevent a lease-less
  // in-flight turn from being clobbered. If sticky check indicates a lease exists,
  // we would route to that sticky target.

  // Step 4: If !gate.shouldAttempt(...)
  if (!gate.shouldAttempt(sid, now)) {
    return { placed: false, reason: "ttl-guarded" };
  }

  // Step 5: If resolved.reason === "not-routed"
  if (resolved.reason === "not-routed") {
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
