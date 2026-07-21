import { describe, test, expect } from 'vitest';
import { classify, dispatch } from '../src/dispatch.js';
import { ROUTE_CLASSIFICATION_TABLE } from '../src/routes.classification.js';

describe('Route Dispatcher', () => {
  // session-path:
  test('GET /session/ses_x -> session-path/route-session', () => {
    expect(classify('GET', '/session/ses_x')).toBe('session-path');
    expect(dispatch('GET', '/session/ses_x')).toEqual({
      class: 'session-path',
      action: 'route-session',
      recognized: true,
      allowedMethods: [],
    });
  });

  test('POST /session/ses_x/message -> session-path/route-session', () => {
    expect(classify('POST', '/session/ses_x/message')).toBe('session-path');
    expect(dispatch('POST', '/session/ses_x/message')).toEqual({
      class: 'session-path',
      action: 'route-session',
      recognized: true,
      allowedMethods: [],
    });
  });

  test('/api/session/ses_x/event -> session-path/route-session', () => {
    expect(classify('GET', '/api/session/ses_x/event')).toBe('session-path');
    expect(dispatch('GET', '/api/session/ses_x/event')).toEqual({
      class: 'session-path',
      action: 'route-session',
      recognized: true,
      allowedMethods: [],
    });
  });

  // precedence:
  test('GET /session/status -> global-ro/forward-anchor (NOT session-path)', () => {
    expect(classify('GET', '/session/status')).toBe('global-ro');
    expect(dispatch('GET', '/session/status')).toEqual({
      class: 'global-ro',
      action: 'forward-anchor',
      recognized: true,
      allowedMethods: [],
    });
  });

  test('GET /api/session/active -> global-ro/forward-anchor (NOT session-path)', () => {
    expect(classify('GET', '/api/session/active')).toBe('global-ro');
    expect(dispatch('GET', '/api/session/active')).toEqual({
      class: 'global-ro',
      action: 'forward-anchor',
      recognized: true,
      allowedMethods: [],
    });
  });

  // session-query:
  test('GET /event -> session-query/route-session', () => {
    expect(classify('GET', '/event')).toBe('session-query');
    expect(dispatch('GET', '/event')).toEqual({
      class: 'session-query',
      action: 'route-session',
      recognized: true,
      allowedMethods: [],
    });
  });

  test('GET /api/event -> session-query/route-session', () => {
    expect(classify('GET', '/api/event')).toBe('session-query');
    expect(dispatch('GET', '/api/event')).toEqual({
      class: 'session-query',
      action: 'route-session',
      recognized: true,
      allowedMethods: [],
    });
  });

  // create:
  test('POST /session -> create/create', () => {
    expect(classify('POST', '/session')).toBe('create');
    expect(dispatch('POST', '/session')).toEqual({
      class: 'create',
      action: 'create',
      recognized: true,
      allowedMethods: [],
    });
  });

  // pty:
  test('GET /pty -> pty/pty-501', () => {
    expect(classify('GET', '/pty')).toBe('pty');
    expect(dispatch('GET', '/pty')).toEqual({
      class: 'pty',
      action: 'pty-501',
      recognized: true,
      allowedMethods: [],
    });
  });

  test('GET /pty/pty_x/connect -> pty/pty-501', () => {
    expect(classify('GET', '/pty/pty_x/connect')).toBe('pty');
    expect(dispatch('GET', '/pty/pty_x/connect')).toEqual({
      class: 'pty',
      action: 'pty-501',
      recognized: true,
      allowedMethods: [],
    });
  });

  // global-sideeffect:
  test('POST /global/dispose -> global-sideeffect/deny-global-mutation', () => {
    expect(classify('POST', '/global/dispose')).toBe('global-sideeffect');
    expect(dispatch('POST', '/global/dispose')).toEqual({
      class: 'global-sideeffect',
      action: 'deny-global-mutation',
      recognized: true,
      allowedMethods: [],
    });
  });

  test('POST /global/upgrade -> global-sideeffect/deny-global-mutation', () => {
    expect(classify('POST', '/global/upgrade')).toBe('global-sideeffect');
    expect(dispatch('POST', '/global/upgrade')).toEqual({
      class: 'global-sideeffect',
      action: 'deny-global-mutation',
      recognized: true,
      allowedMethods: [],
    });
  });

  test('PATCH /global/config -> global-sideeffect/deny-global-mutation', () => {
    expect(classify('PATCH', '/global/config')).toBe('global-sideeffect');
    expect(dispatch('PATCH', '/global/config')).toEqual({
      class: 'global-sideeffect',
      action: 'deny-global-mutation',
      recognized: true,
      allowedMethods: ['GET'],
    });
  });

  test('POST /mcp -> global-sideeffect/deny-global-mutation', () => {
    expect(classify('POST', '/mcp')).toBe('global-sideeffect');
    expect(dispatch('POST', '/mcp')).toEqual({
      class: 'global-sideeffect',
      action: 'deny-global-mutation',
      recognized: true,
      allowedMethods: ['GET'],
    });
  });

  test('PATCH /config -> global-sideeffect/deny-global-mutation', () => {
    expect(classify('PATCH', '/config')).toBe('global-sideeffect');
    expect(dispatch('PATCH', '/config')).toEqual({
      class: 'global-sideeffect',
      action: 'deny-global-mutation',
      recognized: true,
      allowedMethods: ['GET'],
    });
  });

  // global-event:
  test('GET /global/event -> global-event/gone-410', () => {
    expect(classify('GET', '/global/event')).toBe('global-event');
    expect(dispatch('GET', '/global/event')).toEqual({
      class: 'global-event',
      action: 'gone-410',
      recognized: true,
      allowedMethods: [],
    });
  });

  // tui:
  test('GET /tui/control/next -> tui/tui-501', () => {
    expect(classify('GET', '/tui/control/next')).toBe('tui');
    expect(dispatch('GET', '/tui/control/next')).toEqual({
      class: 'tui',
      action: 'tui-501',
      recognized: true,
      allowedMethods: [],
    });
  });

  test('POST /tui/append-prompt -> tui/tui-501', () => {
    expect(classify('POST', '/tui/append-prompt')).toBe('tui');
    expect(dispatch('POST', '/tui/append-prompt')).toEqual({
      class: 'tui',
      action: 'tui-501',
      recognized: true,
      allowedMethods: [],
    });
  });

  test('POST /tui/control/response -> tui/tui-501', () => {
    expect(classify('POST', '/tui/control/response')).toBe('tui');
    expect(dispatch('POST', '/tui/control/response')).toEqual({
      class: 'tui',
      action: 'tui-501',
      recognized: true,
      allowedMethods: [],
    });
  });

  // global-ro:
  test('GET /global/health -> global-ro/forward-anchor', () => {
    expect(classify('GET', '/global/health')).toBe('global-ro');
    expect(dispatch('GET', '/global/health')).toEqual({
      class: 'global-ro',
      action: 'forward-anchor',
      recognized: true,
      allowedMethods: [],
    });
  });

  test('GET /doc -> global-ro/forward-anchor', () => {
    expect(classify('GET', '/doc')).toBe('global-ro');
    expect(dispatch('GET', '/doc')).toEqual({
      class: 'global-ro',
      action: 'forward-anchor',
      recognized: true,
      allowedMethods: [],
    });
  });

  // unrecognized:
  test('GET /nonexistent -> unrecognized/not-found-404, recognized:false', () => {
    expect(classify('GET', '/nonexistent')).toBe('unrecognized');
    expect(dispatch('GET', '/nonexistent')).toEqual({
      class: 'unrecognized',
      action: 'not-found-404',
      recognized: false,
      allowedMethods: [],
    });
  });

  test('GET / -> web-ui/not-found-404, recognized:true', () => {
    expect(classify('GET', '/')).toBe('web-ui');
    expect(dispatch('GET', '/')).toEqual({
      class: 'web-ui',
      action: 'not-found-404',
      recognized: true,
      allowedMethods: [],
    });
  });

  test('GET /_build/app.js -> unrecognized/not-found-404, recognized:false', () => {
    expect(classify('GET', '/_build/app.js')).toBe('unrecognized');
    expect(dispatch('GET', '/_build/app.js')).toEqual({
      class: 'unrecognized',
      action: 'not-found-404',
      recognized: false,
      allowedMethods: [],
    });
  });

  test('DELETE /global/health -> unrecognized/not-found-404, recognized:false', () => {
    expect(classify('DELETE', '/global/health')).toBe('unrecognized');
    expect(dispatch('DELETE', '/global/health')).toEqual({
      class: 'unrecognized',
      action: 'not-found-404',
      recognized: false,
      allowedMethods: [],
    });
  });

  // trailing-slash normalization:
  test('trailing slash normalization', () => {
    expect(classify('GET', '/session/ses_x/')).toBe('session-path');
    expect(classify('GET', '/')).toBe('web-ui');
    expect(classify('GET', '')).toBe('unrecognized');
  });

  // a templated multi-param route:
  test('templated multi-param route', () => {
    expect(classify('DELETE', '/session/ses_x/message/msg_y/part/part_z')).toBe('session-path');
  });

  // module-load integrity: every entry in ROUTE_CLASSIFICATION_TABLE classifies to ITS OWN class when you feed it a concretized path
  test('module-load integrity: table coverage', () => {
    for (const entry of ROUTE_CLASSIFICATION_TABLE) {
      // Concretize path: replace any {token} with a dummy value e.g. "ses_x" or "x" or "123".
      // Let's replace any {tokenID} or {token} with 'dummy_id_123'.
      // Also, strip query suffix just in case.
      let concretePath = entry.path.split('?')[0];
      // Strip trailing slash first (except root)
      if (concretePath.endsWith('/') && concretePath !== '/') {
        concretePath = concretePath.slice(0, -1);
      }
      concretePath = concretePath.replace(/\{[^}]+\}/g, 'dummy_id_123');
      // Replace * wildcard with a dummy subpath if it exists
      concretePath = concretePath.replace(/\*/g, 'sub/path/to/file.txt');

      const cls = classify(entry.method, concretePath);
      expect(cls).toBe(entry.class);
    }
  });

  // HEAD fallback to GET:
  test('HEAD requests fall back to GET classification', () => {
    expect(classify('HEAD', '/global/health')).toBe('global-ro');
    expect(dispatch('HEAD', '/global/health')).toEqual({
      class: 'global-ro',
      action: 'forward-anchor',
      recognized: true,
      allowedMethods: [],
    });

    expect(classify('HEAD', '/session/ses_x')).toBe('session-path');
    expect(dispatch('HEAD', '/session/ses_x')).toEqual({
      class: 'session-path',
      action: 'route-session',
      recognized: true,
      allowedMethods: [],
    });

    expect(classify('HEAD', '/nonexistent')).toBe('unrecognized');
    expect(dispatch('HEAD', '/nonexistent')).toEqual({
      class: 'unrecognized',
      action: 'not-found-404',
      recognized: false,
      allowedMethods: [],
    });
  });
});
