# opencode fork roll-forward v1.17.13 -> v1.18.18 — server/core/infra patch triage

Date: 2026-08-14. Read-only research. No files in shared repos modified; no mutating git
commands run. Verification used `git archive v1.18.18 | tar -x` into throwaway `/tmp` trees
(`git apply --check` there), NOT `git worktree add` on the shared repo.

Repos:
- Source: `/home/dev/projects/opencode`, remote `origin` = anomalyco/opencode.
- Patches: `/home/dev/projects/opencode-patched/patches/`.

---

## 0. Repository-history caveat (matters for the b0017bf1b9 question)

`v1.17.13` and `v1.18.18` are NOT in a simple ancestor relationship with the older tag line:

```
git merge-base --is-ancestor v1.17.13 v1.18.18   -> exit 1
git rev-list --count v1.18.18..v1.17.13          -> 1   (10c894bdee "release: v1.17.13")
git rev-list --count v1.17.13..v1.18.18          -> 713
```

So `v1.17.13` is a release-branch tip whose only unique commit is its own release commit;
the 713-commit delta `v1.17.13..v1.18.18` is the real upstream churn and is the right
comparison. Separately, the repo's history was rewritten/re-grafted at some point:
`git tag --contains b0017bf1b9` lists 97 tags but stops at **v1.17.9** and includes none of
v1.17.10-13 or v1.18.x, while `v1.17.9` and `v1.17.13` mutually diverge by 14188/428 commits.

**Consequence: SHA-containment is not a valid test in this repo. Every determination below
is CONTENT-based (reading the v1.18.18 source), not SHA-based.**

---

## 1. Zero-churn claim — VERIFIED, not trusted

All seven touched source paths exist at BOTH tags (no moves, no renames, no `--follow`
surprises), and only two changed:

| Path | v1.17.13 | v1.18.18 | diff v1.17.13..v1.18.18 |
|---|---|---|---|
| `packages/opencode/src/server/routes/instance/httpapi/handlers/event.ts` | Y | Y | **identical** |
| `packages/core/src/event.ts` | Y | Y | **identical** |
| `packages/opencode/src/snapshot/index.ts` | Y | Y | **identical** |
| `packages/core/src/catalog.ts` | Y | Y | **identical** |
| `packages/opencode/src/bus/global.ts` | Y | Y | **identical** |
| `packages/core/src/project/copy.ts` | Y | Y | 1 line (96d53c6716) |
| `packages/opencode/src/plugin/index.ts` | Y | Y | 2 lines (341c64cc97) |

Companion test files: `httpapi-event.test.ts`, `core/test/event.test.ts`,
`core/test/catalog.test.ts`, `core/test/project-copy.test.ts` all exist at both tags and are
**identical**. `test/snapshot/bounded-diff.test.ts`, `test/bus/global.test.ts`,
`test/plugin/loader-observability.test.ts` are patch-created (absent at both tags) — fine.

Anti-"it moved" checks performed beyond path existence:
- Full v1.18.18 handler directory listing (`.../httpapi/handlers/`) — exactly one `event.ts`.
- `git grep -l 'EventTable|readAggregate' v1.18.18 -- packages/` produces a file set
  **byte-identical** to the same query at v1.17.13 → no new/duplicate event-log module.
- Live-callsite checks: `Snapshot.diffFull` still called from `session/summary.ts:98`;
  `bus/global` imported by 10 src files incl. the event/global SSE handlers; `ProjectCopy`
  wired into `httpapi/server.ts:62`; `CatalogV2.provider.available`/`model.available` still
  the real projection at `catalog.ts:184/210`. None of these are dead code superseded by a
  parallel new module.

The two real churn hunks are **disjoint from every patch region**:

```
copy.ts:139   - const resolved = AbsolutePath.make(FSUtil.resolve(input))
              + const resolved = AbsolutePath.make(yield* fs.resolve(input))
plugin/index.ts +import { ModalPlugin } from "./modal/modal"   (line 16)
                +    ModalPlugin,                              (line 74)
```

