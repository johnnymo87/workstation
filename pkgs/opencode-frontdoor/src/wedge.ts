import type { Config } from "./config.js";
import { probeServeHealth } from "./health.js";

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

      const ok = await probeServeHealth(target, config, deps);
      if (!active) return;

      if (ok) {
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
