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
    const logLine = JSON.stringify({
      ts,
      type: "request",
      ...entry,
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