---

## 2. `git apply --check` results against a pristine v1.18.18 tree

Method: `git archive v1.18.18 packages/{opencode,core}/{src,test} | tar -x -C $tmp`,
`git init` in `$tmp`, then `git apply --check -v <patch>` per patch.

| Patch | Result |
|---|---|
| event-session-scope | **clean**, no offsets |
| event-cold-start-directory | **fails standalone** (expected — see §4) |
| project-copy-debounce | **clean**, no offsets |
| step-end-diff-bound | clean, offsets: H1 @23 (-8), H2 @796 (+1), H3 @806 (+1) |
| globalbus-maxlisteners | **clean**, no offsets |
| event-log-gate | **clean**, no offsets |
| available-cache | **clean**, no offsets |
| plugin-loader-observability | clean, offsets: H1 @138 (+2), H2 @198 (+2), H3 @254 (+2) |

Ordered re-check: applying `event-session-scope` first, then
`git apply --check event-cold-start-directory` → **clean** (both source and test hunks).
So the only "failure" is the documented ordering dependency, not drift.

Offset notes:
- `plugin-loader-observability` +2 on all hunks is exactly the 2 lines `341c64cc97` added
  above the patch regions (`ModalPlugin` import + registration). Benign.
- `step-end-diff-bound`'s offsets are NOT v1.18.18 drift — `snapshot/index.ts` is
  byte-identical at v1.17.13 and v1.18.18, so these offsets are pre-existing patch-generation
  drift (patch authored against an older 1.17.x base) and reproduce identically at v1.17.13.

---

## 3. Is the behavior already upstream in v1.18.18? (per patch)

### 1. `event-session-scope.patch` — NOT upstream
`git grep -n 'session_ids\|sessionIds' v1.18.18 -- packages/opencode/src packages/protocol/src`
returns **nothing**. The handler file is byte-identical to v1.17.13.
`httpapi/groups/event.ts` also unchanged (relevant: the query-param declaration the
session-door-routes patch adds is still absent, and
`test/server/httpapi-query-schema-drift.test.ts` exists at BOTH tags — no new guard).
**Verdict: KEEP-clean. Confidence: high.**

