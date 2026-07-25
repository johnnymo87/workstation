export interface Metrics {
  degradedRequests: number;
  /**
   * Mutating requests forwarded to the ANCHOR because the sid — and, after the
   * sq1v parent walk, its root — had no pigeon route. These run on a possibly
   * wrong process. Kept as a counter (not a 503) deliberately: if it stays ~zero
   * over a week, tighten that branch to a retryable 503 like FABLE-S2 does for
   * the pigeon-down case. See docs/plans/2026-07-25-sq1v-child-session-parent-walk.md.
   */
  notRoutedMutationToAnchor: number;
}

export function createMetrics(): Metrics {
  return { degradedRequests: 0, notRoutedMutationToAnchor: 0 };
}
