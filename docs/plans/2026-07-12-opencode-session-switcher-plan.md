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
Neovim Lua (telescope, `vim.uv`); Nix `sqlite` (read-only); home-manager
deployment via `users/dev/opencode-config.nix`. Host: cloudbox first.

**Read before starting:** the design doc (above); `assets/opencode/plugins/self-compact.ts`
(plugin/event-hook shape), `self-compact-impl.ts` (testable-helper split
convention); `assets/nvim/lua/user/oc_auto_attach.lua` and `.../telescope.lua`;
`pkgs/nvims/test.sh` (pure-Lua-helper test convention);
`~/.local/bin/oc-search` (read-only sqlite invocation pattern). Source of truth
for events: `~/projects/opencode/packages/opencode/src/{session/status.ts,
permission/index.ts,question/index.ts,session/session.ts}`.

**Conventions:**
- TDD everywhere a harness exists (plugin → vitest; pure Lua → `test.sh`).
- Plugin **test-only helpers live in `*-impl.ts`**, never the plugin file — the
  loader invokes every named export as a plugin factory
  (`self-compact.ts:15-18`). Only `export default` is the factory.
- Commit after every green step.
- Everything is **cloudbox-gated** in `opencode-config.nix` (`lib.mkIf isCloudbox`)
  for Phase 1.

---

## Task 0: Confirm the one remaining verification (`--dir <deleted>` attach)

Gates the directory-gone fallback (design §4). Pure investigation; no code.

**Step 1:** On cloudbox, pick a real detached session whose directory still
exists; note its `id` and `directory` from `GET /session/<id>` (or oc-search).

**Step 2:** Simulate a pruned dir: create a temp dir, start a session there via
`opencode-launch`, let it go idle, `:bdelete` its attach buffer, then `rmdir`
the temp dir.

**Step 3:** Manually run the resume the picker will use:
```bash
cd $HOME && opencode attach http://127.0.0.1:4096 \
  --session <sid> --dir <the-now-deleted-dir>
```
Expected (per `attach.ts:58-67`): no crash; TUI opens and streams events (dir
string passed through, matches stored dir, event filter satisfied).

**Step 4:** Record the result in the design doc's "Verification findings" as
confirmed/□. If it does NOT work, the directory-gone path becomes **preview-only**
and Task 12's attach branch is cut — flag before proceeding.

**Step 5:** Commit the design-doc note.
```bash
git add docs/plans/2026-07-12-opencode-session-switcher-design.md
git commit -m "docs: confirm --dir <deleted> attach behavior (smoke test)"
```

---

## Task 1: State reducer — pure event→state function (plugin core)

**Files:**
- Create: `assets/opencode/plugins/session-state-impl.ts`
- Test: `assets/opencode/plugins/test/session-state.test.ts`

First confirm exact event property field names in source (spike, ~5 min):
`permission.asked`/`.replied` payload key for the permission id
(`permission/index.ts:70-78`), and `question.asked`/`.replied`/`.rejected`
(`question/index.ts:90-92`). Use those names in the reducer.

**Step 1: Write failing tests.**
```typescript
import { describe, it, expect } from "vitest"
import { applyEvent, effectiveState, emptyState, type StateMap } from "../session-state-impl"

const ev = (type: string, properties: any) => ({ type, properties })

describe("applyEvent", () => {
  it("session.status busy -> working", () => {
    const s = applyEvent(emptyState(), ev("session.status", { sessionID: "s1", status: { type: "busy" } }))
    expect(effectiveState(s.s1)).toBe("working")
  })
  it("session.status idle -> idle and clears pending permission", () => {
    let s = applyEvent(emptyState(), ev("permission.asked", { sessionID: "s1", id: "p1" }))
    expect(effectiveState(s.s1)).toBe("blocked")
    s = applyEvent(s, ev("session.status", { sessionID: "s1", status: { type: "idle" } }))
    expect(effectiveState(s.s1)).toBe("idle") // abort-while-pending clears ghosts
  })
  it("permission.asked -> blocked overrides working", () => {
    let s = applyEvent(emptyState(), ev("session.status", { sessionID: "s1", status: { type: "busy" } }))
    s = applyEvent(s, ev("permission.asked", { sessionID: "s1", id: "p1" }))
    expect(effectiveState(s.s1)).toBe("blocked")
  })
  it("two permissions pend as a set; one reply keeps blocked", () => {
    let s = applyEvent(emptyState(), ev("permission.asked", { sessionID: "s1", id: "p1" }))
    s = applyEvent(s, ev("permission.asked", { sessionID: "s1", id: "p2" }))
    s = applyEvent(s, ev("permission.replied", { sessionID: "s1", id: "p1" }))
    expect(effectiveState(s.s1)).toBe("blocked")
  })
  it("question.asked -> blocked; replied clears", () => {
    let s = applyEvent(emptyState(), ev("question.asked", { sessionID: "s1", id: "q1" }))
    expect(effectiveState(s.s1)).toBe("blocked")
    s = applyEvent(s, ev("question.replied", { sessionID: "s1", id: "q1" }))
    expect(effectiveState(s.s1)).toBe("idle")
  })
  it("session.status retry -> retry", () => {
    const s = applyEvent(emptyState(), ev("session.status", { sessionID: "s1", status: { type: "retry", attempt: 2, message: "429", next: 2000 } }))
    expect(effectiveState(s.s1)).toBe("retry")
  })
  it("session.error -> error", () => {
    const s = applyEvent(emptyState(), ev("session.error", { sessionID: "s1" }))
    expect(effectiveState(s.s1)).toBe("error")
  })
  it("ignores unrelated events and events without sessionID", () => {
    const s = applyEvent(emptyState(), ev("message.part.updated", { sessionID: "s1" }))
    expect(s.s1).toBeUndefined()
  })
})
```

