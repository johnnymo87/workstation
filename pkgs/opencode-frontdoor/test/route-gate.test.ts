import { describe, test, expect } from 'vitest';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { checkDocRoutes, runRouteGateCli } from '../src/route-gate.js';

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
