import { describe, test, expect } from 'vitest';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { checkDocRoutes, runRouteGateCli } from '../src/route-gate.js';
import { ROUTE_DISPOSITIONS } from '../src/routes.dispositions.js';

describe('Route Classification Gate (Check A)', () => {
  test('passes on clean synthetic /doc fixture', () => {
    const doc = {
      paths: {
        '/api/health': {
          get: { summary: 'Health check' },
        },
        '/session/{sessionID}': {
          get: { summary: 'Get session' },
          patch: { summary: 'Update session' },
        },
      },
    };

    const result = checkDocRoutes(doc, { minRoutes: 1 });
    expect(result.passed).toBe(true);
    expect(result.totalChecked).toBe(3);
    expect(result.unrecognized).toEqual([]);
  });

  test('fails and lists unrecognized routes', () => {
    const doc = {
      paths: {
        '/api/health': {
          get: { summary: 'Health check' },
        },
        '/unknown/unrecognized/route/123': {
          get: { summary: 'Unknown route' },
          post: { summary: 'Unknown mutation' },
        },
      },
    };

    const result = checkDocRoutes(doc, { minRoutes: 1 });
    expect(result.passed).toBe(false);
    expect(result.totalChecked).toBe(3);
    expect(result.unrecognized).toEqual([
      { method: 'GET', path: '/unknown/unrecognized/route/123' },
      { method: 'POST', path: '/unknown/unrecognized/route/123' },
    ]);
  });

  test('fails on sanity floor when route count is below minRoutes', () => {
    const doc = {
      paths: {
        '/api/health': {
          get: { summary: 'Health check' },
        },
      },
    };

    const result = checkDocRoutes(doc, { minRoutes: 100 });
    expect(result.passed).toBe(false);
    expect(result.totalChecked).toBe(1);
    expect(result.error).toContain('Sanity floor failed');
  });

  test('fails on empty or malformed /doc JSON', () => {
    expect(checkDocRoutes(null).passed).toBe(false);
    expect(checkDocRoutes({}).passed).toBe(false);
    expect(checkDocRoutes({ paths: 'not-an-object' }).passed).toBe(false);
  });

  test('ignores non-method keys under path items', () => {
    const doc = {
      paths: {
        '/api/health': {
          get: { summary: 'Health check' },
          parameters: [{ name: 'foo', in: 'query' }],
          servers: [{ url: 'http://localhost' }],
          summary: 'Path summary',
          description: 'Path description',
          $ref: '#/components/schemas/Foo',
        },
      },
    };

    const result = checkDocRoutes(doc, { minRoutes: 1 });
    expect(result.passed).toBe(true);
    expect(result.totalChecked).toBe(1);
    expect(result.unrecognized).toEqual([]);
  });

  describe('CLI Runner', () => {
    test('exits 0 on clean doc file', () => {
      const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'gate-test-'));
      const docFile = path.join(tmpDir, 'doc.json');
      fs.writeFileSync(
        docFile,
        JSON.stringify({
          paths: {
            '/api/health': { get: {} },
          },
        })
      );

      const exitCode = runRouteGateCli([docFile, '--min-routes', '1']);
      expect(exitCode).toBe(0);
      fs.rmSync(tmpDir, { recursive: true, force: true });
    });

    test('exits 1 on unrecognized route in doc file', () => {
      const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'gate-test-'));
      const docFile = path.join(tmpDir, 'doc.json');
      fs.writeFileSync(
        docFile,
        JSON.stringify({
          paths: {
            '/unrecognized/xyz': { get: {} },
          },
        })
      );

      const exitCode = runRouteGateCli([docFile, '--min-routes', '1']);
      expect(exitCode).toBe(1);
      fs.rmSync(tmpDir, { recursive: true, force: true });
    });

    test('exits 1 on missing or invalid file', () => {
      expect(runRouteGateCli(['/nonexistent/file.json'])).toBe(1);
    });
  });
});

