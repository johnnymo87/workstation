/**
 * Route Denial Dispositions for opencode-frontdoor.
 *
 * Check B invariant: Every route in `/doc` that frontdoor denies MUST carry
 * an explicit, structured disposition explaining why the denial is architecturally
 * correct, superseded by a session-scoped route, or a known gap.
 */

export type DispositionKind =
  | 'by-design-501'         // class-level blanket: pty / tui / per-process-ro
  | 'not-session-scopable'  // global mutation with no session context; denial is architecturally correct
  | 'superseded'            // a forwarded session-scoped route serves this need
  | 'needs-mechanism'       // D4: needs anchor-pin or broadcast that the door lacks
  | 'accepted-gap';         // known gap, consciously accepted

export type TuiSurface = 'absent' | 'degrades' | 'unverified';

/**
 * Membership in the TUI's documented SDK surface list at
 * `docs/plans/2026-07-24-phase9-door-route-allowlist.md:17`.
 *
 * - `absent`: corresponding SDK call is NOT in that documented list.
 * - `degrades`: in the list AND Phase 9 audit at `2026-07-24-phase9-door-route-allowlist.md:35`
 *   recorded it as denied-by-design with graceful degradation.
 * - `unverified`: in the list, but through-door consequence was never audited.
 */
export interface RouteDisposition {
  kind: DispositionKind;
  rationale: string;
  supersededBy?: string;
  bead?: string;
  tuiSurface?: TuiSurface;
}

export const CLASS_DISPOSITIONS: Record<string, RouteDisposition> = {
  pty: {
    kind: 'by-design-501',
    rationale: 'PTY routes require stateful local terminal streams (Task 5.1); frontdoor returns 501 by design.',
  },
  tui: {
    kind: 'by-design-501',
    rationale: 'TUI control routes require process-local UI state (Task 5.1); frontdoor returns 501 by design.',
  },
};

