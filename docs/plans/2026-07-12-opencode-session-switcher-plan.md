# OpenCode Session Switcher — Phase 1 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to
> implement this plan task-by-task.

**Goal:** A telescope fuzzy switcher that lists opencode sessions with semantic
state (working/blocked/idle/retry/error), grouped by project and scoped by tmux
session, and jumps-or-attaches to the selected session.

**Architecture:** Three independent, individually-truthful reads joined at
picker-open: (1) `opencode.db` = base list of sessions; (2) a per-serve-instance
heartbeated JSON *state overlay* written by an opencode plugin; (3) read-time
discovery over `/tmp/nvim-<pane>.sock` = attachment location. No shared mutable
file, no write-side registry. Full rationale + verified facts:
`docs/plans/2026-07-12-opencode-session-switcher-design.md`.

**Tech Stack:** TypeScript opencode plugin (`@opencode-ai/plugin`, vitest);
Neovim Lua (telescope, `vim.uv`, `vim.system`); Nix `sqlite` (read-only);
home-manager deployment via `users/dev/opencode-config.nix`. Host: cloudbox first.

**Read before starting:** the design doc; `assets/opencode/plugins/self-compact.ts`
(plugin/event-hook shape), `self-compact-impl.ts` (testable-helper split);
`assets/nvim/lua/user/oc_auto_attach.lua` and `.../telescope.lua`;
`pkgs/nvims/test.sh` (pure-Lua-helper test convention — **copy this**, don't
invent a new harness); `~/.local/bin/oc-search` (read-only sqlite pattern).
Event source of truth: `~/projects/opencode/packages/opencode/src/{session/status.ts,
permission/index.ts,question/index.ts,session/session.ts,session/session.sql.ts}`.

**Conventions:**
- TDD everywhere a harness exists (plugin → vitest; pure Lua → `test.sh`).
- Plugin **test-only helpers live in `*-impl.ts`** — the loader invokes every
  named export as a plugin factory (`self-compact.ts:15-18`). Only
  `export default` is the factory.
- Commit after every green step. Everything **cloudbox-gated** in Phase 1.

