/**
 * Query-string parameters whose VALUES may be written to the log.
 *
 * Default-deny: anything not listed here is logged as `name=<elided>`, so the
 * key is still visible for forensics but the value never lands on disk. A new
 * parameter added upstream is elided automatically rather than leaking by
 * omission.
 *
 * `auth_token` is deliberately absent. Note it cannot be assumed pre-stripped:
 * buildForwardSearch only removes it when a serve credential is configured
 * (proxy.ts), and the door currently runs WITHOUT one -- so a client-supplied
 * auth_token reaches this log path intact. Redaction here must not depend on
 * that config.
 *
 * The listed values are local filesystem paths and small scalars already
 * present elsewhere in this log or in session metadata, and their cardinality
 * is bounded by the number of open project directories.
 */
export const QUERY_VALUE_ALLOWLIST: ReadonlySet<string> = new Set([
  "directory",
  "location[directory]",
  "workspace",
  "path",
  "limit",
  "start",
]);

/**
 * Render a query string for logging, eliding every non-allowlisted value.
 *
 * Exists because `logResponse` logged only `url.pathname`, so the door's own
 * log could not distinguish `/config` from `/config?directory=<x>`. That gap
 * actively misled an investigation: a query for '?' across 2283 global-ro rows
 * returned zero, which was read as "clients send no query strings" when it was
 * guaranteed by the field's definition. A real client sends `?directory=` on
 * every request. See workstation-eon4.
 */
export function redactQuery(search: string | undefined): string | undefined {
  if (!search) return undefined;
  const raw = search.startsWith("?") ? search.slice(1) : search;
  if (!raw) return undefined;
  const parts: string[] = [];
  for (const [k, v] of new URLSearchParams(raw)) {
    parts.push(QUERY_VALUE_ALLOWLIST.has(k) ? `${k}=${v}` : `${k}=<elided>`);
  }
  return parts.length ? parts.join("&") : undefined;
}

export interface RequestLogEntry {
  class: string;
  sid: string | null;
  target: string;
  prospective: boolean;
  degraded: boolean;
  status: number;
  durationMs: number;
  method?: string;
  path?: string;
  /** Redacted query string; see redactQuery. Absent when there was no query. */
  query?: string;
  action?: string;
  /** sq1v: the owner was resolved via an ancestor's route (child/subagent session). */
  viaParent?: boolean;
  /** sq1v: the sid pigeon lease ops used (the root). Differs from `sid` for children. */
  routingSid?: string | null;
}

export interface MetricsSnapshot {
  degradedToAnchor: number;
  totalRequests: number;
}

export interface LoggerDeps {
  sink?: (line: string) => void;
  now?: () => number;
}

export class RequestLogger {
  private sink: (line: string) => void;
  private now: () => number;
  private degradedToAnchor = 0;
  private totalRequests = 0;

  constructor(deps?: LoggerDeps) {
    this.sink = deps?.sink ?? console.log;
    this.now = deps?.now ?? Date.now;
  }

  log(entry: RequestLogEntry): void {
    // SECURITY NOTE: NEVER log secrets. Do not include pigeon auth tokens,
    // Authorization headers, or any sensitive credentials in the logged entry.
    // The entry schema is designed strictly to avoid capturing any request
    // headers or request bodies that might contain credentials.
    const ts = new Date(this.now()).toISOString();
    // Explicitly enumerate the fields rather than spreading `...entry`: this is
    // a hard allowlist so that a caller who (accidentally) passes an
    // over-shaped object cast as `any` cannot leak extra properties
    // (e.g. Authorization headers, tokens, cookies) into the log line.
    // JSON.stringify drops `undefined`, so absent optionals are omitted cleanly.
    const logLine = JSON.stringify({
      ts,
      type: "request",
      class: entry.class,
      sid: entry.sid,
      target: entry.target,
      prospective: entry.prospective,
      degraded: entry.degraded,
      status: entry.status,
      durationMs: entry.durationMs,
      method: entry.method,
      path: entry.path,
      query: entry.query,
      action: entry.action,
      viaParent: entry.viaParent,
      routingSid: entry.routingSid,
    });
    this.sink(logLine);

    this.totalRequests++;
    if (entry.degraded === true) {
      this.degradedToAnchor++;
    }
  }

  snapshot(): MetricsSnapshot {
    return {
      degradedToAnchor: this.degradedToAnchor,
      totalRequests: this.totalRequests,
    };
  }
}