export const ROUTE_DISPOSITIONS: Record<string, RouteDisposition> = {
  // D4 rows (workstation-mlve.11 / needs-mechanism):
  'PUT /auth/{providerID}': {
    kind: 'needs-mechanism',
    bead: 'workstation-mlve.11',
    rationale: 'Provider auth state mutation requires anchor-pinning or broadcast mechanism not yet implemented in door.',
  },
  'DELETE /auth/{providerID}': {
    kind: 'needs-mechanism',
    bead: 'workstation-mlve.11',
    rationale: 'Provider auth removal requires anchor-pinning or broadcast mechanism not yet implemented in door.',
  },
  'POST /provider/{providerID}/oauth/authorize': {
    kind: 'needs-mechanism',
    bead: 'workstation-mlve.11',
    rationale: 'Provider OAuth authorization flow requires anchor-pinning or broadcast mechanism not yet implemented in door.',
  },
  'POST /provider/{providerID}/oauth/callback': {
    kind: 'needs-mechanism',
    bead: 'workstation-mlve.11',
    rationale: 'Provider OAuth callback flow requires anchor-pinning or broadcast mechanism not yet implemented in door.',
  },
  'POST /mcp/{name}/auth': {
    kind: 'needs-mechanism',
    bead: 'workstation-mlve.11',
    rationale: 'MCP authentication flow requires anchor-pinning or broadcast mechanism not yet implemented in door.',
  },
  'DELETE /mcp/{name}/auth': {
    kind: 'needs-mechanism',
    bead: 'workstation-mlve.11',
    rationale: 'MCP authentication removal requires anchor-pinning or broadcast mechanism not yet implemented in door.',
  },
  'POST /mcp/{name}/auth/authenticate': {
    kind: 'needs-mechanism',
    bead: 'workstation-mlve.11',
    rationale: 'MCP authentication execution requires anchor-pinning or broadcast mechanism not yet implemented in door.',
  },
  'POST /mcp/{name}/auth/callback': {
    kind: 'needs-mechanism',
    bead: 'workstation-mlve.11',
    rationale: 'MCP authentication callback requires anchor-pinning or broadcast mechanism not yet implemented in door.',
  },
  'POST /instance/dispose': {
    kind: 'needs-mechanism',
    bead: 'workstation-mlve.11',
    rationale: 'Process instance disposal requires broadcast across all active serve processes.',
  },

  // Superseded rows:
  'POST /permission/{requestID}/reply': {
    kind: 'superseded',
    supersededBy: 'POST /api/session/{sessionID}/permission/{requestID}/reply',
    rationale: 'Permission request replies are session-scoped and routed via POST /api/session/{sessionID}/permission/{requestID}/reply.',
  },
  'POST /question/{requestID}/reply': {
    kind: 'superseded',
    supersededBy: 'POST /api/session/{sessionID}/question/{requestID}/reply',
    rationale: 'Question replies are session-scoped and routed via POST /api/session/{sessionID}/question/{requestID}/reply.',
  },
  'POST /question/{requestID}/reject': {
    kind: 'superseded',
    supersededBy: 'POST /api/session/{sessionID}/question/{requestID}/reject',
    rationale: 'Question rejections are session-scoped and routed via POST /api/session/{sessionID}/question/{requestID}/reject.',
  },
  'GET /global/event': {
    kind: 'superseded',
    supersededBy: 'GET /event',
    rationale: 'Deprecated global event stream (410 Gone); clients must use session-scoped event stream GET /event?session_ids=.',
  },
  'GET /mcp': {
    kind: 'superseded',
    supersededBy: 'GET /session/{sessionID}/mcp',
    rationale: 'Per-process MCP status stream cannot represent multi-serve pool state (F3); superseded by session-scoped status GET /session/{sessionID}/mcp.',
  },
  // Solved in Phase 10 via session-scoped route POST /session/{sessionID}/mcp/{name}/connect; deliberately excluded from D4.
  'POST /mcp/{name}/connect': {
    kind: 'superseded',
    supersededBy: 'POST /session/{sessionID}/mcp/{name}/connect',
    rationale: 'MCP connection management is superseded by session-scoped POST /session/{sessionID}/mcp/{name}/connect. Phase 10 solved this via session-scoped routes; deliberately excluded from D4.',
  },
  // Solved in Phase 10 via session-scoped route POST /session/{sessionID}/mcp/{name}/disconnect; deliberately excluded from D4.
  'POST /mcp/{name}/disconnect': {
    kind: 'superseded',
    supersededBy: 'POST /session/{sessionID}/mcp/{name}/disconnect',
    rationale: 'MCP disconnection management is superseded by session-scoped POST /session/{sessionID}/mcp/{name}/disconnect. Phase 10 solved this via session-scoped routes; deliberately excluded from D4.',
  },

  // Corrected 2026-07-25; AUDITED and resolved 2026-07-26 (workstation-mlve.11).
  'POST /sync/start': {
    kind: 'not-session-scopable',
    tuiSurface: 'degrades',
    rationale:
      'Process-global workspace sync engine start; the door cannot session-scope it. D4 audit: the only callers are tui/src/context/sdk.tsx:99 (SSE) and :127 (RPC), BOTH gated on Flag.OPENCODE_EXPERIMENTAL_WORKSPACES (sdk.tsx:96/:124) and BOTH written `await sdk.sync.start().catch(() => {})`, so the door 403 is swallowed. The flag is off here: enabledByExperimental falls back to the EXACT var OPENCODE_EXPERIMENTAL (core/src/flag/flag.ts:11-13), and neither it nor OPENCODE_EXPERIMENTAL_WORKSPACES is set anywhere in the workstation repo. Consequence: workspace sync loops never start; nothing else is affected. Resolved by verification, not mechanism.',
  },

  // Individual global mutation / non-session-scopable rows (32 total: 11 degrades, 21 absent; plus POST /sync/start above = 12 degrades overall).
  // The 5 formerly-'unverified' rows were audited 2026-07-26 under workstation-mlve.11 and are now 'degrades' with the evidence inline.
  'POST /log': {
    kind: 'not-session-scopable',
    tuiSurface: 'absent',
    rationale: 'Process-global logging endpoint targets single process stdout/file, not a session.',
  },
  'POST /experimental/control-plane/move-session': {
    kind: 'not-session-scopable',
    tuiSurface: 'degrades',
    rationale: 'Internal control-plane session migration mutation operates across processes without session-scoped door route wrapper. In TUI SDK surface list and recorded as denied-by-design with graceful degradation (2026-07-24-phase9-door-route-allowlist.md:35).',
  },
  'PATCH /global/config': {
    kind: 'not-session-scopable',
    tuiSurface: 'absent',
    rationale: 'Modifies process-level global configuration; no session context.',
  },
  'POST /global/dispose': {
    kind: 'not-session-scopable',
    tuiSurface: 'absent',
    rationale: 'Disposes global process runtime state; no session context.',
  },
  'POST /global/upgrade': {
    kind: 'not-session-scopable',
    tuiSurface: 'degrades',
    rationale: 'Triggers process-global application binary upgrade; no session context. In TUI SDK surface list and recorded as denied-by-design with graceful degradation (2026-07-24-phase9-door-route-allowlist.md:35).',
  },
  'PATCH /config': {
    kind: 'not-session-scopable',
    tuiSurface: 'absent',
    rationale: 'Mutates global server configuration settings; no session context.',
  },
  'POST /experimental/console/switch': {
    kind: 'not-session-scopable',
    tuiSurface: 'degrades',
    bead: 'workstation-e4tp',
    rationale:
      'Switches global console organization context for process; no session context. D4 audit (workstation-mlve.11): called from tui/src/component/dialog-console-org.tsx:98. Degrades SILENTLY, not gracefully — the call passes `{ throwOnError: true }` with no try/catch, and DialogSelect discards the returned promise (ui/dialog-select.tsx:34/71), so the door 403 becomes an UNHANDLED REJECTION. It does not crash today only because @opentui/core registers a process-level unhandledRejection handler and opencode sets openConsoleOnError:false (tui/src/app.tsx:196), so the error lands in an invisible console buffer and the dialog silently does nothing. Bun exits 1 on an unhandled rejection with no handler, so this is one dependency bump from a TUI crash. NOTE this is the ONLY row of the six D4-audited rows that is NOT gated by the experimental flag — it needs only a Console login with 2+ switchable orgs. Door behaviour is correct; the hazard is client-side and tracked as workstation-e4tp.',
  },
  'POST /experimental/worktree': {
    kind: 'not-session-scopable',
    tuiSurface: 'absent',
    rationale: 'Creates process-global git worktree; no session context.',
  },
  'DELETE /experimental/worktree': {
    kind: 'not-session-scopable',
    tuiSurface: 'absent',
    rationale: 'Deletes process-global git worktree; no session context.',
  },
  'POST /experimental/worktree/reset': {
    kind: 'not-session-scopable',
    tuiSurface: 'absent',
    rationale: 'Resets process-global git worktree state; no session context.',
  },
  'POST /vcs/apply': {
    kind: 'not-session-scopable',
    tuiSurface: 'absent',
    rationale: 'Applies VCS patch to process working directory; no session context.',
  },
  'POST /mcp': {
    kind: 'not-session-scopable',
    tuiSurface: 'absent',
    rationale: 'Adds server to process-global MCP configuration; no session context.',
  },
  'POST /project/git/init': {
    kind: 'not-session-scopable',
    tuiSurface: 'absent',
    rationale: 'Initializes git repository in process working directory; no session context.',
  },
  'PATCH /project/{projectID}': {
    kind: 'not-session-scopable',
    tuiSurface: 'absent',
    rationale: 'Modifies process project settings; no session context.',
  },
  'POST /experimental/project/{projectID}/copy/generate-name': {
    kind: 'not-session-scopable',
    tuiSurface: 'degrades',
    rationale: 'Generates project copy name globally; no session context. In TUI SDK surface list and recorded as denied-by-design with graceful degradation (2026-07-24-phase9-door-route-allowlist.md:35).',
  },
  'POST /sync/replay': {
    kind: 'not-session-scopable',
    tuiSurface: 'absent',
    rationale: 'Replays sync engine operations process-globally; no session context.',
  },
  'POST /sync/steal': {
    kind: 'not-session-scopable',
    tuiSurface: 'absent',
    rationale: 'Steals sync engine lease process-globally; no session context.',
  },
  'POST /sync/history': {
    kind: 'not-session-scopable',
    tuiSurface: 'absent',
    rationale: 'Fetches sync history for process; no session context.',
  },
  'POST /experimental/workspace': {
    kind: 'not-session-scopable',
    tuiSurface: 'degrades',
    rationale:
      'Creates experimental workspace in process directory; no session context. D4 audit: callers are tui/src/component/prompt/workspace.tsx:31 and dialog-session-list.tsx:110, both behind Flag.OPENCODE_EXPERIMENTAL_WORKSPACES (prompt/index.tsx:535), which is OFF here. Both call sites try/catch AND check result.error, surfacing a toast ("Creating workspace failed") carrying the door message. This is the one row of the six that yields 405 + Allow: GET rather than 403, because GET /experimental/workspace is a sibling global-ro (routes.classification.ts:146). Graceful; resolved by verification, not mechanism.',
  },
  'POST /experimental/workspace/sync-list': {
    kind: 'not-session-scopable',
    tuiSurface: 'degrades',
    rationale:
      'Syncs workspace list for process; no session context. D4 audit: callers are dialog-workspace-create.tsx:81 and dialog-workspace-list.tsx:91, both behind Flag.OPENCODE_EXPERIMENTAL_WORKSPACES (OFF here), both written `.catch(() => undefined)` with the return value discarded — fire-and-forget. Consequence of the door 403: adapter-discovered workspaces are silently not registered. Graceful; resolved by verification, not mechanism.',
  },
  'DELETE /experimental/workspace/{id}': {
    kind: 'not-session-scopable',
    tuiSurface: 'degrades',
    rationale:
      'Deletes experimental workspace; no session context. D4 audit: callers are dialog-workspace-list.tsx:67 (.catch -> result.error -> toast) and dialog-session-list.tsx:153 (no try/catch, checks result.error only — safe because the generated SDK defaults throwOnError to false, v2/gen/client/client.gen.ts:222-232). Both behind Flag.OPENCODE_EXPERIMENTAL_WORKSPACES (OFF here; the list command is hidden without it, app.tsx:609). Toast "Failed to delete workspace". Graceful; resolved by verification, not mechanism.',
  },
  'POST /experimental/workspace/warp': {
    kind: 'not-session-scopable',
    tuiSurface: 'degrades',
    rationale:
      'Warps workspace state process-globally; no session context. D4 audit: caller is dialog-workspace-create.tsx:102 (warpWorkspaceSession), behind Flag.OPENCODE_EXPERIMENTAL_WORKSPACES (OFF here, prompt/index.tsx:535). try/catch -> toast "Failed to warp session", returns false. Graceful; resolved by verification, not mechanism.',
  },
  'POST /integration/{integrationID}/connect/key': {
    kind: 'not-session-scopable',
    tuiSurface: 'absent',
    rationale: 'Connects integration key globally for process; no session context.',
  },
  'POST /integration/{integrationID}/connect/oauth': {
    kind: 'not-session-scopable',
    tuiSurface: 'absent',
    rationale: 'Initiates integration OAuth connection process-globally; no session context.',
  },
  'DELETE /integration/attempt/{attemptID}': {
    kind: 'not-session-scopable',
    tuiSurface: 'absent',
    rationale: 'Deletes integration OAuth attempt state from process; no session context.',
  },
  'POST /integration/attempt/{attemptID}/complete': {
    kind: 'not-session-scopable',
    tuiSurface: 'absent',
    rationale: 'Completes integration OAuth attempt in process; no session context.',
  },
  'PATCH /credential/{credentialID}': {
    kind: 'not-session-scopable',
    tuiSurface: 'absent',
    rationale: 'Updates process credential store; no session context.',
  },
  'DELETE /credential/{credentialID}': {
    kind: 'not-session-scopable',
    tuiSurface: 'absent',
    rationale: 'Removes credential from process credential store; no session context.',
  },
  'DELETE /permission/saved/{id}': {
    kind: 'not-session-scopable',
    tuiSurface: 'absent',
    rationale: 'Deletes process-global saved permission entry; no session context.',
  },
  'POST /experimental/project/{projectID}/copy': {
    kind: 'not-session-scopable',
    tuiSurface: 'degrades',
    rationale: 'Initiates project copy process-globally; no session context. In TUI SDK surface list and recorded as denied-by-design with graceful degradation (2026-07-24-phase9-door-route-allowlist.md:35).',
  },
  'DELETE /experimental/project/{projectID}/copy': {
    kind: 'not-session-scopable',
    tuiSurface: 'degrades',
    rationale: 'Cancels project copy process-globally; no session context. In TUI SDK surface list and recorded as denied-by-design with graceful degradation (2026-07-24-phase9-door-route-allowlist.md:35).',
  },
  'POST /experimental/project/{projectID}/copy/refresh': {
    kind: 'not-session-scopable',
    tuiSurface: 'degrades',
    rationale: 'Refreshes project copy status process-globally; no session context. In TUI SDK surface list and recorded as denied-by-design with graceful degradation (2026-07-24-phase9-door-route-allowlist.md:35).',
  },
};

