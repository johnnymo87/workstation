/**
 * Route Classification Table for opencode-frontdoor.
 *
 * --- RECONCILIATION ---
 * - Snapshot routes (from http://127.0.0.1:4096/doc): 188
 * - Exclusions: 0 (The web-ui served at "/" and its static assets are not declared in `/doc`, so they are excluded from the snapshot)
 * - Patch-only routes: 3 (GET /event?session_ids= and GET /api/event?session_ids=, source: event-session-scope.patch; plus GET /doc, OpenAPI spec added manually (FABLE-W6))
 * - Total table entries: 191
 *
 * --- DUAL SURFACE ---
 * This API exposes a dual surface: a bare surface (e.g. /session/...) and its `/api/*` mirror.
 * Both paths are fully mapped and classified.
 *
 * --- PATCH SOURCE ---
 * - `session_ids` is patch-only:
 *   Source: ~/projects/opencode-patched/patches/event-session-scope.patch
 */

export type RouteClass =
  | "session-path"
  | "session-query"
  | "create"
  | "fork"
  | "pty"
  | "global-ro"
  | "global-sideeffect"
  | "global-event"
  /*
   * NEW-D Scope Statement:
   * The web UI (`packages/app`, a PTY client served at `/`) is UNSUPPORTED through the front door;
   * `/` + static assets are undeclared in `/doc` and intentionally fall through to `unrecognized` -> 404-loud
   * (and PTY -> 501, per Task 5.1). Use direct serve ports to access the web UI.
   * The `web-ui` RouteClass is retained here defensively to document intent and preserve the
   * loud-404 invariant in the dispatcher (warn on `web-ui` matching), even though no ROUTE_CLASSIFICATION_TABLE
   * entry currently maps to it.
   */
  | "web-ui"
  | "tui"
  | "unrecognized";

export interface RouteEntry {
  method: string;
  path: string;
  class: RouteClass;
  note?: string;
}

