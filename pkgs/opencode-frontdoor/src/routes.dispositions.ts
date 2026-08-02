/**
 * Route Denial Dispositions for opencode-frontdoor.
 *
 * Check B invariant: Every route in `/doc` that frontdoor denies MUST carry
 * an explicit, structured disposition explaining why the denial is architecturally
 * correct, superseded by a session-scoped route, or a known gap.
 */

import { normalizePath, compilePathTemplate, isTemplatePath } from './path-template.js';

export type DispositionKind =
  | 'by-design-501'         // class-level blanket: pty / tui / per-process-ro
  | 'not-session-scopable'  // global mutation with no session context; denial is architecturally correct
  | 'superseded'            // a forwarded session-scoped route serves this need
  | 'needs-mechanism'       // D4: needs anchor-pin or broadcast that the door lacks
  | 'terminal-denial'       // investigated; forwarding was REJECTED on evidence. Not a gap.
  | 'accepted-gap';         // known gap, consciously accepted

/**
 * `terminal-denial` vs `needs-mechanism` — the distinction is load-bearing.
 *
 * `needs-mechanism` means "we want to forward this and haven't built the way
 * yet". It is a debt marker: it requires an open bead, and the D4 completion
 * criterion is that the list of such rows reaches empty.
 *
 * `terminal-denial` means "we investigated and decided NOT to forward it". The
 * work is finished. Leaving such rows as `needs-mechanism` decays three ways,
 * all of which we walked into on 2026-07-26:
 *   - the pinned list can never empty, so the completion criterion becomes
 *     permanently unmet instead of retired;
 *   - the kind requires a bead, so live rows end up citing a CLOSED one;
 *   - the next reader sees "needs-mechanism" and builds the mechanism that was
 *     already falsified, because the falsification lives only in a plan file.
 * So a terminal-denial row must carry its evidence inline. That is the whole
 * point of the kind: the row is the record.
 */

/**
 * WHAT actually stops this route from working through the front door.
 *
 * `kind` records the DECISION (denied by design / superseded / gap); this records
 * the MECHANISM. They are independent, and conflating them is how a row gets a
 * plausible label for the wrong reason: `/integration/attempt/*` sat under
 * "no session context" for months when the real blocker is a per-instance RAM
 * Map (`core/src/integration.ts:227`), so it was invisible to a search for
 * process-pinned routes. See docs/plans/2026-07-26-mlve11-d4-mechanisms.md (F8, R5).
 *
 * The census over these values is pinned in `route-gate.ts`, so adding a row
 * forces an explicit answer and changing the distribution fails the gate.
 *
 * - `class-level-501`: denied by class, not by route (pty / tui).
 * - `superseded-by-session-route`: not blocked at all — a session-scoped route
 *   does the same job and the door forwards that one instead.
 * - `process-pinned-ram`: the operation needs a live object in ONE process's
 *   heap (a pending-OAuth Map, a PKCE closure, a cached instance). Delivering it
 *   to any other process fails or silently does nothing.
 * - `shared-disk-plus-stale-cache`: the state IS shared on disk, but every
 *   process caches it in memory with no invalidation, so a successful write does
 *   not become visible to the rest of the pool.
 * - `process-local-side-effect`: the effect targets the receiving process's own
 *   resources (its stdout, its binary, its config, its instance cache). Any
 *   serve can do it; which one did it is arbitrary, which makes it meaningless
 *   through a load-balancing door.
 * - `needs-audit`: NOT yet traced to a mechanism. An honest placeholder, not a
 *   free pass — it is pinned and meant to be burned down, the same way
 *   `tuiSurface: 'unverified'` was driven to zero on 2026-07-26.
 */
export type DispositionConstraint =
  | 'class-level-501'
  | 'superseded-by-session-route'
  | 'process-pinned-ram'
  | 'shared-disk-plus-stale-cache'
  | 'process-local-side-effect'
  | 'needs-audit';

export type TuiSurface = 'absent' | 'degrades' | 'unverified';

/**
 * Where wire-facing text sends an operator instead of naming a serve address.
 *
 * WHY THIS EXISTS (Step 2 residual (a), bead `workstation-u417`): a denial body is an
 * INSTRUCTION CHANNEL. It is read by automated consumers, agents and TUIs, so anything
 * printed there becomes something they can follow. Printing serve addresses here
 * manufactured exactly the direct-to-serve violations the opacity guard was built to
 * catch — and the guard cannot see wire text, so nothing caught them.
 *
 * Rule, enforced by `test/wire-text.test.ts`: wire-facing strings name the CONSTRAINT and
 * point HERE. Port-level recipes live in the runbook, in the repo, where they are
 * reviewable.
 */
export const OPERATOR_RUNBOOK = 'docs/runbooks/frontdoor-per-serve-operations.md';

/**
 * The four MCP-OAuth routes. Here direct-to-one-serve IS the correct procedure — but it
 * is silently breakable, so the wire text carries the SILENCE, not the recipe: the
 * callback listener binds a fixed port and, if that port is already taken, returns
 * success WITHOUT binding (mcp/oauth-callback.ts:114-120). The redirect then lands in the
 * wrong process and the call blocks ~5 minutes before failing. Bead `workstation-u417`
 * (R6): "that silence is where the next incident lives".
 */
