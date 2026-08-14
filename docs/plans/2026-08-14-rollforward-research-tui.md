# Roll-forward research: TUI cluster + serve/routing cluster (v1.17.13 -> v1.18.18)

Date: 2026-08-14. Read-only research. Method: three throwaway detached worktrees
of `/home/dev/projects/opencode` at `v1.18.18` (`31406ccc51`), then
`git apply --check` / `git apply --reject` / `git apply --3way`. All worktrees
removed afterward. No shared checkout mutated.

## 0. Executive summary

**The whole assigned scope is in far better shape than expected.** Running the
FULL 28-patch ordered `apply.sh` series against a pristine v1.18.18 worktree,
**every patch in my scope applied cleanly except `vim.patch`**, and `vim.patch`
resolves with a plain `git apply --3way` producing **zero conflict markers**.

Full ordered-apply result (all 28, for context; * = my scope):

| Patch | Result |
|---|---|
| gemini-empty-parts | FAIL (test file moved `packages/opencode/test/provider/transform.test.ts`) — other cluster |
| tool-fix | OK |
| cache-thinking-skip | OK |
| retry-cap | FAIL (`packages/opencode/src/session/retry.ts` gone from index) — other cluster |
| **vim** * | **FAIL clean-apply / OK via `--3way`** |
| sqlite-foreign-key-wrap | OK |
| event-session-scope | OK |
| createnext-readback | OK |
| **serve-lease** * | OK (17 trailing-whitespace warnings only) |
| **attach-route-resolve** * | OK |
| **bootstrap-disposed-filter** * | OK |
| event-cold-start-directory | OK |
| project-copy-debounce | OK |
| step-end-diff-bound | OK |
| globalbus-maxlisteners | OK |
| event-log-gate | OK |
| compaction-bounded-load | OK |
| available-cache | OK |
| **session-door-routes** * | OK |
| **tui-door-attach** * | OK |
| **tui-door-tests** * | OK |
| **session-mcp-routes** * | OK |
| **tui-mcp-dialog** * | OK |
| opus5-adaptive-thinking | FAIL (`provider/transform.ts` — expected, upstream shipped 2b2aacc9 in v1.18.5) — other cluster |
| **tui-reconcile-bound** * | OK |
| **registry-port-fence** * | OK |
| plugin-loader-observability | OK |
| message-serve-provenance | OK |

Reason it's so clean: upstream barely touched the files this scope owns.
`git diff --stat v1.17.13 v1.18.18` across all ~21 files touched by my patches =
**83 insertions / 17 deletions across 10 files**. These files are **byte-identical**
between the two tags:

- `packages/tui/src/context/sdk.tsx`  <- big one; four patches touch it
- `packages/tui/src/context/local.tsx`
- `packages/tui/src/util/session.ts`
- `packages/tui/src/component/dialog-mcp.tsx`
- `packages/opencode/src/cli/cmd/attach.ts`
- `packages/opencode/src/cli/cmd/serve.ts`
- `packages/core/src/flag/flag.ts`
- `packages/opencode/src/server/routes/instance/httpapi/groups/session.ts`
- `packages/opencode/src/server/routes/instance/httpapi/groups/event.ts`
- `packages/sdk/js/src/v2/gen/sdk.gen.ts`
- `packages/tui/test/fixture/tui-environment.tsx`

---

## 1. Verdict table

