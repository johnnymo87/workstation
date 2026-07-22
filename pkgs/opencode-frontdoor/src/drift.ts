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
  start(): void;
  stop(): void;
  /** Internal seam: runs exactly one poll cycle. Exposed for deterministic tests; production uses start()/stop(). */
  runCheckOnce(): Promise<void>;
}

export function createDriftMonitor(opts: {
  extraction: SidExtraction;
  currentOwner: string;
  config: Config;
  isMidTurn?: () => boolean;
  deps?: {
    fetch?: typeof fetch;
  };
  onDrop: () => void;
}): DriftMonitor {
  const { extraction, currentOwner, config, deps, onDrop } = opts;

  const normalizedCurrentOwner = stripTrailingSlashes(currentOwner);

  let driftState = INITIAL_OWNER_DRIFT_STATE;
  let timer: ReturnType<typeof setTimeout> | undefined;
  let active = false;
  let dropped = false;
  let loggedDivergence = false;
  let loggedMidTurnSuppression = false;

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
          loggedDivergence = false;
        } else if (urls.size >= 2) {
          effectiveResolved = normalizedCurrentOwner;
          if (!loggedDivergence) {
            loggedDivergence = true;
            console.warn(
              "[frontdoor] multi-session stream has diverging owners; leg cannot follow all sessions:",
              [...urls].join(", ")
            );
          }
        } else {
          // size 0: all sids degraded (transient pigeon blip). This is NOT a
          // confirmed resolution of a divergence episode, so leave
          // loggedDivergence unchanged — only a real size===1 resolution resets
          // it. Otherwise a blip flapping through a live divergence would
          // re-spam the warning on every recovery.
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
      if (opts.isMidTurn?.()) {
        // NEW-H: a sid with a fresh forwarded-request (sticky) entry is mid-turn;
        // dropping the SSE leg now would cut an actively-flowing turn. Suppress.
        // driftState was already reset to INITIAL by evaluateOwnerDrift.
        if (!loggedMidTurnSuppression) {
          loggedMidTurnSuppression = true;
          console.warn("[frontdoor] owner drift confirmed but sid is mid-turn (sticky); suppressing SSE drop");
        }
      } else {
        triggerDrop();
      }
    } else if (effectiveResolved === normalizedCurrentOwner) {
      // Reset the once-per-episode suppression log ONLY when drift has genuinely
      // resolved (resolved owner == current). A non-reconnect poll mid-episode
      // (candidate still building toward the confirm threshold — which also
      // happens every cycle because evaluateOwnerDrift resets state on each
      // confirmed reconnect) is NOT stable, so resetting there would re-spam the
      // warning every other poll during a single suppression episode.
      loggedMidTurnSuppression = false;
    }
  }

  return {
    start,
    stop,
    /** Internal seam: runs exactly one poll cycle. Exposed for deterministic tests; production uses start()/stop(). */
    runCheckOnce,
  };
}
