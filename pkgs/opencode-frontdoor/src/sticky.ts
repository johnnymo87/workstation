import type { SidExtraction } from "./sid.js";
import { extractSessionIdFromPath } from "./sid.js";

export interface StickyEntry {
  serve: string;
  expiry: number;
  leaseRenewedAt: number;
}

export class StickyMap {
  private entries = new Map<string, StickyEntry>();
  private lastSweep = 0;

  constructor(private ttlMs: number) {}

  record(sid: string, serve: string, now: number, leaseRenewedAt?: number): void {
    const existing = this.entries.get(sid);
    const finalLeaseRenewedAt = leaseRenewedAt !== undefined
      ? leaseRenewedAt
      : (existing ? existing.leaseRenewedAt : now);

    this.entries.set(sid, { serve, expiry: now + this.ttlMs, leaseRenewedAt: finalLeaseRenewedAt });
    if (now - this.lastSweep >= this.ttlMs) {
      for (const [key, entry] of this.entries.entries()) {
        if (now >= entry.expiry) {
          this.entries.delete(key);
        }
      }
      this.lastSweep = now;
    }
  }

  get(sid: string, now: number): string | undefined {
    const entry = this.entries.get(sid);
    if (entry === undefined) {
      return undefined;
    }
    if (now >= entry.expiry) {
      this.entries.delete(sid);
      return undefined;
    }
    return entry.serve;
  }

  has(sid: string, now: number): boolean {
    return this.get(sid, now) !== undefined;
  }

  needsLeaseRenewal(sid: string, now: number): boolean {
    const entry = this.entries.get(sid);
    if (entry === undefined) {
      return false;
    }
    return now - entry.leaseRenewedAt >= this.ttlMs / 2;
  }

  setLeaseRenewedAt(sid: string, now: number): void {
    const entry = this.entries.get(sid);
    if (entry !== undefined) {
      entry.leaseRenewedAt = now;
    }
  }

  delete(sid: string): void {
    this.entries.delete(sid);
  }
}

export function isMutatingSessionRequest(method: string, pathname: string, extraction: SidExtraction): boolean {
  if (extraction.kind !== "single") return false;
  const m = method.toUpperCase();
  if (m !== "POST" && m !== "PATCH" && m !== "DELETE") return false;
  return extractSessionIdFromPath(pathname) === extraction.sid; // sid must be in the PATH (not a ?session_ids= GET)
}

export function sidsForStickiness(extraction: SidExtraction | null): string[] {
  if (!extraction) return [];
  if (extraction.kind === "single") return [extraction.sid];
  if (extraction.kind === "multi") return extraction.sids;
  return [];
}