describe('Route Denial Disposition Gate (Check B)', () => {
  test('Positive: real table + real dispositions pass on /tmp/docgate.px1q/doc.json', () => {
    const docPath = '/tmp/docgate.px1q/doc.json';
    if (!fs.existsSync(docPath)) {
      console.warn(`Skipping real /doc test: ${docPath} not found`);
      return;
    }
    const doc = JSON.parse(fs.readFileSync(docPath, 'utf8'));
    const result = checkDocRoutes(doc);
    expect(result.passed).toBe(true);
    expect(result.totalChecked).toBe(195);
    expect(result.denialCount).toBe(77);
    expect(result.unrecognized).toEqual([]);
    expect(result.invalidDispositions).toEqual([]);
  });

  test('Negative: a denial with no disposition fails and is named', () => {
    const doc = {
      paths: {
        '/global/dispose': {
          post: { summary: 'Dispose process' },
        },
      },
    };
    const result = checkDocRoutes(doc, { minRoutes: 1, routeDispositions: {} });
    expect(result.passed).toBe(false);
    expect(result.invalidDispositions).toEqual([
      {
        method: 'POST',
        path: '/global/dispose',
        action: 'deny-global-mutation',
        reason: 'Missing disposition for denial route',
      },
    ]);
  });

  test('Negative: superseded without supersededBy fails', () => {
    const doc = {
      paths: {
        '/sync/start': {
          post: { summary: 'Start sync' },
        },
      },
    };
    const customDispositions = {
      'POST /sync/start': {
        kind: 'superseded' as const,
        rationale: 'Superseded route without target',
      },
    };
    const result = checkDocRoutes(doc, { minRoutes: 1, routeDispositions: customDispositions });
    expect(result.passed).toBe(false);
    expect(result.invalidDispositions[0].reason).toContain('requires a non-empty supersededBy route');
  });

  test('Negative: superseded pointing at a denying route fails', () => {
    const doc = {
      paths: {
        '/sync/start': {
          post: { summary: 'Start sync' },
        },
      },
    };
    const customDispositions = {
      'POST /sync/start': {
        kind: 'superseded' as const,
        supersededBy: 'POST /global/dispose', // pointing at another denial!
        rationale: 'Pointing at denying route',
      },
    };
    const result = checkDocRoutes(doc, { minRoutes: 1, routeDispositions: customDispositions });
    expect(result.passed).toBe(false);
    expect(result.invalidDispositions[0].reason).toContain('points to a non-existent or denying route');
  });

  test('Negative: needs-mechanism without a bead fails', () => {
    const doc = {
      paths: {
        '/instance/dispose': {
          post: { summary: 'Dispose instance' },
        },
      },
    };
    const customDispositions = {
      'POST /instance/dispose': {
        kind: 'needs-mechanism' as const,
        rationale: 'Needs broadcast mechanism',
      },
    };
    const result = checkDocRoutes(doc, { minRoutes: 1, routeDispositions: customDispositions });
    expect(result.passed).toBe(false);
    expect(result.invalidDispositions[0].reason).toContain('requires a non-empty bead reference');
  });

  test('Negative: empty rationale fails', () => {
    const doc = {
      paths: {
        '/global/dispose': {
          post: { summary: 'Dispose process' },
        },
      },
    };
    const customDispositions = {
      'POST /global/dispose': {
        kind: 'not-session-scopable' as const,
        rationale: '   ',
      },
    };
    const result = checkDocRoutes(doc, { minRoutes: 1, routeDispositions: customDispositions });
    expect(result.passed).toBe(false);
    expect(result.invalidDispositions[0].reason).toContain('empty or missing rationale');
  });

  test('Mutation test: deleting exactly one real disposition names that route and fails', () => {
    const docPath = '/tmp/docgate.px1q/doc.json';
    if (!fs.existsSync(docPath)) {
      console.warn(`Skipping mutation test: ${docPath} not found`);
      return;
    }
    const doc = JSON.parse(fs.readFileSync(docPath, 'utf8'));

    const throwawayRouteDispositions = { ...ROUTE_DISPOSITIONS };
    const targetRoute = 'POST /sync/start';
    delete throwawayRouteDispositions[targetRoute];

    const result = checkDocRoutes(doc, { routeDispositions: throwawayRouteDispositions });
    expect(result.passed).toBe(false);
    expect(result.invalidDispositions).toContainEqual({
      method: 'POST',
      path: '/sync/start',
      action: 'deny-global-mutation',
      reason: 'Missing disposition for denial route',
    });
  });
});
