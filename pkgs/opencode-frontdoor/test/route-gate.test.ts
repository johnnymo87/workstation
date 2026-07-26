import { describe, test, expect } from 'vitest';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import {
  checkDocRoutes,
  runRouteGateCli,
  EXPECTED_KIND_CENSUS,
  EXPECTED_NEEDS_MECHANISM_KEYS,
  EXPECTED_MEDIA_TYPE_CENSUS,
  EXPECTED_CONSTRAINT_CENSUS,
} from '../src/route-gate.js';
import { ROUTE_DISPOSITIONS, getRouteDisposition, type RouteDisposition } from '../src/routes.dispositions.js';
import { ROUTE_CLASSIFICATION_TABLE } from '../src/routes.classification.js';
import { dispatch, classify } from '../src/dispatch.js';

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

    const result = checkDocRoutes(doc, { minRoutes: 1, routeDispositions: {}, htmlGuardExemptRoutes: [] });
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

    const result = checkDocRoutes(doc, { minRoutes: 1, routeDispositions: {}, htmlGuardExemptRoutes: [] });
    expect(result.passed).toBe(true);
    expect(result.totalChecked).toBe(1);
    expect(result.unrecognized).toEqual([]);
  });

  test('F1: fails when GET /session/status table row is omitted, naming it as shadowed by GET /session/{sessionID}', () => {
    // Note on remaining tautology: This test overrides routeClassificationTable without
    // overriding routeDispositions, so the 49 real dispositions evaluated against a 1-route
    // synthetic doc cause 49 spurious orphaned disposition errors. Thus expect(result.passed).toBe(false)
    // is a tautology here. The load-bearing assertion is expect(result.shadowed) below.
    const doc = {
      paths: {
        '/session/status': {
          get: { summary: 'Session status' },
        },
      },
    };
    const tableWithoutStatus = ROUTE_CLASSIFICATION_TABLE.filter(
      (r) => !(r.method === 'GET' && r.path === '/session/status')
    );

    const result = checkDocRoutes(doc, {
      minRoutes: 1,
      routeClassificationTable: tableWithoutStatus,
    });

    expect(result.passed).toBe(false);
    expect(result.unrecognized).toEqual([]);
    expect(result.shadowed).toEqual([
      {
        method: 'GET',
        path: '/session/status',
        shadowedBy: 'GET /session/{sessionID}',
      },
    ]);
    expect(result.error).toContain('template-shadowed route(s) found');
  });

  test('F1: genuinely unknown route is reported as unrecognized, not shadowed', () => {
    const doc = {
      paths: {
        '/unknown/unrecognized/route/123': {
          get: { summary: 'Unknown' },
        },
      },
    };

    const result = checkDocRoutes(doc, { minRoutes: 1 });
    expect(result.passed).toBe(false);
    expect(result.shadowed).toEqual([]);
    expect(result.unrecognized).toEqual([
      { method: 'GET', path: '/unknown/unrecognized/route/123' },
    ]);
  });

  test('F1: wildcard row GET /api/fs/read/* passes exact template check', () => {
    const doc = {
      paths: {
        '/api/fs/read/*': {
          get: {
            summary: 'Read FS',
            responses: {
              '200': {
                content: {
                  'application/octet-stream': {},
                },
              },
            },
          },
        },
      },
    };

    const result = checkDocRoutes(doc, { minRoutes: 1, routeDispositions: {} });
    expect(result.passed).toBe(true);
    expect(result.unrecognized).toEqual([]);
    expect(result.shadowed).toEqual([]);
  });

  describe('CLI Runner', () => {
    test('exits 0 on clean doc file', () => {
      // No fallback stub here on purpose. A fallback would let this test pass
      // against a 1-route stub if the fixture went missing, which is the same
      // silent-no-op failure this suite already had (and that test.sh had).
      // A missing fixture must fail loudly.
      const docFile = path.join(__dirname, 'fixtures', 'doc.pinned-1.17.13.4.json');
      const exitCode = runRouteGateCli([docFile, '--min-routes', '100']);
      expect(exitCode).toBe(0);
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
  test('Positive: real table + real dispositions pass on the pinned /doc fixture', () => {
    const docPath = path.join(__dirname, 'fixtures', 'doc.pinned-1.17.13.4.json');
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
        constraint: 'needs-audit' as const,
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
        constraint: 'needs-audit' as const,
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
        constraint: 'needs-audit' as const,
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
        constraint: 'needs-audit' as const,
        rationale: '   ',
      },
    };
    const result = checkDocRoutes(doc, { minRoutes: 1, routeDispositions: customDispositions });
    expect(result.passed).toBe(false);
    expect(result.invalidDispositions[0].reason).toContain('empty or missing rationale');
  });

  test('Negative: missing constraint fails', () => {
    const doc = {
      paths: {
        '/global/dispose': {
          post: { summary: 'Dispose process' },
        },
      },
    };
    // Deliberately cast: the point is to prove the GATE rejects this, not just
    // the compiler. A table can reach the gate via JSON or a loosened type.
    const customDispositions = {
      'POST /global/dispose': {
        kind: 'not-session-scopable' as const,
        tuiSurface: 'absent' as const,
        rationale: 'no constraint given',
      },
    } as unknown as Record<string, RouteDisposition>;
    const result = checkDocRoutes(doc, { minRoutes: 1, routeDispositions: customDispositions });
    expect(result.passed).toBe(false);
    expect(result.invalidDispositions.some((d) => d.reason.includes('requires a constraint field'))).toBe(true);
  });

  test('Negative: unknown constraint value fails', () => {
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
        constraint: 'because-i-said-so',
        tuiSurface: 'absent' as const,
        rationale: 'invented constraint',
      },
    } as unknown as Record<string, RouteDisposition>;
    const result = checkDocRoutes(doc, { minRoutes: 1, routeDispositions: customDispositions });
    expect(result.passed).toBe(false);
    expect(result.invalidDispositions.some((d) => d.reason.includes('Invalid constraint value'))).toBe(true);
  });

  test('Mutation test: deleting exactly one real disposition names that route and fails', () => {
    const docPath = path.join(__dirname, 'fixtures', 'doc.pinned-1.17.13.4.json');
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

  test('F2: fails and names orphaned disposition key for non-existent route', () => {
    const doc = {
      paths: {
        '/api/health': {
          get: { summary: 'Health check' },
        },
      },
    };
    const customDispositions = {
      'POST /this/route/does-not-exist': {
        kind: 'not-session-scopable' as const,
        constraint: 'needs-audit' as const,
        rationale: 'Orphaned disposition rationale',
      },
    };

    const result = checkDocRoutes(doc, { minRoutes: 1, routeDispositions: customDispositions });
    expect(result.passed).toBe(false);
    expect(result.orphanedDispositions).toEqual(['POST /this/route/does-not-exist']);
    expect(result.error).toContain('orphaned disposition(s) found: POST /this/route/does-not-exist');
  });

  test('F2: real dispositions produce zero orphans against real /doc', () => {
    const docPath = path.join(__dirname, 'fixtures', 'doc.pinned-1.17.13.4.json');
    const doc = JSON.parse(fs.readFileSync(docPath, 'utf8'));
    const result = checkDocRoutes(doc);
    expect(result.orphanedDispositions).toEqual([]);
    expect(result.passed).toBe(true);
  });

  test('reports unrecognized, shadowed, invalid disposition, and orphaned disposition in a single run', () => {
    const doc = {
      paths: {
        '/unknown/route': { get: {} },
        '/session/status': { get: {} },
        '/global/dispose': { post: {} },
      },
    };
    const tableWithoutStatus = ROUTE_CLASSIFICATION_TABLE.filter(
      (r) => !(r.method === 'GET' && r.path === '/session/status')
    );
    const customDispositions = {
      'POST /orphaned/disposition': {
        kind: 'not-session-scopable' as const,
        constraint: 'needs-audit' as const,
        tuiSurface: 'absent' as const,
        rationale: 'Orphan',
      },
    };

    const result = checkDocRoutes(doc, {
      minRoutes: 1,
      routeClassificationTable: tableWithoutStatus,
      routeDispositions: customDispositions,
    });

    expect(result.passed).toBe(false);
    expect(result.unrecognized).toEqual([{ method: 'GET', path: '/unknown/route' }]);
    expect(result.shadowed).toEqual([
      { method: 'GET', path: '/session/status', shadowedBy: 'GET /session/{sessionID}' },
    ]);
    expect(result.invalidDispositions).toEqual([
      {
        method: 'GET',
        path: '/unknown/route',
        action: 'not-found-404',
        reason: 'Missing disposition for denial route',
      },
      {
        method: 'POST',
        path: '/global/dispose',
        action: 'deny-global-mutation',
        reason: 'Missing disposition for denial route',
      },
    ]);
    expect(result.orphanedDispositions).toEqual(['POST /orphaned/disposition']);
    expect(result.error).toContain('unrecognized route(s) found');
    expect(result.error).toContain('template-shadowed route(s) found');
    expect(result.error).toContain('denial route(s) missing or with invalid dispositions');
    expect(result.error).toContain('orphaned disposition(s) found');
  });

  test('Negative: not-session-scopable missing tuiSurface fails and names route', () => {
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
        constraint: 'needs-audit' as const,
        rationale: 'Disposes process',
      },
    };
    const result = checkDocRoutes(doc, { minRoutes: 1, routeDispositions: customDispositions });
    expect(result.passed).toBe(false);
    expect(result.invalidDispositions).toEqual([
      {
        method: 'POST',
        path: '/global/dispose',
        action: 'deny-global-mutation',
        reason: 'Kind "not-session-scopable" requires a tuiSurface field (\'absent\' | \'degrades\' | \'unverified\')',
      },
    ]);
  });

  test('Negative: invalid tuiSurface value fails', () => {
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
        constraint: 'needs-audit' as const,
        tuiSurface: 'invalid-surface' as any,
        rationale: 'Disposes process',
      },
    };
    const result = checkDocRoutes(doc, { minRoutes: 1, routeDispositions: customDispositions });
    expect(result.passed).toBe(false);
    expect(result.invalidDispositions[0].reason).toContain('Invalid tuiSurface value "invalid-surface"');
  });

  test('New superseded rows validate against classification table', () => {
    const newSupersededKeys = [
      'GET /mcp',
      'POST /mcp/{name}/connect',
      'POST /mcp/{name}/disconnect',
      'GET /global/event',
    ];
    for (const key of newSupersededKeys) {
      const disp = ROUTE_DISPOSITIONS[key];
      expect(disp).toBeDefined();
      expect(disp.kind).toBe('superseded');
      expect(disp.supersededBy).toBeDefined();

      const parts = disp.supersededBy!.trim().split(/\s+/);
      const sMethod = parts[0].toUpperCase();
      const sPath = parts.slice(1).join(' ');
      const sDispatch = dispatch(sMethod, sPath);
      expect(['route-session', 'create', 'fork', 'forward-anchor']).toContain(sDispatch.action);
    }
  });

  test('needs-mechanism set equals exactly the 9 expected D4 routes', () => {
    const docPath = path.join(__dirname, 'fixtures', 'doc.pinned-1.17.13.4.json');
    const doc = JSON.parse(fs.readFileSync(docPath, 'utf8'));
    const result = checkDocRoutes(doc);

    expect(result.needsMechanismKeys).toEqual(EXPECTED_NEEDS_MECHANISM_KEYS);
  });

  test('Census assertion on the pinned /doc fixture', () => {
    const docPath = path.join(__dirname, 'fixtures', 'doc.pinned-1.17.13.4.json');
    const doc = JSON.parse(fs.readFileSync(docPath, 'utf8'));
    const result = checkDocRoutes(doc);

    expect(result.dedupedDenialCount).toBe(70);
    expect(result.kindCensus).toEqual(EXPECTED_KIND_CENSUS);
  });

  describe('Check C — Response Media-Type Poison Invariant', () => {
    test('Check C: passes on the real committed fixture and mediaTypeCensus matches expected', () => {
      const docPath = path.join(__dirname, 'fixtures', 'doc.pinned-1.17.13.4.json');
      const doc = JSON.parse(fs.readFileSync(docPath, 'utf8'));
      const result = checkDocRoutes(doc);

      expect(result.passed).toBe(true);
      expect(result.htmlDeclaringRoutes).toEqual([]);
      expect(result.mediaTypeCensus).toEqual({
        'application/json': 512,
        'text/event-stream': 4,
        'text/x-diff; charset=utf-8': 1,
        'application/octet-stream': 1,
      });
    });

    test('Check C: fails on synthetic doc declaring text/html or text/html with parameters, passes on text/htmlx', () => {
      const htmlDoc = {
        paths: {
          '/test/html': {
            get: {
              responses: {
                '200': {
                  content: {
                    'text/html': {},
                  },
                },
              },
            },
          },
          '/test/html-param': {
            get: {
              responses: {
                '200': {
                  content: {
                    'text/html; charset=utf-8': {},
                  },
                },
              },
            },
          },
          '/test/htmlx': {
            get: {
              responses: {
                '200': {
                  content: {
                    'text/htmlx': {},
                  },
                },
              },
            },
          },
        },
      };

      const result = checkDocRoutes(htmlDoc, { minRoutes: 1, routeDispositions: {} });
      expect(result.passed).toBe(false);
      expect(result.htmlDeclaringRoutes).toHaveLength(2);
      expect(result.htmlDeclaringRoutes).toEqual([
        { method: 'GET', path: '/test/html', status: '200', mediaType: 'text/html' },
        { method: 'GET', path: '/test/html-param', status: '200', mediaType: 'text/html; charset=utf-8' },
      ]);
      expect(result.error).toContain('Check C failed');
      expect(result.mediaTypeCensus).toEqual({
        'text/html': 1,
        'text/html; charset=utf-8': 1,
        'text/htmlx': 1,
      });
    });
  });

  describe('Census Enforcement on Default Path', () => {
    test('DEFAULT path enforces census and fails on kind census mismatch', () => {
      const docPath = path.join(__dirname, 'fixtures', 'doc.pinned-1.17.13.4.json');
      const doc = JSON.parse(fs.readFileSync(docPath, 'utf8'));

      const result = checkDocRoutes(doc, {
        expectedKindCensus: { ...EXPECTED_KIND_CENSUS, 'needs-mechanism': 0 },
      });

      expect(result.passed).toBe(false);
      expect(result.error).toContain('Kind census mismatch');
      expect(result.error).toContain(
        `needs-mechanism: expected 0, got ${EXPECTED_KIND_CENSUS['needs-mechanism']}`
      );
    });

    test('F2: fails on inflated expectedKindCensus (shrink/grow direction test)', () => {
      const docPath = path.join(__dirname, 'fixtures', 'doc.pinned-1.17.13.4.json');
      const doc = JSON.parse(fs.readFileSync(docPath, 'utf8'));

      const result = checkDocRoutes(doc, {
        expectedKindCensus: { ...EXPECTED_KIND_CENSUS, 'needs-mechanism': 10 },
      });

      expect(result.passed).toBe(false);
      expect(result.error).toContain('Kind census mismatch');
      expect(result.error).toContain(
        `needs-mechanism: expected 10, got ${EXPECTED_KIND_CENSUS['needs-mechanism']}`
      );
    });

    test('DEFAULT path enforces the constraint census in both directions', () => {
      const docPath = path.join(__dirname, 'fixtures', 'doc.pinned-1.17.13.4.json');
      const doc = JSON.parse(fs.readFileSync(docPath, 'utf8'));

      const shrunk = checkDocRoutes(doc, {
        expectedConstraintCensus: { ...EXPECTED_CONSTRAINT_CENSUS, 'needs-audit': 0 },
      });
      expect(shrunk.passed).toBe(false);
      expect(shrunk.error).toContain('Constraint census mismatch');
      expect(shrunk.error).toContain('needs-audit: expected 0, got 26');

      const grown = checkDocRoutes(doc, {
        expectedConstraintCensus: { ...EXPECTED_CONSTRAINT_CENSUS, 'process-pinned-ram': 99 },
      });
      expect(grown.passed).toBe(false);
      expect(grown.error).toContain('process-pinned-ram: expected 99, got 9');
    });

    test('a compensating swap between constraints cannot pass silently', () => {
      // The failure mode the constraint census exists for: relabelling a row
      // from one bucket to another keeps the TOTAL identical, so any check that
      // only counted denials would stay green.
      const docPath = path.join(__dirname, 'fixtures', 'doc.pinned-1.17.13.4.json');
      const doc = JSON.parse(fs.readFileSync(docPath, 'utf8'));

      const swapped = checkDocRoutes(doc, {
        expectedConstraintCensus: {
          ...EXPECTED_CONSTRAINT_CENSUS,
          'process-pinned-ram': EXPECTED_CONSTRAINT_CENSUS['process-pinned-ram'] + 1,
          'needs-audit': EXPECTED_CONSTRAINT_CENSUS['needs-audit'] - 1,
        },
      });
      expect(swapped.passed).toBe(false);
      expect(swapped.error).toContain('Constraint census mismatch');
    });

    test('DEFAULT path enforces needs-mechanism keys and fails on key mismatch', () => {
      const docPath = path.join(__dirname, 'fixtures', 'doc.pinned-1.17.13.4.json');
      const doc = JSON.parse(fs.readFileSync(docPath, 'utf8'));

      const result = checkDocRoutes(doc, {
        expectedNeedsMechanismKeys: [],
      });

      expect(result.passed).toBe(false);
      expect(result.error).toContain('Needs-mechanism keys mismatch');
      expect(result.error).toContain('added [');
    });

    test('F2: fails on expectedNeedsMechanismKeys containing extra key not in real table', () => {
      const docPath = path.join(__dirname, 'fixtures', 'doc.pinned-1.17.13.4.json');
      const doc = JSON.parse(fs.readFileSync(docPath, 'utf8'));

      const result = checkDocRoutes(doc, {
        expectedNeedsMechanismKeys: [...EXPECTED_NEEDS_MECHANISM_KEYS, 'POST /extra/nonexistent/key'],
      });

      expect(result.passed).toBe(false);
      expect(result.error).toContain('Needs-mechanism keys mismatch');
      expect(result.error).toContain('removed [POST /extra/nonexistent/key]');
    });

    test('F3: doc with zero declared content fails media-type census floor', () => {
      const emptyDoc = {
        paths: {
          '/api/health': {
            get: { summary: 'No content declared' },
          },
        },
      };

      const result = checkDocRoutes(emptyDoc, { minRoutes: 1 });
      expect(result.passed).toBe(false);
      expect(result.error).toContain('Media-type census mismatch');
      expect(result.error).toContain('application/json: expected 512, got 0');
    });
  });

  describe('Check D — Octet-Stream Exemption Invariant', () => {
    test('Check D: passes on the real committed fixture', () => {
      const docPath = path.join(__dirname, 'fixtures', 'doc.pinned-1.17.13.4.json');
      const doc = JSON.parse(fs.readFileSync(docPath, 'utf8'));
      const result = checkDocRoutes(doc);

      expect(result.passed).toBe(true);
      expect(result.octetStreamRoutes).toEqual(['GET /api/fs/read/*']);
    });

    test('Check D: fails when doc declares octet-stream route not in HTML_GUARD_EXEMPT_ROUTES', () => {
      const doc = {
        paths: {
          '/api/fs/read/*': {
            get: {
              responses: { '200': { content: { 'application/octet-stream': {} } } },
            },
          },
          '/api/extra/raw': {
            get: {
              responses: { '200': { content: { 'application/octet-stream': {} } } },
            },
          },
        },
      };

      const result = checkDocRoutes(doc, {
        minRoutes: 1,
        htmlGuardExemptRoutes: ['GET /api/fs/read/*'],
      });
      expect(result.passed).toBe(false);
      expect(result.error).toContain('Check D failed');
      expect(result.error).toContain('declared application/octet-stream in /doc but not in HTML_GUARD_EXEMPT_ROUTES: [GET /api/extra/raw]');
    });

    test('Check D: fails when HTML_GUARD_EXEMPT_ROUTES has route not declared in doc', () => {
      const doc = {
        paths: {
          '/api/fs/read/*': {
            get: {
              responses: { '200': { content: { 'application/octet-stream': {} } } },
            },
          },
        },
      };

      const result = checkDocRoutes(doc, {
        minRoutes: 1,
        htmlGuardExemptRoutes: ['GET /api/fs/read/*', 'GET /stale/exemption/*'],
      });
      expect(result.passed).toBe(false);
      expect(result.error).toContain('Check D failed');
      expect(result.error).toContain('present in HTML_GUARD_EXEMPT_ROUTES but does not declare application/octet-stream in /doc: [GET /stale/exemption/*]');
    });
  });
});