**Step 2: Run — expect FAIL** (`applyEvent` not defined):
`cd assets/opencode/plugins && npx vitest run test/session-state.test.ts`

**Step 3: Implement `session-state-impl.ts`.** Sketch (fill in confirmed field
names):
```typescript
export type Activity = "working" | "blocked" | "idle" | "retry" | "error" | "unknown"
export interface SessionEntry {
  activity: Exclude<Activity, "blocked" | "unknown">  // raw status axis
  pendingPermissions: string[]
  pendingQuestions: string[]
  retry?: { attempt: number; next: number }
  lastActivity: number
  updatedAt: number
}
export type StateMap = Record<string, SessionEntry>
export const emptyState = (): StateMap => ({})

const now = () => Date.now()
const ensure = (m: StateMap, sid: string): SessionEntry =>
  (m[sid] ??= { activity: "idle", pendingPermissions: [], pendingQuestions: [], lastActivity: now(), updatedAt: now() })

export function applyEvent(prev: StateMap, event: { type: string; properties?: any }, clock = now): StateMap {
  const p = event.properties ?? {}
  const sid: string | undefined = p.sessionID
  if (!sid) return prev
  const m: StateMap = { ...prev }
  const e = { ...ensure(m, sid) }; m[sid] = e
  e.updatedAt = clock(); e.lastActivity = clock()
  switch (event.type) {
    case "session.status": {
      const t = p.status?.type
      if (t === "idle") { e.activity = "idle"; e.pendingPermissions = []; e.pendingQuestions = []; e.retry = undefined }
      else if (t === "busy") { e.activity = "working"; e.retry = undefined }
      else if (t === "retry") { e.activity = "retry"; e.retry = { attempt: p.status.attempt, next: p.status.next } }
      break
    }
    case "permission.asked":   e.pendingPermissions = [...new Set([...e.pendingPermissions, p.id])]; break
    case "permission.replied": e.pendingPermissions = e.pendingPermissions.filter(x => x !== p.id); break
    case "question.asked":     e.pendingQuestions = [...new Set([...e.pendingQuestions, p.id])]; break
    case "question.replied":
    case "question.rejected":  e.pendingQuestions = e.pendingQuestions.filter(x => x !== p.id); break
    case "session.error":      e.activity = "error"; break
    default: return prev   // no-op events don't create entries
  }
  return m
}

export function effectiveState(e?: SessionEntry): Activity {
  if (!e) return "idle"
  if (e.pendingPermissions.length || e.pendingQuestions.length) return "blocked"
  return e.activity
}
```

**Step 4: Run — expect PASS.**

**Step 5: Commit.**
```bash
git add assets/opencode/plugins/session-state-impl.ts assets/opencode/plugins/test/session-state.test.ts
git commit -m "feat(plugin): pure session-state reducer"
```

---

## Task 2: State overlay serialization (per-instance file shape + merge)

**Files:**
- Modify: `assets/opencode/plugins/session-state-impl.ts`
- Test: `assets/opencode/plugins/test/session-state.test.ts`

