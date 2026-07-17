import { describe, test, expect } from 'vitest';
import { createMetrics } from '../src/metrics.js';

describe('metrics', () => {
  test('creates a metrics object starting at 0', () => {
    const metrics = createMetrics();
    expect(metrics).toEqual({ degradedRequests: 0 });
  });

  test('can increment degradedRequests', () => {
    const metrics = createMetrics();
    metrics.degradedRequests++;
    expect(metrics.degradedRequests).toBe(1);
  });
});
