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
   * NOT-ROUTED sessions placed by a state-pinning request (`connect`) — i.e. how often the
   * `vjq0` fix RESCUED a connect that would otherwise have stranded its MCP state on the
   * anchor while the following turn ran elsewhere.
   *
   * Scoped to `reason === "not-routed"` on purpose: `prospective` connects are also placed
   * now, but they were already safe (they record sticky), so counting them would make this
   * read ~12/week and imply the race fires that often. It does not.
   *
   * Exists because the fix would otherwise BLIND the only pre-existing signal for this
   * class: a not-routed connect that now places no longer increments
   * `notRoutedMutationToAnchor`. Without this counter we would trade a silent bug for a
   * silent fix and have no way to tell the difference.
   */
  promotedOnConnect: number;
  /**
   * Upstream responses returning `text/html` blocked by the frontdoor html-poison
   * guard and converted into a 502 bad_gateway response. Makes skew episodes
   * countable rather than journal-only.
   * See docs/plans/2026-07-25-m3z2-html-poison-guard.md.
   */
  htmlPoisonBlocked: number;
  /**
   * Count of connection-level failovers across pool members during forward-pool.
   */
  poolFailover: number;
}

export function createMetrics(): Metrics {
  return { degradedRequests: 0, notRoutedMutationToAnchor: 0, promotedOnConnect: 0, htmlPoisonBlocked: 0, poolFailover: 0 };
}
