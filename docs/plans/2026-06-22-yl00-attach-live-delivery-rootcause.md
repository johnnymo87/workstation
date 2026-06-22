# yl00 root-cause: attached TUI misses pigeon-injected messages (live SSE delivery gap)

Status: Root cause CONFIRMED (devbox, 2026-06-22). Diagnosis only — no fix applied yet.
Bead: workstation-yl00 (P1 bug). Feeds: workstation-mn9r, workstation-zao4 (acceptance
criteria). Coordinates with: workstation-7zr7 (attach client /route + reconnect).

## Verdict (TL;DR)

The bug is **cause #2 (a serve-side emission/sync bug)**, NOT cause #1 (event-loop
saturation). It is a **cold-start race in opencode-serve's `GET /event` SSE handler**:

> An `/event` subscription captures its directory/location filter **once at subscribe
> time**. A subscription opened against a serve that has **not yet run the session's
> directory's first agent turn** (a "cold" directory-instance) permanently drops all
> `message.*` / `session.status` / `session.idle` / `session.updated` events for that
> session — it still receives `session.next.*` and global lifecycle events. The turn
> runs and persists to SQLite (so re-attach shows the result), but live delivery to
> that pre-warm subscription never happens.

Cause #1 (saturation) is ruled out as the operative cause: the gap reproduces
deterministically at trivial load (serves <10% CPU, K=2), and when delivery works it is
instantaneous (token deltas within ms). Saturation may independently degrade fan-out at
high M, but it is not what produces yl00.

## How the verdict was reached (evidence)

Substrate: devbox pool, K=2 (`serve-0` :4096, `serve-1` :4097), pigeon `:4731`, lease
enforcement live (`OPENCODE_ROUTING_DB`, `OPENCODE_SERVE_ID` set on both serves), opencode
`v1.17.7-patched.1` (includes `event-session-scope.patch` = `?session_ids=` filter, and
`serve-lease.patch`).

Injection path = the real swarm/telegram path: `POST :4731/swarm/send {from,to,payload}`
→ arbiter → `client.sendPrompt(target, directory, prompt)` → `POST <owner>/session/<id>/prompt_async`
with `x-opencode-directory: <session.directory>` (`opencode-client.ts:101-112`).
Subscribers = `curl -N <owner>/event?session_ids=<sid>` with matching `x-opencode-directory`
(faithfully mirrors how `opencode attach --session <id> --dir <dir>` subscribes).

1. **Alignment (no current divergence).** All 6 live attached sessions: the serve each TUI
   is attached to (`ps`) matches pigeon `/route` owner. So the symptom is NOT "TUI attached
   to the wrong serve" in steady state.
2. **Warm delivery works.** Injecting into a warm directory-instance with a fresh
   subscriber (session_ids + matching dir) delivered the FULL turn live:
   `message.updated`, `message.part.delta` ("P","ONG2"), `session.idle`. Non-owner serve
   stayed silent (correct).
3. **Cold first-turn drops content events (reproduced 3x).** A subscription opened while the
   owner serve cold-initialised the directory-instance (the `plugin.added`/`catalog.updated`
   flood) received the init flood + `session.next.agent.switched` + `session.next.model.switched`
   + heartbeats — but **zero** `message.*` / `session.status` / `session.idle`, even though
   the assistant reply was generated and stored in SQLite.
4. **The gap is sticky for the subscription's lifetime.** A single subscription opened cold
   missed `message.*` for BOTH a cold turn and a later warm turn (12 s apart) on the same open
   connection.
5. **Capstone (clean, same session, same turn).** Two subscriptions with the same dir header,
   both open during turn #2:
   - sub#A opened **pre-first-turn**: `delta:0 msg.updated:0 idle:0` (nothing).
   - sub#B opened **post-first-turn**: `delta:3 msg.updated:5` (delivered).
   Both turns completed in the DB (CAP1, CAP2). Same turn, same header → only the open-time
   instance state differs → **the subscription's filter binding is the discriminator.**

## Mechanism (source-grounded)

- `handlers/event.ts` (`eventResponse`) captures `instance = InstanceState.context` and
  `workspaceID = InstanceState.workspaceID` **once**, then filters every event:
  `event.location?.directory === instance.directory && (event.location.workspaceID === undefined || === workspaceID)`.
- `event-v2-bridge.ts` `publish` stamps `location` from `InstanceRef`/`WorkspaceRef` **at
  publish time**, and emits **no `location`** when `InstanceRef` is `undefined`. These
  sessions are `projectID:"global"` (workspaceID undefined → the workspaceID clause always
  passes), so the **directory** clause is the discriminator.
- `run-state.ts`: the agent loop runs **forked** onto a long-lived per-directory
  `data.scope` captured at the directory-instance's first `InstanceState` lookup
  (`Runner.make(data.scope, …)`), surviving the HTTP request. `session.next.*` are published
  synchronously in the prompt request's fiber context (correct `InstanceRef` → matches a
  cold sub's captured directory, so they pass); `message.*`/`session.status`/`session.idle`
  are published from the forked loop and carry a `location.directory` that does **not** match
  what a pre-first-turn subscription captured (but DOES match a post-first-turn subscription).
- Exact "why the directory value differs cold-vs-warm" (raw header vs normalized/canonical
  instance directory, or a transient pre-init InstanceRef) was not pinned by black-box
  probing — the SSE handler strips `location` from its output. **First step of the fix task:**
  build a local instrumented `opencode serve` that logs `event.location.directory` for
  `message.*` vs `session.next.*` and the subscription's captured `instance.directory`, for a
  pre- vs post-first-turn subscription. That one log run pins the exact mismatch.

