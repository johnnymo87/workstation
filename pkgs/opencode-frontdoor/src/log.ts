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
  action?: string;
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
      action: entry.action,
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