export const ROUTE_CLASSIFICATION_TABLE: RouteEntry[] = [
  { method: "GET", path: "/agent", class: "global-ro" },
  { method: "GET", path: "/api/agent", class: "global-ro" },
  { method: "GET", path: "/api/command", class: "global-ro" },
  { method: "DELETE", path: "/api/credential/{credentialID}", class: "global-sideeffect" },
  { method: "PATCH", path: "/api/credential/{credentialID}", class: "global-sideeffect" },
  { method: "GET", path: "/api/event", class: "session-query", note: "Can receive session_ids query param (source: event-session-scope.patch)" },
  { method: "GET", path: "/api/event?session_ids=", class: "session-query", note: "patch-only session-query (source: event-session-scope.patch)" },
  { method: "GET", path: "/api/fs/find", class: "global-ro" },
  { method: "GET", path: "/api/fs/list", class: "global-ro" },
  { method: "GET", path: "/api/fs/read/*", class: "global-ro" },
  { method: "GET", path: "/api/health", class: "global-ro" },
  { method: "GET", path: "/api/integration", class: "global-ro" },
  { method: "GET", path: "/api/integration/{integrationID}", class: "global-ro" },
  { method: "POST", path: "/api/integration/{integrationID}/connect/key", class: "global-sideeffect" },
  { method: "POST", path: "/api/integration/{integrationID}/connect/oauth", class: "global-sideeffect" },
  { method: "DELETE", path: "/api/integration/attempt/{attemptID}", class: "global-sideeffect" },
  { method: "GET", path: "/api/integration/attempt/{attemptID}", class: "global-ro" },
  { method: "POST", path: "/api/integration/attempt/{attemptID}/complete", class: "global-sideeffect" },
  { method: "GET", path: "/api/location", class: "global-ro" },
  { method: "GET", path: "/api/model", class: "global-ro" },
  { method: "GET", path: "/api/permission/request", class: "global-ro" },
  { method: "GET", path: "/api/permission/saved", class: "global-ro" },
  { method: "DELETE", path: "/api/permission/saved/{id}", class: "global-sideeffect" },
  { method: "GET", path: "/api/provider", class: "global-ro" },
  { method: "GET", path: "/api/provider/{providerID}", class: "global-ro" },
  { method: "GET", path: "/api/pty", class: "pty" },
  { method: "POST", path: "/api/pty", class: "pty" },
  { method: "DELETE", path: "/api/pty/{ptyID}", class: "pty" },
  { method: "GET", path: "/api/pty/{ptyID}", class: "pty" },
  { method: "PUT", path: "/api/pty/{ptyID}", class: "pty" },
  { method: "GET", path: "/api/pty/{ptyID}/connect", class: "pty" },
  { method: "POST", path: "/api/pty/{ptyID}/connect-token", class: "pty" },
  { method: "GET", path: "/api/question/request", class: "global-ro" },
  { method: "GET", path: "/api/reference", class: "global-ro" },
  { method: "GET", path: "/api/session", class: "global-ro" },
  { method: "POST", path: "/api/session", class: "create" },
  { method: "GET", path: "/api/session/{sessionID}", class: "session-path" },
  { method: "POST", path: "/api/session/{sessionID}/agent", class: "session-path" },
  { method: "POST", path: "/api/session/{sessionID}/compact", class: "session-path" },
  { method: "GET", path: "/api/session/{sessionID}/context", class: "session-path" },
  { method: "GET", path: "/api/session/{sessionID}/event", class: "session-path" },
  { method: "GET", path: "/api/session/{sessionID}/history", class: "session-path" },
  { method: "POST", path: "/api/session/{sessionID}/interrupt", class: "session-path" },
  { method: "GET", path: "/api/session/{sessionID}/message", class: "session-path" },
  { method: "GET", path: "/api/session/{sessionID}/message/{messageID}", class: "session-path" },
  { method: "POST", path: "/api/session/{sessionID}/model", class: "session-path" },
  { method: "GET", path: "/api/session/{sessionID}/permission", class: "session-path" },
  { method: "POST", path: "/api/session/{sessionID}/permission", class: "session-path" },
  { method: "GET", path: "/api/session/{sessionID}/permission/{requestID}", class: "session-path" },
  { method: "POST", path: "/api/session/{sessionID}/permission/{requestID}/reply", class: "session-path" },
  { method: "POST", path: "/api/session/{sessionID}/prompt", class: "session-path" },
  { method: "GET", path: "/api/session/{sessionID}/question", class: "session-path" },
  { method: "POST", path: "/api/session/{sessionID}/question/{requestID}/reject", class: "session-path" },
  { method: "POST", path: "/api/session/{sessionID}/question/{requestID}/reply", class: "session-path" },
  { method: "POST", path: "/api/session/{sessionID}/revert/clear", class: "session-path" },
  { method: "POST", path: "/api/session/{sessionID}/revert/commit", class: "session-path" },
  { method: "POST", path: "/api/session/{sessionID}/revert/stage", class: "session-path" },
  { method: "POST", path: "/api/session/{sessionID}/wait", class: "session-path" },
  { method: "GET", path: "/api/session/active", class: "global-ro" },
  { method: "GET", path: "/api/skill", class: "global-ro" },
  { method: "DELETE", path: "/auth/{providerID}", class: "global-sideeffect" },
  { method: "PUT", path: "/auth/{providerID}", class: "global-sideeffect" },
  { method: "GET", path: "/command", class: "global-ro" },
  { method: "GET", path: "/config", class: "global-ro" },
  { method: "PATCH", path: "/config", class: "global-sideeffect" },
  { method: "GET", path: "/config/providers", class: "global-ro" },
  { method: "GET", path: "/doc", class: "global-ro", note: "OpenAPI spec; self-undeclared, added manually (FABLE-W6)" },
  { method: "GET", path: "/event", class: "session-query", note: "Can receive session_ids query param (source: event-session-scope.patch)" },
  { method: "GET", path: "/event?session_ids=", class: "session-query", note: "patch-only session-query (source: event-session-scope.patch)" },
  { method: "GET", path: "/experimental/capabilities", class: "global-ro" },
  { method: "GET", path: "/experimental/console", class: "global-ro" },
  { method: "GET", path: "/experimental/console/orgs", class: "global-ro" },
  { method: "POST", path: "/experimental/console/switch", class: "global-sideeffect" },
  { method: "POST", path: "/experimental/control-plane/move-session", class: "global-sideeffect" },
  { method: "DELETE", path: "/experimental/project/{projectID}/copy", class: "global-sideeffect" },
  { method: "POST", path: "/experimental/project/{projectID}/copy", class: "global-sideeffect" },
  { method: "POST", path: "/experimental/project/{projectID}/copy/generate-name", class: "global-sideeffect" },
  { method: "POST", path: "/experimental/project/{projectID}/copy/refresh", class: "global-sideeffect" },
  { method: "GET", path: "/experimental/resource", class: "global-ro" },
  { method: "GET", path: "/experimental/session", class: "global-ro" },
  { method: "POST", path: "/experimental/session/{sessionID}/background", class: "session-path" },
  { method: "GET", path: "/experimental/tool", class: "global-ro" },
  { method: "GET", path: "/experimental/tool/ids", class: "global-ro" },
  { method: "GET", path: "/experimental/workspace", class: "global-ro" },
  { method: "POST", path: "/experimental/workspace", class: "global-sideeffect" },
  { method: "DELETE", path: "/experimental/workspace/{id}", class: "global-sideeffect" },
  { method: "GET", path: "/experimental/workspace/adapter", class: "global-ro" },
  { method: "GET", path: "/experimental/workspace/status", class: "global-ro" },
  { method: "POST", path: "/experimental/workspace/sync-list", class: "global-sideeffect" },
  { method: "POST", path: "/experimental/workspace/warp", class: "global-sideeffect" },
  { method: "DELETE", path: "/experimental/worktree", class: "global-sideeffect" },
  { method: "GET", path: "/experimental/worktree", class: "global-ro" },
  { method: "POST", path: "/experimental/worktree", class: "global-sideeffect" },
  { method: "POST", path: "/experimental/worktree/reset", class: "global-sideeffect" },
  { method: "GET", path: "/file", class: "global-ro" },
  { method: "GET", path: "/file/content", class: "global-ro" },
  { method: "GET", path: "/file/status", class: "global-ro" },
  { method: "GET", path: "/find", class: "global-ro" },
  { method: "GET", path: "/find/file", class: "global-ro" },
  { method: "GET", path: "/find/symbol", class: "global-ro" },
  { method: "GET", path: "/formatter", class: "global-ro" },
  { method: "GET", path: "/global/config", class: "global-ro" },
  { method: "PATCH", path: "/global/config", class: "global-sideeffect" },
  { method: "POST", path: "/global/dispose", class: "global-sideeffect" },
  { method: "GET", path: "/global/event", class: "global-event" },
  { method: "GET", path: "/global/health", class: "global-ro" },
  { method: "POST", path: "/global/upgrade", class: "global-sideeffect" },
  { method: "POST", path: "/instance/dispose", class: "global-sideeffect" },
  { method: "POST", path: "/log", class: "global-sideeffect" },
  { method: "GET", path: "/lsp", class: "global-ro" },
  { method: "GET", path: "/mcp", class: "global-ro" },
  { method: "POST", path: "/mcp", class: "global-sideeffect" },
  { method: "DELETE", path: "/mcp/{name}/auth", class: "global-sideeffect" },
  { method: "POST", path: "/mcp/{name}/auth", class: "global-sideeffect" },
  { method: "POST", path: "/mcp/{name}/auth/authenticate", class: "global-sideeffect" },
  { method: "POST", path: "/mcp/{name}/auth/callback", class: "global-sideeffect" },
  { method: "POST", path: "/mcp/{name}/connect", class: "global-sideeffect" },
  { method: "POST", path: "/mcp/{name}/disconnect", class: "global-sideeffect" },
  { method: "GET", path: "/path", class: "global-ro" },
  { method: "GET", path: "/permission", class: "global-ro" },
  { method: "POST", path: "/permission/{requestID}/reply", class: "global-sideeffect" },
  { method: "GET", path: "/project", class: "global-ro" },
  { method: "PATCH", path: "/project/{projectID}", class: "global-sideeffect" },
  { method: "GET", path: "/project/{projectID}/directories", class: "global-ro" },
  { method: "GET", path: "/project/current", class: "global-ro" },
  { method: "POST", path: "/project/git/init", class: "global-sideeffect" },
  { method: "GET", path: "/provider", class: "global-ro" },
  { method: "POST", path: "/provider/{providerID}/oauth/authorize", class: "global-sideeffect" },
  { method: "POST", path: "/provider/{providerID}/oauth/callback", class: "global-sideeffect" },
  { method: "GET", path: "/provider/auth", class: "global-ro" },
  { method: "GET", path: "/pty", class: "pty" },
  { method: "POST", path: "/pty", class: "pty" },
  { method: "DELETE", path: "/pty/{ptyID}", class: "pty" },
  { method: "GET", path: "/pty/{ptyID}", class: "pty" },
  { method: "PUT", path: "/pty/{ptyID}", class: "pty" },
  { method: "GET", path: "/pty/{ptyID}/connect", class: "pty" },
  { method: "POST", path: "/pty/{ptyID}/connect-token", class: "pty" },
  { method: "GET", path: "/pty/shells", class: "pty" },
  { method: "GET", path: "/question", class: "global-ro" },
  { method: "POST", path: "/question/{requestID}/reject", class: "global-sideeffect" },
  { method: "POST", path: "/question/{requestID}/reply", class: "global-sideeffect" },
  { method: "GET", path: "/session", class: "global-ro" },
  { method: "POST", path: "/session", class: "create" },
  { method: "DELETE", path: "/session/{sessionID}", class: "session-path" },
  { method: "GET", path: "/session/{sessionID}", class: "session-path" },
  { method: "PATCH", path: "/session/{sessionID}", class: "session-path" },
  { method: "POST", path: "/session/{sessionID}/abort", class: "session-path" },
  { method: "GET", path: "/session/{sessionID}/children", class: "session-path" },
  { method: "POST", path: "/session/{sessionID}/command", class: "session-path" },
  { method: "GET", path: "/session/{sessionID}/diff", class: "session-path" },
  { method: "POST", path: "/session/{sessionID}/fork", class: "fork" },
  { method: "POST", path: "/session/{sessionID}/init", class: "session-path" },
  { method: "GET", path: "/session/{sessionID}/message", class: "session-path" },
  { method: "POST", path: "/session/{sessionID}/message", class: "session-path" },
  { method: "DELETE", path: "/session/{sessionID}/message/{messageID}", class: "session-path" },
  { method: "GET", path: "/session/{sessionID}/message/{messageID}", class: "session-path" },
  { method: "DELETE", path: "/session/{sessionID}/message/{messageID}/part/{partID}", class: "session-path" },
  { method: "PATCH", path: "/session/{sessionID}/message/{messageID}/part/{partID}", class: "session-path" },
  { method: "POST", path: "/session/{sessionID}/permissions/{permissionID}", class: "session-path" },
  { method: "POST", path: "/session/{sessionID}/prompt_async", class: "session-path" },
  { method: "POST", path: "/session/{sessionID}/revert", class: "session-path" },
  { method: "DELETE", path: "/session/{sessionID}/share", class: "session-path" },
  { method: "POST", path: "/session/{sessionID}/share", class: "session-path" },
  { method: "POST", path: "/session/{sessionID}/shell", class: "session-path" },
  { method: "POST", path: "/session/{sessionID}/summarize", class: "session-path" },
  { method: "GET", path: "/session/{sessionID}/todo", class: "session-path" },
  { method: "POST", path: "/session/{sessionID}/unrevert", class: "session-path" },
  { method: "GET", path: "/session/status", class: "global-ro" },
  { method: "GET", path: "/skill", class: "global-ro" },
  { method: "POST", path: "/sync/history", class: "global-sideeffect" },
  { method: "POST", path: "/sync/replay", class: "global-sideeffect" },
  { method: "POST", path: "/sync/start", class: "global-sideeffect" },
  { method: "POST", path: "/sync/steal", class: "global-sideeffect" },
  { method: "POST", path: "/tui/append-prompt", class: "tui" },
  { method: "POST", path: "/tui/clear-prompt", class: "tui" },
  { method: "GET", path: "/tui/control/next", class: "tui" },
  { method: "POST", path: "/tui/control/response", class: "tui" },
  { method: "POST", path: "/tui/execute-command", class: "tui" },
  { method: "POST", path: "/tui/open-help", class: "tui" },
  { method: "POST", path: "/tui/open-models", class: "tui" },
  { method: "POST", path: "/tui/open-sessions", class: "tui" },
  { method: "POST", path: "/tui/open-themes", class: "tui" },
  { method: "POST", path: "/tui/publish", class: "tui" },
  { method: "POST", path: "/tui/select-session", class: "tui" },
  { method: "POST", path: "/tui/show-toast", class: "tui" },
  { method: "POST", path: "/tui/submit-prompt", class: "tui" },
  { method: "GET", path: "/vcs", class: "global-ro" },
  { method: "POST", path: "/vcs/apply", class: "global-sideeffect" },
  { method: "GET", path: "/vcs/diff", class: "global-ro" },
  { method: "GET", path: "/vcs/diff/raw", class: "global-ro" },
  { method: "GET", path: "/vcs/status", class: "global-ro" }
];