## Real-world trigger

Matches the observed symptom, especially after the 3am nightly reset (serves restart cold)
or after migration/reconstitution onto a serve that hasn't served that directory yet:
`oc-auto-attach` restores a session and opens `/event` against a cold directory-instance →
the subscription is permanently filtered for `message.*` until the TUI reconnects. Re-attach
opens a fresh (now-warm) subscription → works. This is exactly "TUI lags; re-sync on
re-attach shows it."

## Implications for other beads

### 7zr7 (attach client /route self-resolve + reconnect) — IMPORTANT
7zr7's "reconnect on SSE drop / 409/410/421/503/refused" will **NOT** fix yl00: the cold-start
race does **not** drop the SSE connection — it stays open and silently filters. A drop-triggered
reconnect never fires. Either yl00 needs a serve-side fix, or the attach client needs an
additional heuristic ("re-subscribe if the first expected `message.*`/`session.status` after a
known-busy turn never arrives", or "always re-subscribe once after the instance reports warm").
Division stands: yl00 = serve-side emission/filter; 7zr7 = client /route + drop-reconnect.

### mn9r / zao4 (replace: broker + reconstitutor + process-per-session) — acceptance criteria
Make this a **hard acceptance criterion** of any replacement:

> Live delivery of an externally-injected (pigeon/swarm) message to an attached interactive
> session MUST work when the subscription is opened **before** the session's first turn on
> that runtime / against a **cold** instance — not only when opened post-warm. Test the
> pre-first-turn / cold-instance case explicitly; plus replay-from-durable-store on re-attach.

A process-per-session model that co-locates session-runner + renderer removes the
cross-client fan-out filter entirely (no `/event` directory filter between them) — but only if
designed in. A broker/reconstitutor that reuses opencode-serve's `/event` inherits this
cold-start filter race and must fix or avoid it.

## Fix options (for the eventual yl00 fix task — not yet decided)

1. **Serve-side (root cause):** ensure the forked agent loop publishes `message.*` with the
   same canonical `location.directory` the `/event` handler binds to — i.e., make the
   publish-time `InstanceRef.directory` and the subscribe-time `instance.directory` use one
   normalized source of truth. (Confirm exact mismatch first via the instrumented build.)
2. **Serve-side (filter robustness):** in `handlers/event.ts`, when `?session_ids=` is
   present, prefer the session aggregate (`event.data.sessionID ∈ session_ids`) over the
   directory clause for session-scoped events, so a per-session subscription is not also
   gated on a directory string that can drift on cold start. (Composes with the x8wi patch;
   keep global/lifecycle pass-through.)
3. **Client-side (workaround, overlaps 7zr7):** re-subscribe once after first warm signal.

Option 2 is the most targeted and pool-aligned (per-session subscriptions are exactly the
pool's model), but verify it cannot leak cross-directory events for the same session id.

## Fix landed (devbox, 2026-06-22) — option 2

User chose **option 2**. Implemented as `~/projects/opencode-patched/patches/event-cold-start-directory.patch`
(opencode-patched commit `c32dee0`, pushed; registered last in `patches/apply.sh`, MUST apply after
`event-session-scope`).

**Exact mechanism pinned (source, v1.17.7):** the discriminator is `FSUtil.resolve`
(`packages/core/src/fs-util.ts:225`): it returns `normalizePath(realpathSync(p))` when the path
**exists** but only `normalizePath(pathResolve(p))` (no symlink resolution) on **ENOENT**. The
`/event` handler binds `instance.directory` (= `InstanceRef.directory`, itself `FSUtil.resolve`d in
`instance-store.ts:109`) at subscribe time and the bridge stamps `location.directory` (= the forked
loop's `InstanceRef.directory`) at publish time. When the two sides resolve the same logical
directory at different lifecycle/existence moments (or through a symlinked path), the strings differ
and the exact-`===` directory filter (`handlers/event.ts:50-54`) silently drops the watched session's
events. Confirmed sufficient for the fix without a separate instrumented-serve run: option 2 bypasses
the directory comparison entirely for session-scoped events.

**The fix:** in `handlers/event.ts`, collapse the two sequential `Stream.filter`s (directory, then
session) into one. When `?session_ids=` is present and the event has a string `event.data.sessionID`,
forward iff `sessionIds.has(sid)` — independent of directory. `sessionID` is globally unique, so no
cross-directory leak. Non-session events and no-`session_ids` subscriptions keep directory/workspace
scoping; `server.connected`/heartbeat/`server.instance.disposed` are unaffected (outside the filter).

**TDD / verification:** added regression test "delivers watched-session events to a session-scoped
stream emitted by a different directory instance (yl00)" to `httpapi-event.test.ts` — a `?session_ids=`
subscriber bound to directory D2 must receive a session's `session.deleted` emitted from D1 (global
bus; `event.location.directory !== instance.directory`). RED (5s timeout) pre-fix, GREEN post-fix.
Full `httpapi-event.test.ts` = 7/7 pass; clean `apply.sh` on a fresh v1.17.7 worktree; the patched
package typecheck adds **zero** new errors (one pre-existing `session/session.ts:944` TS2719 from
`createnext-readback.patch`, unrelated to yl00).

**Not yet deployed.** Cutting `v1.17.7-patched.3` (`gh workflow run build-release.yml --field
version=1.17.7 --field revision=3`) bundles the WHOLE current `apply.sh` (serve-lease, createnext-readback,
attach-route-resolve = 7zr7's in-flight M7, plus this) and deploying it bumps `users/dev/home.base.nix`
+ restarts live serves. Coordinate revision numbering + readiness with cloudbox 7zr7 before release.
