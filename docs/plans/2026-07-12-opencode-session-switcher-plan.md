# OpenCode Session Switcher — Phase 1 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to
> implement this plan task-by-task.

---

## ROADMAP / SPINE (read this first — updated 2026-07-31, after PR #234)

**Where we are:** Tasks 1/2/3 (writer) and Task 6 (reader, `oc-session-list`)
are merged. **But the feature currently displays nothing**, and the reason is
S0 below. Do not build UI on top of an empty data source.

Each step is a bead (`bd show <id>`), which is the durable spine — beads survive
compaction, this file is the narrative. Per-step cycle: **compact → optional
oracle-fable consult → SDD if applicable → adversarial-reviewer-fable → PR if
applicable.** The "if applicable" is real: S0 is diagnosis, not implementation,
and forcing SDD onto it would be theatre.

| # | Bead | Step | Cycle stages that apply | Blocked by |
|---|---|---|---|---|
| ~~S0~~ | `workstation-gzkf` | ~~Diagnose the writer coverage hole~~ **DONE 2026-08-01** — cause: plugins bind at instance creation; pool never restarted after the 12:34 deploy | compact → systematic-debugging → write-up | — |
| ~~S1~~ | `workstation-kwoh` | ~~Restart the serve pool as part of the deploy~~ **DONE 2026-08-01** — gen 528 + pool restart; working session now appears in its own overlay | compact → deploy+restart → verify on fleet | — |
| S2 | `workstation-ix6n` | Deploy #232 + #234 to fleet, re-verify | **folded into S1** | — |
| ~~S3~~ | `workstation-rq7k` | ~~Emit `nodata`, not `idle`~~ **DONE 2026-08-01** (PR #243) — predicate is a recency-keyed hybrid, not the obvious per-directory rule (see S3 write-up) | compact → oracle → TDD → adversarial → PR | — |
| ~~S4~~ | `workstation-vyad` | ~~Task 4: thin **async** Lua caller~~ **DONE 2026-08-02** (PR #251) — `session_switcher/cli.lua`; async justified by measurement, not by the (currently unreachable) deadlock | compact → TDD → adversarial → PR | — |
| ~~S5~~ | `workstation-afp2` | ~~Task 5: Lua socket discovery~~ **DONE 2026-08-02** (PR #253) — liveness is `attach_status` **and** per-buffer job truth; dedupe is live-beats-dead, not last-writer | compact → TDD → adversarial → PR | — |
| ~~S6~~ | `workstation-vk9y` | ~~Task 8: join + row model~~ **DONE 2026-08-04** (PR #295) — split join: the CLI folds/sorts/unions, `model.lua` only annotates attachment and filters | compact → oracle → SDD → adversarial → PR | — |
| S7 | `workstation-7w9z` | Task 9: Telescope picker (title mode) | compact → SDD → adversarial → PR | — |

The next switcher work is **S7 / `workstation-7w9z`** — Task 9, the Telescope
picker, and the first step that produces something a user can actually press.
S6 recorded its consumer contract on that bead; two items are landmines rather
than preferences. The picker must branch on `row.attached`, **not** on the facet
it asked for: a `pierced` row (error/blocked, own or child) survives
`facet="attached"` while being detached and pane-less, so jumping to `row.pane`
would jump into nothing. And the **CLI owns ordering** — `sort_rank` is emitted
for rendering, not for the picker to re-apply.

S6 was briefly blocked on `workstation-dmat`, deliberately: its join logic lands
in `assets/opencode/plugins/oc-session-list-state.ts`, and until #292 **nothing
in CI ran that package's 239 tests**. Writing new tests there first would have
put S6's correctness behind a harness that never executes — the same mistake
S4 documented in `checks.nvim-lua` and routed around. The block paid for itself
immediately: S6 added 22 bun tests to that file, and all of them run.

### Spawned work — beads this roadmap's own cycles produced

These are NOT spine steps, but each was discovered while executing one.

**Restructured 2026-08-04.** The original framing — "deliberately do not block
S4-S6" — recorded why each was deferred and nothing else: no owner, no next
action, no exit condition. Forty PRs merged while three P1s sat here. A table
that only explains deferral is a graveyard, so each row now names **where the
work actually lives**, and the three items that are not switcher work have moved
out to `docs/plans/2026-08-04-unverified-claims-roadmap.md`.

| Bead | From | What | Why it is not a spine step |
|---|---|---|---|
| `workstation-5yox` | S0/S1 | Plugin-loader footgun: guard deployed plugins against the shape that took devbox down | **Has its own roadmap** — `docs/plans/2026-08-01-plugin-loader-hardening-roadmap.md`, steps 0-2 shipped, step 3 split 3a/3b, step 4 pending. Not a leftover; do not describe it as unaddressed |
| `workstation-h0mp` | S1 | Guard: detect when a `home-manager switch` deploys a **stale** config | **Moved out** → unverified-claims roadmap, step 3. S0's actual root cause, but deploy-lifecycle safety rather than switcher code |
| `workstation-9i5k` | S3 | Verify the nightly reset does not cause a **morning `nodata` storm** | Raised by S3's adversarial review and explicitly **suspected, not measured**. A restarted serve with no instances yet has no files, so it reads as "not reporting". Measure the reset→reopen ordering before changing anything. **Stays here** — switcher-domain, and the next action is a MEASUREMENT, not a fix |
| `workstation-pscu` | S4 | **`pkgs/oc-auto-attach/test-project-key.sh` runs nowhere** — no `doCheck`, and CI runs only `nix flake check`, so its assertions are inert | **Moved out** → unverified-claims roadmap, step 1. Not switcher work, and it must land before `oeyv` (which would otherwise force allowlisting the file it exists to catch) |
| `workstation-095u` | S5 | Sessions in **non-tmux or nested nvims are undiscoverable** — nvims creates no socket there, so no peer can see them | A limitation of the socket convention, not of discovery. S5's job was to stop reporting corpses as live; this is about sessions it cannot see at all. Recorded as a consumer contract on S6 and S7: *absence is not proof*. **Stays here** — switcher-domain |
| `workstation-dmat` | S6 | **The three TS harnesses under `assets/opencode/plugins/` ran nowhere** — 205 vitest tests, 34 bun tests, and a 116-line integration script, none reachable from `nix flake check`. Worse than absent: `npm test` exited green over the bun suite it never loaded | ✅ **Done** (PR #292). The one spawned bead that *did* block a spine step: S6 puts its join logic in `oc-session-list-state.ts`, and landing that behind an unrun harness would have been the fourth instance of this pattern, committed knowingly |
| `workstation-oeyv` | `dmat` | Repo-wide meta-guard: assert every test file is reachable from *some* flake check | **Moved out** → unverified-claims roadmap, step 2, **blocked by `pscu`**. Needs an adversarial review *before* implementation: it gates every future PR, and this repo has already reverted one meta-guard's exemption mechanism |

Note that `pscu` is the same shape one level up: a *test* that was not running
where we assumed it was. S0/S1/`h0mp` were an unrun writer; `pscu` is an unrun
guard; the frontdoor-opacity check `flake.nix` already documents was a third;
`dmat` was a fourth and the largest — 239 tests plus an integration script.
Four independent instances is not a coincidence — when this repo says something
is covered, check that the thing doing the covering executes.

That observation now has a roadmap of its own rather than a paragraph in someone
else's: `docs/plans/2026-08-04-unverified-claims-roadmap.md`.

`dmat` also sharpened the diagnosis. The failure is **not** always "no harness
exists". There, a harness existed and passed locally while silently skipping a
whole suite, because vitest's `include` did not match a bun-based `.spec.ts`.
So the property worth guarding is *runner coverage* — is this file actually
executed by something — not merely "is there a test file". That is what
`oeyv` is scoped to, and why a green local `npm test` is not evidence.

The through-line: S0, S1, and `h0mp` are all the same failure — **the writer was
not running where we assumed it was**, and nothing said so. S3 is the tripwire
that makes that class audible; `9i5k` is the check that the tripwire does not
cry wolf every morning and get ignored, which would put us right back here.

### Why S0 is the spine, not a footnote

`oc-session-list --with-state` returns **129 rows with zero state**. The reader
is correct; the overlays have nothing to say. Measured 2026-07-31:

- 42 overlay files, **all** live pids, **all** fresh (0 dead, 0 stale)
- **only 2 of 42 contain any session entry** — 4 entries, all plain `idle`
- the session doing this work was **active throughout and appears in no
  overlay**; it is assigned to `serve-2`, which has 6 files, **none for its
  directory**

The strongest clue: **no file exists for that `(serve, directory)` pair at all**,
so this is about file *creation*, not entry eviction.

Two traps to avoid, both of which this project has already fallen into:

1. **`desired_serve_id` is DESIRED, not actual.** Verify where the session is
   really served before blaming the plugin. Do not convict the memorable
   suspect on circumstantial evidence.
2. **A silent failure is the expected shape here.** opencode swallows a throwing
   plugin factory, so "the plugin is broken" and "the serve has no sessions"
   look identical from outside. #232's loud-unarmed logging — which would
   discriminate hypothesis H4 — **is merged but NOT deployed** (the fleet runs
   #230). That makes S2 partly a diagnostic *enabler* for S0; but gather
   evidence from the current state first, since deploying mutates the system
   under investigation.

S3 is deliberately **not** blocked on S0: it is the permanent tripwire that
would have made this class of emptiness scream instead of whisper, and it is
worth having regardless of what S0 concludes.

---

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
> **ownership-aware ordering instead of wall-clock** (Task 2; the original
> `(epoch, revision)` form was itself wrong — superseded by finding #8), **TOCTOU
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
2. ~~**`revision` is never incremented**~~ — **DONE** (commit `98c25b6`, shipped in
   PR #226): the reducer bumps on every committed change, with a test that fails if
   the bump is absent. Note finding #8 has since demoted `revision` to *intra-file*
   use; it is no longer the cross-file tiebreak.
3. ~~**`epoch = process start time` is not a fencing token**~~ — **RESOLVED
   2026-07-31**, design doc finding #8. Epoch is deleted outright. Ownership is a
   read-time join on pigeon's `session_assignment.desired_serve_id`; cross-file
   freshness is `lastActivity`. Task 2 below is rewritten accordingly.
4. **Deployed-fleet event fixture** must be captured before Task 3 wires the real
   bus (version skew, design doc finding #7). **Still open — blocks Task 3.**

## Task 2: Overlay serialization + merge (stale ⇒ unknown, never dropped)

**Files:** Modify `session-state-impl.ts`; extend the test.

**⚠ Epoch is dead. Ownership comes from an owner map.** GATE item 3 is resolved by
design-doc finding #8 — read it before implementing. Summary of what changed:

- **No `epoch` field anywhere.** Boot time does not order ownership (migrate a
  session onto an *older-booted* serve and the stale entry wins permanently — a
  persistent inversion, not a race).
- **`revision` is intra-file only.** It is per-writer: serve A watching a session
  for a week reaches revision 400, serve B owning it for ten minutes is at 3, so A
  would win forever. That is the *same bug shape* the review already killed once —
  a monotonic-per-writer counter treated as a global order. Never compare it
  across files.
- **Ownership is a read-time join.** Overlay entries carry `serveId`; the caller
  supplies `owners: Record<sessionId, serveId>` built from pigeon's
  `session_assignment.desired_serve_id` (Task 6 does the sqlite read; `mergeOverlays`
  stays pure and takes the map as an argument).
- **The join key is the ROOT session.** Pigeon places by `routingSid` = the root of
  the session tree, so child/subagent sids have no row (measured: 4,600 children
  live, 2 have rows). Task 6 must build `owners[sid] = owner_of(rootOf(sid))` via
  the `parent_id` walk it already does. Getting this wrong silently routes ~53% of
  sessions through bare wall-clock ordering.
- **Absence is authoritative.** A live owner file *for the session's directory*
  that omits the session means idle — emit nothing, do not fall through. One serve
  writes one file per directory, so match `(serveId, directory)`.
- **Cross-file freshness is `lastActivity`** — wall-clock, one machine, one clock.
  (The reducer already sets it on committed events only; it is exactly
  "when this writer last saw this session do something".)

Winner rule, in order:
1. A **live** overlay whose `serveId === owners[sid]` wins outright.
2. Else the **freshest `lastActivity` among live** overlays.
3. Else `unknown: true` from the freshest dead entry.

Note rule 1 requires *live*: a `desired_serve_id` pointing at a crashed serve must
not win with a dead entry — fall through to rule 2 so a live observer can speak.

**Step 1: Failing tests**
```typescript
import { mergeOverlays } from "../session-state-impl"
const entry = (over: any = {}) => ({ activity: "working", error: false, pendingPermissions: [], pendingQuestions: [], lastActivity: 10, updatedAt: 10, revision: 1, ...over })
const file = (serveId: string, pid: number, sessions: any, heartbeat = 1000) => ({ serveId, pid, heartbeat, sessions })
const opts = (over: any = {}) => ({ now: 1000, staleMs: 45000, isAlive: () => true, owners: {}, ...over })

it("owner wins even when its wall clock is OLDER (migration)", () => {
  // The bug this encodes: a delayed `idle` from the OLD owner must not
  // overwrite `blocked` from the NEW owner just because it arrived later.
  const old = file("serve-0", 1, { s1: entry({ activity: "idle", pendingPermissions: [], lastActivity: 999, revision: 9 }) })
  const cur = file("serve-1", 2, { s1: entry({ activity: "working", pendingPermissions: ["p1"], lastActivity: 10, revision: 1 }) })
  const m = mergeOverlays([old, cur] as any, opts({ owners: { s1: "serve-1" } }))
  expect(m.s1.pendingPermissions).toEqual(["p1"])
})
it("higher revision does NOT win across files (revision is per-writer)", () => {
  const a = file("serve-0", 1, { s1: entry({ activity: "idle", lastActivity: 10, revision: 400 }) })
  const b = file("serve-1", 2, { s1: entry({ activity: "working", lastActivity: 999, revision: 3 }) })
  const m = mergeOverlays([a, b] as any, opts())            // no owner known
  expect(m.s1.activity).toBe("working")                      // freshest lastActivity wins
})
it("no owner entry -> freshest lastActivity among live wins", () => {
  const a = file("serve-0", 1, { s1: entry({ activity: "idle", lastActivity: 500 }) })
  const b = file("serve-1", 2, { s1: entry({ activity: "working", lastActivity: 900 }) })
  expect(mergeOverlays([a, b] as any, opts()).s1.activity).toBe("working")
})
it("owner pointing at a DEAD serve does not win; a live observer speaks", () => {
  const dead = file("serve-0", 999, { s1: entry({ activity: "idle", lastActivity: 999 }) })
  const live = file("serve-1", 2,   { s1: entry({ activity: "working", pendingPermissions: ["p1"], lastActivity: 10 }) })
  const m = mergeOverlays([dead, live] as any, opts({ owners: { s1: "serve-0" }, isAlive: (pid: number) => pid === 2 }))
  expect(m.s1.unknown).toBeFalsy()
  expect(m.s1.pendingPermissions).toEqual(["p1"])
})
it("dead pid and stale heartbeat -> entries flagged unknown, NOT dropped", () => {
  const deadPid = file("serve-0", 999, { s2: entry() })
  const stale   = file("serve-1", 2,   { s3: entry() }, 900)
  const m = mergeOverlays([deadPid, stale] as any, opts({ staleMs: 45, isAlive: (pid: number) => pid === 2 }))
  expect(m.s2.unknown).toBe(true)
  expect(m.s3.unknown).toBe(true)   // heartbeat age 100 > 45
})
it("unknown entries clear pending sets (never assert a block nobody is holding)", () => {
  const dead = file("serve-0", 999, { s1: entry({ pendingPermissions: ["p1"], pendingQuestions: ["q1"] }) })
  const m = mergeOverlays([dead] as any, opts({ isAlive: () => false }))
  expect(m.s1.pendingPermissions).toEqual([])
  expect(m.s1.pendingQuestions).toEqual([])
})
```

**Step 2: FAIL → Step 3: Implement.** `serializeOverlay({pid, serveId, directory,
heartbeat, sessions})` = shape passthrough (**no `epoch`**).
`mergeOverlays(files, {now, staleMs, isAlive, owners})`: for each file compute
`live = isAlive(pid) && now - heartbeat <= staleMs`; union sessions keeping the
winner by the three-step rule above; if a session's winning file is NOT live, emit
`{ ...entry, unknown: true, pendingPermissions: [], pendingQuestions: [] }`.
(Prune plain-idle entries with empty sets and no error from the union — absent≡idle.)

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
report**: this is a Phase-1 blocker, not a nice-to-have). Smoke: trigger a
permission prompt, restart that serve, confirm the session still reads `blocked`
after restart.

**⚠ Writer identity hazard (D4, adversarial review).** The filename
`${serve}-${dirhash}.json` carries **no pid**, and `OPENCODE_SERVE_ID` is
*inherited by child processes* — a documented hijack vector (`route-gate.nix:38-43`,
the 2026-07-25 incident). Any nested `opencode` that loads the globally-configured
plugin in the same directory becomes a **second live writer of the same file**,
alternating whole-file overwrites. Worse, it interacts lethally with the
zombie-writer fix below ("if the file stamp is newer than ours, go silent"): a
short-lived stray would **permanently silence the real serve's writer** for that
directory, so every session there flips to `unknown` once the heartbeat ages out.
Mitigate: verify this process is the registered pool member (own pid/port against
the serve registry) before writing, or at minimum stamp the pid and refuse to
stay silent when the superseding writer is dead.

**Overlay needs a schema `version` field** (D5) — the reader must validate entry
shape before merging, or a version-skewed writer's entry (e.g. missing
`pendingPermissions`) crashes the picker.

**No `epoch`.** The overlay carries `serveId` (from `OPENCODE_SERVE_ID`) and
nothing boot-derived; see finding #8. Two further writer duties from that finding:

- **Idle eviction.** Drop a session from the overlay once it has had no events for
  30–60 min with empty pending sets and no error. Absent ≡ idle (the DB base-list
  still carries every session), so this shrinks the stale-zombie surface
  structurally instead of by guesswork.
- **Seed-vs-stream race (GATE item 1).** `seedFromSnapshot` is currently
  replace-authoritative and stomps `revision` to 0, so a late snapshot can drop a
  permission asked after the snapshot was taken, or resurrect one already replied.
  Fix here: accept a snapshot only for sessions with **no event-derived entry yet**
  (or make it union-only), and prefer a periodic ~60 s reconcile over a one-shot
  boot seed. Do **not** `await` the seed during plugin init — that deadlocks boot.

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

**Step 3: Deploy — ⚠ THE SNIPPET BELOW IS WRONG. DO NOT USE IT.**
~~```nix
xdg.configFile."opencode/plugins/session-state.ts" = lib.mkIf isCloudbox { source = "${assetsPath}/opencode/plugins/session-state.ts"; };
xdg.configFile."opencode/plugins/session-state-impl.ts" = lib.mkIf isCloudbox { source = "${assetsPath}/opencode/plugins/session-state-impl.ts"; };
```~~

Two independent reasons, both found by smoke-testing before deploying
(2026-07-31):

1. **Per-file `xdg.configFile` entries break sibling imports.** Each entry lands
   in its *own* `/nix/store` path, and opencode resolves a plugin through
   `realpathSync` before importing — so `session-state.ts` would look for
   `session-state-impl.ts` next to itself **in the store** and not find it. This
   is documented in `opencode-config.nix` itself (the caveman comment) and the
   failure is **silent**: opencode swallows the import error, `opencode debug
   info` still lists the plugin, and the log stays empty.
2. **Everything in `~/.config/opencode/plugins/` is loaded as a plugin.**
   Observed directly: deploying the impl file there produces
   `failed to load plugin … session-state-impl.ts error="Plugin export is not a
   function"` on every instance bootstrap. No `*-impl.ts` is deployed to that
   directory today, and that is not an accident.

**The established precedent for a multi-file plugin is a Nix-built,
self-contained JS bundle** — see `localPkgs.self-compact-plugin`, which inlines
its deps and deploys a single `self-compact.js` (+ `.js.map`) for exactly these
reasons. Task 3's deployment must do the same: add a `session-state-plugin`
package that bundles `session-state.ts` + `session-state-impl.ts` into one
`session-state.js`, then deploy that single file (cloudbox-gated).

Deployment is therefore **its own task**, not a two-line step. The writer
plugin itself is complete and verified in isolation (see Step 4).

**Step 4a: Isolated smoke — DONE 2026-07-31, before touching the fleet.**
A bad plugin at init breaks instance creation for *every* directory on *every*
serve, including the one hosting the session doing the work, so the writer was
first exercised in a throwaway `opencode serve` on a spare port with its own
`XDG_CONFIG_HOME`. Confirmed there: the plugin loads, the pool-serve guard
returns true against the real `/proc/self/cmdline`, the overlay lands at the
expected filename with the right schema (`version`, `instanceStamp`, `pid`,
`serveId`, `directory`, `heartbeat`, `sessions`), the heartbeat advances every
15 s, and boot does not deadlock.

**Bonus confirmation of D4.** The throwaway serve was *refused by the pool's own
route-gate* — `FATAL: refusing to claim routing slot serve-test: bound port 4199
!= expected port 4098 … most likely it inherited OPENCODE_SERVE_ID and
OPENCODE_ROUTING_DB from a parent opencode session`. The inheritance hazard the
D4 guard exists to stop is real enough that the routing layer already guards it
independently. Note this guard only covers processes that *bind a routing slot*;
a nested non-serve `opencode` inherits the env without tripping it, which is
exactly the gap the plugin's own cmdline check closes.

**Step 4b: Manual smoke on the fleet — DONE 2026-07-31 (commit `1724e6c`).**
The bundle package now exists: `pkgs/opencode-plugin-bundle` (shared builder),
called by `pkgs/session-state-plugin` and, after refactor, by
`pkgs/self-compact-plugin`. Deployed cloudbox-gated via
`nix run home-manager -- switch --flake .#cloudbox`.

Verified on the live fleet, in order:

1. **The gate is real.** The cloudbox generation contains `session-state.js` +
   `.js.map`; the devbox generation contains neither. No `*-impl` file is
   deployed to the plugins directory on either.
2. **No serve restart was needed.** A new *instance* picks the plugin up:
   `GET :4700/question?directory=/tmp/opencode/probe-dir` (read-only, through
   the front door) created an instance on serve-0 which immediately wrote
   `serve-0-5e5bd0e61ab58c6a.json`. All four pool serves stayed `active
   (running)`; zero plugin errors in the pool journal.
3. **Real state transitions, both paths.** Driving a turn on that session
   produced `revision: 3, error: true` on a failed call and then
   `revision: 7, error: false, activity: idle` on a successful one — so the
   error flag is set *and cleared*, not sticky. (The first failure was my own
   bad model id, `claude-haiku-4-5@default` instead of `@20251001` — not a
   plugin fault.)
4. **`session.deleted` empirically confirmed.** `DELETE /session/<id>` removed
   the entry from `sessions`. This is the payload whose key I nearly
   misreported in cycle 3 (the TUI reads `info.id`, the schema carries
   `sessionID`); the reducer demonstrably reads the right field on the
   deployed version, which retires that open question.

**Note:** on serve SIGKILL/nightly reset the file is NOT removed (exit handler
doesn't run) — that's expected; the reader's dead-PID/stale check + GC (Task 4)
handles it, and a same-port restart overwrites it. Do not treat a lingering file
as a bug. Observed live: the probe left `serve-0-*.json` behind with
`sessions: {}` for a `/tmp` directory that no longer matters — a concrete
instance of the orphaned-overlay item below, which Task 4's reader must handle.

**Adversarial review outcome (2026-07-31).** One HIGH, fixed in `72010b9`:
`evictIdleSessions` never consulted `activity`, so a session 46 minutes into a
long turn was evicted and -- because absent means idle -- reported idle while
working. Proved with a failing test first. Also fixed: `shouldGoSilent` now
requires the superseding writer to be *live* (a recycled pid inheriting a
crashed predecessor's high stamp could otherwise silence the real writer), and
the guard logs when it goes inert with `OPENCODE_SERVE_ID` set.

**Two corrections to things this plan asserted as fact (2026-07-31, cycle 4):**

- **"A bad plugin at init breaks instance creation for every directory on every
  serve" is FALSE on 1.17.13.** Measured with a plugin that writes a marker at
  import, writes a second marker inside its factory, and then throws: both
  markers appear (so it really was imported and the factory really did run and
  throw) and session creation still succeeds, with an empty log. opencode
  swallows a throwing factory the same way it swallows a failed sibling import.
  The blast radius of a plugin bug here is therefore much smaller than this plan
  claimed -- but the failure is even quieter, which for a *state writer* is the
  worse half: an absent overlay is indistinguishable from a serve with no
  sessions. Isolated smoke-testing is still worth doing; the justification is
  "silent wrongness", not "takes the host down".
- **The test suite was talking to a live pool serve.** `fetchPendingSnapshot`
  received `globalThis.fetch` while the tests passed a mock through
  `client._client.getConfig()`, which the plugin never reads. Every `npm test`
  fired two real requests at `ctx.serverUrl` (127.0.0.1:4096), causing a
  production serve to create an instance for the test's temp directory. Fixed by
  injecting fetch through `opts` (commit `3fd06b9`). Note the knock-on: on CI, or
  any host without a pool, those requests failed into the silent catch, so
  **BUG FIX 1's seeding path had no real coverage anywhere** -- it passed on
  cloudbox for one reason and on CI for another. This is the second time a test
  was assumed to be isolated and was not (the first deleted a live serve's
  overlay file).

### Cycle 5 outcome: four of these are now closed with deployed evidence

Resolved in `session-switcher-task5`. Recorded here because two of them were
closed by *measurement that contradicted the assumption in the item itself*.

- **RESOLVED [MED] Nested serve.** The proposed fix ("derive the expected port
  from the serve-id") turned out to be unnecessary: `opencode-serve-start`
  already **exports** `OPENCODE_SERVE_EXPECTED_PORT`, and its own comment
  describes precisely this attack (the 2026-07-25 hijack, bead pigeon-13p). The
  plugin now runs the same fence over `ctx.serverUrl`
  (`checkServePortFence`). Confirmed empirically that the premise is real: a
  throwaway serve spawned from inside a session *does* inherit
  `OPENCODE_SERVE_ID`, and tripped the routing FATAL only because
  `OPENCODE_ROUTING_DB` happened to be inherited too -- scrub that one variable
  and the old guards pass. Port compared, host deliberately not: a host
  comparison would take the writer inert fleet-wide if `ctx.serverUrl` ever
  reported `localhost` or `::1`.
- **RESOLVED [MED] GET response shape.** Verified against a deployed 1.17.13
  server holding a real pending prompt. Both endpoints return arrays; the
  running binary's own OpenAPI document declares `id` and `sessionID` as
  **required** strings on `PermissionRequest` and `QuestionRequest`. The
  assumption was correct -- but it was an assumption, and BUG FIX 1 rested
  entirely on it.
- **RESOLVED [MED] The `?directory=` negative control.** Ran it properly: two
  sessions in two directories on one serve, one real pending permission.
  Matching dir -> 1, `projB` -> 0, nonexistent -> 0, unfiltered -> 1 (positive
  control), trailing slash tolerated. The param genuinely filters, so the feared
  permanent phantom `blocked` from cross-directory seeding cannot occur.
- **RESOLVED [MED] permission.\* fixtures.** Captured real `permission.asked`
  (key in `properties.id`) and `permission.replied` (key in
  `properties.requestID`) from a deployed server, confirming the reducer's
  asymmetry for the half that previously rested on a one-time source read.
  Forcing the prompt needed a *global* config `{"permission":"ask"}` under a
  private `XDG_CONFIG_HOME` -- the project-level override that failed in cycle 3
  was the wrong lever.
- **RESOLVED [LOW] `isValidOverlay` skew.** Now validates `lastActivity`,
  `updatedAt`, `activity` and `error`, **per entry**. Verified against
  production first: all 11 live entries across the 23 current overlay files
  pass, so it rejects skew and not real data. The first attempt applied the
  check at file granularity, which the adversarial review caught -- see below;
  that would have let one malformed entry hand a session to a stale file from
  another serve.

Method notes worth keeping:

- The capture ran on a throwaway serve with its own `XDG_CONFIG_HOME` and
  `XDG_DATA_HOME`, so the session-state plugin never loaded and no live overlay
  was touched; a before/after listing of `session-state.d` confirmed it. Given
  two prior incidents of tests touching production, isolation is now built in
  rather than asserted.
- Both new test suites were **mutation-checked**. The first pass of the fixture
  tests caught only 4 of 6 seeded defects: comparing a parsed field against the
  same fixture field passes vacuously when a rename makes both `undefined`, and
  a hand-built reply event hardcoding `requestID` cannot detect that the real
  payload drifted. Both were rewritten.
- `expectedPort` is injectable because the test runner inherits a real
  `OPENCODE_SERVE_EXPECTED_PORT` from whichever pool serve hosts the session
  running the suite. Note that passing `expectedPort: undefined` does **not**
  mean unarmed -- it falls back to `process.env`. Third instance of ambient
  production state leaking into a supposedly isolated test.

#### Cycle 5 adversarial review: two items deferred, one policy to write down

- **[MED, deferred] Prefer a PID fence over the port fence.** The reviewer's
  better idea: `opencode-serve-start` `exec`s opencode, so `$$` at export time
  *is* the serve's eventual pid. Exporting `OPENCODE_SERVE_EXPECTED_PID=$$` and
  comparing against `process.pid` closes every port/host/socket variant at once,
  because children inherit the variable but never the pid. Deferred only because
  it needs a wrapper change in `hosts/cloudbox/configuration.nix` plus a fleet
  rebuild, and it would sit unarmed until that lands. The loopback+port fence
  shipped here is the belt; this is the braces.

  **Update (2026-07-31, cycle 6).** Relayed to the `frontdoor` session because
  the routing registry's fence (bead pigeon-13p) has the same port-only shape:
  it compares `OPENCODE_SERVE_EXPECTED_PORT` against the bound port with no
  interface check, so a nested serve on `--hostname ::1 --port <slot>` passes it.
  Impact there is narrower than a hijack — the registered endpoint is hardcoded
  `http://127.0.0.1:${port}`, so traffic still lands on the real serve; what you
  get is `registerSelf` under a different `instance_uuid`, which invalidates the
  real serve's session leases, plus self-heal churn. Filed as **workstation-4b1q**
  (P2). Deliberately **not** exercised live: writing to the production routing
  registry to confirm a mechanism the code already makes plain is a bad trade.
  Frontdoor confirmed the `exec` premise on all three wrappers
  (`hosts/cloudbox/configuration.nix:961`, `home.devbox.nix:801`,
  `home.darwin.nix:338`), so `$$ == process.pid` is a clean equality test with no
  host-shape caveat — but note the fence fails **closed**, so if a wrapper ever
  stops `exec`ing, that pool silently stops registering. Assert the `exec`
  property rather than assuming it.
- **[MED-LOW, deferred] The `openapiShapes` block in the fixture is still a
  hand-summarized spec** rather than a raw schema fragment. Lower stakes than
  the directory matrix was, because the raw GET body independently corroborates
  the field names, but it is the same transcription class of evidence.
- **[POLICY, must be written down] `OVERLAY_VERSION` skew.** The writer ships in
  a nix bundle that auto-updates every 8 hours; the reader will ship as part of
  `oc-session-list`. They therefore drift. The rules:
  - Any change to the *file-level* shape requires an `OVERLAY_VERSION` bump, and
    the **reader deploys first** (an unknown version is ignored, so a reader that
    does not yet understand the new version blacks out; a writer emitting an old
    version a new reader still accepts does not).
  - *Additive entry-level* changes (a new `activity` value, a new optional
    field) must NOT bump the version, and must be tolerated by the reader
    per-entry. That is exactly what the entry-level validation now does: an
    unrecognized entry is dropped, its healthy siblings survive, and the serve
    is not blinded.

**Carried forward, NOT fixed here** (ranked; all from the same review):

- **[MED] Nested `opencode serve` slips both guards.** The cmdline check accepts
  token[1]=="serve", and the route-gate FATAL only fires for a process that
  *claims a routing slot*. A nested serve with `OPENCODE_SERVE_ID` inherited but
  no routing-DB claim → same filename, different pid → the same-pid-only silence
  rule never fires → two live writers alternate whole-file overwrites. Cheap
  strong fix: cross-check `ctx.serverUrl`'s port against the port the serve-id
  is supposed to own; a nested serve cannot bind the real slot's port.
- **[MED] The seed's GET response shape is unverified against deployed.**
  `fetchPendingSnapshot` assumes `/permission` and `/question` return arrays of
  `{sessionID, id}`. The committed fixtures are *events only*. If the field
  names differ, `seedFromSnapshot` skips every item silently and BUG FIX 1
  (boot blindness) quietly reverts with zero signal. Also never negatively
  controlled: we proved a matching `?directory=` returns the prompt, never that
  a non-matching one *excludes* it. If the param is ignored, a serve seeds other
  directories' sessions into its overlay, where they never receive events, and
  `hasPending` then blocks eviction → a permanent phantom `blocked`.
  Capture a GET response with a real pending prompt as a fixture.
- **[MED] Union-only means drift in an *existing* entry is never repaired.** The
  60s reconcile only fills in wholly-missing sessions. Race: boot with P
  pending → fetch lists P → P is replied while the JSON is still parsing → the
  `replied` event no-ops (no entry yet) → the seed then creates the entry with P
  pending → phantom `blocked` that only heals on that session's next idle, and
  never if the session never runs again. Consider a timestamp-fenced
  subtraction (drop pendings absent from a snapshot taken after `updatedAt`).
- **[MED] Fixtures cover questions only.** `deployed-fixtures.test.ts` advertises
  itself as guarding the `.asked`/`.replied` asymmetry, but contains zero
  `permission.*` events -- that half rests on a one-time bundle read. Forcing a
  real permission prompt needs a config whose `permission` is not `"*": "allow"`;
  the project-level override did not merge in the attempt made here.
- **[MED-LOW, sharpened by observation] A live instance for a dead directory
  heartbeats forever.** Observed on the fleet: probe/test directories under
  `/tmp` were deleted, but serve-0 still holds instances for them, so their
  overlays keep rewriting with a *fresh* heartbeat and `sessions: {}`
  indefinitely. Consequence for Task 4: **heartbeat age cannot be the staleness
  test.** A file can be current, its writer alive, and its subject nonexistent.
  The reader needs directory existence and/or intersection with the DB's session
  list, not just a freshness check. This is the same "DB stays authoritative for
  existence" requirement noted below, arrived at from the opposite direction.
- **[MED-LOW] No GC or age cap for orphaned overlay files.** Serve renumbering or
  a retired directory leaves a file forever, and the merge emits `unknown` from
  arbitrarily old dead files with no age bound → permanent picker noise and a
  monotonically growing `session-state.d`. Wants a reader-side age cap or a
  sweeper (Task 4).
- **[LOW] `isValidOverlay` does not type-check `lastActivity`/`activity`,** so a
  same-version skewed entry can yield NaN comparisons and an arbitrary merge
  winner. And writer (plugin bundle) vs reader (`oc-session-list`) ship by
  different vehicles, so an `OVERLAY_VERSION` bump blacks out all state during
  the skew window -- the lockstep requirement should be written down.
- **[LOW] Reader must intersect the overlay with the DB base list.** A reconcile
  response landing after `session.deleted` can resurrect a ghost entry; this is
  harmless *only* if the DB stays authoritative for existence. Make that an
  explicit Task 4/6 requirement rather than an assumption.

**Step 5: Commit** `feat(plugin): session-state overlay writer (cloudbox)`.

---

## Cycle 6 decision (2026-07-31): the merge stays in TypeScript; Task 4 is resequenced

Task 4 as written below said "port of `mergeOverlays`" into Lua. **Task 6 Step 3b
supersedes that**, and it names Task 4 explicitly ("Tasks 4/5/8's Lua modules
become *thin callers* of this"). Resolved before any code was written, because
two merge implementations drifting apart is the obvious failure mode.

**Decision: ONE implementation, in TypeScript, owned by `oc-session-list`.**
Extract `mergeOverlays` + its entry-level validation out of the writer's
`session-state-impl.ts` into a shared module under `assets/opencode/plugins/`,
imported by the CLI entry point. Lua becomes a thin, **async** caller. Rationale:

- **`mergeOverlays` is currently dead code.** Verified by grep: defined at
  `session-state-impl.ts:376`, referenced only by 31 test sites, **never called
  by the writer plugin**. The writer only ever writes its own
  `serve-N-dir.json`, so merging is purely reader-side. The choice was therefore
  never "TS vs. a Lua port" — the reader logic is *homeless*, and this picks its
  one home. (Corollary: the per-entry validation hardening won in cycle 5 is
  guarding code that ships to nobody until this lands.)
- Step 3b's Lua escape hatch is conditioned on "if the merge is easier to keep in
  Lua" — it isn't, given a hardened impl plus 31 tests already exist. Porting
  discards them and re-opens exactly the bug classes adversarial review caught
  (whole-file rejection, skewed-entry NaN ordering).
- A Lua-owned merge makes every future non-nvim frontend (fzf/tmux, recovery)
  depend on nvim. Step 3b exists precisely to prevent that.

**Resequencing:** merge **and opportunistic GC** move into Task 6 (GC is
reader-side; it belongs with the merge, else the CLI reads files Lua has not
swept). Tests move with them. Task 4 is demoted to a small "thin Lua caller"
step and runs **after** Task 6, before Task 8. Task 5 is unaffected
(`rpc.snapshot()` must live in each nvim regardless).

**New hazard to design against — sync-invocation deadlock.** If `--with-state`
performs discovery via `nvim --server <sock> --remote-expr` and the *invoking*
nvim calls the CLI **synchronously**, the CLI RPCs back into a blocked nvim and
hangs until timeout. The Lua caller must use `vim.system` + callback (async),
and/or the CLI must accept `--skip-sock <own>`.

**Three plan claims corrected this cycle (all verified, not inherited):**

1. **"The writer bundle auto-updates every 8 hours" is FALSE.** That workflow
   (`.github/workflows/update-opencode-patched.yml`) bumps **opencode-patched**,
   the opencode *binary*, in `home.base.nix`. **No** workflow touches
   `session-state-plugin` — it rebuilds from repo source on `home-manager
   switch`. So writer and reader ship on the *same vehicle, same commit, same
   activation*. The `OVERLAY_VERSION` lockstep policy above is therefore
   belt-and-braces for partial activations, **not** a different-vehicles skew
   problem. Moving the merge to TS further lets `OVERLAY_VERSION` be one
   imported constant inlined into both artifacts at build time.
2. **`pkgs/nvims/test.sh` is NOT a headless-Lua harness** — it is a bash-mirror +
   source-guard harness and invokes no nvim. The real `nvim -l` precedent is
   `pkgs/oc-auto-attach/test-project-key.sh:682` (with a SKIP fallback when nvim
   is absent). Copy that one in Task 4.
3. **Do not reuse `pkgs/opencode-plugin-bundle` stage 2 verbatim.** Its
   checkPhase asserts `typeof m.default === 'function'` ("Expected default export
   to be a plugin factory function") and installs a bare `.js` with no bin and no
   shebang. Reuse the **deps stage** (no second lockfile, no second TS build
   ecosystem); fork stage 2 with a CLI checkPhase and a `makeWrapper` bin.

**Measured against the live DBs (2026-07-31). Several of Task 6's numbers were
stale or wrong — use these.**

| Claim in plan | Measured |
|---|---|
| `session` ~6,184 rows | **8,771** (13 GB DB; the bulk is `part`, which the base list never touches) |
| "~15 ms" for the root walk | **130 ms** naive (correlated `MAX(depth)`); **46 ms** with an upward CTE + `ROW_NUMBER()`; ~109 ms end-to-end process |
| "multi-level nesting … live-verified real grandchild chains" | **FALSE today. Max depth is 1.** 8,771 at depth 0, 4,668 at depth 1, **nothing at depth 2+**. No grandchild chain exists on this host. |
| ~53% of sessions are children | **Confirmed: 4,668 / 8,771 = 53%** |
| archived exclusion | **Zero archived sessions exist.** `time_archived IS NULL` for all 8,771 — the filter is unobservable live and MUST be fixture-tested. |

Two consequences worth stating plainly:

- **The `COALESCE(parent_id, id)` warning is still right, but not for the stated
  reason.** On today's data a single-level lift and a full walk return
  *identical* results, because nothing is deeper than one level. The recursive
  walk is kept as (a) future-proofing for deeper swarm topologies and (b) the
  correct handling of orphans — see next point — not because multi-level chains
  are currently observable. Do not cite "live-verified grandchild chains" again.
- **983 sessions are orphans** (`parent_id` set, parent row absent) — a
  population the plan never mentions. The upward walk stops at the missing
  parent and treats the orphan as its own root, which is the sane outcome; a
  `COALESCE` lift would instead group them under a phantom root id. Task 6's
  `owners[sid] = owner_of(rootOf(sid))` join inherits this, so orphans resolve
  to themselves and simply miss the assignment table — same as any child.

**✅ RESOLVED 2026-08-01 (S0, `workstation-gzkf`) — cause: plugins bind at
INSTANCE CREATION, and the serve pool was never restarted after the writer was
deployed. Not a writer bug; a deploy-lifecycle gap (H3).** Full evidence and the
controlled experiment are in "S0 diagnosis" immediately below. The original
report, left intact because its measurements are still accurate:**

**⚠ HIGH, ~~OPEN~~ RESOLVED — the deployed writer has a coverage hole, found while smoke-testing
`--with-state` (2026-07-31).** `oc-session-list --with-state` returned 129 rows
with **zero** carrying any state. The CLI is behaving correctly; the overlays
genuinely have nothing to say. Measured against the live fleet:

- 42 overlay files, **all** with live pids and fresh heartbeats (0 dead, 0 stale).
- **Only 2 of 42 files contain any session entry at all** — 4 entries total, and
  all 4 are plain `idle`, so the merge correctly prunes them to nothing
  ("absence == idle").
- **This session was actively working the whole time** and appears in NO
  overlay. It is assigned to `serve-2` (`session_assignment` row, state
  `assigned`), and `serve-2` has 6 overlay files — **none for
  `/home/dev/projects/workstation`**, the directory it is working in.

So an actively-working session on its assigned serve produced no overlay entry
and not even a file for its directory. That is exactly the failure mode this
plan already documented from cycle 4: opencode swallows a throwing plugin
factory, and *"an absent overlay is indistinguishable from a serve with no
sessions."* Candidate causes, none yet confirmed: the plugin never initialized
for that (serve, directory) pair; it threw at init and was swallowed; or the
instance predates the deployed bundle. **Task 3 is not as "done" as it looks —
the switcher renders nothing useful until this is understood.** Investigate
before building the picker on top (Tasks 4/8/9), and note that the deployed
build is #230's — #232 is merged but NOT deployed.

### S0 diagnosis (2026-08-01): the writer was never running where it mattered

**Cause. opencode binds plugins to an app *instance* at instance-creation time.
A long-lived serve never retrofits a newly deployed plugin into instances that
already exist.** The pool serves started **09:18**; `session-state.js` was
deployed at **12:34** by a `home-manager switch` that did **not** restart them.
Every directory a serve had already touched in that 3h16m window is therefore
permanently writer-less *for the life of that process* — and those are exactly
the long-running, actively-worked directories. Directories first touched after
12:34 get a writer normally. Hence the near-perfect anti-correlation.

**Proof (controlled experiment, no prod mutation).** Two throwaway serves on
:4791/:4792 with `OPENCODE_SERVE_ID`/`OPENCODE_SESSION_STATE_DIR` overridden and
`XDG_*` isolated — the override matters, because a session's own bash inherits
`OPENCODE_SERVE_ID=serve-2`, so an un-scrubbed child serve writes the *pool's*
overlay filenames. On :4792, starting from an **empty** plugins dir:

| step | action | overlay |
|---|---|---|
| 1 | create instance for `dirA` (plugin absent) | 0 files |
| 2 | **copy `session-state.js` in** (simulates the deploy), re-request `dirA` | **still 0** |
| 3 | request `dirB` (new instance, post-deploy) | **1 file, immediately** |

Same process throughout. Step 2 is the finding: an existing instance never picks
the plugin up, no matter how many requests hit it.

**Corroboration from the live fleet:**

- **No overlay has an `instanceStamp` earlier than the 12:34 deploy.** Earliest
  is 16:15, 7h *after* serve start. If instances refreshed, stamps would spread
  back to 09:18.
- This session (`ses_0b36d8b66`, `/home/dev/projects/workstation`) was created
  **11:08:14** — 86 minutes *before* the plugin existed. Its instance predates
  the writer, so it can never be recorded.
- Same-repo control: `workstation/.worktrees/{scheduled-swarm-wake,
  monitoring-mergequeue-fix}` (worktrees first touched after the deploy) **have**
  overlays; `/home/dev/projects/workstation` does not. `mono` has an overlay on
  serve-2 and serve-3 but **not** on serve-1, which is the serve currently
  leasing it. Identical config, different instance age — activity, not config.
- Live-leased `(serve,dir)` pairs and overlay pairs were **perfectly disjoint**
  (6 vs 42, zero intersection).

**Hypotheses refuted, not merely unselected:**

- **H1 (factory threw, swallowed):** no `[session-state]` line in `opencode.log`
  *or* the journal. `console.error` from a plugin lands in the serve's journal,
  not `opencode.log` — checked both.
- **H2 (never hosted on serve-2):** refuted. `session_lease` shows a live,
  unexpired lease with a matching `instance_uuid`. `desired_serve_id` was the
  untrustworthy field; the lease is the actual one.
- **H4 (fence inert):** the fence does not exist in the deployed build (#232
  unshipped), so it cannot be the cause.
- **H5 (directory-key mismatch):** `session.directory` is exactly
  `/home/dev/projects/workstation`; the hash matches. *But* a related
  discrepancy surfaced and is worth remembering: `POST /api/session?directory=X`
  returned `location.directory` = the serve's cwd, **not** `X`, while the
  overlay was filed under `X`. Instance directory and session location are
  distinct concepts and can disagree — a live hazard for the Task 8 join.

**`n=0` on the surviving 42 is NOT a second bug.** Idle entries are evicted by
design ("absence == idle"), and the surviving writers are precisely the
directories with no activity. Consistent.

**Verdict: deploy gap, not a writer bug.** The writer is correct and has simply
never run anywhere that mattered — so Task 3 remains *unvalidated on the fleet*,
not wrong. The fix is to restart the serve pool after deploying plugin changes,
which makes **S1 and S2 the same action**; the standing requirement is that any
deploy touching `assets/opencode/plugins/**` must restart `opencode-serve@*`,
otherwise it silently no-ops for every existing instance.

**⚠ Re-measured 12h later (2026-08-01 09:52) — a SECOND, now-dominant failure:
the writer is not deployed at all.** The overnight reset restarted the pool at
09:24, which should have been the natural experiment confirming the diagnosis
above. Instead of full coverage the overlay dir is **empty — 0 files**, and
`~/.config/opencode/plugins/session-state.js` **no longer exists**.

A `home-manager switch` ran at **09:23** (generation 1953) and its closure omits
the plugin. This is not a rollback of intent: `main` still ships the
`xdg.configFile."opencode/plugins/session-state.js"` block, the host is
`cloudbox`, and `isCloudbox` is plainly true (its sibling
`subagent-routing.ts`, gated on `isDarwin || isCloudbox`, is present). The
plugin entered `opencode-config.nix` in **#230, merged 07-31 12:39** — so a
switch run from any worktree branched before that timestamp silently
**un-deploys the writer fleet-wide**. Several such worktrees exist
(`ws-iwpj-phase2`, `/tmp/wt-shellenv-fix`, `monitoring-mergequeue-fix`,
`scheduled-swarm-wake`).

**This does not invalidate the instance-binding diagnosis** — that was proven by
controlled experiment and still explains the original 42-empty-overlay
observation. It adds a second, independent hazard that S1 must handle, and it
is arguably worse: home-manager is **last-writer-wins across concurrent swarm
worktrees**, so any agent running a switch from a stale checkout reverts every
other agent's deployed config, silently and fleet-wide. A restart alone would
have fixed nothing this morning, because there is now no plugin to load.

S1 therefore needs *both*: deploy from an up-to-date checkout **and** restart
the pool — and the deploy needs some guard against stale-worktree clobber
(at minimum, verifying the expected files exist in the new generation
afterwards).

**This also retires the "8-hour auto-update" comfort in `session-state.ts`.** The
comment reasons that a fleet-wide inert writer "needs to be discoverable from the
log rather than by noticing the picker is empty, because the fleet auto-updates
every 8 hours." Cycle 6 already disproved the auto-update claim; S0 shows the
consequence is worse than assumed — a deploy that lands without a restart is
inert *and* logs nothing, because the code that would log never runs.

**Task 8 input (from cycle 6 adversarial review): distinguish "no data" from
"authoritatively idle".** The reader already holds `owners[sid]` and the overlay
file list, so when `owners[sid]` exists but NO live file matches
`(ownerServe, session.directory)`, that is *no data* — materially different from
"the live owner is silent, therefore idle". Today both flatten to
`activity: "idle"` (`oc-session-list-state.ts`, the `else` branch of
`queryWithState`). Emitting `unknown` (or a distinct `nodata`) for that case
would have made the writer-coverage hole above *scream* rather than whisper: the
129-rows-zero-state smoke result would have shown 129 `nodata` instead of a
confident wall of `idle`. Cheap, and it belongs in the row model.

Incidental corroboration of the GC requirement: the live overlay dir contains
`/tmp/opencode/probe-dir`, `/tmp/opencode/probe-dir2` and
`/tmp/session-state-test-1785515432827` — leftover probe files from earlier
cycles' experiments, i.e. exactly the orphan population Task 6's GC collects.

**`session_assignment` verified** in pigeon's unified daemon DB
(`/home/dev/projects/pigeon/packages/daemon/data/pigeon-daemon.db`, also
`OPENCODE_ROUTING_DB`): `session_id` PK, `desired_serve_id`, 561 rows. It also
carries a **`state` column the plan never mentions** (`assigned | draining |
dormant | migrating`); live rows include `dormant`. Treating a dormant
assignment as ownership is harmless *given* merge Rule 1 also requires the owner
file to be live — a dormant session's owner simply omits it, and "absence is
authoritative" then yields idle, which is correct. Do not filter on `state`
without re-deriving that argument.

**Testing note (cycle 6, CORRECTED 2026-08-04):** the bun-based tests live in
`test/*.spec.ts`, which is deliberately OUTSIDE vitest's `test/**/*.test.ts`
glob — they need `bun:test` and `bun:sqlite` and cannot run under vitest.
Renaming them to `.test.ts` breaks `npm test`.

The claim that "they run via `pkgs/oc-session-list/test.sh`" was **false when
written** — `test.sh` never invoked them, and nothing invoked `test.sh`
(`workstation-dmat`). Since #292 they run in the `plugin-bun` flake check, and
`test.sh` runs separately in `oc-session-list-bin` against the *built binary*.
Two different harnesses covering two different things; neither calls the other.

**bun:sqlite is the chosen SQLite access path.** SQLite is compiled into the bun
binary, so there is *zero* store-path-rot surface — which is the actual intent of
"package with a nix sqlite dependency" below (that note targets `oc-search`'s
hardcoded store paths, it does not mandate the `sqlite3` CLI). Supports
`{readonly:true}` and `PRAGMA busy_timeout`. Bonus: Task 6 Step 1 becomes "test
the query against a fixture DB" rather than "test the emitted SQL string", which
is a strictly stronger test. Opacity guard is unaffected either way — still
SQLite-only, no HTTP.

---

## Task 4 (DEMOTED — runs after Task 6): thin Lua caller

**Superseded in part by the Cycle 6 decision above.** `overlay.merge`,
`overlay.read`'s liveness logic, and GC now live in `oc-session-list` (Task 6).
What remains here: invoke the CLI **asynchronously** (`vim.system` + callback —
see the deadlock hazard above), `vim.json.decode` the result, and define the
error surface when the CLI is missing, slow, or returns non-zero. Test with the
`nvim -l` harness from `pkgs/oc-auto-attach/test-project-key.sh:682`.

*Original text, retained for the semantics the CLI must now satisfy:*

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

> **SUPERSEDED IN PART — implemented 2026-08-04 as S6 (PR #295).** The step
> below was written when the join was going to live in Lua. Step 3b moved it
> CLI-side, so the work SPLIT along data gravity, and the "Files" line no longer
> describes what was built:
>
> * **TypeScript** — `oc-session-list-fold.ts` (new): `effective_state`, the
>   child fold, dir-missing stat, and the sort. `oc-session-list-state.ts`: the
>   overlay-truth union. `oc-session-list-base.ts`: `queryTreesForSessions`.
>   Exposed as **`--fold`**, an opt-in flag — folding `--with-state` in place
>   would have destroyed the flat per-row view that the S3 nodata-vs-idle
>   forensics (and `pkgs/oc-session-list/test.sh`) read.
> * **Lua** — `.../model.lua` is now *small*: annotate attachment from
>   `discovery.locate()`, filter, preserve order. It recomputes nothing and
>   **must never sort**; the CLI owns ordering.
> * **The union moved too.** Bullet 7 below assigns it to the picker ("fetch
>   their rows individually", Task 9). That is dead text: Lua has no SQLite, so
>   implementing it there would have required a new per-sid CLI mode plus N
>   process spawns at ~120-250 ms each. The CLI already holds the DB handle and
>   does it in one pass, injected at the `baseRows` level *before* ownership is
>   resolved — appending later would silently drop those rows to merge Rule 2.
>
> **Phase-1 scope cuts, deliberate.** `seen_at`, `space` and `tags` do not exist
> in any implementation, so the **`idle`+`unseen` sort tier** (bullets 5-6) and
> the **space/tag scope filter** (bullet 8) are NOT built — inventing the inputs
> would have produced a filter that passes everything and a test that asserts
> nothing. The blocked-pierces-scope requirement survives in the form that *is*
> implementable today: it pierces the **attached/detached facet**. Project
> clustering is also cut; it conflicts with a global attention sort, and
> Telescope's own sorter groups by the `[project]` ordinal once the user types.
>
> **`child_state` lifts the parent's SORT, not just its glyph.** Bullet 1 forbids
> the parent masquerading as blocked; it says nothing about ordering. A fold that
> left the sort alone would bury the single most attention-worthy row in the list
> under whatever its parent happened to be doing — so the tier is
> `min(own, worst-descendant)` while the glyph stays distinct.

**Files:** ~~Create `.../model.lua`; extend `test.sh`.~~ See the note above.

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


---

## S3 write-up (2026-08-01): the tripwire had to be tuned, not just added

`queryWithState` reported `activity: "idle"` for every row with no overlay state,
which conflated "a live writer watched and said nothing" with "nobody was
watching". On 2026-08-01 that printed **886 confident `idle` rows for ~9 hours**
during a total writer outage. Landed as PR #243.

**The measurement that changed the design.** Both obvious predicates are wrong,
and only the live fleet showed it:

| predicate | false alarms on a HEALTHY fleet | catches #234 (per-instance blindness)? |
|---|---|---|
| per-`(serve, directory)` (the oracle's recommendation) | **62%** of rows | yes |
| serve-level only (my first cut) | 0% | **no** |
| recency-keyed hybrid (shipped) | **0.00%** at 1/5/15/60m | yes |

The directory rule saturates because the writer emits a file per `(serve,
directory)` only while an instance is loaded, so dormant sessions are fileless
forever — a tripwire firing on 62% of rows is one nobody reads. The serve-level
rule is quiet but blind to the failure that happened *first*: plugins bind at
instance creation, so a serve can write for post-deploy directories while being
permanently blind to pre-deploy ones, and those are the actively-worked ones.

The hybrid keys on recency — a row touched within `FRESH_MS` had an instance
loaded that recently, so a missing file means "not watching", not "evicted".

**Two traps found by review, both real:**

1. The aggregate warning originally triggered on `nodataCount === baseRows.length`
   and **could not have fired during the outage it was written for**. An
   un-deploy removes the plugin, not the files; serves keep running so orphan GC
   (dead-pid-gated) never collects them, heartbeats just age out, and sessions
   named in stale files merge as `unknown` — never nodata. Trigger is now "no
   live writer is reporting".
2. `pkgs/oc-session-list/test.sh` asserted `"activity": "idle"` against an empty
   overlay dir — the exact shape of the outage. **The test encoded the bug as the
   expectation**, and correctly broke.

**Standing requirement for S4/S5/S6:** `nodata` is a tripwire, not a status.
Consumers MUST render it at least as loudly as `idle`. Folding it into a
`default:` branch that draws a blank cell makes it quieter than the bug it
exists to catch, which would silently undo this work.