**Step 1: Write failing tests** for `serializeOverlay` and `mergeOverlays`:
```typescript
import { serializeOverlay, mergeOverlays } from "../session-state-impl"

it("serializeOverlay stamps pid/serve/directory/heartbeat", () => {
  const o = serializeOverlay({ pid: 42, serve: "4096", directory: "/d", heartbeat: 100, sessions: emptyState() })
  expect(o.pid).toBe(42); expect(o.serve).toBe("4096"); expect(o.heartbeat).toBe(100)
})

it("mergeOverlays keeps newest updatedAt per session", () => {
  const a = { pid: 1, heartbeat: 1000, sessions: { s1: { activity: "working", pendingPermissions: [], pendingQuestions: [], lastActivity: 10, updatedAt: 10 } } }
  const b = { pid: 2, heartbeat: 1000, sessions: { s1: { activity: "idle", pendingPermissions: [], pendingQuestions: [], lastActivity: 20, updatedAt: 20 } } }
  const merged = mergeOverlays([a, b] as any, { now: 1000, staleMs: 45000, isAlive: () => true })
  expect(merged.s1.activity).toBe("idle")   // newer wins (serve-lease migration)
})

it("mergeOverlays drops dead-pid and stale-heartbeat files -> unknown", () => {
  const live = { pid: 1, heartbeat: 1000, sessions: { s1: { activity: "working", pendingPermissions: [], pendingQuestions: [], lastActivity: 10, updatedAt: 10 } } }
  const deadPid = { pid: 999, heartbeat: 1000, sessions: { s2: { activity: "working", pendingPermissions: [], pendingQuestions: [], lastActivity: 10, updatedAt: 10 } } }
  const stale = { pid: 2, heartbeat: 900, sessions: { s3: { activity: "working", pendingPermissions: [], pendingQuestions: [], lastActivity: 10, updatedAt: 10 } } }
  const merged = mergeOverlays([live, deadPid, stale] as any, { now: 1000, staleMs: 45, isAlive: (pid) => pid === 1 || pid === 2 })
  expect(merged.s1).toBeDefined()
  expect(merged.s2).toBeUndefined()  // dead pid
  expect(merged.s3).toBeUndefined()  // heartbeat age 100 > staleMs 45
})
```

**Step 2: Run — expect FAIL.**

**Step 3: Implement** `serializeOverlay(input)` (identity/shape helper) and
`mergeOverlays(files, { now, staleMs, isAlive })`: filter files where
`isAlive(pid)` and `now - heartbeat <= staleMs`; union sessions keeping max
`updatedAt`.

**Step 4: Run — expect PASS. Step 5: Commit** `feat(plugin): overlay serialize + merge`.

---

## Task 3: State overlay plugin (wiring, heartbeat, teardown)

**Files:**
- Create: `assets/opencode/plugins/session-state.ts`
- Modify: `users/dev/opencode-config.nix` (deploy, cloudbox-gated)

Not unit-tested (I/O + timers); verified by manual smoke in Step 4.

**Step 1: Implement `session-state.ts`** (mirror `self-compact.ts` shape):
```typescript
import type { Plugin } from "@opencode-ai/plugin"
import { mkdirSync, writeFileSync, renameSync, rmSync } from "node:fs"
import { join } from "node:path"
import { homedir } from "node:os"
import { applyEvent, serializeOverlay, emptyState, type StateMap } from "./session-state-impl"

const DIR = join(homedir(), ".local/share/opencode/session-state.d")
const HEARTBEAT_MS = 15_000

const plugin: Plugin = async (ctx) => {
  mkdirSync(DIR, { recursive: true })
  const serve = new URL(ctx.serverUrl).port || "0"
  const dirhash = Buffer.from(ctx.directory ?? "").toString("hex").slice(0, 16)
  const file = join(DIR, `${serve}-${dirhash}-${process.pid}.json`)
  let sessions: StateMap = emptyState()

  const flush = () => {
    const payload = serializeOverlay({
      pid: process.pid, serve, directory: ctx.directory, heartbeat: Date.now(), sessions,
    })
    const tmp = `${file}.tmp`
    writeFileSync(tmp, JSON.stringify(payload))
    renameSync(tmp, file)  // atomic per-writer
  }
  flush()
  const timer = setInterval(flush, HEARTBEAT_MS)
  if (typeof timer.unref === "function") timer.unref()

  const cleanup = () => { try { clearInterval(timer); rmSync(file, { force: true }) } catch {} }
  process.once("exit", cleanup)

  return {
    event: async ({ event }) => {
      if (event?.type === "session.deleted") { delete sessions[(event.properties as any)?.sessionID]; flush(); return }
      const next = applyEvent(sessions, event)
      if (next !== sessions) { sessions = next; flush() }
    },
  }
}
export default plugin
```
Notes: confirm the InstanceDisposed/teardown hook name against
`plugin/index.ts` — if a dispose event is delivered to `event`, tombstone there
too (belt-and-suspenders with the `process.once("exit")`).