export const MCP_OAUTH_USER_MESSAGE =
  'MCP OAuth state is pinned to a single process by a module-level map keyed by MCP name, so the whole flow must complete against one serve and cannot be proxied.';

export const MCP_OAUTH_REMEDY =
  'For an ordinary MCP connect, use the session-scoped route POST /session/{sessionID}/mcp/{name}/connect, which the front door routes to the session owner. ' +
  'The auth flow itself is an operator procedure with a known silent-failure mode (a stray process holding the callback port makes it fail late and quietly): ' +
  `see ${OPERATOR_RUNBOOK} §2.`;

/**
 * `POST /instance/dispose` is the row where the generic "call a serve port directly" hint
 * was not merely opaque-unfriendly but ACTIVELY HARMFUL: the caller cannot know which
 * member holds the instance, and hitting one that does not cold-boots it and disposes
 * nothing. Telling the caller to pick a port is precisely the trap.
 */
export const INSTANCE_DISPOSE_USER_MESSAGE =
  'Disposal is per-serve and per-directory, and this route inverts through the front door: a serve that does not hold the instance loads it before the handler runs, so the request would boot an instance rather than dispose one.';

export const INSTANCE_DISPOSE_REMEDY =
  'Do not pick a serve and retry — that is the inversion this denial prevents. ' +
  `Invalidating everywhere is an operator procedure and cancels in-flight runs: see ${OPERATOR_RUNBOOK} §3.`;

/**
 * The remedy for provider-credential mutation, shared by the four routes whose
 * success path writes `auth.json` (`PUT|DELETE /auth/{providerID}` and both
 * `POST /provider/{providerID}/oauth/*` routes — the latter because
 * `provider/auth.ts:203-220` calls `auth.set()` on success).
 *
 * This exists as a constant because the generic denial hint ("call a serve port
 * directly") is ACTIVELY WRONG for these routes: writing one serve returns 200
 * while the other three — and the writer's own already-booted instances — keep
 * the old credential indefinitely. See docs/plans/2026-07-26-mlve11-d4-mechanisms.md
 * (Group A, and F3 for why the OAuth pair inherits it).
 *
 * Step 6 of that plan replaces the hand-rolled procedure below with a CLI; when
 * it lands, this constant is the single place to update.
 */
export const POOL_CREDENTIAL_REMEDY =
  'auth.json is shared by every serve and has no lock, and each serve caches the credential in RAM, so this write must be made once and then re-read everywhere. ' +
  'Do NOT broadcast it: concurrent whole-document writes can silently lose an update. ' +
  'The re-read step is disruptive — it cancels in-flight runs and SIGTERMs stdio MCP children. ' +
  `This is an operator procedure: see ${OPERATOR_RUNBOOK} §1.`;

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
  /**
   * REQUIRED. The mechanism that blocks this route (see `DispositionConstraint`).
   * Required so that adding a row cannot skip the question.
   */
  constraint: DispositionConstraint;
  /**
   * Repo-facing. May cite file:line and may be long. NOT sent on the wire —
   * see `userMessage` for the caller-facing half.
   */
  rationale: string;
  /**
   * Wire-facing, optional. One sentence naming the REAL constraint, with no
   * file:line citations. When present, `proxy.ts` puts it in the denial body in
   * place of the generic "mutates per-process state" text.
   *
   * Set this whenever the generic denial text would mislead the caller.
   */
  userMessage?: string;
  /**
   * Wire-facing, optional. What the caller should actually DO. When absent,
   * `proxy.ts` falls back to a generic "this is per-process; the door cannot do it for
   * you; see the runbook" text. That fallback used to read "call a serve port directly",
   * which was wrong for anything sharing pool-wide state AND handed every caller a
   * bypass recipe (Step 2 residual (a), bead `workstation-u417`).
   *
   * Wire-facing text must never name a serve address — enforced by `test/wire-text.test.ts`.
   */
  remedy?: string;
  supersededBy?: string;
  bead?: string;
  tuiSurface?: TuiSurface;
}

export const CLASS_DISPOSITIONS: Record<string, RouteDisposition> = {
  pty: {
    kind: 'by-design-501',
    constraint: 'class-level-501',
    rationale: 'PTY routes require stateful local terminal streams (Task 5.1); frontdoor returns 501 by design.',
  },
  tui: {
    kind: 'by-design-501',
    constraint: 'class-level-501',
    rationale: 'TUI control routes require process-local UI state (Task 5.1); frontdoor returns 501 by design.',
  },
};

/**
 * Shared evidence for the four MCP OAuth rows. Inline on every row (via
 * concatenation) so the reasoning travels with the disposition rather than
 * living only in a plan file -- see the `terminal-denial` note above.
 */