### 2. `event-cold-start-directory.patch` — NOT upstream
Same file, byte-identical. The directory-equality gate it fixes is untouched upstream.
**Verdict: KEEP-clean (must apply after #1). Confidence: high.**

### 3. `event-log-gate.patch` — NOT upstream. See §5 for the full sunset determination.
`packages/core/src/event.ts` is byte-identical at v1.18.18; the dup-check SELECT and the
`db.insert(EventTable)` at line 337 are still **unconditional**. `git grep EXPERIMENTAL_WORKSPACES`
in `packages/{core,opencode}/src` at v1.18.18 yields only three hits — `flag/flag.ts:50`
(the flag definition), `control-plane/workspace.ts:532` (sets it for a spawned workspace),
`effect/runtime-flags.ts:50` — **none of which gate the event log**.
Patch dependency `truthy` is still exported from `packages/core/src/flag/flag.ts:3`. ✅
**Verdict: KEEP-clean. Confidence: high.**

### 4. `step-end-diff-bound.patch` — NOT upstream
`packages/opencode/src/snapshot/index.ts:737` at v1.18.18 still reads:
```ts
formatPatch(structuredPatch(file, file, before, after, "", "", { context: Number.MAX_SAFE_INTEGER }))
```
No `maxEditLength` anywhere in `packages/` at v1.18.18 (grep clean). The only other
`structuredPatch` callsite, `project/vcs.ts:18`, is an empty-patch helper (`context: 0`) —
not the hot path. Consumer `diffFull` still called from `session/summary.ts:98`.
Upstream issue anomalyco/opencode#29762 evidently still open as of v1.18.18.
**Verdict: KEEP-clean. Confidence: high.**

### 5. `available-cache.patch` — NOT upstream
`packages/core/src/catalog.ts` byte-identical. No `cachedInvalidateWithTTL` in the file;
`provider.available()` (:184) and `model.available()` (:210) still recompute the full
projection per call, and `model.available()` still calls `provider.available()` (:211, :219)
so the herd cost compounds exactly as before. The apply.sh SUNSET note ("upstream >= v1.17.13
still recomputes per call as of 2026-07-04") remains true at v1.18.18.
**Verdict: KEEP-clean. Confidence: high.**

### 6. `globalbus-maxlisteners.patch` — NOT upstream
`git grep 'setMaxListeners\|MaxListeners' v1.18.18 -- packages/` returns **zero** hits;
`bus/global.ts` byte-identical (still ends at `export const GlobalBus = new GlobalBusEmitter()`).
GlobalBus is imported by 10 src files at v1.18.18 including
`httpapi/handlers/global.ts` and `httpapi/handlers/event.ts` — the exact per-SSE-client
listener fan-out the patch exists for. Node's default cap of 10 still applies.
**Verdict: KEEP-clean. Confidence: high.**

*Process note:* this patch has **no numbered header entry** in `patches/apply.sh` — it is in
the `PATCHES=()` array (line 559) between `step-end-diff-bound` (#13/#14) and `event-log-gate`
(#16) but the header jumps #14 → #15(REMOVED) → #16 with no entry for it, and
`grep -n qjk4 apply.sh` returns nothing. Its rationale (bead workstation-qjk4, M3.3) exists
only in the patch's own inline comments. Worth fixing during the roll-forward.

### 7. `project-copy-debounce.patch` — NOT upstream
At v1.18.18 `packages/core/src/project/copy.ts` still has:
- `refreshAfterBoot` at :110 with **no** `OPENCODE_PROJECT_COPY_REFRESH_ON_BOOT` guard,
- `{ concurrency: "unbounded" }` at **both** fan-out sites (:220, :239),
- `layer: Layer.effectDiscard(refreshAfterBoot)` at :290 — still fires per location boot,
- no module-scope single-flight map.
The one upstream change (96d53c6716, `FSUtil.resolve` → `yield* fs.resolve` inside `canonical`
at :139) is in a different function from every patch hunk; `git apply --check` clean.
**Verdict: KEEP-clean. Confidence: high.**

### 8. `plugin-loader-observability.patch` — NOT upstream
v1.18.18 `packages/opencode/src/plugin/index.ts` still has:
- `missing(candidate, _retry, message) {}` at :190 — a bare no-op,
- all four `error(...)` stages (`install` :196, `compatibility` :202, `entry` :207, default
  `load` :212) routing only to `publishPluginError` (:137), which publishes a
  `Session.Event.Error` no log sink observes,
- no per-plugin "plugin loaded" INFO line.
The pre-existing `Effect.logError("failed to load plugin", { path: load.spec, error })` at
:229 (whose message/field the patch deliberately reuses) is intact, so the patch's
"consumer needs no change" property still holds.
**Verdict: KEEP-clean. Confidence: high.**

---

## 4. Apply ordering

- **`event-session-scope` MUST precede `event-cold-start-directory`.** Verified empirically:
  cold-start alone fails both hunks against pristine v1.18.18
  (`error: patch failed: .../handlers/event.ts:26`, and
  `error: patch failed: packages/opencode/test/server/httpapi-event.test.ts:2` — its context
  includes the `session_ids` parsing block and the import line that session-scope adds);
  applied in order, both are clean.
- No other ordering constraint inside this subset. The remaining six each touch a distinct
  source file with no overlap:
  `core/event.ts`, `snapshot/index.ts`, `core/catalog.ts`, `bus/global.ts`,
  `core/project/copy.ts`, `plugin/index.ts`.
- Cross-subset (outside my scope, but relevant): `session-door-routes.patch` declares the
  `?session_ids=` query param on the event group and depends on `event-session-scope` having
  landed (HttpApi 400s on undeclared query params). The existing `PATCHES=()` order already
  satisfies this.
- `patches/apply.sh` current order for this subset is already correct and can be kept as-is:
  `event-session-scope` … `event-cold-start-directory`, `project-copy-debounce`,
  `step-end-diff-bound`, `globalbus-maxlisteners`, `event-log-gate`, … `available-cache`,
  … `plugin-loader-observability`.

---

## 5. HIGHEST-VALUE QUESTION: the `event-log-gate` sunset trigger (b0017bf1b9)

**apply.sh #16 says: "Mirrors upstream's own later gate (commit b0017bf1b9, sync/index.ts).
SUNSET: drop on cutover to an upstream that ships b0017bf1b9 or successor gating."**

### Determination: DO NOT SUNSET. The trigger has not fired.

**(a) The commit itself.**
```
b0017bf1b96ef14fc1ecf91c0b9c4b18e2dfea71
James Long, Wed Mar 25 10:47:40 2026
feat(core): initial implementation of syncing (#17814)
```
It is NOT an ancestor of v1.18.18 (`git merge-base --is-ancestor b0017bf1b9 v1.18.18` → exit 1),
nor of v1.17.13. `git tag --contains b0017bf1b9` lists tags only up to **v1.17.9**. Given the
history rewrite documented in §0, that SHA result alone is inconclusive — hence the content
analysis below, which is the actual answer.

**(b) What b0017bf1b9's gate actually did.** In the file it created,
`packages/opencode/src/sync/index.ts`, inside `function process(def, event, options)`:

```ts
Database.transaction((tx) => {
  projector(tx, event.data)
  if (Flag.OPENCODE_EXPERIMENTAL_WORKSPACES) {
    tx.insert(EventSequenceTable).values({ aggregate_id, seq }).onConflictDoUpdate(...).run()
    tx.insert(EventTable).values({ id, seq, aggregate_id, type, data }).run()
  }
  ...
})
```

**(c) That file does not exist at v1.18.18.** `git ls-tree -r v1.18.18 -- packages/core/src/sync/`
is empty, and there is no `packages/opencode/src/sync/index.ts`. The v1.2/v1.3-era sync engine
was rewritten into the EventV2 service in `packages/core/src/event.ts`, and **the gate was not
carried across the rewrite.** At v1.18.18, `commitSyncEvent`'s dup-check SELECT
(`event.ts:304-306`) and `db.insert(EventTable)` (`event.ts:337`) are unconditional.

**(d) Is there successor gating?** No. The only `OPENCODE_EXPERIMENTAL_WORKSPACES` references
in v1.18.18 `packages/{core,opencode}/src` are the flag definition (`core/src/flag/flag.ts:50`),
a child-process env set (`control-plane/workspace.ts:532`), and a runtime-flags mirror
(`effect/runtime-flags.ts:50`). None is on the event-log write path.

### How upstream's gate compares to ours — exact deltas

Upstream's gate is **broader in one respect and narrower/absent in three**:

1. **BROADER — upstream also gated `EventSequenceTable`.** b0017bf1b9 wrapped the
   `EventSequenceTable` upsert inside the same `if`. **Ours deliberately does not**: our patch
   keeps the seq-counter write unconditional because seq drives ordering/idempotency for the
   live (non-workspace) paths, and it is one tiny row per aggregate. So on the sequence table
   ours is strictly *more conservative* than the gate we cited as precedent. This is the one
   place where the header's "mirrors upstream's gate" is loose — it mirrors the intent for
   `EventTable` only, and intentionally diverges on `EventSequenceTable`.
2. **NARROWER — upstream did not gate the dup-check SELECT.** Ours also skips the
   `SELECT ... FROM EventTable WHERE id = ?` guard (correct: with no inserts there is nothing
   to collide with, and the SELECT was itself synchronous main-thread cost per commit).
3. **NARROWER — different engine.** Upstream's gate was in the legacy `sync/index.ts`
   projector transaction, which no longer exists. It covers zero of the v1.18.18 write paths.
4. **Evaluation timing.** Upstream read the eagerly-computed `Flag.OPENCODE_EXPERIMENTAL_WORKSPACES`
   at module load. Ours reads env lazily via a `eventLogEnabled()` closure so tests/embedders
   can toggle post-load. Our fallback (`process.env[X] === undefined ? truthy("OPENCODE_EXPERIMENTAL")
   : truthy(X)`) is a byte-for-byte reimplementation of v1.18.18's
   `enabledByExperimental` (`core/src/flag/flag.ts:11-13`), so the on/off semantics match.

### Safety re-verification of our gate at v1.18.18 (does anything new read the log?)

`git grep -l 'EventTable|readAggregate' v1.18.18 -- packages/` yields an identical file set to
v1.17.13 — no new reader appeared in 713 commits. Concretely, at v1.18.18 the readers are:

| Reader | Reachable with workspaces OFF? |
|---|---|
| `core/src/event.ts` `readAggregate` (:78) | only caller is `core/src/session.ts:354` (`V2Session.history`) |
| `core/src/event.ts` `readAfter` (:546) | **no callers at all** outside `event.ts` |
| `core/src/event.ts` `remove`/`replay` | delete + replay paths, not log consumers |
| `control-plane/workspace.ts:647-655` | workspace *warp*; short-circuits `return` when `target.type === "local"` (:639-643) — the EventTable read is on the **remote-target branch only** |
| `httpapi/handlers/sync.ts:7` | the `/sync` group (`start`/`replay`/`steal`/`history`) — workspace sync surface |

The one item worth flagging as **residual risk (unchanged from v1.17.13, not a regression)**:
`V2Session.history` is declared as a real HTTP endpoint in `packages/protocol/src/groups/session.ts:307`
(`GET /api/session/:sessionID/history`, operationId `v2.session.history`) and is present in the
generated SDK. With our gate active it would return an empty history. I could NOT locate an
`.handle("session.history", …)` implementation in
`packages/opencode/src/server/routes/instance/httpapi/handlers/` at v1.18.18 (the handler chain
in `handlers/session.ts:414-440` does not include it), so the endpoint may be declared-but-unwired
on the instance API. **Crucially, this is identical at both tags**: the protocol declaration is
at the same line 307 in v1.17.13, and `grep -c V2SessionHistory` in
`packages/sdk/js/src/v2/gen/sdk.gen.ts` is 3 at both. So the roll-forward does not change the
patch's risk profile — but the pre-existing question ("is `V2Session.history` served, and does
anything call it?") is still open and is the one thing that could invalidate the gate's
"nothing reads the log when workspaces are off" premise.

---

## 6. Verdict table

| Patch | Verdict | Confidence | Reason |
|---|---|---|---|
| event-session-scope | KEEP-clean | high | no `session_ids` anywhere in v1.18.18; handler byte-identical; `git apply --check` clean, zero offsets |
| event-cold-start-directory | KEEP-clean | high | same file byte-identical; clean once applied after event-session-scope (verified) |
| event-log-gate | KEEP-clean | high | sunset NOT triggered — b0017bf1b9's gate lived in a `sync/index.ts` that no longer exists; `EventTable` insert still unconditional at `core/event.ts:337`; no successor gate |
| step-end-diff-bound | KEEP-clean | high | `snapshot/index.ts:737` still `context: MAX_SAFE_INTEGER`, no `maxEditLength` in tree; applies with pre-existing (not new) offsets |
| available-cache | KEEP-clean | high | `catalog.ts` byte-identical; `available()` still recomputes per call; clean apply |
| globalbus-maxlisteners | KEEP-clean | high | zero `setMaxListeners` in v1.18.18; `bus/global.ts` byte-identical; clean apply |
| project-copy-debounce | KEEP-clean | high | boot refresh ungated, `concurrency:"unbounded"` at :220/:239, no single-flight; the one upstream line (`fs.resolve`) is in a disjoint function; clean apply |
| plugin-loader-observability | KEEP-clean | high | `missing(){}` no-op at :190, four `error` stages log nothing, no "plugin loaded" INFO; clean apply (+2 offset from ModalPlugin) |

Net: **8 KEEP-clean, 0 DROP, 0 REWRITE.** No hunk in this subset needs rebasing.

---

## 7. Not determined / open items

1. **Is `GET /api/session/:sessionID/history` actually served?** Declared in
   `packages/protocol/src/groups/session.ts:307` and present in the generated SDK/openapi at
   both tags, but I found no matching `.handle(...)` in the instance httpapi handlers. If some
   other server surface implements the protocol `session` group, that endpoint reads the event
   log via `V2Session.history` → `EventV2.readAggregate`, and `event-log-gate` makes it return
   empty when workspaces are off. Unchanged by the roll-forward, but unresolved on the merits.
2. **Runtime/typecheck verification not performed.** Everything here is `git apply --check`
   plus source reading. Neither `bun typecheck` nor the patch-carried tests were run (that needs
   a full checkout + install, which is beyond read-only research). "Applies cleanly" ≠ "compiles"
   — e.g. the `Effect` / drizzle API surface could have shifted under an unchanged file.
   Recommend running `bun --cwd packages/opencode typecheck`, `bun --cwd packages/core typecheck`,
   and the four patch-carried suites (`test/bus/global.test.ts`,
   `test/snapshot/bounded-diff.test.ts`, `test/plugin/loader-observability.test.ts`,
   `core/test/event.test.ts`) after the stack is applied.
3. **Why the tag/SHA lineage is discontinuous** (v1.17.9 vs v1.17.13 mutual divergence of
   14188/428 commits) — I established that it is, and worked around it, but did not determine
   *when or how* the anomalyco history was rewritten. Anyone else using
   `git tag --contains <sha>` in this repo will be misled the same way.
4. **`globalbus-maxlisteners` has no header entry in `patches/apply.sh`** — undocumented in the
   numbered series (gap between #14 and #16). Not a roll-forward blocker; a docs fix to make
   during the refresh. Its bead is workstation-qjk4 (M3.3), recoverable only from the patch's
   inline comments.

---

## 8. Housekeeping note (shared-repo safety)

While cleaning up my `/tmp` scratch trees I found `/tmp/oc1818.l6BZ` registered as a git
worktree of `/home/dev/projects/opencode` at `31406ccc51` (v1.18.18), clean, alongside a
peer's `/tmp/msgv2-scope-80503922` (same commit) and `/tmp/opencode/v1177-apply`. My own
scratch trees were plain `git archive | tar -x` extractions of `packages/` only (no
`git worktree add`), and this one contains a FULL checkout (README/AGENTS.md/infra/...), so
its provenance is ambiguous — it may belong to a concurrent session. **I did not delete it
and did not run `git worktree prune`**, since removing a live peer worktree is exactly the
shared-tree hazard to avoid. If it turns out to be orphaned, the owner should remove it with
`git worktree remove --force /tmp/oc1818.l6BZ`.

My own scratch dirs (`/tmp/ocseq.*`, `/tmp/oc1818.path`, `/tmp/ocseq.path`, `/tmp/et.txt`)
were removed. No file in `/home/dev/projects/opencode` or
`/home/dev/projects/opencode-patched` was modified; the only pre-existing dirty item in the
opencode repo is an untracked `DB-CORRUPTION-RESEARCH.md` that predates this session.
