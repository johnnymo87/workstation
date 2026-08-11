import { describe, test, expect } from 'vitest';
import { createMetrics } from '../src/metrics.js';

describe('metrics', () => {
  test('creates a metrics object starting at 0', () => {
    const metrics = createMetrics();
    expect(metrics).toEqual({ degradedRequests: 0, notRoutedMutationToAnchor: 0,
      promotedOnConnect: 0, htmlPoisonBlocked: 0, poolFailover: 0 });
  });

  test('can increment degradedRequests', () => {
    const metrics = createMetrics();
    metrics.degradedRequests++;
    expect(metrics.degradedRequests).toBe(1);
  });

  test('can increment notRoutedMutationToAnchor', () => {
    const metrics = createMetrics();
    metrics.notRoutedMutationToAnchor++;
    expect(metrics.notRoutedMutationToAnchor).toBe(1);
  });

  test('can increment htmlPoisonBlocked', () => {
    const metrics = createMetrics();
    metrics.htmlPoisonBlocked++;
    expect(metrics.htmlPoisonBlocked).toBe(1);
  });

  test('can increment poolFailover', () => {
    const metrics = createMetrics();
    metrics.poolFailover++;
    expect(metrics.poolFailover).toBe(1);
  });
});