const MCP_OAUTH_DENIAL_EVIDENCE =
  'Denial is a DECISION, not a missing feature. Anchor-forwarding is available (forward-anchor already exists) and was rejected on two verified grounds. (1) The callback listener binds a FIXED port 19876 and mcp/oauth-callback.ts:114-120 returns SUCCESS WITHOUT BINDING when the port is already owned, so whichever process grabbed 19876 first receives every browser redirect; a process that did not bind it has an empty pendingAuths and answers 400 "potential CSRF attack" while the caller blocks the full 5-minute CALLBACK_TIMEOUT_MS. The squat is live on this box: any stray `opencode` process can take 19876 with no error at bind time, which is precisely tonight\'s incident class. (2) The door\'s cheap first-byte timeout is 5000ms (config.ts:58) and isExemptFromFirstByteTimeout only exempts paths containing a session ID (timeouts.ts:26-53). None of these paths has one, so the authenticate route would 503 on every call regardless of routing. Consistent hashing on {name} was considered and is strictly WORSE than anchoring: it deliberately spreads names across processes, so most callbacks would land on a process that does not own 19876. Do not implement it.';

export const ROUTE_DISPOSITIONS: Record<string, RouteDisposition> = {
  // D4 rows (workstation-mlve.11 / needs-mechanism):
  'PUT /auth/{providerID}': {
    kind: 'terminal-denial',
    constraint: 'shared-disk-plus-stale-cache',
    tuiSurface: 'degrades',
    rationale:
      'Denial is a DECISION; the escape hatch is a CLI, not the door. auth.json is shared, but Provider bakes auth.all() into InstanceState (provider/provider.ts:1502-1512), copies the key into the constructed SDK (:1686) and memoizes it (:1700, :1801-1823) behind a ScopedCache with capacity POSITIVE_INFINITY, no TTL, and exactly ONE invalidation path: instance disposal (effect/instance-state.ts:26-45). So anchor-forwarding this write returns 200 while three other members -- and the writer\'s own already-booted instances -- keep the previous credential indefinitely. That is a false success, which is worse than a denial. ' +
      'Two supporting facts. The write is unsafe on its own terms: whole-document read-modify-write with no lock and no atomic rename (auth/index.ts:73-81, fs-util.ts:100-104), while mcp/auth.ts:72-82 does take a flock for the same job -- an upstream asymmetry, and the reason the CLI must write exactly once. And these routes carry NO directory context at all (groups/control.ts:36-75 applies neither instance-context nor workspace-routing middleware; AuthParams:8-10 has no directory/workspace field), so any "dispose the same directory afterwards" scheme has no referent. ' +
      'TUI consequence (audited 2026-07-26): dialog-provider.tsx:396-405 calls sdk.client.auth.set() WITHOUT checking the error, then instance.dispose() also unchecked, and can then show a "Saved credential for <id>" toast. Through the door both calls 403 and the user is told the credential was saved when nothing was written. This is the WORST surface of the four credential routes -- silent AND actively misleading -- and it is why the denial body now carries a real remedy instead of "call a serve port directly".',
    userMessage:
      'Provider credentials are shared pool-wide state that each serve caches in memory until its instance is disposed, so a write delivered to one serve would report success while the rest of the pool keeps using the previous credential.',
    remedy: POOL_CREDENTIAL_REMEDY,
  },
  'DELETE /auth/{providerID}': {
    kind: 'terminal-denial',
    constraint: 'shared-disk-plus-stale-cache',
    tuiSurface: 'absent',
    rationale:
      'Same constraint as PUT /auth/{providerID}: auth.remove writes shared auth.json (auth/index.ts:83-89) but evicts nothing from any already-booted instance\'s memoized Provider cache (provider/provider.ts:1502-1512, invalidated only by disposal per effect/instance-state.ts:26-45), so the pool would keep authenticating with a credential the user believes is deleted -- a false success with a security flavour. Same absent directory context as the PUT (groups/control.ts:36-75, AuthParams:8-10). No TUI caller (grepped v1.17.13 packages/tui/src for auth.remove: zero hits), hence absent. Use the CLI escape hatch, which disposes every member after the write.',
    userMessage:
      'Provider credentials are shared pool-wide state that each serve caches in memory until its instance is disposed, so a removal delivered to one serve would report success while the rest of the pool keeps authenticating with the deleted credential.',
    remedy: POOL_CREDENTIAL_REMEDY,
  },
  'POST /provider/{providerID}/oauth/authorize': {
    kind: 'terminal-denial',
    constraint: 'process-pinned-ram',
    tuiSurface: 'degrades',
    rationale:
      'DIFFERENT constraint from the /auth pair, and the distinction matters: these routes DO have directory context, so "no session context" would be the wrong reason. What pins them is RAM -- provider/auth.ts:100-103 holds pending: Map<ProviderID, AuthOAuthResult> inside InstanceState, keyed by (process, directory), and the PKCE verifier lives in a JavaScript CLOSURE (match.callback) that is never serialized. A callback landing on any other process fails at :191-193 with 400 ProviderAuthOauthMissing. ' +
      'Consistent hashing on (providerID, resolvedDirectory) was considered and rejected: the door would have to replicate four layers of upstream resolution (?workspace= overrides ?directory= via middleware/workspace-routing.ts:154-157, OPENCODE_WORKSPACE_ID short-circuits both, then decodeURIComponent + FSUtil.resolve normalise), and any drift produces a deterministically wrong key -- silent and 100% reproducible. ' +
      'The deeper reason not to forward: provider/auth.ts:203-220 calls auth.set() on success, so a forwarded callback IS a Group A write and inherits the same pool-wide staleness. Denying the /auth pair while forwarding this one was never a defensible line. ' +
      'TUI consequence (audited 2026-07-26): dialog-provider.tsx:185-195 checks result.error and shows an error toast, then clears the dialog. Degrades VISIBLY, though the toast renders JSON.stringify(error) rather than a friendly message.',
    userMessage:
      'This OAuth flow keeps its PKCE verifier in one serve process\'s memory, so the matching callback must reach that same process; and the flow completes by writing a provider credential, which is shared pool-wide state the other serves would not pick up.',
    remedy: POOL_CREDENTIAL_REMEDY,
  },
  'POST /provider/{providerID}/oauth/callback': {
    kind: 'terminal-denial',
    constraint: 'process-pinned-ram',
    tuiSurface: 'degrades',
    rationale:
      'The callback half of the flow; see POST /provider/{providerID}/oauth/authorize for the full reasoning. It must reach the same process that issued the authorize because the PKCE verifier is closure-held and never written down, and its success path writes provider credentials via auth.set() (provider/auth.ts:203-220). ' +
      'TUI consequence (audited 2026-07-26): both callers surface the failure -- dialog-provider.tsx:265-282 (auto/device flow, onMount) shows an error toast, and :325-337 (manual code entry) sets an inline error. Degrades VISIBLY. Note the immediately following `await sdk.client.instance.dispose()` at :281 and :332 is itself denied, so even a forwarded success would be followed by a discarded 403 -- the two rows have to move together or not at all.',
    userMessage:
      'This callback can only be completed by the same serve process that issued the matching authorize request, because the PKCE verifier is held in that process\'s memory and is never written down; and its success path writes a provider credential, which is shared pool-wide state the other serves would not pick up.',
    remedy: POOL_CREDENTIAL_REMEDY,
  },
  'POST /mcp/{name}/auth': {
    kind: 'terminal-denial',
    constraint: 'process-pinned-ram',
    tuiSurface: 'absent',
    rationale:
      'MCP OAuth state is pinned to one process by the module-level pendingOAuthTransports Map (mcp/index.ts:112), keyed by mcpName. ' + MCP_OAUTH_DENIAL_EVIDENCE,
    userMessage: MCP_OAUTH_USER_MESSAGE,
    remedy: MCP_OAUTH_REMEDY,
  },
  'DELETE /mcp/{name}/auth': {
    kind: 'terminal-denial',
    constraint: 'process-pinned-ram',
    tuiSurface: 'absent',
    rationale:
      'Removal must reach the process holding this server\'s live transport and pending-auth entry (mcp/index.ts:112). ' + MCP_OAUTH_DENIAL_EVIDENCE,
    userMessage: MCP_OAUTH_USER_MESSAGE,
    remedy: MCP_OAUTH_REMEDY,
  },
  'POST /mcp/{name}/auth/authenticate': {
    kind: 'terminal-denial',
    constraint: 'process-pinned-ram',
    tuiSurface: 'absent',
    rationale:
      'This is the route that blocks on the browser callback, so it is the clearest case: even with perfect routing it exceeds the door\'s first-byte timeout every time. ' + MCP_OAUTH_DENIAL_EVIDENCE,
    userMessage: MCP_OAUTH_USER_MESSAGE,
    remedy: MCP_OAUTH_REMEDY,
  },
  'POST /mcp/{name}/auth/callback': {
    kind: 'terminal-denial',
    constraint: 'process-pinned-ram',
    tuiSurface: 'absent',
    rationale:
      'The callback must be handled by the process that issued the authorize request and owns its transport (mcp/index.ts:112). Cross-process it fails as a bare throw (mcp/index.ts:928-929), i.e. a 500 rather than a typed 4xx. ' + MCP_OAUTH_DENIAL_EVIDENCE,
    userMessage: MCP_OAUTH_USER_MESSAGE,
    remedy: MCP_OAUTH_REMEDY,
  },
  'POST /instance/dispose': {
    kind: 'terminal-denial',
    constraint: 'process-pinned-ram',
    tuiSurface: 'degrades',
    rationale:
      'Denial is a DECISION. Forwarding was rejected because the route INVERTS through the door: instance-context middleware LOADS (cold-boots) the target instance before the handler runs, and instance-store.ts:117-120 forks completeLoad into the SERVER scope, so when the door gives up at its 5s first-byte timeout (config.ts:58; no session ID in the path means no exemption per timeouts.ts:26-53) the boot is NOT cancelled. Net effect on a cold member: caller gets 503, plugins/LSP/MCP stdio children are spawned, the instance is cached, and NOTHING is disposed -- the exact opposite of the request. ' +
      'Broadcast was also rejected: dispose is already directory-keyed server-side, so fanning out to the 3 members that do not hold the instance cold-boots all of them, and mcp/index.ts:546 pendingOAuthTransports.clear() is process-global, so disposing directory /a would wipe a pending MCP OAuth flow for directory /b on every member. The 200 response carries no signal about which process held the instance (handlers/instance.ts:24-27 always returns true), so it cannot even drive targeting. ' +
      'TUI consequence (audited 2026-07-26): dialog-provider.tsx:281/:332/:405 and dialog-console-org.tsx:106 all call `await sdk.client.instance.dispose()` WITHOUT checking the returned error, then immediately `await sync.bootstrap()`. So a door 403 is discarded silently and the dialog proceeds with stale provider state; nothing crashes and nothing is reported. Degrades, but invisibly.',
    userMessage: INSTANCE_DISPOSE_USER_MESSAGE,
    remedy: INSTANCE_DISPOSE_REMEDY,
  },

  // Superseded rows:
  'POST /permission/{requestID}/reply': {
    kind: 'superseded',
    constraint: 'superseded-by-session-route',
    supersededBy: 'POST /api/session/{sessionID}/permission/{requestID}/reply',
    rationale: 'Permission request replies are session-scoped and routed via POST /api/session/{sessionID}/permission/{requestID}/reply.',
  },
  'POST /question/{requestID}/reply': {
    kind: 'superseded',
    constraint: 'superseded-by-session-route',
    supersededBy: 'POST /api/session/{sessionID}/question/{requestID}/reply',
    rationale: 'Question replies are session-scoped and routed via POST /api/session/{sessionID}/question/{requestID}/reply.',
  },
  'POST /question/{requestID}/reject': {
    kind: 'superseded',
    constraint: 'superseded-by-session-route',
    supersededBy: 'POST /api/session/{sessionID}/question/{requestID}/reject',
    rationale: 'Question rejections are session-scoped and routed via POST /api/session/{sessionID}/question/{requestID}/reject.',
  },
  'GET /global/event': {
    kind: 'superseded',
    constraint: 'superseded-by-session-route',
    supersededBy: 'GET /event',
    rationale: 'Deprecated global event stream (410 Gone); clients must use session-scoped event stream GET /event?session_ids=.',
  },
  'GET /mcp': {
    kind: 'superseded',
    constraint: 'superseded-by-session-route',
    supersededBy: 'GET /session/{sessionID}/mcp',
    rationale: 'Per-process MCP status stream cannot represent multi-serve pool state (F3); superseded by session-scoped status GET /session/{sessionID}/mcp.',
  },
  // Solved in Phase 10 via session-scoped route POST /session/{sessionID}/mcp/{name}/connect; deliberately excluded from D4.
  'POST /mcp/{name}/connect': {
    kind: 'superseded',
    constraint: 'superseded-by-session-route',
    supersededBy: 'POST /session/{sessionID}/mcp/{name}/connect',
    rationale: 'MCP connection management is superseded by session-scoped POST /session/{sessionID}/mcp/{name}/connect. Phase 10 solved this via session-scoped routes; deliberately excluded from D4.',
  },
  // Solved in Phase 10 via session-scoped route POST /session/{sessionID}/mcp/{name}/disconnect; deliberately excluded from D4.
  'POST /mcp/{name}/disconnect': {
    kind: 'superseded',
    constraint: 'superseded-by-session-route',
    supersededBy: 'POST /session/{sessionID}/mcp/{name}/disconnect',
    rationale: 'MCP disconnection management is superseded by session-scoped POST /session/{sessionID}/mcp/{name}/disconnect. Phase 10 solved this via session-scoped routes; deliberately excluded from D4.',
  },

  // Corrected 2026-07-25; AUDITED and resolved 2026-07-26 (workstation-mlve.11).
  'POST /sync/start': {
    kind: 'not-session-scopable',
    constraint: 'needs-audit',
    tuiSurface: 'degrades',
    rationale:
      'Process-global workspace sync engine start; the door cannot session-scope it. D4 audit: the only callers are tui/src/context/sdk.tsx:99 (SSE) and :127 (RPC), BOTH gated on Flag.OPENCODE_EXPERIMENTAL_WORKSPACES (sdk.tsx:96/:124) and BOTH written `await sdk.sync.start().catch(() => {})`, so the door 403 is swallowed. The flag is off here: enabledByExperimental falls back to the EXACT var OPENCODE_EXPERIMENTAL (core/src/flag/flag.ts:11-13), and neither it nor OPENCODE_EXPERIMENTAL_WORKSPACES is set anywhere in the workstation repo. Consequence: workspace sync loops never start; nothing else is affected. Resolved by verification, not mechanism.',
  },

  // Individual global mutation / non-session-scopable rows (32 total: 11 degrades, 21 absent; plus POST /sync/start above = 12 degrades overall).
  // The 5 formerly-'unverified' rows were audited 2026-07-26 under workstation-mlve.11 and are now 'degrades' with the evidence inline.
  'POST /log': {
    kind: 'not-session-scopable',
    constraint: 'process-local-side-effect',
    tuiSurface: 'absent',
    rationale: 'Process-global logging endpoint targets single process stdout/file, not a session.',
  },
  'POST /experimental/control-plane/move-session': {
    kind: 'not-session-scopable',
    constraint: 'needs-audit',
    tuiSurface: 'degrades',
    rationale: 'Internal control-plane session migration mutation operates across processes without session-scoped door route wrapper. In TUI SDK surface list and recorded as denied-by-design with graceful degradation (2026-07-24-phase9-door-route-allowlist.md:35).',
  },
  'PATCH /global/config': {
    kind: 'not-session-scopable',
    constraint: 'process-local-side-effect',
    tuiSurface: 'absent',
    rationale:
      'Modifies process-level global configuration; no session context. It is also a HIDDEN MASS DISPOSE: on any actual change, handlers/global.ts:88 forks disposeAllInstancesAndEmitGlobalDisposed(), tearing down EVERY instance in the receiving process — cancelling in-flight runs and SIGTERMing stdio MCP children for every directory it was serving. Forwarding this to an arbitrary pool member would therefore be an arbitrary partial outage, and the config change would still be invisible to the other three.',
  },
  'POST /global/dispose': {
    kind: 'not-session-scopable',
    constraint: 'process-local-side-effect',
    tuiSurface: 'absent',
    rationale: 'Disposes global process runtime state; no session context.',
  },
  'POST /global/upgrade': {
    kind: 'not-session-scopable',
    constraint: 'process-local-side-effect',
    tuiSurface: 'degrades',
    rationale: 'Triggers process-global application binary upgrade; no session context. In TUI SDK surface list and recorded as denied-by-design with graceful degradation (2026-07-24-phase9-door-route-allowlist.md:35).',
  },
  'PATCH /config': {
    kind: 'not-session-scopable',
    constraint: 'process-local-side-effect',
    tuiSurface: 'absent',
    rationale:
      'Mutates global server configuration settings; no session context. It is also a HIDDEN DISPOSE: handlers/config.ts:20 calls markInstanceForDisposal() on the current instance, so the write tears down the instance that served it. The previous rationale omitted this, which is what F8 flagged — a row can be denied for a true reason and still describe itself wrongly.',
  },
  'POST /experimental/console/switch': {
    kind: 'not-session-scopable',
    constraint: 'needs-audit',
    tuiSurface: 'degrades',
    bead: 'workstation-85ui',
    rationale:
      'Switches global console organization context for process; no session context. D4 audit (workstation-mlve.11): called from tui/src/component/dialog-console-org.tsx:98. Degrades SILENTLY, not gracefully — the call passes `{ throwOnError: true }` with no try/catch, and DialogSelect discards the returned promise (ui/dialog-select.tsx:34/71), so the door 403 becomes an UNHANDLED REJECTION. It does not crash today only because @opentui/core registers a process-level unhandledRejection handler and opencode sets openConsoleOnError:false (tui/src/app.tsx:196), so the error lands in an invisible console buffer and the dialog silently does nothing. Bun exits 1 on an unhandled rejection with no handler, so this is one dependency bump from a TUI crash. NOTE this is the ONLY row of the six D4-audited rows that is NOT gated by the experimental flag — it needs only a Console login with 2+ switchable orgs. Door behaviour is correct; the hazard is client-side and tracked as workstation-85ui.',
  },
  'POST /experimental/worktree': {
    kind: 'not-session-scopable',
    constraint: 'needs-audit',
    tuiSurface: 'absent',
    rationale: 'Creates process-global git worktree; no session context.',
  },
  'DELETE /experimental/worktree': {
    kind: 'not-session-scopable',
    constraint: 'needs-audit',
    tuiSurface: 'absent',
    rationale: 'Deletes process-global git worktree; no session context.',
  },
  'POST /experimental/worktree/reset': {
    kind: 'not-session-scopable',
    constraint: 'needs-audit',
    tuiSurface: 'absent',
    rationale: 'Resets process-global git worktree state; no session context.',
  },
  'POST /vcs/apply': {
    kind: 'not-session-scopable',
    constraint: 'needs-audit',
    tuiSurface: 'absent',
    rationale: 'Applies VCS patch to process working directory; no session context.',
  },
  'POST /mcp': {
    kind: 'not-session-scopable',
    constraint: 'needs-audit',
    tuiSurface: 'absent',
    rationale: 'Adds server to process-global MCP configuration; no session context.',
  },
  'POST /project/git/init': {
    kind: 'not-session-scopable',
    constraint: 'needs-audit',
    tuiSurface: 'absent',
    rationale: 'Initializes git repository in process working directory; no session context.',
  },
  'PATCH /project/{projectID}': {
    kind: 'not-session-scopable',
    constraint: 'needs-audit',
    tuiSurface: 'absent',
    rationale: 'Modifies process project settings; no session context.',
  },
  'POST /experimental/project/{projectID}/copy/generate-name': {
    kind: 'not-session-scopable',
    constraint: 'needs-audit',
    tuiSurface: 'degrades',
    rationale: 'Generates project copy name globally; no session context. In TUI SDK surface list and recorded as denied-by-design with graceful degradation (2026-07-24-phase9-door-route-allowlist.md:35).',
  },
  'POST /sync/replay': {
    kind: 'not-session-scopable',
    constraint: 'needs-audit',
    tuiSurface: 'absent',
    rationale: 'Replays sync engine operations process-globally; no session context.',
  },
  'POST /sync/steal': {
    kind: 'not-session-scopable',
    constraint: 'needs-audit',
    tuiSurface: 'absent',
    rationale: 'Steals sync engine lease process-globally; no session context.',
  },
  'POST /sync/history': {
    kind: 'not-session-scopable',
    constraint: 'needs-audit',
    tuiSurface: 'absent',
    rationale: 'Fetches sync history for process; no session context.',
  },
  'POST /experimental/workspace': {
    kind: 'not-session-scopable',
    constraint: 'needs-audit',
    tuiSurface: 'degrades',
    rationale:
      'Creates experimental workspace in process directory; no session context. D4 audit: callers are tui/src/component/prompt/workspace.tsx:31 and dialog-session-list.tsx:110, both behind Flag.OPENCODE_EXPERIMENTAL_WORKSPACES (prompt/index.tsx:535), which is OFF here. Both call sites try/catch AND check result.error, surfacing a toast ("Creating workspace failed") carrying the door message. This is the one row of the six that yields 405 + Allow: GET rather than 403, because GET /experimental/workspace is a sibling global-ro (routes.classification.ts:146). Graceful; resolved by verification, not mechanism.',
  },
  'POST /experimental/workspace/sync-list': {
    kind: 'not-session-scopable',
    constraint: 'needs-audit',
    tuiSurface: 'degrades',
    rationale:
      'Syncs workspace list for process; no session context. D4 audit: callers are dialog-workspace-create.tsx:81 and dialog-workspace-list.tsx:91, both behind Flag.OPENCODE_EXPERIMENTAL_WORKSPACES (OFF here), both written `.catch(() => undefined)` with the return value discarded — fire-and-forget. Consequence of the door 403: adapter-discovered workspaces are silently not registered. Graceful; resolved by verification, not mechanism.',
  },
  'DELETE /experimental/workspace/{id}': {
    kind: 'not-session-scopable',
    constraint: 'needs-audit',
    tuiSurface: 'degrades',
    rationale:
      'Deletes experimental workspace; no session context. D4 audit: callers are dialog-workspace-list.tsx:67 (.catch -> result.error -> toast) and dialog-session-list.tsx:153 (no try/catch, checks result.error only — safe because the generated SDK defaults throwOnError to false, v2/gen/client/client.gen.ts:222-232). Both behind Flag.OPENCODE_EXPERIMENTAL_WORKSPACES (OFF here; the list command is hidden without it, app.tsx:609). Toast "Failed to delete workspace". Graceful; resolved by verification, not mechanism.',
  },
  'POST /experimental/workspace/warp': {
    kind: 'not-session-scopable',
    constraint: 'needs-audit',
    tuiSurface: 'degrades',
    rationale:
      'Warps workspace state process-globally; no session context. D4 audit: caller is dialog-workspace-create.tsx:102 (warpWorkspaceSession), behind Flag.OPENCODE_EXPERIMENTAL_WORKSPACES (OFF here, prompt/index.tsx:535). try/catch -> toast "Failed to warp session", returns false. Graceful; resolved by verification, not mechanism.',
  },
  'POST /integration/{integrationID}/connect/key': {
    kind: 'not-session-scopable',
    constraint: 'needs-audit',
    tuiSurface: 'absent',
    rationale: 'Connects integration key globally for process; no session context.',
  },
  'POST /integration/{integrationID}/connect/oauth': {
    kind: 'not-session-scopable',
    constraint: 'needs-audit',
    tuiSurface: 'absent',
    rationale: 'Initiates integration OAuth connection process-globally; no session context.',
  },
  'DELETE /integration/attempt/{attemptID}': {
    kind: 'not-session-scopable',
    constraint: 'process-pinned-ram',
    tuiSurface: 'absent',
    rationale:
      'RE-DISPOSITIONED 2026-07-26 (F8). The old reason ("no session context") was true but not the CONSTRAINT, which hid this route from any search for process-pinned state. Verified: attempts live in `SynchronizedRef.makeUnsafe(new Map<AttemptID, AttemptEntry>())` created inside integration locationLayer (core/src/integration.ts:227), i.e. per (process, location) RAM keyed by the attemptID in this very path. This is a THIRD OAuth family with the same shape as provider OAuth and MCP OAuth; it sits outside D4 only because of the old label.',
  },
  'POST /integration/attempt/{attemptID}/complete': {
    kind: 'not-session-scopable',
    constraint: 'process-pinned-ram',
    tuiSurface: 'absent',
    rationale:
      'RE-DISPOSITIONED 2026-07-26 (F8). Completing an attempt requires the entry created by the matching connect/oauth call, which lives in the per-(process, location) attempts Map at core/src/integration.ts:227. Delivering this to any other pool member finds no entry. Same family as DELETE /integration/attempt/{attemptID}; see that row.',
  },
  'PATCH /credential/{credentialID}': {
    kind: 'not-session-scopable',
    constraint: 'needs-audit',
    tuiSurface: 'absent',
    rationale:
      'CONSTRAINT UNVERIFIED — and the previous rationale ("process credential store") is FALSE. Traced 2026-07-26: credential.update routes to Integration.Service.connection.update (server/src/handlers/credential.ts:9-14), which is backed by Credential.Service over the shared SQL Database (core/src/credential.ts:7,54), not by process memory. A write is therefore durable and pool-visible, so process-pinning is NOT the blocker and this row may not need denying at all. It stays denied pending an audit of whether any process caches the credential list in RAM (the Group A failure mode) — deliberately NOT relabelled to a confident-sounding value, which is the mistake F8 documented.',
  },
  'DELETE /credential/{credentialID}': {
    kind: 'not-session-scopable',
    constraint: 'needs-audit',
    tuiSurface: 'absent',
    rationale:
      'CONSTRAINT UNVERIFIED — the previous rationale ("process credential store") is FALSE for the same reason as PATCH /credential/{credentialID}: it routes to Integration.Service.connection.remove over the shared SQL Database. See that row.',
  },
  'DELETE /permission/saved/{id}': {
    kind: 'not-session-scopable',
    constraint: 'needs-audit',
    tuiSurface: 'absent',
    rationale: 'Deletes process-global saved permission entry; no session context.',
  },
  'POST /experimental/project/{projectID}/copy': {
    kind: 'not-session-scopable',
    constraint: 'needs-audit',
    tuiSurface: 'degrades',
    rationale: 'Initiates project copy process-globally; no session context. In TUI SDK surface list and recorded as denied-by-design with graceful degradation (2026-07-24-phase9-door-route-allowlist.md:35).',
  },
  'DELETE /experimental/project/{projectID}/copy': {
    kind: 'not-session-scopable',
    constraint: 'needs-audit',
    tuiSurface: 'degrades',
    rationale: 'Cancels project copy process-globally; no session context. In TUI SDK surface list and recorded as denied-by-design with graceful degradation (2026-07-24-phase9-door-route-allowlist.md:35).',
  },
  'POST /experimental/project/{projectID}/copy/refresh': {
    kind: 'not-session-scopable',
    constraint: 'needs-audit',
    tuiSurface: 'degrades',
    rationale: 'Refreshes project copy status process-globally; no session context. In TUI SDK surface list and recorded as denied-by-design with graceful degradation (2026-07-24-phase9-door-route-allowlist.md:35).',
  },
};

