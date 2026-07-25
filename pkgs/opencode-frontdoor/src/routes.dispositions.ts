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

export interface RouteDisposition {
  kind: DispositionKind;
  rationale: string;
  supersededBy?: string;
  bead?: string;
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
  'POST /mcp/{name}/connect': {
    kind: 'needs-mechanism',
    bead: 'workstation-mlve.11',
    rationale: 'Global MCP connection management requires anchor-pinning or broadcast mechanism not yet implemented in door.',
  },
  'POST /mcp/{name}/disconnect': {
    kind: 'needs-mechanism',
    bead: 'workstation-mlve.11',
    rationale: 'Global MCP disconnection management requires anchor-pinning or broadcast mechanism not yet implemented in door.',
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
  'POST /sync/start': {
    kind: 'superseded',
    supersededBy: 'POST /session/{sessionID}/init',
    rationale: 'Session sync and initialization is performed via session-scoped POST /session/{sessionID}/init.',
  },

  // Carried-across recorded reasoning rows:
  'GET /global/event': {
    kind: 'not-session-scopable',
    rationale: 'Deprecated global event stream (410 Gone); clients must use session-scoped event stream GET /event?session_ids=.',
  },
  'GET /mcp': {
    kind: 'not-session-scopable',
    rationale: 'Per-process MCP status stream cannot represent multi-serve pool state (F3); denied as 501.',
  },

  // Individual global mutation / non-session-scopable rows:
  'POST /log': {
    kind: 'not-session-scopable',
    rationale: 'Process-global logging endpoint targets single process stdout/file, not a session.',
  },
  'POST /experimental/control-plane/move-session': {
    kind: 'not-session-scopable',
    rationale: 'Internal control-plane session migration mutation operates across processes without session-scoped door route wrapper.',
  },
  'PATCH /global/config': {
    kind: 'not-session-scopable',
    rationale: 'Modifies process-level global configuration; no session context.',
  },
  'POST /global/dispose': {
    kind: 'not-session-scopable',
    rationale: 'Disposes global process runtime state; no session context.',
  },
  'POST /global/upgrade': {
    kind: 'not-session-scopable',
    rationale: 'Triggers process-global application binary upgrade; no session context.',
  },
  'PATCH /config': {
    kind: 'not-session-scopable',
    rationale: 'Mutates global server configuration settings; no session context.',
  },
  'POST /experimental/console/switch': {
    kind: 'not-session-scopable',
    rationale: 'Switches global console organization context for process; no session context.',
  },
  'POST /experimental/worktree': {
    kind: 'not-session-scopable',
    rationale: 'Creates process-global git worktree; no session context.',
  },
  'DELETE /experimental/worktree': {
    kind: 'not-session-scopable',
    rationale: 'Deletes process-global git worktree; no session context.',
  },
  'POST /experimental/worktree/reset': {
    kind: 'not-session-scopable',
    rationale: 'Resets process-global git worktree state; no session context.',
  },
  'POST /vcs/apply': {
    kind: 'not-session-scopable',
    rationale: 'Applies VCS patch to process working directory; no session context.',
  },
  'POST /mcp': {
    kind: 'not-session-scopable',
    rationale: 'Adds server to process-global MCP configuration; no session context.',
  },
  'POST /project/git/init': {
    kind: 'not-session-scopable',
    rationale: 'Initializes git repository in process working directory; no session context.',
  },
  'PATCH /project/{projectID}': {
    kind: 'not-session-scopable',
    rationale: 'Modifies process project settings; no session context.',
  },
  'POST /experimental/project/{projectID}/copy/generate-name': {
    kind: 'not-session-scopable',
    rationale: 'Generates project copy name globally; no session context.',
  },
  'POST /sync/replay': {
    kind: 'not-session-scopable',
    rationale: 'Replays sync engine operations process-globally; no session context.',
  },
  'POST /sync/steal': {
    kind: 'not-session-scopable',
    rationale: 'Steals sync engine lease process-globally; no session context.',
  },
  'POST /sync/history': {
    kind: 'not-session-scopable',
    rationale: 'Fetches sync history for process; no session context.',
  },
  'POST /experimental/workspace': {
    kind: 'not-session-scopable',
    rationale: 'Creates experimental workspace in process directory; no session context.',
  },
  'POST /experimental/workspace/sync-list': {
    kind: 'not-session-scopable',
    rationale: 'Syncs workspace list for process; no session context.',
  },
  'DELETE /experimental/workspace/{id}': {
    kind: 'not-session-scopable',
    rationale: 'Deletes experimental workspace; no session context.',
  },
  'POST /experimental/workspace/warp': {
    kind: 'not-session-scopable',
    rationale: 'Warps workspace state process-globally; no session context.',
  },
  'POST /integration/{integrationID}/connect/key': {
    kind: 'not-session-scopable',
    rationale: 'Connects integration key globally for process; no session context.',
  },
  'POST /integration/{integrationID}/connect/oauth': {
    kind: 'not-session-scopable',
    rationale: 'Initiates integration OAuth connection process-globally; no session context.',
  },
  'DELETE /integration/attempt/{attemptID}': {
    kind: 'not-session-scopable',
    rationale: 'Deletes integration OAuth attempt state from process; no session context.',
  },
  'POST /integration/attempt/{attemptID}/complete': {
    kind: 'not-session-scopable',
    rationale: 'Completes integration OAuth attempt in process; no session context.',
  },
  'PATCH /credential/{credentialID}': {
    kind: 'not-session-scopable',
    rationale: 'Updates process credential store; no session context.',
  },
  'DELETE /credential/{credentialID}': {
    kind: 'not-session-scopable',
    rationale: 'Removes credential from process credential store; no session context.',
  },
  'DELETE /permission/saved/{id}': {
    kind: 'not-session-scopable',
    rationale: 'Deletes process-global saved permission entry; no session context.',
  },
  'POST /experimental/project/{projectID}/copy': {
    kind: 'not-session-scopable',
    rationale: 'Initiates project copy process-globally; no session context.',
  },
  'DELETE /experimental/project/{projectID}/copy': {
    kind: 'not-session-scopable',
    rationale: 'Cancels project copy process-globally; no session context.',
  },
  'POST /experimental/project/{projectID}/copy/refresh': {
    kind: 'not-session-scopable',
    rationale: 'Refreshes project copy status process-globally; no session context.',
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