> **Prior-art consult (2026-07-30).** The agent-session-switcher *category* now
> exists (ccmux, Claude Agent View, Agent Deck, AoE, workmux, …) but none models
> our *logical conversation* identity. Plan changes: **new Task 0.5 — timeboxed
> ccmux spike** (gates whether we extend it or only steal techniques); four bug
> fixes folded in — **pending-interaction snapshot at plugin init** (Task 1/3),
> **(epoch, revision) ordering instead of wall-clock** (Task 2), **TOCTOU
> re-resolve on accept** (Task 10), **invoking-client-scoped tmux focus**
> (Task 10); plus the **`attention: seen/unseen` axis** (Tasks 7/8) and the
> **join moves into `oc-session-list`** so nvim isn't the correctness boundary
> (Tasks 6/9). Full rationale in the design doc's "Prior art" section.
>
> **Front-door reconciliation (2026-07-30).** The serve pool now sits behind a
> single door. Changes to this plan, all contained:
> **(a)** every attach/resume targets **`$FRONTDOOR_URL`** (default
> `http://127.0.0.1:4700`), never `:4096` — Tasks 0, 9, 10.
> **(b)** Task 10's detached-resume **shells out to the `oc-auto-attach` binary**
> instead of calling the Lua `M.open()`, so it inherits health-probe,
> `/route`→`/place` **pre-placement** (`C6`) and the door URL. Calling the Lua
> directly would skip pre-placement and cause door drift-reconnects.
> **(c)** `users/dev/test-frontdoor-opacity.sh` scans **`pkgs/*/default.nix`** —
> so `pkgs/oc-session-list` is governed. It is SQLite-only (no HTTP), so it
> passes with **no exemption marker**; keep it that way (adding any health check
> or serve URL fails the guard closed). Run the guard in Tasks 6 and 12.
> **(d)** Discovery must join **`oc_auto_attach.status(sid)`** — a `[FAILED]`
> attach buffer keeps `b:oc_session_id`, so buffer-presence alone would report a
> dead attach as `attached` (Task 5/8).
> **(e)** `oc_auto_attach.lua` line numbers shifted: the `isdirectory` guard is
> now **`:45`** (was `:35`), jobstart `:68`, `--dir` `:71`, `cwd` `:74`.
> **(f)** Pigeon is token-gated (anonymous `/route` → 401) and the serve token
> (Stage 2) is open — the switcher stays **HTTP-free except attach**, so neither
> can break it. Do not add serve calls.
> Unchanged and re-verified: K=4 / ports 4096-4099 (`serve-pool.nix:36`),
> `OPENCODE_SERVE_ID=serve-<i>` (`:22`), no shared bus, serve-lease migration,
> per-(serve×dir) plugin host, global `opencode.db`, nvims sockets, and the
> `--dir` event-filter rationale (`oc_auto_attach.lua:10-21`, intact).
>
> **Changes after review round 2 (2026-07-12).** Verified fixes folded in:
> (#1) dirhash was the first 8 bytes of the path — **all `/home/dev/...` paths
> collided**; now sha256. (#2) `permission.replied`/`question.replied` carry
> **`requestID`**, not `id` (`.asked` uses `id`) — reducer + tests corrected.
> (#3) `session.error` is followed ~instantly by `idle`; **error must be sticky**
> (cleared on next `busy`, not `idle`). (#4) merge returns **stale→`unknown`**
> entries, does not drop them. (#5) overlay filename drops the pid (design's
> restart-overwrite GC) + reader-side GC; clean-exit removal is best-effort only.
> (#6) base list ranks **per root** so a blocked child can't fall off the LIMIT.
> Mediums: `OPENCODE_SERVE_ID` as identity; discovery async + in-process self;
> tags merge-before-write; cross-host degrade; `switch-client -t %pane`; exclude
> archived; prune idle entries. **DB is NOT a scan risk** — 6,184 session rows,
> `ORDER BY time_updated DESC LIMIT 50` measured at 15 ms (13 GB is all in
> `part`, which the base list never touches).

---

## Task 0: Confirm the one remaining verification (`--dir <deleted>` attach)

Gates Task 10's directory-gone attach branch (design §4). Investigation only.

**Step 1:** Start a session in a temp dir via `opencode-launch`, let it idle,
`:bdelete` its attach buffer, then `rmdir` the temp dir.

**Step 2:** Run the exact resume the picker will use — **through the door**:
```bash
cd $HOME && opencode attach "${FRONTDOOR_URL:-http://127.0.0.1:4700}" \
  --session <sid> --dir <deleted-dir>
```
Expected (per `attach.ts:58-67`): no crash; TUI opens and streams (dir string
passes through, matches stored dir, event filter satisfied).

**Step 3:** Record confirmed/□ in the design doc's "Verification findings". If it
FAILS, Task 10's attach branch becomes **preview-only** — flag before proceeding.

**Step 4: Commit** the design-doc note.

---

## Task 0.5: ccmux spike (timeboxed, gates Task 1) — 2h max

**Investigation only. No code.** ccmux (`github.com/epilande/ccmux`) is the
closest prior art and already has an OpenCode event integration plus the
peripheral work we'd otherwise rebuild (picker/row model, notifications, tmux
target resolution, previews, sidebar). Decide: **extend it**, or **keep our
design and steal its techniques**.

**Step 1:** Clone read-only to `/tmp/opencode/ccmux`; read `docs/architecture.md`,
`docs/agent-adapters.md`, and its OpenCode adapter.

**Step 2:** Answer these six decisive questions in writing — they are all about
whether its identity model can invert from `pane/process → agent` to
`logical session → 0..N attachments`:
1. Can **one OpenCode server yield N independent logical rows** (not one
   aggregated row)? *Known concern: its docs say several logical sessions behind
   one server fold into that server's pane row — which is our exact topology.*
2. Can a row exist with **no TTY/pane at all** (detached-but-blocked)?
3. Can selection dispatch an arbitrary **`focus-or-attach(session_id)`** callback?
4. Can **attachments be a collection** rather than the session's identity?
5. Can transcript search be delegated to an **external provider** (our SQLite/FTS)?
6. Can **`question.asked/replied/rejected` + a pending snapshot** be added cleanly?

**Step 3: Decide and record** in the design doc's Prior-art section:
- **≥4 yes, and (1)+(2) are yes** → extending ccmux likely beats building; STOP
  and re-plan against it.
- **(1) or (2) is no** (expected) → keep this plan; extract a short "techniques to
  steal" list (tmux focus handling, notification shape, preview rendering) to
  reference from Tasks 9-11.

**Step 4: Commit** the decision note. Do not skip the write-up — an unrecorded
spike gets re-litigated.

---

## Task 1: State reducer — pure event→state (plugin core)

**Files:** Create `assets/opencode/plugins/session-state-impl.ts`; Test
`assets/opencode/plugins/test/session-state.test.ts`.

Field names are **already verified** (do not re-spike): `permission.asked` =
`{ id, sessionID, ... }` (`permission/index.ts:36`); `permission.replied` =
`{ sessionID, requestID, reply }` (`:71-78`). `question.asked` = `{ id,
sessionID, ... }` (`question/index.ts:58`); `question.replied`/`.rejected` =
`{ sessionID, requestID, ... }` (`:78-92`). `session.error.sessionID` is
**optional** (`session/session.ts:363`).

**Step 1: Write failing tests** (note asked→`id`, replied→`requestID`):
```typescript
import { describe, it, expect } from "vitest"
import { applyEvent, effectiveState, emptyState } from "../session-state-impl"
const ev = (type: string, properties: any) => ({ type, properties })

describe("applyEvent", () => {
  it("busy -> working; idle -> idle", () => {
    let s = applyEvent(emptyState(), ev("session.status", { sessionID: "s1", status: { type: "busy" } }))
    expect(effectiveState(s.s1)).toBe("working")
    s = applyEvent(s, ev("session.status", { sessionID: "s1", status: { type: "idle" } }))
    expect(effectiveState(s.s1)).toBe("idle")
  })
  it("permission.asked(id) -> blocked; replied(requestID) clears", () => {
    let s = applyEvent(emptyState(), ev("permission.asked", { sessionID: "s1", id: "p1" }))
    expect(effectiveState(s.s1)).toBe("blocked")
    s = applyEvent(s, ev("permission.replied", { sessionID: "s1", requestID: "p1" }))
    expect(effectiveState(s.s1)).toBe("idle")
  })
  it("two permissions pend as a set; one reply keeps blocked", () => {
    let s = applyEvent(emptyState(), ev("permission.asked", { sessionID: "s1", id: "p1" }))
    s = applyEvent(s, ev("permission.asked", { sessionID: "s1", id: "p2" }))
    s = applyEvent(s, ev("permission.replied", { sessionID: "s1", requestID: "p1" }))
    expect(effectiveState(s.s1)).toBe("blocked")
  })
  it("question.asked(id) -> blocked; replied(requestID) clears", () => {
    let s = applyEvent(emptyState(), ev("question.asked", { sessionID: "s1", id: "q1" }))
    expect(effectiveState(s.s1)).toBe("blocked")
    s = applyEvent(s, ev("question.rejected", { sessionID: "s1", requestID: "q1" }))
    expect(effectiveState(s.s1)).toBe("idle")
  })
  it("abort-while-pending: idle clears pending sets", () => {
    let s = applyEvent(emptyState(), ev("permission.asked", { sessionID: "s1", id: "p1" }))
    s = applyEvent(s, ev("session.status", { sessionID: "s1", status: { type: "idle" } }))
    expect(effectiveState(s.s1)).toBe("idle")
  })
  it("retry -> retry", () => {
    const s = applyEvent(emptyState(), ev("session.status", { sessionID: "s1", status: { type: "retry", attempt: 2, message: "429", next: 2000 } }))
    expect(effectiveState(s.s1)).toBe("retry")
  })
  it("error is STICKY: error then idle is still error", () => {
    let s = applyEvent(emptyState(), ev("session.error", { sessionID: "s1" }))
    s = applyEvent(s, ev("session.status", { sessionID: "s1", status: { type: "idle" } }))
    expect(effectiveState(s.s1)).toBe("error")
  })
  it("error cleared by next busy (new turn)", () => {
    let s = applyEvent(emptyState(), ev("session.error", { sessionID: "s1" }))
    s = applyEvent(s, ev("session.status", { sessionID: "s1", status: { type: "busy" } }))
    expect(effectiveState(s.s1)).toBe("working")
  })
  it("error with no sessionID is ignored", () => {
    expect(applyEvent(emptyState(), ev("session.error", {}))).toEqual({})
  })
  it("unrelated events create no entry and don't mutate", () => {
    const before = emptyState()
    expect(applyEvent(before, ev("message.part.updated", { sessionID: "s1" }))).toBe(before)
  })
  it("idle when already idle is a no-op (does not reset lastActivity)", () => {
    let s = applyEvent(emptyState(), ev("session.status", { sessionID: "s1", status: { type: "busy" } }))
    s = applyEvent(s, ev("session.status", { sessionID: "s1", status: { type: "idle" } }))
    const t = s.s1.lastActivity
    const s2 = applyEvent(s, ev("session.status", { sessionID: "s1", status: { type: "idle" } }))
    expect(s2.s1.lastActivity).toBe(t)   // cancel-non-busy republish must not bump idle-age
  })
})
```

**Step 2: Run — expect FAIL** (`cd assets/opencode/plugins && npx vitest run test/session-state.test.ts`).

**Step 3: Implement `session-state-impl.ts`:**
```typescript
export type Activity = "working" | "blocked" | "idle" | "retry" | "error" | "unknown"
export interface SessionEntry {
  activity: "working" | "idle" | "retry"     // raw status axis
  error: boolean                              // sticky until next busy
  pendingPermissions: string[]
  pendingQuestions: string[]
  retry?: { attempt: number; next: number }
  lastActivity: number
  updatedAt: number
}
export type StateMap = Record<string, SessionEntry>
export const emptyState = (): StateMap => ({})
const now = () => Date.now()
const fresh = (t: number): SessionEntry =>
  ({ activity: "idle", error: false, pendingPermissions: [], pendingQuestions: [], lastActivity: t, updatedAt: t })

export function applyEvent(prev: StateMap, event: { type: string; properties?: any }, clock = now): StateMap {
  const p = event.properties ?? {}
  const sid: string | undefined = p.sessionID
  if (!sid) return prev
  const t = clock()
  const cur = prev[sid]
  const e: SessionEntry = cur ? { ...cur } : fresh(t)
  let changed = !cur
  const bump = () => { e.updatedAt = t; e.lastActivity = t; changed = true }
  switch (event.type) {
    case "session.status": {
      const st = p.status?.type
      if (st === "idle") {
        if (e.activity === "idle" && !e.pendingPermissions.length && !e.pendingQuestions.length) return prev // no-op
        e.activity = "idle"; e.pendingPermissions = []; e.pendingQuestions = []; e.retry = undefined; bump()
      } else if (st === "busy") { e.activity = "working"; e.error = false; e.retry = undefined; bump() }
      else if (st === "retry") { e.activity = "retry"; e.retry = { attempt: p.status.attempt, next: p.status.next }; bump() }
      else return prev
      break
    }
    case "permission.asked":   e.pendingPermissions = [...new Set([...e.pendingPermissions, p.id])]; bump(); break
    case "permission.replied": e.pendingPermissions = e.pendingPermissions.filter(x => x !== p.requestID); bump(); break
    case "question.asked":     e.pendingQuestions = [...new Set([...e.pendingQuestions, p.id])]; bump(); break
    case "question.replied":
    case "question.rejected":  e.pendingQuestions = e.pendingQuestions.filter(x => x !== p.requestID); bump(); break
    case "session.error":      e.error = true; bump(); break
    default: return prev
  }
  if (!changed) return prev
  return { ...prev, [sid]: e }
}

export function effectiveState(e?: SessionEntry): Activity {
  if (!e) return "idle"
  if (e.error) return "error"
  if (e.pendingPermissions.length || e.pendingQuestions.length) return "blocked"
  return e.activity
}
```

**Step 4: Run — expect PASS.**

**Step 4b: Add `seedFromSnapshot` (BUG FIX 1 — startup blindness).** Tests first:
```typescript
it("seedFromSnapshot marks sessions with already-pending permissions as blocked", () => {
  const s = seedFromSnapshot(emptyState(), {
    permissions: [{ sessionID: "s1", id: "p1" }],
    questions:   [{ sessionID: "s2", id: "q1" }],
  })
  expect(effectiveState(s.s1)).toBe("blocked")
  expect(effectiveState(s.s2)).toBe("blocked")
})
```
Then implement (seed pending sets + `revision = 0`). Without this, a plugin that
starts while a permission is pending reports `idle` **forever** — every serve
restart silently loses blocked-ness. Task 3 wires the real snapshot source.

**Step 5: Commit** `feat(plugin): pure session-state reducer + snapshot seed`.

---

## GATE — corrections from the 2026-07-30 adversarial review (do before Task 2)

Four items. Three are doc-level and are folded into the task text below; one is a
code defect in shipped Task 1. Rationale and evidence live in the design doc.

1. **BUG FIX 1's resolution was wrong** — `/api/permission/request` is
   directory/instance-scoped, not global, and the "verified live" empty-list
   evidence could not have shown otherwise. Corrected in the design doc:
   each plugin instance seeds **itself** (own serve, own `ctx.directory`,
   in-process), and the seed is demoted toward a periodic **reconcile**. Also fix
   the seed-vs-stream race (`seedFromSnapshot` may only claim sessions with no
   event-derived entry).
2. **`revision` is never incremented** (`session-state-impl.ts` — declared line 12,
   set to 0 by the seed, bumped nowhere). Task 2's within-epoch tie-break is
   therefore dead on real data, and Task 2's specimen tests hand-craft revision
   values so they would pass anyway. **Fix in code before Task 2**, with a test that
   fails if the bump is absent.
3. **`epoch = process start time` is not a fencing token** — see Task 3 below.
4. **Deployed-fleet event fixture** must be captured before Task 3 wires the real
   bus (version skew, design doc finding #7).

## Task 2: Overlay serialization + merge (stale ⇒ unknown, never dropped)

**Files:** Modify `session-state-impl.ts`; extend the test.

**Step 1: Failing tests** (note: ordering is **(epoch, revision)**, NOT wall clock
— BUG FIX 2):
```typescript
import { mergeOverlays } from "../session-state-impl"
const entry = (over: any = {}) => ({ activity: "working", error: false, pendingPermissions: [], pendingQuestions: [], lastActivity: 10, updatedAt: 10, revision: 1, ...over })

it("higher epoch wins even when its wall clock is OLDER (serve-lease migration)", () => {
  // The bug this encodes: a delayed `idle` from the OLD owner must not
  // overwrite `blocked` from the NEW owner just because it arrived later.
  const oldOwner = { pid: 1, epoch: 1, heartbeat: 1000, sessions: { s1: entry({ activity: "idle", pendingPermissions: [], updatedAt: 999, revision: 9 }) } }
  const newOwner = { pid: 2, epoch: 2, heartbeat: 1000, sessions: { s1: entry({ activity: "working", pendingPermissions: ["p1"], updatedAt: 10, revision: 1 }) } }
  const m = mergeOverlays([oldOwner, newOwner] as any, { now: 1000, staleMs: 45000, isAlive: () => true })
  expect(m.s1.pendingPermissions).toEqual(["p1"])   // new owner wins on epoch
})
it("within one epoch, higher revision wins", () => {
  const a = { pid: 1, epoch: 1, heartbeat: 1000, sessions: { s1: entry({ activity: "working", revision: 1 }) } }
  const b = { pid: 1, epoch: 1, heartbeat: 1000, sessions: { s1: entry({ activity: "idle", revision: 2 }) } }
  const m = mergeOverlays([a, b] as any, { now: 1000, staleMs: 45000, isAlive: () => true })
  expect(m.s1.activity).toBe("idle")
})
it("dead pid and stale heartbeat -> entries flagged unknown, NOT dropped", () => {
  const deadPid = { pid: 999, heartbeat: 1000, sessions: { s2: entry() } }
  const stale   = { pid: 2,   heartbeat: 900,  sessions: { s3: entry() } }
  const m = mergeOverlays([deadPid, stale] as any, { now: 1000, staleMs: 45, isAlive: (pid) => pid === 2 })
  expect(m.s2.unknown).toBe(true)
  expect(m.s3.unknown).toBe(true)   // heartbeat age 100 > 45
})
```

**⚠ Epoch semantics — do not implement as boot time.** The design intends an
*ownership* generation ("the higher epoch always wins"), but a writer's
start-time/boot id does not order ownership. Migrate a session from a
**younger-booted** serve to an **older-booted** one and the new owner's epoch is
*lower*, so the old owner's stale entry wins **permanently** — not a race, a
persistent inversion. Staleness never rescues it: the old serve still hosts other
sessions, so its file heartbeat stays fresh, and nothing prunes a migrated-away
session (the writer prunes only on `session.deleted`). The serve canary restarts
serves individually, so boot times genuinely diverge.

Before implementing, resolve in this order:
1. Find a real per-session **ownership generation** the plugin can read (does the
   serve lease expose one?). Use it as `epoch`.
2. If unreachable: have the writer **self-prune sessions with no events for X
   minutes**, which bounds the inversion window to X, and document the residual.

Either way, **do not ship boot-time epochs described as fencing tokens.**

**Step 2: FAIL → Step 3: Implement.** `serializeOverlay({pid, serve, epoch,
directory, heartbeat, sessions})` = shape passthrough (`epoch` = the ownership
generation per above, NOT a boot id; `revision` is per-session, bumped by the
reducer on every state change — see GATE item 2, this is currently unimplemented). `mergeOverlays(files, {now, staleMs, isAlive})`: for each file
compute `live = isAlive(pid) && now - heartbeat <= staleMs`; union sessions
keeping the winner by **`(epoch, revision)`** — wall clock is diagnostic only and
must never decide; if a session's winning file is
NOT live, emit `{ ...entry, unknown: true, pendingPermissions: [],
pendingQuestions: [] }`. (Prune plain-idle entries with empty sets and no error
from the union — absent≡idle.)

**Step 4: PASS → Step 5: Commit** `feat(plugin): overlay serialize + stale-aware merge`.

---

## Task 3: Overlay writer plugin (identity, heartbeat, filename, GC)

**Files:** Create `assets/opencode/plugins/session-state.ts`; deploy in
`users/dev/opencode-config.nix` (cloudbox-gated). Manual verification.

**Step 1: Implement** (note: **sha256 dirhash**, **`OPENCODE_SERVE_ID` identity**,
**no pid in filename**):
```typescript
import type { Plugin } from "@opencode-ai/plugin"
import { mkdirSync, writeFileSync, renameSync, rmSync } from "node:fs"
import { join } from "node:path"; import { homedir } from "node:os"; import { createHash } from "node:crypto"
import { applyEvent, serializeOverlay, emptyState, type StateMap } from "./session-state-impl"

const DIR = join(homedir(), ".local/share/opencode/session-state.d")
const HEARTBEAT_MS = 15_000
const plugin: Plugin = async (ctx) => {
  mkdirSync(DIR, { recursive: true })
  const serve = process.env.OPENCODE_SERVE_ID || new URL(ctx.serverUrl).port || "0"   // `||` not `??`: an unset port is "" , not null
  const dirhash = createHash("sha256").update(ctx.directory ?? "").digest("hex").slice(0, 16)
  const file = join(DIR, `${serve}-${dirhash}.json`)   // restart overwrites its predecessor (free GC)
  let sessions: StateMap = emptyState()
  const flush = () => {
    const tmp = `${file}.${process.pid}.tmp`
    writeFileSync(tmp, JSON.stringify(serializeOverlay({ pid: process.pid, serve, directory: ctx.directory, heartbeat: Date.now(), sessions })))
    renameSync(tmp, file)   // per-writer temp name avoids cross-instance rename races
  }
  flush()
  const timer = setInterval(flush, HEARTBEAT_MS); if (typeof (timer as any).unref === "function") (timer as any).unref()
  process.once("exit", () => { try { clearInterval(timer); rmSync(file, { force: true }) } catch {} })  // best-effort only
  // ⚠ NOT SUFFICIENT — see "Zombie writer" below. Instance reload disposes and
  // recreates instances *inside a living process*, so `exit` never fires and the
  // old instance keeps flushing to the same file.
  return {
    event: async ({ event }) => {
      if (event?.type === "session.deleted") { const s = (event.properties as any)?.sessionID; if (s && sessions[s]) { delete sessions[s]; flush() } return }
      const next = applyEvent(sessions, event); if (next !== sessions) { sessions = next; flush() }
    },
  }
}
export default plugin
```
Add one vitest guarding the dirhash: two same-prefix paths → distinct filenames
(the bug that passed every other test).

**Step 1b: Wire the pending snapshot (BUG FIX 1).** Before the first `flush()`,
seed state from the instance's **currently-pending** permissions/questions via
`seedFromSnapshot`. Find the in-process authority (the `Permission`/`Question`
`InstanceState` maps — check what the plugin ctx exposes; if nothing is reachable
in-process, fall back to a door-side read, and if neither works **stop and
report**: this is a Phase-1 blocker, not a nice-to-have). Also stamp `epoch`
(process start time) once at init. Smoke: trigger a permission prompt, restart
that serve, confirm the session still reads `blocked` after restart.

**Step 1b: Zombie writer defense (adversarial review, 2026-07-30).** Clearing the
interval on `process.once("exit")` is not enough. `InstanceStore.reload` disposes
and recreates instances **inside a living process** (and `InstanceDisposed` likely
never reaches the plugin — see Risks). The old plugin instance's interval then keeps
flushing **stale state with a fresh heartbeat and a live pid** to the *same*
`${serve}-${dirhash}.json`, alternating whole-file overwrites with the new
instance. The reader cannot detect this: same pid, fresh heartbeat. Every reload
leaks another writer.

Fix: stamp a **per-instance init timestamp** into the file. On each `flush()`, read
the current file first; if its stamp is **newer than our own**, we have been
superseded — `clearInterval` and go silent (do not delete the file; the live
instance owns it).

Cheap verification: trigger one instance reload on cloudbox and confirm the file
does not flap between two states.

**Step 1c: Seed scope + race (GATE items 1 and 4).** Seed **in-process from this
instance's own serve** (`ctx.serverUrl`, `ctx.directory`) — NOT fleet-wide through
the door, which is impossible anyway (the endpoints are directory-scoped) and
would lazily instantiate instances. Fire-and-forget; never `await` during init.
Apply the snapshot only to sessions with **no event-derived entry yet**, so a
late-landing snapshot cannot drop a newer `asked` or resurrect a replied prompt.
Prefer a periodic (~60 s) reconcile over a one-shot boot seed — see the design
doc, which argues the startup-blindness premise is weak for an in-process observer
and the real value is drift repair.

Before this task: capture a real permission ask/reply and a busy/idle cycle from
the **deployed** fleet (1.17.x, not the 1.15.10 source tree) and commit as fixtures.

**Step 2: Typecheck** `npx tsc --noEmit` → clean.

**Step 3: Deploy** beside the other plugin entries in `opencode-config.nix`:
```nix
xdg.configFile."opencode/plugins/session-state.ts" = lib.mkIf isCloudbox { source = "${assetsPath}/opencode/plugins/session-state.ts"; };
xdg.configFile."opencode/plugins/session-state-impl.ts" = lib.mkIf isCloudbox { source = "${assetsPath}/opencode/plugins/session-state-impl.ts"; };
```

**Step 4: Manual smoke.** `nix run home-manager -- switch --flake .#cloudbox`;
drive a session to blocked/working; `cat ~/.local/share/opencode/session-state.d/*.json`.
Expect one file per (serve×dir), advancing `heartbeat`, correct state.
**Note:** on serve SIGKILL/nightly reset the file is NOT removed (exit handler
doesn't run) — that's expected; the reader's dead-PID/stale check + GC (Task 4)
handles it, and a same-port restart overwrites it. Do not treat a lingering file
as a bug.

**Step 5: Commit** `feat(plugin): session-state overlay writer (cloudbox)`.

---

## Task 4: Lua overlay reader (merge, liveness, GC)

**Files:** Create `assets/nvim/lua/user/session_switcher/overlay.lua`; Create
`assets/nvim/lua/user/session_switcher/test.sh` (copy the `pkgs/nvims/test.sh`
harness — headless-Lua via `nvim -l`; this is a proven in-repo pattern, not a
maybe).

**Step 1: Write `test.sh`** asserting the pure `overlay.merge(files, opts)`
matches Task 2's semantics: newest-wins; dead-pid/stale → `unknown` flag (not
dropped). Inject `is_alive` so tests need no real PIDs.

**Step 2: FAIL → Step 3: Implement.** `overlay.merge` (port of `mergeOverlays`).
`overlay.read()` = glob `session-state.d/*.json`, `vim.json.decode` each, `merge`
with `now=os.time()*1000`, `stale_ms=45000`,
`is_alive=function(pid) return vim.uv.kill(pid,0)==0 end`. **Opportunistic GC:**
unlink any file that is both dead-pid AND `heartbeat` older than 10 min.

**Step 4: PASS + manual smoke → Step 5: Commit** `feat(nvim): overlay reader + GC`.

---

## Task 5: Lua socket discovery (attachment location)

**Files:** Create `.../discovery.lua`, `.../rpc.lua`; extend `test.sh`.

**Step 1: Tests** (pure parts): `discovery.pane_of(sock)` (`/tmp/nvim-%3.sock`
→ `%3`); `discovery.dedupe(results)` (last-writer per sid); **`discovery.is_live(hit)`
— `attach_status=="running"` ⇒ attached; `"failed"`/`"exited"` ⇒ NOT attached**
(a `[FAILED]` buffer keeps `b:oc_session_id`, so this test is the guard against
"jump me to a dead terminal").

**Step 2: FAIL → Step 3: Implement.**
- `rpc.snapshot()` → scan this nvim's buffers for `b:oc_session_id`; for each,
  also read `require("user.oc_auto_attach").status(sid)`
  (`oc_auto_attach.lua:30-33`); return
  **`vim.json.encode([...{sid,buffer,tabpage,attach_status}])` (a string)**.
- `discovery.locate()`:
  - **own** sockets: call `rpc.snapshot()` in-process (never `--remote-expr`
    yourself — deadlock hazard);
  - **others**: spawn ALL `vim.system({ "nvim","--server",sock,"--remote-expr",
    "luaeval('require(\"user.session_switcher.rpc\").snapshot()')" }, {stdin=false})`
    jobs **async**, then a single `vim.wait(deadline)`; skip stragglers/dead
    sockets (a target stuck in a modal prompt must not stall the picker).
  - derive tmux via `tmux display -p -t %<pane> '#{session_name}\t#{window_name}'`.
  - return `{ [sid] = { sock, pane, buffer, tabpage, tmux_session, tmux_window } }`.

**Step 4: Manual smoke** on cloudbox: `:lua print(vim.inspect(require("user.session_switcher.discovery").locate()))`
shows live attach buffers with correct tmux window/session; kill an nvim → its
entry vanishes with no error.

**Step 5: Commit** `feat(nvim): read-time nvim-socket discovery`.

---

## Task 6: DB base-list helper (per-root recency, exclude archived)

**Files:** Create `pkgs/oc-session-list/{default.nix,oc-session-list}`; Test
`pkgs/oc-session-list/test.sh`. Package with a nix `sqlite` dependency (avoid
oc-search's hardcoded store-path rot).

**Step 1: Test** the emitted SQL: opens `file:$DB?mode=ro`, `PRAGMA busy_timeout`;
selects `id,title,parent_id,directory,time_updated`; **excludes archived**
(`time_archived IS NULL`, `session/session.sql.ts:52`); ranks **per root** so a
recently-active child keeps its (older) parent tree in the top-N:
**⚠ `COALESCE(parent_id,id)` is WRONG here (adversarial review, 2026-07-30).** It
lifts a child exactly **one** level, but this fleet has **multi-level** nesting —
our own sq1v work walks parents "bounded at depth 8" and live-verified real
grandchild chains. With the COALESCE form a blocked grandchild resolves to a
*middle* session as its root, so it never rolls up to the true root and
**blocked-pierces-scope silently fails for exactly the swarm topology that
motivated this feature.**

Use `WITH RECURSIVE` to walk to the true root (bound the depth), and add a
**3-level fixture test**. At ~6k rows the cost is irrelevant.

The same defect infects **Task 9's** "union in overlay-blocked roots": an overlay
sid may be a deep child, so that individual fetch must walk up too — and must apply
the same `time_archived IS NULL` filter as the base list, or the union will
resurrect archived sessions.

```sql
-- roots (and their trees) ordered by the tree's most-recent activity
-- REPLACE the COALESCE below with a recursive walk to the true root:
WITH tree AS (
  SELECT id,title,parent_id,directory,time_updated,
         COALESCE(parent_id,id) AS root   -- ⚠ single-level; see warning above
  FROM session WHERE time_archived IS NULL
),
ranked AS (SELECT root, MAX(time_updated) AS recency FROM tree GROUP BY root
           ORDER BY recency DESC LIMIT :n)
SELECT t.* FROM tree t JOIN ranked r ON t.root = r.root ORDER BY r.recency DESC;
```
(No index on `time_updated`, but 6,184 rows → ~15 ms; the base list never touches
`part`.)

**Step 2: FAIL → Step 3: Implement** emitting JSON rows. `--tail <sid>` mode is
added in Task 11.

**Step 3b: `--with-state` — the join lives HERE, not in Lua.** Add a mode that
performs the full join (base list + overlay merge + discovery) and emits ready-to
-render rows. Rationale (consult 2026-07-30): the picker must be a *frontend*;
nvim must not be the correctness boundary, and a second frontend (fzf/tmux, for
recovery and use outside nvim) must be possible without reimplementing the merge.
Tasks 4/5/8's Lua modules become **thin callers** of this (or, if the merge is
easier to keep in Lua for Phase 1, they must be a *library* callable headlessly —
either way, one implementation, tested once). The fzf client itself is not Phase-1
scope; the seam is.

**Step 4: Smoke** `oc-session-list --limit 50 | head`.

**Step 4b: Front-door opacity guard must pass.** `pkgs/*/default.nix` is governed
by `users/dev/test-frontdoor-opacity.sh`. This package is **SQLite-only — no HTTP,
no serve URL, no health check** — so it needs **no** `frontdoor-exempt` marker.
Run it and expect a clean pass:
```bash
bash users/dev/test-frontdoor-opacity.sh
```
If it flags this package, you added a serve-addressing site — remove it (take the
data from the DB) rather than adding a marker.

**Step 5: Commit** `feat: oc-session-list per-root recent-session query`.

---

## Task 7: Tags store (sticky space/project, merge-before-write)

**Files:** Create `.../tags.lua`; extend `test.sh`.

**Step 1: Tests:** `tags.classify(entry)` (dir matches `.worktrees/pr%-%d+` →
`space="lgtm"`); `tags.merge(disk, updates)` (sticky last-known, updates win but
never erase unrelated sids — the anti-clobber test); `tags.get`; **`tags.seen(sid, ts)`
+ `tags.attention(entry, seen_at)` → `seen|unseen`** (unseen iff
`lastActivity > seen_at`; never-seen ⇒ `unseen`).

**Step 2: FAIL → Step 3: Implement.** `session-tags.json`; on write, **re-read +
merge then tmp+rename** (≥10 nvims may write concurrently — last-writer-wins on
the WHOLE file would erase peers' tags). Learn `space`/`project` from discovery's
tmux session/window for attached sessions; directory-classify otherwise.

**Step 4: PASS → Step 5: Commit** `feat(nvim): sticky tags store (merge-before-write)`.

---

## Task 8: Join + row model (pure)

**Files:** Create `.../model.lua`; extend `test.sh`.

**Step 1: Tests** for `model.build(baselist, overlay, location, tags, {current_space})`:
- roots only; children folded → parent gets `child_state` (a blocked child →
  parent `child_blocked` glyph, not masqueraded as the parent's own blocked).
- `effective_state`: overlay `unknown` flag → `unknown`; pending/error → blocked/
  error; else activity; missing overlay → idle.
- attachment = `location[sid] ~= nil`.
- **dir-missing overrides BOTH glyph and sort** (Task 0 finding). Stat the
  directory during the join; if it's gone, the row can never make progress, so it
  must not be allowed to sort as `working`. Otherwise a prompted dir-gone session
  emits busy, never idles, and pins itself to the **top** of the list forever.
- sort: `error`/`blocked` → `retry` → `working` → **`idle`+`unseen`** → `idle`/`unknown`;
  then asc idle-age (overlay `lastActivity`, fallback DB `time_updated`);
  clustered by project.
- **attention axis:** assert an `idle` session whose `lastActivity > seen_at`
  renders `unseen` and sorts above ordinary idle — this is what stops
  completed-but-unreviewed work vanishing into the idle pile. Focusing it via the
  picker marks it `seen`.
- scope: keep `space==current_space` OR `space==nil` OR state∈{blocked,error}.
  **Assert a detached, blocked, untagged worker survives the default filter.**
- **overlay-truth union:** assert a root the overlay reports blocked/working is
  present even if Task 6's base list (recency LIMIT) omitted it. (init.lua feeds
  such roots in; model must not drop them.)

**Step 2: FAIL → Step 3: Implement.**

**Step 4: PASS → Step 5: Commit** `feat(nvim): switcher row model`.

---

## Task 9: Telescope picker (title mode)

**Files:** Create `.../init.lua`; modify `telescope.lua`. Manual verification.

**Step 1: Implement** finder: `oc-session-list` → `overlay.read()` →
`discovery.locate()` → `tags` → **union in overlay-blocked/working roots not in
the base list** (fetch their rows individually) → `model.build(current_space)`.
Display `[project] <glyph> <title> · <idle-age>`; `ordinal = project.." "..title`.
Previewer stub (Task 11 fills body). `current_space` = `tmux display -p
'#{session_name}'`.

**Step 2: Keymap** in `telescope.lua`, **guarded for cross-host degrade**:
```lua
vim.keymap.set("n", "<leader>fs", function()
  if vim.fn.executable("oc-session-list") == 0 then
    vim.notify("session switcher unavailable on this host", vim.log.levels.WARN); return
  end
  require("user.session_switcher").open()
end, { desc = "OC sessions" })
```
(Overlay/discovery missing ⇒ finder still renders rows as `unknown`/detached.)

**Step 3: Facet actions:** toggle `attached/detached/all`, `blocked only`,
`lgtm only`/`all spaces` — re-run finder on toggle.

**Step 4: Manual smoke:** lists current-space sessions, correct glyphs, grouped,
blocked on top; detached-blocked shows out-of-scope.

**Step 5: Commit** `feat(nvim): telescope session switcher (title mode)`.

---

## Task 10: Jump-or-attach action (incl. directory-gone)

**Files:** modify `.../init.lua`, `oc_auto_attach.lua`.

**Step 0 (BUG FIX 3 — TOCTOU): re-resolve on accept.** A row can be correct when
rendered and stale when selected (pane closed, buffer replaced, window renamed,
session migrated, state flipped). Before acting, **re-run discovery for that one
sid and re-read the overlay**; act on the fresh result, never on the target
embedded in the row. If it's now detached, fall through to the resume branch.

**Step 0b (BUG FIX 4 — client identity): capture the invoking tmux client** at
picker-open (`tmux display -p '#{client_name}'`) and pass it to every tmux call.
With several attached clients a bare `switch-client` can move an unrelated client
or leave the invoking terminal unchanged.

**Step 1: Select action:**
- **already in THIS nvim** → just focus the buffer/tabpage; no tmux round-trip.
- **attached** (`attach_status == "running"`) elsewhere: `tmux switch-client -c
  <invoking-client> -t %<pane>` (pane id from the *re-resolved* discovery), then
  `nvim --server <sock> --remote-expr` to focus buffer/tabpage (`stdin=false`).
- **detached** (incl. `failed`/`exited` attach buffers): **shell out to the
  packaged `oc-auto-attach` binary** — `vim.system({ "oc-auto-attach", sid },
  { stdin = false })`. Do NOT call the Lua `M.open()` directly: the binary owns
  the health probe, the `/route`→`/place` **pre-placement** (`C6` — without it the
  door's first `/event?session_ids=` drift-reconnects), `$FRONTDOOR_URL`, and the
  settle logic. This also keeps the switcher outside the opacity guard's scope.

**Step 2: Directory-gone ⇒ READ-ONLY (Option A — decided 2026-07-30 after Task 0).**

Task 0 downgraded this branch. Attaching *works* (TUI opens, history renders),
but the session **can never complete a turn** and hangs with no error — see the
design doc's Verification finding #1 for the controlled A/B. So we open it for
reading and refuse to imply it is resumable.

Implementation (in `oc_auto_attach.lua`, driven by the picker):
- Add `opts.allow_missing_dir`: skip the `isdirectory==0` reject (**now line 45**,
  was 35), set jobstart `cwd = vim.env.HOME` (**line 74**), still pass
  `--dir <stored dir>` (**line 71**), and pass
  `url = vim.env.FRONTDOOR_URL or "http://127.0.0.1:4700"`. Default (non-picker)
  path unchanged. No pre-placement needed — these are old/pruned-worktree sessions.
- **Before opening, `vim.notify` a warning**: directory `<dir>` no longer exists;
  this session is **read-only** — sending a message will hang with no error.
- The row itself must be **visibly marked** (Task 8/9) so the state is obvious
  *before* selecting, not only after.

**Do NOT** silently let the user type into it. The whole hazard is that the hang
is indistinguishable from normal thinking.

**Future Option B (deliberately deferred, not scheduled): re-rooting.** Make a
directory-gone session resumable again by rebinding it to a live directory
(`$HOME`, or a user-picked replacement). Attractive because the conversation
itself is intact — only its filesystem anchor is missing. Deferred because it
needs its own machinery: a way to rewrite/override the session's stored directory
server-side (or start a successor session seeded with the old transcript), a
picker affordance to choose the new root, and a decision about whether the
rebinding is sticky. Revisit if read-only turns out to be annoying in practice.
Nothing in Option A blocks it — the row condition and the notice are exactly the
hooks Option B would hang off.

**Step 3: Manual smoke:** cross-window/session jump focuses correctly; resume
detached; resume detached with pruned dir (Task 0 outcome).

**Step 4: Commit** `feat(nvim): jump-or-attach with directory-gone fallback`.

---

## Task 11: Preview body (transcript tail)

**Files:** extend `pkgs/oc-session-list` with `--tail <sid>`; `.../init.lua`
previewer.

**Step 1:** Read-only query: last user prompt + last assistant text `part.data`
for a sid, using the existing `message_session_time_created_id_idx` /
`part_session_idx` (`session.sql.ts:72,88`); `mode=ro` + `busy_timeout`.

**Step 2:** Previewer: header (`title · glyph · idle-age · space · project · dir`)
+ tail body.

**Step 3: Smoke** → **Step 4: Commit** `feat(nvim): switcher preview (transcript tail)`.

---

## Task 12: Integration pass + docs

**Step 1:** E2E on cloudbox (multi-project, lgtm running, a blocked swarm
worker): default hides lgtm, blocked pierces scope, grouping/jump/resume/preview
work, and a **killed serve degrades its sessions to `unknown` within ~45 s** (not
frozen `working`, not `idle`). Also verify a **crashed attach** (`[FAILED]`
buffer) shows as detached/attach-failed and resume repairs it.

**Step 1b: Front-door regression gates.** Both must pass before landing:
```bash
bash users/dev/test-frontdoor-opacity.sh     # no new serve-addressing sites
```
Confirm on the wire that resume went through the door, not a serve:
`pgrep -af 'opencode attach' | grep -c 4700` should account for every attach
started by the picker, and none should show `:409[0-9]`.

**Step 2:** Write `.opencode/skills/using-session-switcher/SKILL.md` (keymap,
facets, glyphs, file locations).

**Step 3:** Design doc status → "Phase 1 implemented".

**Step 4: Commit** then **land:** `nix run home-manager -- switch --flake
.#cloudbox`; `git pull --rebase && git push`; verify `git status` clean.

---

## Deferred (not this plan)

- **Phase 2:** content-search mode (reuse `oc-search`; hit→sid→jump).
- **Phase 3:** Telegram forum-topic notifier (tail overlay transitions;
  `working→blocked`).
- **Later:** statusline counts (only after staleness handling proven), live-buffer
  preview, mobile, cross-host jump, socket/HTTP overlay push, oc-auto-attach
  project→directory routing.
- **Option B — re-rooting a directory-gone session** (user-approved as a *future*
  option, 2026-07-30; Option A read-only ships first). Rebind a session whose
  directory was deleted to a live directory so it becomes resumable again. See
  Task 10 Step 2 for why it's separable and what it would need.

## Risks / watch-items

- **OpenCode event-schema drift.** workmux has already broken on OpenCode
  lifecycle event renames. Keep OpenCode decoding behind a **versioned adapter**
  emitting our own small internal schema (`SessionBusy|SessionIdle|SessionRetrying|
  PermissionPending|PermissionResolved|QuestionPending|QuestionResolved|
  SessionErrored|SessionDeleted`), retain unknown raw events for diagnostics, and
  add fixture tests from captured event sequences. (Task 1 is already shaped this
  way — keep it that way.)
- **Never answer a blocked session by injecting keystrokes into a shared pane.**
  Target the session id via the structured response API or a client explicitly
  bound to that sid. (Future "answer from the picker" feature; noted so it isn't
  built the wrong way.)
- **Attach may not replay a pending interaction** — show pending from our own
  state rather than assuming the attached TUI rediscovers it.
- **Partial serve wedge** (timer fires, agent loop stuck): heartbeat can't catch
  it; `updatedAt`-age vs a claimed-`working` is the only secondary signal
  (documented limitation).
- **InstanceDisposed** likely never reaches the plugin (Bus tears down before its
  dependents) — do NOT rely on it; reader-side dead-PID + GC is the real cleanup.
- **Discovery latency** if many nvims are modal-blocked: mitigated by async-spawn
  + single deadline; keep the deadline tight (~300 ms).