/**
 * Compiled template matchers per disposition map, built lazily and cached.
 *
 * The gate calls `getRouteDisposition` with TEMPLATE paths straight out of
 * `/doc` (`/auth/{providerID}`), which hit the exact-match step. The proxy calls
 * it with CONCRETE request paths (`/auth/anthropic`), which do not — hence the
 * template step below. Both callers must resolve to the same row or the wire
 * message and the gate's rationale would describe different routes.
 */
const templateMatcherCache = new WeakMap<
  Record<string, RouteDisposition>,
  Array<{ method: string; regex: RegExp; disposition: RouteDisposition }>
>();

function templateMatchers(map: Record<string, RouteDisposition>) {
  let compiled = templateMatcherCache.get(map);
  if (!compiled) {
    compiled = [];
    for (const [key, disposition] of Object.entries(map)) {
      const sep = key.indexOf(' ');
      if (sep < 0) continue;
      const keyMethod = key.slice(0, sep).toUpperCase();
      const keyPath = normalizePath(key.slice(sep + 1));
      if (!isTemplatePath(keyPath)) continue;
      compiled.push({ method: keyMethod, regex: compilePathTemplate(keyPath), disposition });
    }
    templateMatcherCache.set(map, compiled);
  }
  return compiled;
}

function matchTemplate(
  map: Record<string, RouteDisposition>,
  upperMethod: string,
  normPath: string
): RouteDisposition | undefined {
  // First match wins, in declaration order. The gate's Check B independently
  // proves every denial resolves to exactly one disposition, so an ambiguous
  // overlap here would be caught there rather than silently picking a row.
  for (const candidate of templateMatchers(map)) {
    if (candidate.method === upperMethod && candidate.regex.test(normPath)) {
      return candidate.disposition;
    }
  }
  return undefined;
}

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
  const normPath = normalizePath(pathname);

  // 2. Exact match in ROUTE_DISPOSITIONS
  const exactKey = `${upperMethod} ${normPath}`;
  if (routeDispMap[exactKey]) {
    return routeDispMap[exactKey];
  }

  // 3. `/api/*` mirror fallback to bare route.
  //    NOTE the house convention: disposition keys are written in BARE form and
  //    this fallback is what makes them cover the `/api/` mirror too. One key
  //    therefore speaks for BOTH forms — if upstream ever gives them different
  //    behaviour, one disposition would silently cover two routes.
  const barePath = normPath.startsWith('/api/') ? normPath.slice(4) : undefined;
  if (barePath !== undefined) {
    const bareKey = `${upperMethod} ${barePath}`;
    if (routeDispMap[bareKey]) {
      return routeDispMap[bareKey];
    }
  }

  // 4. Template match, for concrete request paths (proxy callers).
  const templated = matchTemplate(routeDispMap, upperMethod, normPath);
  if (templated) {
    return templated;
  }

  // 5. Template match against the `/api/`-stripped path, same convention as (3).
  if (barePath !== undefined) {
    return matchTemplate(routeDispMap, upperMethod, barePath);
  }

  return undefined;
}