| Patch | Verdict | Confidence | Justification |
|---|---|---|---|
| `vim.patch` | **KEEP-rebase** | High | Upstream shipped NO vim/modal editing in 1.18. 3 of 15 hunks drift; `--3way` resolves all of them with no conflict markers. One SEMANTIC touch-up needed (new upstream `tui.cursor` config collides with vim's cursor-shape effect). |
| `tui-door-attach.patch` | **KEEP-clean** | High | Applies clean in series. `sdk.tsx` unchanged upstream; `sync.tsx` drift is disjoint; permission/question drift is a 1-line `cursorStyle` prop each. |
| `tui-reconcile-bound.patch` | **KEEP-clean** | High | Applies clean, still last in order. Its files (`sse.ts`, `reconcile.ts`, `sdk.tsx`, fixture) are ours or unchanged upstream. |
| `tui-mcp-dialog.patch` | **KEEP-clean** | High | All four source files unchanged upstream between tags. |
| `bootstrap-disposed-filter.patch` | **KEEP-clean** | High | Applies clean both standalone AND in series; `sync.tsx` upstream drift is in the message-store handlers, disjoint from the bootstrap region. |
| `attach-route-resolve.patch` | **KEEP-clean, but REDUNDANT** | High | Applies clean. However ~half its content is now dead (see §4). Recommend a follow-up consolidation, NOT required for the roll-forward. |
| `tui-door-tests.patch` | **KEEP-clean** | High | Pure new test file `packages/sdk/js/test/door-scope.test.ts`; no upstream conflict possible. |
| `serve-lease.patch` | **KEEP-clean** | High | `flag.ts` and `serve.ts` byte-identical upstream; `prompt.ts` hunks (@1078/@1086/@1339) are disjoint from upstream's two changes (@1112, @1237). |
| `registry-port-fence.patch` | **KEEP-clean** | High | Applies clean after serve-lease; touches only files serve-lease created/edited, all unchanged upstream. |
| `session-door-routes.patch` | **KEEP-clean** | High | Routes still absent upstream at 1.18.18. Groups files + `sdk.gen.ts` byte-identical; the `types.gen.ts` hunks still apply despite upstream's own gen churn. |
| `session-mcp-routes.patch` | **KEEP-clean** | High | Same. Standalone `--check` fails ONLY because it stacks on session-door-routes (same 4 files); clean in series. |

No DROP-upstream, no REWRITE, no OBSOLETE-ours in this scope.

---

## 2. Highest-value question 1: did upstream ship vim / modal editing in 1.18?

**No. Emphatically no.**

Evidence:
- `packages/tui/src/component/vim/` does not exist at v1.18.18.
- `git diff --stat v1.17.13 v1.18.18 -- '*vim*'` = empty.
- `git log v1.17.13..v1.18.18 --grep=vim -i` matches exactly one commit,
  `2b8a5969e9 feat(console): add go usage endpoint (#16513)` — an incidental
  substring hit, nothing to do with vim.
- `rg -il 'vim|normal mode|modal edit'` across `packages/tui/src` +
  `packages/opencode/src` at v1.18.18 matches exactly ONE file,
  `packages/tui/src/parsers-config.ts` (tree-sitter grammar list, irrelevant).
- `packages/tui/src/config/index.tsx` at v1.18.18 has no `vim` key.

So `vim.patch` neither shrinks nor drops. It stays at full size (1767 lines,
7 new files + 3 edited files + 1 new test).

### vim.patch: exact failing hunks

`git apply --reject` against pristine v1.18.18:

| File | Hunk | Status |
|---|---|---|
| `packages/tui/src/app.tsx` | #1, #2, #3 | OK (offsets +4 / +14 / +23) |
| `packages/tui/src/component/prompt/index.tsx` | **#1 (`@@ -54,6 +54,11 @@`)** | **REJECTED** |
| | #2, #3 | OK (offset -2 / -1) |
| | **#4 (`@@ -249,6 +256,19 @@`)** | **REJECTED** |
| | #5..#12 | OK (offset -13 / -12 / -10) |
| `packages/tui/src/config/index.tsx` | **#1 (`@@ -63,6 +63,7 @@`)** | **REJECTED** |
| | #2..#12 (test file) | OK |

Cause of each rejection — all three are *pure context drift from one upstream
feature*, upstream's new configurable terminal cursor:

1. **prompt/index.tsx #1** — upstream replaced `import "opentui-spinner/solid"`
   with `import { registerOpencodeSpinner } from "../register-spinner"`, added
   `import { useLocation } from "../../context/location"` and a top-level
   `registerOpencodeSpinner()` call in the same import block the vim imports
   land in.
2. **prompt/index.tsx #4** — upstream added
   `if (tuiConfig.cursor) input.cursorStyle = tuiConfig.cursor`
   inside the exact `createEffect` that is vim hunk #4's leading context.
3. **config/index.tsx #1** — upstream inserted `cursor: Schema.optional(Cursor),`
   immediately above the `mouse:` line that is vim hunk #1's context.

**NOTE the historically fragile hunk is FINE this time.** The `prompt/index.tsx`
send-path `.catch()` / `vimState.clearPending()` hunk (the one that forced the
1.17.4 re-port) is hunk #9 and applied cleanly at offset -12. No re-port needed.

`git apply --3way` merges all three rejections correctly. Verified resolved
output:

```
config/index.tsx (merged):
   cursor: Schema.optional(Cursor),
   mouse: Schema.optional(Schema.Boolean).annotate({...}),
+  vim: Schema.optional(Schema.Boolean).annotate({ description: "Enable vim-style input for the prompt" }),
```

```
prompt/index.tsx (merged, ~line 258):
   createEffect(() => {
     if (!input || input.isDestroyed) return
     if (props.disabled) input.cursorColor = theme.backgroundElement
     if (!props.disabled) input.cursorColor = theme.text
     if (tuiConfig.cursor) input.cursorStyle = tuiConfig.cursor     <-- upstream
   })
+  createEffect(() => {                                              <-- ours
+    if (!input || input.isDestroyed) return
+    if (vimEnabled() && store.mode === "normal") {
+      if (vimState.isInsert()) { input.cursorStyle = { style: "line", blinking: true }; return }
+      input.cursorStyle = { style: "block", blinking: false }; return
+    }
+    input.cursorStyle = { style: "block", blinking: true }
+  })
```

### vim.patch: the ONE semantic issue the 3-way merge cannot see

Upstream v1.18.18 added a user-facing `tui.cursor` config
(`{ style: "block"|"underline"|"line"|"default", blinking: boolean }`) written
in three places in `prompt/index.tsx`:
- the `createEffect` above (line ~261),
- a focus `setTimeout` (line ~1524),
- a JSX `cursorStyle={tuiConfig.cursor}` prop on the textarea (line ~1530).

vim's effect then unconditionally writes `input.cursorStyle` — including its
`else` branch `{ style: "block", blinking: true }` **when vim is disabled**.
That effect runs after upstream's, so **a user who sets `tui.cursor` and does NOT
use vim gets their cursor setting silently overridden**. Recommended manual fix
when re-cutting the patch:

```ts
// last line of the vim effect
input.cursorStyle = tuiConfig.cursor ?? { style: "block", blinking: true }
```

Secondary (cosmetic, lower priority): the focus `setTimeout` at ~1524 writes
`tuiConfig.cursor` imperatively; that write does not retrigger vim's reactive
effect, so focusing the prompt while in vim NORMAL mode can momentarily show the
configured (line) cursor instead of the block cursor until the next mode change.

### vim.patch: @opentui 0.3.4 -> 0.4.5 bump

`packages/tui/package.json` peer/dep range moved `>=0.3.4` -> `>=0.4.5`
(`bun.lock` resolves `@opentui/{core,keymap,solid}@0.4.5`). vim's entire
`@opentui` surface is `import type { TextareaRenderable } from "@opentui/core"`
plus these five members: `cursorOffset`, `deleteRange`, `insertText`,
`logicalCursor`, `plainText`.

All five are still used by **upstream's own v1.18.18 TUI code** with identical
shapes — e.g. `component/prompt/autocomplete.tsx:181-185` uses
`input.logicalCursor` (`{row, col}`) and `input.deleteRange(row, col, row, col)`;
`ui/dialog-prompt.tsx:30`, `routes/session/question.tsx:142`,
`routes/session/permission.tsx:468` use `plainText`. So the API surface survives
the bump. This is strong circumstantial evidence, **not** a typecheck — see §7.

---

## 3. Highest-value question 2: how much did `sync.tsx` and `sdk.tsx` restructure?

**`packages/tui/src/context/sdk.tsx`: ZERO upstream change. Byte-identical
between v1.17.13 and v1.18.18.** This is the single biggest de-risking fact for
this scope — `attach-route-resolve`, `tui-door-attach` and `tui-reconcile-bound`
all rewrite large regions of it, and none of them contend with upstream at all.

**`packages/tui/src/context/sync.tsx`: 21 lines changed (14+/7-), all in the
message/part store handlers, all disjoint from our hunks.** Upstream's changes:

- new `compareMessage(a,b)` and `messageKey(m) = m.time.created + m.id` helpers,
- `message.updated` binary-searches on `messageKey` instead of `m.id`,
- `message.removed` switched from binary `search` to a linear `findIndex`,
- three cosmetic lambda renames (`(p) =>` -> `(part) =>`),
- one `infos.sort(compareMessage)` added in the trim-to-100 path (~line 621).

This is the client half of upstream `db581e47a3` "order legacy message loop by
time (#40990)" (first tag **v1.18.15**). Our three sync.tsx patches
(`bootstrap-disposed-filter`, `tui-door-attach`, `tui-mcp-dialog`,
`tui-reconcile-bound`) all touch the bootstrap / disposed-event / Promise.all
region, not the event-store switch. All applied clean; no interaction.

Other TUI-file drift, for completeness:
- `app.tsx` +14: `registerOpencodeSpinner()`, `DialogDebug`, `opencode.debug` command.
- `routes/session/permission.tsx` +1 and `routes/session/question.tsx` +1:
  a single `cursorStyle={tuiConfig.cursor}` prop each.
- `packages/tui/package.json`: version bump + new `./component/register-spinner` export.

---

## 4. `attach-route-resolve` vs `tui-door-attach`: further redundancy CONFIRMED

apply.sh entry #15 records `tui-follow-owner` already removed as superseded.
There is more. In the **final stacked tree**, `attach-route-resolve` contributes:

**DEAD (fully reverted or unreferenced):**
- `packages/opencode/src/cli/cmd/attach.ts` — `tui-door-attach` deletes the
  `resolveServeUrl` import, deletes the entire pool-aware-resolution comment
  block and its `const url = args.session ? await resolveServeUrl(...)` line, and
  rewrites the `describe:` string and the `UI.error` string that
  `attach-route-resolve` introduced. Net contribution to the final file: the
  `attach <url>` -> `attach [url]` positional change and the removal of
  `demandOption: true` (2 lines).
- `packages/tui/src/util/route.ts` (new file, `parseServeUrl` / `pigeonDaemonUrl`
  / `resolveServeUrl`) — **ZERO production consumers in the final tree.** Verified
  by ripgrep across all of `packages/`: the only importer is its own unit test
  `packages/tui/test/util/route.test.ts`. (All the `useRoute` hits in the tree are
  upstream's unrelated `packages/tui/src/context/route.tsx` TUI-navigation
  context — a name collision, not a consumer.)
- `packages/tui/test/util/route.test.ts` — tests dead code.
- `packages/tui/package.json` `"./util/route": "./src/util/route.ts"` export —
  exports dead code.
- Its `context/sdk.tsx` hunks 4 and 5 (`@@ -88,22 +96,50 @@`, `@@ -145,7 +181,9 @@`)
  — the `startSSE` re-resolve machinery — are rewritten by tui-door-attach's
  `@@ -87,71 +122,201 @@`.

**STILL LOAD-BEARING:**
- `packages/tui/src/util/sse.ts` (new file, `runSseAttempt`) — created here, then
  edited by `tui-door-attach` and `tui-reconcile-bound`. Live.
- `packages/tui/test/util/sse.test.ts` — live (edited by tui-reconcile-bound).
- `packages/tui/src/app.tsx` `sessionID={input.args.sessionID}` prop on
  `<SDKProvider>` — live; consumed at final `sdk.tsx:134`
  (`let activeSessionID = props.sessionID`).
- `sdk.tsx` hunks 2 and 3 (adding `sessionID?: string` to the props type) — live.

**Recommendation (optional, post-roll-forward cleanup, own bead):** fold the
four load-bearing pieces into `tui-door-attach`, delete `util/route.ts`,
`test/util/route.test.ts`, the `./util/route` package.json export and the
attach.ts hunks, then delete `attach-route-resolve.patch`. That removes ~250
lines of dead code and one whole patch from the series. **Do NOT do this as part
of the roll-forward** — the patch applies clean, so consolidating now mixes a
refactor into a version bump.

---

## 5. Highest-value question 3: should the generated SDK files be regenerated?

**Short answer: textual patching still works at 1.18.18 and is the lower-risk
choice for THIS roll-forward; regeneration is the correct verification step, not
the primary mechanism.**

Facts:
- `packages/sdk/js/src/v2/gen/sdk.gen.ts` is **byte-identical** between v1.17.13
  and v1.18.18. Both patches' `sdk.gen.ts` hunks apply clean.
- `packages/sdk/js/src/v2/gen/types.gen.ts` changed upstream by 11 lines
  (`ProviderConfig.interleaved` widened to `boolean | "reasoning" | ... | string`,
  `reasoning_details` -> `reasoning_text`, and a new `Config.subagent_depth?: number`).
  Those regions are nowhere near our appended session/MCP types; both patches'
  `types.gen.ts` hunks apply clean.

The generator DOES exist:
- `packages/sdk/js/package.json` -> `"build": "bun ./script/build.ts"`.
- `packages/sdk/js/script/build.ts` does: `bun dev generate > openapi.json`
  (run with cwd `packages/opencode`), prunes unreachable `SessionNext*1` schemas,
  then `createClient()` from `@hey-api/openapi-ts@0.90.10` into `./src/v2/gen`
  **with `clean: true`**, then post-processes `types.gen.ts` (rewrites
  `V2SessionHistoryData` `limit`/`after` from `string` to `number`) and throws
  if duplicate `SessionNext*1` variants reappear.

Why NOT make regeneration the primary mechanism:
- `clean: true` wipes and rewrites the whole `src/v2/gen` tree. A regenerated
  patch is a whole-directory diff, enormous, and it re-encodes upstream's own gen
  output into OUR patch — so every future upstream gen change becomes a conflict
  in our patch instead of a clean upstream-only change. The current narrow
  textual hunks are strictly more rebase-friendly, which is exactly what the last
  two rolls demonstrated (they survived a version bump untouched).
- It requires a working `bun install` + `bun dev generate` (boots the opencode
  server to dump OpenAPI) and pins `@hey-api/openapi-ts@0.90.10`; any drift in
  that toolchain injects unrelated churn.

Recommended procedure instead:
1. Apply the series as-is (textual gen hunks).
2. **Verify** in a scratch tree: `bun install && bun --cwd packages/sdk/js run build`,
   then `git diff -- packages/sdk/js/src/v2/gen`. An **empty** diff proves the
   textual hunks reproduce exactly what the generator would have emitted from the
   patched route sources. A non-empty diff is the signal to re-cut the gen hunks
   from that generator output.
3. Ordering matters for that verification: the gen output derives from the route
   sources, so it must run AFTER `session-door-routes` + `session-mcp-routes`
   (and after any other patch touching an httpapi group).

I could not run step 2 (no `node_modules` in a throwaway worktree; installing
would be a heavyweight mutation) — flagged in §7.

---

## 6. Apply-ordering constraints within this scope

Hard constraints (a patch physically cannot apply before its predecessor):

```
serve-lease  ->  registry-port-fence
      (registry-port-fence edits packages/core/src/serve/routing-lease.ts and
       packages/core/test/serve/routing-lease.test.ts, both CREATED by serve-lease)

session-door-routes  ->  session-mcp-routes
      (both edit groups/session.ts, handlers/session.ts, sdk.gen.ts, types.gen.ts;
       session-mcp-routes standalone --check FAILS on all four against pristine
       v1.18.18, and applies clean once session-door-routes is in)

attach-route-resolve  ->  tui-door-attach
      (tui-door-attach's attach.ts hunks REMOVE lines attach-route-resolve adds;
       it also edits util/sse.ts, created by attach-route-resolve)

tui-door-attach  ->  tui-mcp-dialog        (both edit context/sync.tsx)
tui-door-attach  ->  tui-reconcile-bound   (rewrites tui-door-attach's sdk.tsx +
                                            sse.ts + reconcilePending)
session-door-routes  ->  tui-door-attach   (TUI calls the routes it adds)
session-mcp-routes   ->  tui-mcp-dialog    (TUI calls the routes it adds)
bootstrap-disposed-filter -> tui-reconcile-bound (fixture RouteProvider fix)
tui-mcp-dialog       ->  tui-reconcile-bound (apply.sh: "MUST apply LAST")
vim -> attach-route-resolve                (both edit app.tsx; disjoint hunks,
                                            but keep the recorded order)
```

**The existing `apply.sh` PATCHES array order already satisfies every one of
these. No reordering is required for the roll-forward.** Confirmed empirically by
the in-order apply in §0.

Cross-cluster note: `serve-lease` edits `packages/opencode/src/session/prompt.ts`,
which `tool-fix` and `compaction-bounded-load` also edit; the existing order
(tool-fix #2, serve-lease #9, compaction-bounded-load #17) works unchanged.

---

## 7. Interaction with upstream `db581e47a3` (the commit motivating the roll-forward)

`db581e47a3 fix(opencode): order legacy message loop by time (#40990)` —
first containing tag **v1.18.15**. It touches
`packages/opencode/src/session/{message-v2.ts,prompt.ts}` plus two tests.

Its `prompt.ts` change is a single line at ~1112:
`lastUser.id < lastAssistant.id` -> `lastAssistant.parentID === lastUser.id`.
It also adds `Effect.provideService(RuntimeFlags.Service, flags)` at ~1237.

`serve-lease.patch`'s `prompt.ts` hunks are at `@@ -42,13 @@`, `@@ -99,6 @@`,
`@@ -1078,6 @@`, `@@ -1086,6 @@`, `@@ -1339,10 @@`. **All disjoint** from both
upstream line ranges. Applied clean; no semantic coupling (serve-lease wraps the
run loop in a fenced lease acquire/renew/release, it does not reason about
message ordering or orphan detection). serve-lease also patches
`packages/opencode/test/session/prompt.test.ts`, which `db581e47a3` extended by
+40 lines — that too applied clean.

---

## 8. What I could NOT determine

1. **No typecheck, no test run.** A throwaway worktree has no `node_modules`, and
   `bun install` at the repo root would be a heavyweight mutation outside the
   read-only remit. So:
   - the `@opentui` 0.3.4 -> 0.4.5 compatibility of `vim.patch` is argued from
     upstream's own continued use of the same five `TextareaRenderable` members,
     **not proven**;
   - the 3-way-merged `vim.patch` output is proven to be conflict-marker-free and
     syntactically plausible, **not proven to compile**;
   - I could not re-run the `packages/tui` suite to confirm the 191-pass baseline
     and that `tui-reconcile-bound`'s fixture fix still keeps all patched tests green.
   **Next step for whoever executes:** in a scratch worktree with the series
   applied, `bun install` then `bun --cwd packages/tui typecheck && bun --cwd packages/tui test`
   and `bun --cwd packages/opencode typecheck`.
2. **Generated-SDK reproduction not verified** (§5 step 2) — needs
   `bun --cwd packages/sdk/js run build` and an empty `git diff` on
   `packages/sdk/js/src/v2/gen`.
3. **Runtime behavior of the front-door/lease machinery at 1.18.18** is
   untested — textual applicability says nothing about whether the door still
   routes correctly against 1.18.18's server. Needs a live smoke test.
4. **`tui-door-tests` / patch-carried test wiring**: the patch adds
   `packages/sdk/js/test/door-scope.test.ts`, which apply.sh entry #21 says is run
   by a "Phase 8 contract tests" step in `build-release.yml`. That workflow lives
   in `opencode-patched`, outside this scope; I did not verify the step still
   names a valid path at 1.18.18. Worth a one-line check before cutover — an
   unnamed patch-carried test is inert.
5. **Whether upstream 1.18 introduced any NEW consumer of `tui.cursor`** that
   vim's effect would clobber beyond `prompt/index.tsx` — I found the three write
   sites in prompt/index.tsx plus the one-line props in permission.tsx and
   question.tsx, but did not exhaustively audit dialog textareas.

## Appendix: reproduction commands

```bash
wt=$(mktemp -d); git -C ~/projects/opencode worktree add --detach "$wt" v1.18.18
cd "$wt"
for n in $(sed -n '/^PATCHES=(/,/^)/p' ~/projects/opencode-patched/patches/apply.sh \
            | sed '1d;$d' | tr -d ' '); do
  git apply --check ~/projects/opencode-patched/patches/$n.patch \
    && git apply ~/projects/opencode-patched/patches/$n.patch && echo "OK   $n" \
    || echo "FAIL $n"
done
git -C ~/projects/opencode worktree remove --force "$wt"
```