**Step 2: Typecheck.** `cd assets/opencode/plugins && npx tsc --noEmit` → clean.

**Step 3: Deploy (cloudbox-gated).** In `users/dev/opencode-config.nix`, beside
the other `xdg.configFile."opencode/plugins/*.ts"` entries:
```nix
xdg.configFile."opencode/plugins/session-state.ts" = lib.mkIf isCloudbox {
  source = "${assetsPath}/opencode/plugins/session-state.ts";
};
xdg.configFile."opencode/plugins/session-state-impl.ts" = lib.mkIf isCloudbox {
  source = "${assetsPath}/opencode/plugins/session-state-impl.ts";
};
```

**Step 4: Manual smoke.** `nix run home-manager -- switch --flake .#cloudbox`,
restart a serve, run a session to blocked/working, then:
```bash
cat ~/.local/share/opencode/session-state.d/*.json | head
```
Expect a file per (serve×dir) with live `heartbeat` and the session's state.
Confirm `heartbeat` advances every ~15s and the file disappears on serve stop.

**Step 5: Commit** `feat(plugin): session-state overlay writer (cloudbox)`.

---

## Task 4: Lua overlay reader (merge + liveness)

**Files:**
- Create: `assets/nvim/lua/user/session_switcher/overlay.lua`
- Create: `assets/nvim/lua/user/session_switcher/test.sh` (pure-fn tests, nvims pattern)

Testable slice: the merge/liveness logic as a pure function taking a list of
decoded tables + `{ now, stale_ms, is_alive }` (inject `is_alive` so tests don't
need real PIDs), mirroring `mergeOverlays`.

**Step 1: Write `test.sh`** driving a headless nvim (`nvim --headless -l`) that
`require`s the module and asserts: newest-updatedAt wins; dead-pid dropped;
stale-heartbeat dropped. (If headless-Lua harness is too heavy, port the pure
`merge` to a standalone `.lua` run via `nvim -l` — keep the exact assertions
from Task 2.)

**Step 2: Run — expect FAIL.**

**Step 3: Implement** `overlay.M.merge(files, opts)` (port of `mergeOverlays`)
and `overlay.M.read()` = glob `session-state.d/*.json`, `vim.json.decode` each,
`merge` with `now=os.time()*1000`, `stale_ms=45000`,
`is_alive=function(pid) return vim.uv.kill(pid, 0) == 0 end`.

**Step 4: Run — expect PASS. Step 5: Commit** `feat(nvim): session-state overlay reader`.

---

## Task 5: Lua socket discovery (attachment location)

**Files:**
- Create: `assets/nvim/lua/user/session_switcher/discovery.lua`
- Modify: `assets/nvim/lua/user/session_switcher/test.sh`

**Step 1: Write tests** for the pure part: `discovery.parse_pane_from_sock(path)`
(`/tmp/nvim-%3.sock` → `%3`) and `discovery.merge_rpc_results(list)` (dedupe by
sessionID, last-writer). RPC + tmux calls are integration (Step 4).

**Step 2: Run — expect FAIL. Step 3: Implement.**
- `discovery.list_sockets()` → `vim.fn.glob("/tmp/nvim-*.sock", true, true)`.
- `discovery.query(sock)` → `vim.system({ "nvim", "--server", sock, "--remote-expr",
  "luaeval('require(\"user.session_switcher.rpc\").snapshot()')" }, { stdin = false })`
  with a short timeout; **stdin must be closed** (`stdin=false`) — the `</dev/null`
  gotcha (`oc-auto-attach/default.nix:470-475`). Failures (dead socket) → skip.
- Create `assets/nvim/lua/user/session_switcher/rpc.lua` exposing `snapshot()` →
  scan this nvim's buffers for `b:oc_session_id`, return
  `[{ sid, buffer, tabpage }]` as a string the caller decodes.
- `discovery.locate()` → for each socket in parallel, query; derive tmux via
  `tmux display -p -t %<pane> '#{session_name}\t#{window_name}'`; return
  `{ [sid] = { sock, pane, buffer, tabpage, tmux_session, tmux_window } }`.

