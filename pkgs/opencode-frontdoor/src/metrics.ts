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
  /**
   * workstation-27r8. GET/HEAD requests whose client side ended (cheap first-byte
   * timeout, or the client hung up) BEFORE the upstream sent headers, and which
   * the door therefore DETACHED from rather than destroyed. Destroying them is
   * what poisoned a serve: opencode runs lazy per-directory init inside the first
   * caller's request fiber and memoizes an interruption forever (replayed as 499).
   */
  upstreamAbandoned: number;
  /**
   * Detachable upstreams destroyed anyway: still unanswered at
   * `abandonedUpstreamMaxMs`, or over `abandonedUpstreamMaxConcurrent`. Each one
   * may have poisoned a serve's per-directory state (the warn log says which
   * limit fired). Sustained nonzero means a limit is too low for real traffic.
   */
  upstreamAbandonedKilled: number;
  /**
   * Upstream responses with status 499. Through the door these are ALWAYS
   * spurious — the door's own upstream socket is demonstrably open, since it is
   * reading the response — so they mean the serve is replaying a memoized client
   * abort for that directory. Converted to 503 (or failed over on forward-pool).
   */
  upstreamSpurious499: number;
}

export function createMetrics(): Metrics {
  return { degradedRequests: 0, notRoutedMutationToAnchor: 0, promotedOnConnect: 0, htmlPoisonBlocked: 0, poolFailover: 0, upstreamAbandoned: 0, upstreamAbandonedKilled: 0, upstreamSpurious499: 0 };
}
