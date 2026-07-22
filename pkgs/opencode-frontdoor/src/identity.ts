import type { IncomingMessage } from "node:http";

export interface Identity { trusted: boolean; }

// Localhost-only, no auth today (matches serves/pigeon posture). This is the
// single seam where a future Tailscale/reverse-tunnel front would authenticate.
export function identify(_req: IncomingMessage): Identity {
  return { trusted: true };
}