**Step 4: Manual smoke** on cloudbox: from an attached nvim, `:lua
print(vim.inspect(require("user.session_switcher.discovery").locate()))` — expect
your live attach buffers keyed by sid with correct tmux window/session. Kill an
nvim; confirm its entry vanishes (no stale error).

**Step 5: Commit** `feat(nvim): read-time nvim-socket discovery`.

---

## Task 6: DB base-list helper (read-only sqlite, recency-bounded)

**Files:**
- Create: `pkgs/oc-session-list/default.nix` (+ `oc-session-list` script) OR a
  Lua helper shelling to nix `sqlite3`. Prefer a small **packaged script**
  mirroring `oc-search` (nix `sqlite`, `file:$DB?mode=ro`).
- Test: `pkgs/oc-session-list/test.sh` (query shape / arg parsing, nvims pattern)

**Step 1: Write test.sh** asserting the emitted SQL: selects `id, title,
parent_id, directory, time_updated`; `ORDER BY time_updated DESC LIMIT n`; opens
`file:$DB?mode=ro`; sets `PRAGMA busy_timeout`. (Source-guard grep, like
`nvims/test.sh:64-77`.)

**Step 2: Run — expect FAIL. Step 3: Implement** the script: emit newline/JSON
rows for the N most-recent sessions. **DB is ~13 GB — never scan**; rely on the
`time_updated` ordering + `LIMIT`. Confirm an index on the ordering column exists
(`.schema`/`.indexes` via the nix sqlite3); if absent, note it (don't add — the
DB is opencode-owned).

**Step 4: Manual smoke:** `oc-session-list --limit 50 | head` returns recent
sessions with `parent_id`.

**Step 5: Commit** `feat: oc-session-list read-only recent-session query`.

---

## Task 7: Tags store (sticky space/project)

**Files:**
- Create: `assets/nvim/lua/user/session_switcher/tags.lua`
- Modify: `.../test.sh`

**Step 1: Write tests:** `tags.classify(entry)` → if `directory` matches
`.worktrees/pr%-%d+` then `space="lgtm"`; `tags.update(store, sid, {space,project})`
persists sticky last-known; `tags.get(store, sid)` returns last-known or
classification fallback.

**Step 2: FAIL → Step 3: Implement.** Store = `session-tags.json` in
`~/.local/share/opencode/`; updated from discovery results (attached sessions
learn their tmux session→space, window→project); directory-fallback classifier
otherwise.

**Step 4: PASS → Step 5: Commit** `feat(nvim): sticky space/project tags store`.

---

## Task 8: Join + row model (pure)

**Files:**
- Create: `assets/nvim/lua/user/session_switcher/model.lua`
- Modify: `.../test.sh`

**Step 1: Write tests** for `model.build(baselist, overlay, location, tags, opts)`:
- roots only (`parent_id == nil`); children folded → parent gets `child_state`.
- `effective_state`: pending → blocked; else overlay activity; missing → idle;
  stale/unknown → `unknown`.
- attachment = `location[sid] ~= nil`.
- sort: `blocked/error` → `retry` → `working` → `idle`, then asc idle-age,
  clustered by project.
- scope filter: keep rows where `space == current_space` OR `space == nil`
  (untagged) OR `state ∈ {blocked,error}` (**pierces scope** — assert a detached
  blocked untagged worker survives the default filter).
- idle-age uses overlay `lastActivity`, falling back to DB `time_updated`.

**Step 2: FAIL → Step 3: Implement `model.build`.**

**Step 4: PASS → Step 5: Commit** `feat(nvim): switcher row model (join/sort/scope/rollup)`.

---

## Task 9: Telescope picker (title mode) — UI wiring

**Files:**
- Create: `assets/nvim/lua/user/session_switcher/init.lua`
- Modify: `assets/nvim/lua/user/telescope.lua` (keymap + load)

Not unit-tested; manual verification.

**Step 1: Implement** a custom finder: `oc-session-list` → `overlay.read()` →
`discovery.locate()` → `tags` → `model.build(current_space)`. Entry display:
`[project] <glyph> <title> · <idle-age>`; `ordinal = project.." "..title` (fuzzy
over both). Attach a previewer (Task 11 fills body; header now).

**Step 2: Keymap** in `telescope.lua`:
`vim.keymap.set("n", "<leader>fs", function() require("user.session_switcher").open() end, { desc = "OC sessions" })`.

