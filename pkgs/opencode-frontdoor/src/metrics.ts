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
  /**
   * Upstream responses returning `text/html` blocked by the frontdoor html-poison
   * guard and converted into a 502 bad_gateway response. Makes skew episodes
   * countable rather than journal-only.
   * See docs/plans/2026-07-25-m3z2-html-poison-guard.md.
   */
  htmlPoisonBlocked: number;
}

export function createMetrics(): Metrics {
  return { degradedRequests: 0, notRoutedMutationToAnchor: 0, htmlPoisonBlocked: 0 };
}