export function getRouteDisposition(
  method: string,
  pathname: string,
  routeClass: string,
  customRouteDispositions?: Record<string, RouteDisposition>,
  customClassDispositions?: Record<string, RouteDisposition>
): RouteDisposition | undefined {
  const routeDispMap = customRouteDispositions ?? ROUTE_DISPOSITIONS;
  const classDispMap = customClassDispositions ?? CLASS_DISPOSITIONS;

  // 1. Class-level disposition
  if (classDispMap[routeClass]) {
    return classDispMap[routeClass];
  }

  const upperMethod = method.toUpperCase();
  let normPath = pathname.split('?')[0];
  if (normPath.endsWith('/') && normPath !== '/') {
    normPath = normPath.slice(0, -1);
  }

  // 2. Exact match in ROUTE_DISPOSITIONS
  const exactKey = `${upperMethod} ${normPath}`;
  if (routeDispMap[exactKey]) {
    return routeDispMap[exactKey];
  }

  // 3. `/api/*` mirror fallback to bare route
  if (normPath.startsWith('/api/')) {
    const barePath = normPath.slice(4);
    const bareKey = `${upperMethod} ${barePath}`;
    if (routeDispMap[bareKey]) {
      return routeDispMap[bareKey];
    }
  }

  return undefined;
}
