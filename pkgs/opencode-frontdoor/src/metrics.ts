export interface Metrics {
  degradedRequests: number;
}

export function createMetrics(): Metrics {
  return { degradedRequests: 0 };
}