**Step 3: Facet actions** (picker-local maps): toggle `attached/detached/all`,
`blocked only`, `lgtm only`/`all spaces`. Re-run the finder on toggle.

**Step 4: Manual smoke** on cloudbox: `<leader>fs` lists current-space sessions
with correct glyphs, grouped by project, blocked on top; typing a project name
clusters; a detached blocked session shows even out-of-scope.

**Step 5: Commit** `feat(nvim): telescope session switcher (title mode)`.

---

## Task 10: Jump-or-attach action (incl. directory-gone)

**Files:**
- Modify: `assets/nvim/lua/user/session_switcher/init.lua`
- Modify: `assets/nvim/lua/user/oc_auto_attach.lua`

**Step 1: Implement the select action:**
- **attached** (`location[sid]`): if `tmux_session ~= current` →
  `tmux switch-client -t <session>`; then `tmux select-window -t
  <session>:<window>`; then `nvim --server <sock> --remote-expr` to focus the
  buffer/tabpage (stdin closed).
- **detached**: call the existing `oc_auto_attach` resume path.

**Step 2: Directory-gone support in `oc_auto_attach.lua`.** Add an opts flag
(e.g. `opts.allow_missing_dir`) so the picker-resume path: skips the
`isdirectory==0` hard-reject (line 35), sets jobstart `cwd = vim.env.HOME` (or
collapsed project root), and still passes `--dir <stored dir>`. Keep the default
(non-picker) path unchanged. Add a note if Task 0 downgraded this to
preview-only (then this branch shows a notice instead of attaching).

**Step 3: Manual smoke:** jump to an attached session in another tmux
window/session (focus lands correctly); resume a detached session; resume a
detached session whose dir was pruned (Task 0 outcome).

**Step 4: Commit** `feat(nvim): jump-or-attach with directory-gone fallback`.

---

## Task 11: Preview body (transcript tail)

**Files:**
- Modify: `pkgs/oc-session-list/` (add a `--tail <sid>` mode, or a sibling
  `oc-session-tail`) and `.../init.lua` previewer.

**Step 1:** Add a read-only query returning the last user prompt + last assistant
text parts for a sid from `part.data` (nix sqlite, `mode=ro`, `busy_timeout`).
`test.sh` source-guards the SQL shape.

**Step 2:** Previewer sets buffer lines: header (`title · glyph · idle-age ·
space · project · dir`) + tail body.

**Step 3: Manual smoke:** preview shows readable last-exchange for both attached
and detached rows.

**Step 4: Commit** `feat(nvim): switcher preview (transcript tail)`.

---

## Task 12: Phase-1 integration pass + docs

**Step 1:** End-to-end on cloudbox with a realistic herd (several projects,
lgtm running, a blocked swarm worker): verify scope default hides lgtm, blocked
pierces scope, grouping, jump, resume, preview, and that a wedged/killed serve
degrades its sessions to `unknown` (not frozen `working`) within ~45s.

**Step 2:** Write a short repo skill
`.opencode/skills/using-session-switcher/SKILL.md` (keymap, facets, what glyphs
mean, where the overlay/tags files live) — mirrors existing skill style.

**Step 3:** Update the design doc status to "Phase 1 implemented".

**Step 4: Commit** `docs: session-switcher usage skill + phase-1 status`.

**Step 5: Land:** `nix run home-manager -- switch --flake .#cloudbox`, then the
mandatory `git pull --rebase && git push`.

---

## Deferred (not this plan)

- **Phase 2:** content-search mode (reuse `oc-search` corpus; hit→sid→jump).
- **Phase 3:** Telegram forum-topic notifier (tail `session-state` transitions;
  fire on `working→blocked`).
- **Later:** statusline counts (only after staleness handling proven in the
  wild), live-buffer preview, mobile, cross-host jump, socket/HTTP overlay push,
  oc-auto-attach project→directory routing.

## Risks / watch-items carried from design

- Exact event **property field names** (permission/question ids) — Task 1 spike
  confirms against source before the reducer is trusted.
- Plugin **teardown hook** name (InstanceDisposed vs process exit) — Task 3.
- **Partial serve wedge** (timer fires, agent loop stuck) — heartbeat won't catch
  it; `updatedAt`-age is the only secondary signal (documented limitation).
- Headless-Lua **test harness** viability (Tasks 4–8) — if `nvim -l` is awkward,
  keep pure functions dependency-free and test via a minimal Lua runner; do not
  drop the assertions.
