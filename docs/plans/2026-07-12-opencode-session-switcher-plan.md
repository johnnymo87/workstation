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

**Step 2:** Run the exact resume the picker will use:
```bash
cd $HOME && opencode attach http://127.0.0.1:4096 --session <sid> --dir <deleted-dir>
```
Expected (per `attach.ts:58-67`): no crash; TUI opens and streams (dir string
passes through, matches stored dir, event filter satisfied).

**Step 3:** Record confirmed/□ in the design doc's "Verification findings". If it
FAILS, Task 10's attach branch becomes **preview-only** — flag before proceeding.

**Step 4: Commit** the design-doc note.

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

**Step 4: Run — expect PASS. Step 5: Commit** `feat(plugin): pure session-state reducer`.

---

## Task 2: Overlay serialization + merge (stale ⇒ unknown, never dropped)

**Files:** Modify `session-state-impl.ts`; extend the test.

**Step 1: Failing tests:**
```typescript
import { mergeOverlays } from "../session-state-impl"
const entry = (over: any = {}) => ({ activity: "working", error: false, pendingPermissions: [], pendingQuestions: [], lastActivity: 10, updatedAt: 10, ...over })

it("newest updatedAt wins (serve-lease migration)", () => {
  const a = { pid: 1, heartbeat: 1000, sessions: { s1: entry({ activity: "working", updatedAt: 10 }) } }
  const b = { pid: 2, heartbeat: 1000, sessions: { s1: entry({ activity: "idle", updatedAt: 20 }) } }
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

**Step 2: FAIL → Step 3: Implement.** `serializeOverlay({pid, serve, directory,
heartbeat, sessions})` = shape passthrough. `mergeOverlays(files, {now, staleMs,
isAlive})`: for each file compute `live = isAlive(pid) && now - heartbeat <=
staleMs`; union sessions keeping max `updatedAt`; if a session's winning file is
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
  const serve = process.env.OPENCODE_SERVE_ID ?? new URL(ctx.serverUrl).port ?? "0"
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
→ `%3`); `discovery.dedupe(results)` (last-writer per sid).

**Step 2: FAIL → Step 3: Implement.**
- `rpc.snapshot()` → scan this nvim's buffers for `b:oc_session_id`; return
  **`vim.json.encode([...{sid,buffer,tabpage}])` (a string)**.
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
```sql
-- roots (and their trees) ordered by the tree's most-recent activity
WITH tree AS (
  SELECT id,title,parent_id,directory,time_updated,
         COALESCE(parent_id,id) AS root
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

**Step 4: Smoke** `oc-session-list --limit 50 | head`.

**Step 5: Commit** `feat: oc-session-list per-root recent-session query`.

---

## Task 7: Tags store (sticky space/project, merge-before-write)

**Files:** Create `.../tags.lua`; extend `test.sh`.

**Step 1: Tests:** `tags.classify(entry)` (dir matches `.worktrees/pr%-%d+` →
`space="lgtm"`); `tags.merge(disk, updates)` (sticky last-known, updates win but
never erase unrelated sids — the anti-clobber test); `tags.get`.

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
- sort: `error`/`blocked` → `retry` → `working` → `idle`/`unknown`; then asc
  idle-age (overlay `lastActivity`, fallback DB `time_updated`); clustered by project.
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

**Step 1: Select action:**
- **attached**: `tmux switch-client -t %<pane>` (single unambiguous call —
  resolves session+window+pane; pane id is from discovery), then
  `nvim --server <sock> --remote-expr` to focus buffer/tabpage (`stdin=false`).
- **detached**: existing `oc_auto_attach` resume path.

**Step 2: Directory-gone in `oc_auto_attach.lua`.** Add `opts.allow_missing_dir`:
the picker-resume path skips the `isdirectory==0` reject (line 35), sets jobstart
`cwd = vim.env.HOME`, still passes `--dir <stored dir>`. Default path unchanged.
If Task 0 downgraded to preview-only, this branch shows a notice instead.

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
frozen `working`, not `idle`).

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

## Risks / watch-items

- **Partial serve wedge** (timer fires, agent loop stuck): heartbeat can't catch
  it; `updatedAt`-age vs a claimed-`working` is the only secondary signal
  (documented limitation).
- **InstanceDisposed** likely never reaches the plugin (Bus tears down before its
  dependents) — do NOT rely on it; reader-side dead-PID + GC is the real cleanup.
- **Discovery latency** if many nvims are modal-blocked: mitigated by async-spawn
  + single deadline; keep the deadline tight (~300 ms).
