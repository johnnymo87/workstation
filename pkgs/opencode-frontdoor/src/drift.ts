import type { Config } from "./config.js";
import { stripTrailingSlashes } from "./http.js";
import { resolveOwner } from "./resolve.js";
import type { SidExtraction } from "./sid.js";

export type OwnerDriftState = { candidate: string | undefined; count: number };
export const INITIAL_OWNER_DRIFT_STATE: OwnerDriftState = { candidate: undefined, count: 0 };

export function evaluateOwnerDrift(
  state: OwnerDriftState,
  current: string,
  resolved: string,
  confirmations = 2,
): { state: OwnerDriftState; reconnect: boolean } {
  const normResolved = stripTrailingSlashes(resolved);
  const normCurrent = stripTrailingSlashes(current);
  if (!normResolved || normResolved === normCurrent) {
    return { state: INITIAL_OWNER_DRIFT_STATE, reconnect: false };
  }
  const count = state.candidate === normResolved ? state.count + 1 : 1;
  if (count >= confirmations) {
    return { state: INITIAL_OWNER_DRIFT_STATE, reconnect: true };
  }
  return { state: { candidate: normResolved, count }, reconnect: false };
}

export interface DriftMonitor {
  markActivity(): void;
  start(): void;
  stop(): void;
  /** Internal seam: runs exactly one poll cycle. Exposed for deterministic tests; production uses start()/stop(). */
  runCheckOnce(): Promise<void>;
}

export function createDriftMonitor(opts: {
  extraction: SidExtraction;
  currentOwner: string;
  config: Config;
  deps?: {
    fetch?: typeof fetch;
    now?: () => number;
  };
  onDrop: () => void;
}): DriftMonitor {
  const { extraction, currentOwner, config, deps, onDrop } = opts;

  const nowFn = deps?.now ?? Date.now;
  const normalizedCurrentOwner = stripTrailingSlashes(currentOwner);

  let driftState = INITIAL_OWNER_DRIFT_STATE;
  let lastActivityAt = nowFn();
  let timer: ReturnType<typeof setTimeout> | undefined;
  let active = false;
  let dropped = false;

  function isActive(): boolean {
    return nowFn() - lastActivityAt < config.quiesceMs;
  }

  function markActivity(): void {
    lastActivityAt = nowFn();
  }

  function stop(): void {
    active = false;
    if (timer) {
      clearTimeout(timer);
      timer = undefined;
    }
  }

  function triggerDrop(): void {
    if (dropped) return;
    dropped = true;
    stop();
    onDrop();
  }

  function scheduleNext(): void {
    if (!active) return;
    timer = setTimeout(async () => {
      timer = undefined;
      if (!active) return;
      try {
        await runCheckOnce();
      } catch (err) {
        console.error("[frontdoor] drift monitor check failed:", err);
      }
      if (active) {
        scheduleNext();
      }
    }, config.driftCheckMs);
    timer.unref?.();
  }

  function start(): void {
    if (active) return;
    active = true;
    lastActivityAt = nowFn();
    scheduleNext();
  }

  async function runCheckOnce(): Promise<void> {
    if (!active || dropped) return;

    let effectiveResolved = normalizedCurrentOwner;

    try {
      if (extraction.kind === "single") {
        const r = await resolveOwner(extraction.sid, config, { fetch: deps?.fetch });
        if (!active || dropped) return;
        effectiveResolved = r.degraded ? normalizedCurrentOwner : stripTrailingSlashes(r.url);
      } else if (extraction.kind === "multi") {
        const list = await Promise.all(
          extraction.sids.map(sid => resolveOwner(sid, config, { fetch: deps?.fetch }))
        );
        if (!active || dropped) return;
        const real = list.filter(r => !r.degraded);
        const urls = new Set(real.map(r => stripTrailingSlashes(r.url)));
        if (urls.size === 1) {
          effectiveResolved = [...urls][0];
        } else {
          effectiveResolved = normalizedCurrentOwner;
        }
      }
    } catch (err) {
      if (!active || dropped) return;
      effectiveResolved = normalizedCurrentOwner;
    }

    const evalResult = evaluateOwnerDrift(driftState, normalizedCurrentOwner, effectiveResolved);
    driftState = evalResult.state;

    if (evalResult.reconnect) {
      if (isActive()) {
        // active-guard: never drop an actively-flowing leg mid-turn.
        // re-arm the confirmation by setting state to { candidate: effectiveResolved, count: 1 } and keep polling
        // (so the next confirmed + quiescent poll drops). Never drop while active.
        driftState = { candidate: effectiveResolved, count: 1 };
        // This activity-based "active" signal is the current realization of the Phase-3.4 sticky map (NEW-H):
        // 3.4 will later formalize it; for now observed SSE activity IS the sticky-refresh.
      } else {
        triggerDrop();
      }
    }
  }

  return {
    markActivity,
    start,
    stop,
    /** Internal seam: runs exactly one poll cycle. Exposed for deterministic tests; production uses start()/stop(). */
    runCheckOnce,
  };
}
