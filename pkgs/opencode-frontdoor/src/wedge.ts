import type { Config } from "./config.js";
import { boundedFetch, stripTrailingSlashes } from "./http.js";

export interface WedgeProbeOptions {
  target: string;
  config: Config;
  deps?: {
    fetch?: typeof fetch;
  };
  onWedged: () => void;
}

export interface WedgeProbe {
  start(): void;
  stop(): void;
}

export function createWedgeProbe(opts: WedgeProbeOptions): WedgeProbe {
  const { target, config, deps, onWedged } = opts;

  let timer: ReturnType<typeof setTimeout> | undefined;
  let active = false;
  let failures = 0;

  function stop(): void {
    active = false;
    if (timer) {
      clearTimeout(timer);
      timer = undefined;
    }
  }

  function scheduleNext(): void {
    if (!active) return;

    timer = setTimeout(async () => {
      timer = undefined;
      if (!active) return;

      const url = `${stripTrailingSlashes(target)}/global/health`;
      const result = await boundedFetch(url, {
        method: "GET",
        timeoutMs: config.routeTimeoutMs,
        fetchImpl: deps?.fetch,
      });

      if (!active) return;

      const success = result.ok && result.response?.status === 200;

      if (success) {
        failures = 0;
        scheduleNext();
      } else {
        failures++;
        if (failures >= 2) {
          stop();
          onWedged();
        } else {
          scheduleNext();
        }
      }
    }, config.wedgeProbeIntervalMs);

    timer.unref?.();
  }

  function start(): void {
    if (active) return;
    active = true;
    scheduleNext();
  }

  return {
    start,
    stop,
  };
}
