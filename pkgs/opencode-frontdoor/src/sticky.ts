export interface StickyEntry {
  serve: string;
  expiry: number;
}

export class StickyMap {
  private entries = new Map<string, StickyEntry>();
  private lastSweep = 0;

  constructor(private ttlMs: number) {}

  record(sid: string, serve: string, now: number): void {
    this.entries.set(sid, { serve, expiry: now + this.ttlMs });
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

  delete(sid: string): void {
    this.entries.delete(sid);
  }
}
