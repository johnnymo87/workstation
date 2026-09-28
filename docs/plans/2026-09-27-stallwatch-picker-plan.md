# Stall-watch Picker Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** A `<leader>fp` telescope picker that lists stall-watch programs (Screen 1), drills into the sessions each program's goose items name (Screen 2, flagged/all), and jumps to a session through the session switcher's existing decide/exec path — exactly as specified in `docs/plans/2026-09-27-stallwatch-picker-design.md`.

**Architecture:** Two small generic CLI additions (`oc-session-list --ids`, `oc-tags sessions <tag>`) feed one async snapshot fetch at picker open (`source.lua`). Everything after the fetch is a pure function of that snapshot (`model.lua`, `spec.lua`), rendered by a thin telescope layer (`init.lua`) that reuses the session switcher's ordering controls, glyphs, `cli.fetch`, `flow:accept`, and a newly-exported `session_switcher.dispatch` for the jump.

**Tech Stack:** Lua (Neovim 0.11, telescope.nvim), TypeScript on bun (`oc-session-list`), Python 3 (`oc-tags`), bash test harnesses, Nix flake checks.

**Beads epic:** workstation-p8ch

---

## Read this first (zero-context orientation)

**Where you are.** Worktree `/home/dev/projects/workstation/.worktrees/stallwatch-picker`, branch `stallwatch-picker`, host `cloudbox` (`echo $OPENCODE_HOSTNAME`; the flake system is `aarch64-linux`). Every path below is relative to the worktree root. Never edit `~/projects/workstation` itself.

**Git rules (hard).** Commit bare (`git commit -m ...`, no `-c user.*`, no `GIT_AUTHOR_*`). Every message starts with `[NO-JIRA] `. No `reset`/`stash`/`checkout --`/`restore`/`clean`/`rebase`/`--amend`/force-push. Stage explicit paths only.

**Flake checks only see the git index.** `nix build .#checks.aarch64-linux.<name>` builds from tracked+staged files. A new file that is not `git add`ed is invisible to it and the check will test the OLD tree. Always `git add` the task's paths *before* running a check.

**How each suite runs.**

| Suite | Local command | Flake check | Pinned in `flake.nix` |
|---|---|---|---|
| oc-session-list unit (bun) | `cd assets/opencode/plugins && bun test test/oc-session-list.spec.ts` | `plugin-bun` | `expected_expects=355` at `flake.nix:2125` |
| oc-session-list built binary | `bash pkgs/oc-session-list/test.sh` | `oc-session-list-bin` | greps at `flake.nix:2290-2297` |
| oc-tags | `python3 pkgs/oc-tags/test_oc_tags.py` | `oc-tags-tests` | `Ran 181 tests` at `flake.nix:1118` |
| nvim Lua (switcher + this picker) | `bash assets/nvim/test-session-switcher.sh` | `nvim-lua` | PASS-line count + per-suite counts at `flake.nix:1573-1593` |
| test reachability | `bash users/dev/test-unwired-tests.sh` | `test-reachability` | none (census only) |

**Pinned counts are measured, not guessed.** Every number this plan says to pin was measured on a throwaway prototype of exactly this code. If your measured number differs, pin YOUR measured number and say so in the commit message — never edit a test to hit the plan's number. The bun `expect()` count must be measured with a sandbox-like HOME, because some cases skip or iterate live data under the real HOME (measured: 800 expects with the real HOME, 355 with a sandbox one on unmodified `main`):

```bash
H=$(mktemp -d); mkdir -p "$H/.local/share/opencode/session-state.d"
echo '{"version":1,"serveId":"sentinel","pid":999999,"heartbeat":0,"directory":"/sentinel","sessions":{}}' \
  > "$H/.local/share/opencode/session-state.d/sentinel.json"
( cd assets/opencode/plugins && HOME="$H" bun test test/oc-session-list.spec.ts 2>&1 | tail -6 )
```

### PRIVACY GATE — run before EVERY commit

This repo is public; the stall-watcher is private. Nothing it produces — program/tag names, item text, session titles or ids, digest content — may appear in code, tests, fixtures, commit messages, or docs. All fixtures here are synthetic (`alpha`, `beta`, `ses_fixture_*`, invented sentences). The automated scrub skips `docs/plans/`, so this gate is by hand plus one mechanical check that builds its needle list from the live data **at runtime in /tmp** (nothing is written to the repo):

```bash
# 1. Read the staged diff yourself, line by line. Only synthetic names may appear.
git diff --cached

# 2. Mechanical: no live string from the stall-watcher in the ADDED lines.
priv=$(mktemp -d)
~/projects/eng-agent-platform/stallwatch/items.sh --json > "$priv/items.json" || echo "read command failed; do step 1 extra carefully"
# The length filter runs AFTER jq -r has split multi-line item text into lines:
# item text contains blank lines, and ONE empty needle makes grep -F match every
# line (measured: a filter inside jq let exactly that through).
jq -r '.programs[].tag,
       (.programs[].items[] | .fingerprint, .text, (.sessions[] | .id, .title, .directory))
       | select(type == "string")' "$priv/items.json" | awk 'length($0) >= 4' | sort -u > "$priv/needles.txt"
d=$(jq -r '.latest_digest // empty' "$priv/items.json")
[ -n "$d" ] && [ -r "$d" ] && awk 'length($0) >= 20' "$d" >> "$priv/needles.txt"
[ -n "$d" ] && echo "$d" >> "$priv/needles.txt"
grep -c '^[[:space:]]*$' "$priv/needles.txt"          # must print 0
git diff --cached | grep '^+' > "$priv/added.txt"
# Line NUMBERS only -- do not echo private text into the terminal/transcript.
hits=$(grep -n -F -f "$priv/needles.txt" "$priv/added.txt" | cut -d: -f1 | tr '\n' ' ')
if [ -n "$hits" ]; then echo "STOP: private string in staged added-lines #: $hits"; else echo "privacy gate: clean"; fi
rm -rf "$priv"

# 3. Repo-wide org scrub (scrubbing-company-references skill checklist).
rg -i "wonder|freshrealm|food-truck|blueapron" --glob '!docs/plans/*' --glob '!.git/*' --glob '!**/issues.jsonl'
rg "cops-[0-9]" -i --glob '!docs/plans/*' --glob '!.git/*' --glob '!**/issues.jsonl'
rg -i "azurecr\.io|akscluster" --glob '!docs/plans/*' --glob '!.git/*' --glob '!**/issues.jsonl'
rg "70497edc|712020:|3963715585|3963191313" --glob '!.git/*' --glob '!**/issues.jsonl'
rg "@(wonder|freshrealm|company-name)\." --glob '!.git/*' --glob '!**/issues.jsonl'
rg "storage\.googleapis\.com/[a-z0-9-]+|gs://" --glob '!docs/plans/*' --glob '!.git/*' --glob '!**/issues.jsonl'
```

Expected: step 2 prints `0` then `privacy gate: clean`. A `STOP` can be a false positive — session directories and some fingerprints are generic strings that already occur in this repo (measured: several existing files match the directory needles) — so read the numbered added lines yourself and decide; never "fix" a STOP by weakening the needles; step 3 prints nothing new from your diff (compare against `main` if anything pre-existing shows). The default command path `~/projects/eng-agent-platform/stallwatch/items.sh` is allowed: that repo name already appears in `users/dev/home.base.nix`.

---

## Decisions this plan makes (where the design was silent or the code disagreed)

1. **Task order: pins move with their suites.** The suggested order put all flake wiring in one late task. The `nvim-lua`, `plugin-bun` and `oc-tags-tests` checks pin *exact* counts, so any commit that adds assertions without re-pinning is a red commit. Each task below re-pins the check its tests live in; the final task only runs the whole `nix flake check`.
2. **`--ids` replaces the recency window and ignores `--limit`.** The design's premise is that most item/tagged sessions fall outside any window; applying `--limit` would drop the rows the flag exists to fetch. For the same reason the `--fold` overlay *union* is off in ids mode (the answer is the set asked for). `--ids ""` prints `[]` rather than falling back to the window. The Lua side never sends `--ids` with an empty list (it skips the call).
3. **`--ids` is chunked.** `queryTreesForSessions` (`oc-session-list-base.ts:45`) silently keeps only the first 200 ids per call. A new `queryTreesForIds` loops it in chunks of 200 (each statement still bounded), dedupes, sorts newest-first, and hard-caps a request at 2000 ids with an `onWarn` (stderr → the picker's ⚠ warnings). It inherits archived-exclusion and child→whole-tree from the existing function rather than re-deriving them.
4. **The jump is shared, not copied.** The descriptor handling lives inline in `session_switcher/init.lua:287-348`. Copying it would be exactly the drift this codebase keeps documenting, so Task 3 extracts it verbatim into an exported `session_switcher.dispatch(desc, row, client, opts)`; the switcher's own `<CR>` calls it, and its 656 existing spec assertions pass unchanged (verified). It stays in the telescope layer because `exec.lua` is "one side effect per function, no branching".
5. **`cli.fetch` serves step 3.** `session_switcher/cli.lua` gains an `ids` option in `build_argv`, so step 3 gets cli.fetch's timeout, exactly-once callback, decode guard and stderr-as-warnings for free.
6. **Flagged view order = item order** (first appearance walking items in contract order, i.e. most urgent first). The design fixes all-view order ("each in `oc-session-list` order") but not flagged-view order.
7. **All view keeps CLI-absent flagged rows.** Flagged rows the CLI did not return (archived/deleted) are appended to the flagged group in item order, so pressing `<C-f>` never makes a flagged session disappear. "Rest" = CLI rows whose id is in that program's `oc-tags sessions` list. Automated (lgtm) sessions are not filtered in either view.
8. **Unjoined-row fallbacks.** Title = item session `title`, then the id (the design says "title = id"; the contract carries a title, so it is tried first). `dir_missing = (directory_exists == false)`: a *missing* `directory_exists` is treated as "not known gone" (the design's "optional field missing → tolerated"). Unjoined rows render a blank state glyph and blank age — not the `~` "unknown" glyph, which asserts "stale data from a dead source".
9. **Program markers use `== false`.** `[log-only]` when `armed == false`, `[disabled]` when `enabled == false`; a missing field shows no marker.
10. **Cursor restore uses `selection_strategy = "closest"`.** Telescope's default `"reset"` re-applies `default_selection_index` on every keystroke (`telescope/pickers.lua` `_do_selection`), pinning the cursor to a row position the filter may have emptied. `"closest"` applies it only while the prompt is empty. `default_selection_index` is the program's 1-based position in the results; `Picker:get_row` already maps it through `sorting_strategy = "descending"` (`max_results - index`), so it must NOT be inverted by hand. Verified against real telescope headlessly: select `beta`, `<CR>`, `<C-b>` → cursor back on `beta`.
11. **`<C-d>` is Screen 1 only**, as the design lists it. It shadows telescope's `preview_scrolling_down` in Screen 1; `<C-f>` shadows `preview_scrolling_left` in Screen 2 (the switcher already does the same with `<C-f>`).
12. **Keymap is registered at startup only if the command is executable** (design), unlike `<leader>fs`, which is always bound and notifies at press time.
13. **Digest age** comes from the digest file's mtime (the contract gives only a path). Shown in the scratch window's `winbar`; the buffer is not named after the path.

---

### Task 0: Baseline

**Files:** none.

**Step 1: Confirm host, branch and a green baseline**

```bash
echo "$OPENCODE_HOSTNAME"; git status --short; git log --oneline -3
bash assets/nvim/test-session-switcher.sh 2>&1 | tail -3
python3 pkgs/oc-tags/test_oc_tags.py 2>&1 | tail -3
```

Expected: `cloudbox`; clean tree; top commit is the design doc; `all session_switcher lua tests passed`; `Ran 181 tests` / `OK`.

---

### Task 1: `oc-session-list --ids <sid,...>`

**Files:**
- Modify: `assets/opencode/plugins/oc-session-list-base.ts` (insert after line 85, before `queryBaseList` at 87)
- Modify: `assets/opencode/plugins/oc-session-list.ts:2,6-15,27-30,64-66,74,89-90,111-126`
- Test: `assets/opencode/plugins/test/oc-session-list.spec.ts` (import at line 6; append after line 2496)
- Test: `pkgs/oc-session-list/test.sh` (insert before line 169, `echo "ALL PASS (oc-session-list)"`)
- Modify: `flake.nix:2125` (plugin-bun expect pin), `flake.nix:2290-2297` (oc-session-list-bin greps)

Context: `main()` (`oc-session-list.ts:94-135`) builds `baseRows` from `queryBaseList(db, {limit})`, then `queryWithState` (with the overlay-union `unionLookup` only under `--fold`), then `foldRows`, which owns ordering (attention group first, then tree recency; `oc-session-list-fold.ts:242-249`). `--ids` swaps only the first step.

**Step 1: Write the failing unit tests**

Apply to `assets/opencode/plugins/test/oc-session-list.spec.ts` (import change + new `describe` appended at the end):

```diff
--- a/assets/opencode/plugins/test/oc-session-list.spec.ts
+++ b/assets/opencode/plugins/test/oc-session-list.spec.ts
@@ -3,7 +3,7 @@
 import { existsSync, readdirSync, mkdirSync, mkdtempSync, writeFileSync, rmSync } from "node:fs";
 import { join } from "node:path";
 import { tmpdir } from "node:os";
-import { queryBaseList, queryTreesForSessions } from "../oc-session-list-base.js";
+import { IDS_CAP, IDS_CHUNK, queryBaseList, queryTreesForIds, queryTreesForSessions } from "../oc-session-list-base.js";
 import { main, parseCliArgs } from "../oc-session-list.js";
 import {
   attentionCandidates,
@@ -2494,3 +2494,70 @@
     }
   });
 });
+
+// --ids (workstation-p8ch): an explicit id set instead of the recency window.
+describe("--ids: explicit session set", () => {
+  function insert(db: Database, id: string, parent: string | null, updated: number, archived: number | null = null) {
+    db.query(
+      `INSERT INTO session (id, project_id, parent_id, slug, directory, title, version, time_created, time_updated, time_archived)
+       VALUES (?, 'p1', ?, ?, '/proj', ?, '1.0', 1, ?, ?)`,
+    ).run(id, parent, id, `Title ${id}`, updated, archived);
+  }
+
+  it("parses --ids <csv> and --ids=<csv>, trimming and dropping empties", () => {
+    expect(parseCliArgs(["--ids", "a, b,,c"]).ids).toEqual(["a", "b", "c"]);
+    expect(parseCliArgs(["--ids=x,y"]).ids).toEqual(["x", "y"]);
+  });
+
+  it("absent flag is null (normal listing); present-but-empty is an empty set", () => {
+    expect(parseCliArgs([]).ids).toBeNull();
+    expect(parseCliArgs(["--ids", ""]).ids).toEqual([]);
+    expect(parseCliArgs(["--ids"]).ids).toEqual([]);
+  });
+
+  it("a child id brings its whole root tree; archived and unknown ids are dropped", () => {
+    const db = createTestDb();
+    insert(db, "root_a", null, 100);
+    insert(db, "kid_a", "root_a", 200);
+    insert(db, "gone_a", null, 300, 301);
+    const rows = queryTreesForIds(db, ["kid_a", "gone_a", "never_existed"]);
+    expect(rows.map((r) => r.id).sort()).toEqual(["kid_a", "root_a"]);
+    expect(rows.every((r) => r.root_id === "root_a")).toBe(true);
+  });
+
+  it("is NOT bounded by the recency window", () => {
+    const db = createTestDb();
+    insert(db, "old_root", null, 1);
+    for (let i = 0; i < 5; i++) insert(db, `new_${i}`, null, 1000 + i);
+    expect(queryBaseList(db, { limit: 2 }).map((r) => r.id)).not.toContain("old_root");
+    expect(queryTreesForIds(db, ["old_root"]).map((r) => r.id)).toEqual(["old_root"]);
+  });
+
+  it("resolves more than one chunk of ids, deduped, newest first", () => {
+    const db = createTestDb();
+    const n = IDS_CHUNK + 50;
+    const ids: string[] = [];
+    for (let i = 0; i < n; i++) {
+      const id = `r_${String(i).padStart(4, "0")}`;
+      insert(db, id, null, i);
+      ids.push(id);
+    }
+    // The same id twice, straddling the chunk boundary, must still yield one row.
+    const rows = queryTreesForIds(db, [...ids, ids[0]]);
+    expect(rows.length).toBe(n);
+    expect(new Set(rows.map((r) => r.id)).size).toBe(n);
+    expect(rows[0].id).toBe(ids[n - 1]);
+    expect(rows[n - 1].id).toBe(ids[0]);
+    // The single-call helper silently keeps 200: that is why the loop exists.
+    expect(queryTreesForSessions(db, ids).length).toBe(IDS_CHUNK);
+  });
+
+  it("warns, rather than truncating silently, past IDS_CAP", () => {
+    const db = createTestDb();
+    const ids = Array.from({ length: IDS_CAP + 1 }, (_, i) => `x_${i}`);
+    const warnings: string[] = [];
+    queryTreesForIds(db, ids, (m) => warnings.push(m));
+    expect(warnings.length).toBe(1);
+    expect(warnings[0]).toContain(String(IDS_CAP));
+  });
+});
```

**Step 2: Run them to verify they fail**

Run: `cd assets/opencode/plugins && bun test test/oc-session-list.spec.ts 2>&1 | tail -8`
Expected: FAIL — `SyntaxError: Export named 'IDS_CAP' not found in module '.../oc-session-list-base.ts'` (the whole file fails to load).

**Step 3: Implement `queryTreesForIds`**

```diff
--- a/assets/opencode/plugins/oc-session-list-base.ts
+++ b/assets/opencode/plugins/oc-session-list-base.ts
@@ -84,6 +84,48 @@
   return query.all(...capped);
 }
 
+/** Chunk size for `queryTreesForIds`: queryTreesForSessions' own per-statement cap. */
+export const IDS_CHUNK = 200;
+/** Hard cap on one `--ids` request. Past it the tail is dropped LOUDLY (onWarn). */
+export const IDS_CAP = 2000;
+
+/**
+ * `oc-session-list --ids`: the FULL root trees of an explicit set of session
+ * ids, independent of the recency window.
+ *
+ * A thin loop over queryTreesForSessions, so it inherits both of that
+ * function's properties -- archived stays gone, a child id brings its whole
+ * tree -- instead of re-deriving them. The loop exists because that function
+ * silently keeps only the first 200 ids of a call: fine for its overlay-union
+ * caller, wrong for a caller that names its set explicitly (a program's tagged
+ * sessions plus its item sessions can exceed 200). Each statement stays
+ * bounded at IDS_CHUNK; the whole request is capped at IDS_CAP, and exceeding
+ * the cap WARNS rather than truncating in silence.
+ *
+ * Rows are deduped by id (two chunks can name members of one tree) and
+ * returned newest-first, the order a single queryTreesForSessions call uses.
+ */
+export function queryTreesForIds(
+  db: Database,
+  sessionIds: string[],
+  onWarn?: (msg: string) => void,
+): SessionRow[] {
+  let ids = [...new Set(sessionIds.filter((s) => typeof s === "string" && s !== ""))];
+  if (ids.length > IDS_CAP) {
+    onWarn?.(`--ids named ${ids.length} sessions; only the first ${IDS_CAP} were resolved`);
+    ids = ids.slice(0, IDS_CAP);
+  }
+  const byId = new Map<string, SessionRow>();
+  for (let i = 0; i < ids.length; i += IDS_CHUNK) {
+    for (const row of queryTreesForSessions(db, ids.slice(i, i + IDS_CHUNK))) {
+      if (!byId.has(row.id)) byId.set(row.id, row);
+    }
+  }
+  return [...byId.values()].sort(
+    (a, b) => b.time_updated - a.time_updated || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0),
+  );
+}
+
 export function queryBaseList(db: Database, options?: BaseListOptions): SessionRow[] {
   const limit = options?.limit ?? 50;
 
```

**Step 4: Wire the flag into the CLI**

```diff
--- a/assets/opencode/plugins/oc-session-list.ts
+++ b/assets/opencode/plugins/oc-session-list.ts
@@ -1,5 +1,5 @@
 import { Database } from "bun:sqlite";
-import { queryBaseList, queryTreesForSessions } from "./oc-session-list-base.js";
+import { queryBaseList, queryTreesForIds, queryTreesForSessions } from "./oc-session-list-base.js";
 import { queryWithState, runOrphanGc } from "./oc-session-list-state.js";
 import { foldRows } from "./oc-session-list-fold.js";
 
@@ -12,6 +12,13 @@
   fold: boolean;
   gc: boolean;
   help: boolean;
+  /**
+   * `--ids a,b,c`: resolve exactly these sessions' root trees instead of the
+   * recency window. null = flag absent (normal listing). An empty array means
+   * the flag was given with nothing in it, and yields an empty list -- never a
+   * fall back to the recency window, which would answer a different question.
+   */
+  ids: string[] | null;
 }
 
 export function parseCliArgs(args: string[]): CliOptions {
@@ -28,6 +35,9 @@
   let fold = false;
   let gc = false;
   let help = false;
+  let ids: string[] | null = null;
+  const splitIds = (v: string): string[] =>
+    v.split(",").map((s) => s.trim()).filter((s) => s !== "");
 
   for (let i = 0; i < args.length; i++) {
     const arg = args[i];
@@ -63,6 +73,10 @@
       overlayDir = arg.slice(14);
     } else if (arg === "--gc") {
       gc = true;
+    } else if (arg === "--ids") {
+      ids = splitIds(args[++i] ?? "");
+    } else if (arg.startsWith("--ids=")) {
+      ids = splitIds(arg.slice(6));
     }
   }
 
@@ -71,7 +85,7 @@
   // meaningless. Fall back to the default rather than surprising the caller.
   if (!Number.isFinite(limit) || limit <= 0) limit = 50;
 
-  return { limit, dbPath, routingDbPath, overlayDir, withState, fold, gc, help };
+  return { limit, dbPath, routingDbPath, overlayDir, withState, fold, gc, help, ids };
 }
 
 export function printHelp(): void {
@@ -87,6 +101,9 @@
   --routing-db <path>   Path to pigeon-daemon.db (default: $OPENCODE_ROUTING_DB, else $HOME/projects/pigeon/packages/daemon/data/pigeon-daemon.db)
   --overlay-dir <path> Directory containing session-state overlays (default: $HOME/.local/share/opencode/session-state.d)
   --gc                 Perform orphan GC on dead overlay files older than 10 minutes
+  --ids <id,...>       Resolve exactly these sessions (a child id brings its whole root tree;
+                       archived and unknown ids are dropped). Replaces the recency window:
+                       --limit is ignored and --fold adds no overlay union.
   --help, -h           Show this help message
 `);
 }
@@ -110,18 +127,28 @@
 
   try {
     const db = new Database(options.dbPath, { readonly: true });
-    const baseRows = queryBaseList(db, { limit: options.limit });
+    const warn = (msg: string) => console.error(`oc-session-list: ${msg}`);
+    // --ids REPLACES the recency window rather than filtering it: the caller
+    // (the stall-watch picker) names sessions precisely because most of them
+    // fall outside any window, so applying --limit would drop the rows it came
+    // for. For the same reason the --fold overlay union is off in ids mode --
+    // the answer is the set that was asked for, not that set plus whatever
+    // else is attention-worthy right now.
+    const idsMode = options.ids !== null;
+    const baseRows = idsMode
+      ? queryTreesForIds(db, options.ids ?? [], warn)
+      : queryBaseList(db, { limit: options.limit });
 
     if (options.withState) {
       const rowsWithState = queryWithState(baseRows, {
         routingDbPath: options.routingDbPath,
-        onWarn: (msg: string) => console.error(`oc-session-list: ${msg}`),
+        onWarn: warn,
         overlayDir: options.overlayDir,
         // The union only makes sense when we are folding to roots: it exists so
         // an attention-worthy row outside the recency window still reaches the
         // picker. Wiring it here (not inside queryWithState) keeps the DB handle
         // where it belongs and leaves the plain --with-state shape untouched.
-        ...(options.fold ? { unionLookup: (sids: string[]) => queryTreesForSessions(db, sids) } : {}),
+        ...(options.fold && !idsMode ? { unionLookup: (sids: string[]) => queryTreesForSessions(db, sids) } : {}),
       });
       const out = options.fold ? foldRows(rowsWithState) : rowsWithState;
       console.log(JSON.stringify(out, null, 2));
```

**Step 5: Run the unit tests to verify they pass**

Run: `cd assets/opencode/plugins && bun test test/oc-session-list.spec.ts 2>&1 | tail -6`
Expected: `0 fail`, 6 more passing tests than baseline.

**Step 6: Add the built-binary stage to `pkgs/oc-session-list/test.sh`** (before the final `echo "ALL PASS (oc-session-list)"`)

```diff
--- a/pkgs/oc-session-list/test.sh
+++ b/pkgs/oc-session-list/test.sh
@@ -166,4 +166,37 @@
   && fail "--with-state alone emitted row-model fields -- the flag is not gating anything"
 pass "--fold folds descendants into one root row and leaves --with-state untouched"
 
+# --- Stage 6: --ids (workstation-p8ch), end to end through the BUILT binary. ---
+#
+# The bun tests cover queryTreesForIds; this proves the flag is wired in the
+# shipped artifact and REPLACES the recency window rather than filtering it.
+# old_root is older than every other root, so `--limit 1` alone cannot reach it.
+bun -e '
+import { Database } from "bun:sqlite";
+const db = new Database("'$TEST_DB'");
+db.exec(`INSERT INTO session VALUES ("old_root", "p1", NULL, "old-root", "/proj", "Old Root", "1.0", 1, 1, NULL);`);
+'
+JSON_IDS_OUT="$("$BIN" --db "$TEST_DB" --with-state --fold --limit 1 \
+  --ids child_1,archived_1,old_root,never_existed \
+  --overlay-dir "$LIVE_OVERLAY_DIR" --routing-db "$TMP_DIR/no-routing.db" 2>/dev/null)" \
+  || fail "oc-session-list --ids failed on fixture DB"
+
+grep -q '"id": "root_1"' <<<"$JSON_IDS_OUT" \
+  || fail "--ids child_1 did not resolve to its root row root_1"
+grep -q '"id": "old_root"' <<<"$JSON_IDS_OUT" \
+  || fail "--ids was truncated by --limit 1 (old_root is outside the recency window)"
+grep -q '"id": "child_1"' <<<"$JSON_IDS_OUT" \
+  && fail "--ids --fold emitted a CHILD as its own row"
+grep -q '"id": "archived_1"' <<<"$JSON_IDS_OUT" \
+  && fail "--ids resurrected an ARCHIVED session"
+grep -q '"id": "never_existed"' <<<"$JSON_IDS_OUT" \
+  && fail "--ids invented a row for an unknown id"
+[ "$(grep -c '"id": ' <<<"$JSON_IDS_OUT")" = 2 ] \
+  || fail "--ids should yield exactly 2 root rows (root_1, old_root)"
+
+JSON_EMPTY_OUT="$("$BIN" --db "$TEST_DB" --ids "" 2>/dev/null)" || fail "--ids '' failed"
+[ "$(tr -d '[:space:]' <<<"$JSON_EMPTY_OUT")" = "[]" ] \
+  || fail "--ids with an empty list must print [] -- not fall back to the recency window"
+pass "--ids resolves child->root, drops archived/unknown, ignores --limit"
+
 echo "ALL PASS (oc-session-list)"
```

**Step 7: Prove stage 6 fails against the OLD binary, then passes against the new one**

Run: `OC_SESSION_LIST_BIN="$(command -v oc-session-list)" bash pkgs/oc-session-list/test.sh 2>&1 | tail -3`
Expected: `FAIL: --ids was truncated by --limit 1 (old_root is outside the recency window)` (the installed binary ignores the unknown flag).

Run: `bash pkgs/oc-session-list/test.sh 2>&1 | tail -4` (full local run: bun tests + `nix build .#oc-session-list` + stages 3-6)
Expected: `PASS: --ids resolves child->root, drops archived/unknown, ignores --limit` then `ALL PASS (oc-session-list)`.

**Step 8: Re-pin the flake checks**

Measure the expect count with the sandbox-HOME command from "Read this first" (prototype measured **371**; baseline 355, +16). In `flake.nix:2125` set `expected_expects=<measured>`. In the `oc-session-list-bin` check, after the nodata grep (`flake.nix:2290-2293`), add:

```nix
        grep -q '^PASS: --ids resolves child->root' "$TMPDIR/out.txt" || {
          echo "GATE FAILURE: the --ids stage did not run." >&2
          exit 1
        }
```

**Step 9: Run the checks**

```bash
git add assets/opencode/plugins/oc-session-list-base.ts assets/opencode/plugins/oc-session-list.ts \
  assets/opencode/plugins/test/oc-session-list.spec.ts pkgs/oc-session-list/test.sh flake.nix
nix build .#checks.aarch64-linux.plugin-bun .#checks.aarch64-linux.oc-session-list-bin .#checks.aarch64-linux.plugin-tsc -L --no-link
```

Expected: all three build. (`plugin-tsc` typechecks the plugins dir; the new code must be type-clean.)

**Step 10: Privacy gate, then commit**

```bash
git commit -m "[NO-JIRA] oc-session-list: --ids resolves an explicit session set, bypassing the recency window (workstation-p8ch)"
```

---

### Task 2: `oc-tags sessions <tag>`

**Files:**
- Modify: `pkgs/oc-tags/oc_tags.py` (insert before line 193 `rm_session_tag`; parser before line 1289 `# report`; `cmd_sessions` before line 1441 `cmd_rm`; `main` lines 1534 and 1542-1543)
- Test: `pkgs/oc-tags/test_oc_tags.py:86-94` (`SUBCOMMAND_ARGV` roster) and new class before line 1024 (`class TestCfp`)
- Modify: `pkgs/oc-tags/README.md:15` (usage block)
- Modify: `flake.nix:1118-1119` (`Ran 181 tests` pin)

Context: tags live in `tags.db` table `session_tag(session_id PK, tag, created_at)` (`oc_tags.py:80-84`); `set` resolves a subagent to its root before storing (`cmd_set`, `oc_tags.py:1320-1331`), so stored ids are roots. `open_store(path, readonly=True)` returns an empty in-memory schema when the file does not exist (`oc_tags.py:149-157`). `TestGlobalDbFlagsBeforeSubcommand.test_subcommand_roster_is_complete` (`test_oc_tags.py:168-187`) fails if a subcommand is added to the parser but not to `SUBCOMMAND_ARGV` — that is intended and is part of this task.

**Step 1: Write the failing tests**

```diff
--- a/pkgs/oc-tags/test_oc_tags.py
+++ b/pkgs/oc-tags/test_oc_tags.py
@@ -88,6 +88,7 @@
         "ls": [],
         "rm": ["ses_x"],
         "which": ["ses_x"],
+        "sessions": ["mytag"],
         "report": [],
         "top": [],
         "serve": [],
@@ -1021,6 +1022,58 @@
         self.assertEqual(rc, 0)
 
 
+class TestSessionsSubcommand(unittest.TestCase):
+    """`oc-tags sessions <tag>` (workstation-p8ch): newline-separated ids."""
+
+    def setUp(self):
+        self.tmp = tempfile.TemporaryDirectory()
+        self.tags_db = str(Path(self.tmp.name) / "tags.db")
+        with oc_tags.open_store(self.tags_db) as st:
+            oc_tags.set_session_tag(st, "ses_fixture_b", "alpha")
+            oc_tags.set_session_tag(st, "ses_fixture_a", "alpha")
+            oc_tags.set_session_tag(st, "ses_fixture_c", "beta")
+
+    def tearDown(self):
+        self.tmp.cleanup()
+
+    def _run(self, *argv):
+        out, err = io.StringIO(), io.StringIO()
+        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
+            rc = oc_tags.main(["sessions", *argv, "--tags-db", self.tags_db])
+        return rc, out.getvalue(), err.getvalue()
+
+    def test_lists_only_that_tags_ids_sorted_one_per_line(self):
+        rc, out, _ = self._run("alpha")
+        self.assertEqual(rc, 0)
+        self.assertEqual(out, "ses_fixture_a\nses_fixture_b\n")
+
+    def test_unknown_tag_is_empty_output_exit_zero(self):
+        rc, out, err = self._run("gamma")
+        self.assertEqual(rc, 0)
+        self.assertEqual(out, "")
+        self.assertEqual(err, "")
+
+    def test_tag_is_normalised_like_set(self):
+        rc, out, _ = self._run("  BETA ")
+        self.assertEqual(rc, 0)
+        self.assertEqual(out, "ses_fixture_c\n")
+
+    def test_missing_tags_db_is_empty_not_an_error(self):
+        missing = str(Path(self.tmp.name) / "nope" / "tags.db")
+        out = io.StringIO()
+        with contextlib.redirect_stdout(out):
+            rc = oc_tags.main(["sessions", "alpha", "--tags-db", missing])
+        self.assertEqual(rc, 0)
+        self.assertEqual(out.getvalue(), "")
+        self.assertFalse(os.path.exists(missing), "a read must not create tags.db")
+
+    def test_invalid_tag_exits_nonzero(self):
+        rc, out, err = self._run("auto:x")
+        self.assertEqual(rc, 1)
+        self.assertEqual(out, "")
+        self.assertIn("auto:", err)
+
+
 class TestCfp(unittest.TestCase):
     def setUp(self):
         self.tmp = tempfile.TemporaryDirectory()
```

**Step 2: Run to verify they fail**

Run: `python3 pkgs/oc-tags/test_oc_tags.py 2>&1 | tail -4`
Expected: FAILED — errors like `argument command: invalid choice: 'sessions'` (argparse exit 2 surfaces as rc 2 / SystemExit in the roster tests) across the new class and the roster/flag loops.

**Step 3: Implement**

```diff
--- a/pkgs/oc-tags/oc_tags.py
+++ b/pkgs/oc-tags/oc_tags.py
@@ -190,6 +190,16 @@
     return dict(conn.execute("SELECT session_id, tag FROM session_tag"))
 
 
+def tagged_sessions(conn, tag: str) -> list[str]:
+    """Session ids carrying exactly `tag`, sorted (deterministic output)."""
+    return [
+        r[0]
+        for r in conn.execute(
+            "SELECT session_id FROM session_tag WHERE tag=? ORDER BY session_id", (tag,)
+        )
+    ]
+
+
 def rm_session_tag(conn, session_id: str) -> bool:
     return conn.execute("DELETE FROM session_tag WHERE session_id=?", (session_id,)).rowcount > 0
 
@@ -1286,6 +1296,13 @@
     rm_p.add_argument("target", nargs="?", help="session id to remove")
     _add_db_options(rm_p)
 
+    # sessions
+    sessions_p = sub.add_parser(
+        "sessions", help="print the root session ids carrying a tag, one per line"
+    )
+    sessions_p.add_argument("tag", help="tag to list")
+    _add_db_options(sessions_p)
+
     # report
     rep = sub.add_parser("report", help="text table of dollars by tag by day")
     rep.add_argument("--days", type=int, default=14, help="number of days to report")
@@ -1438,6 +1455,31 @@
     return 0
 
 
+def cmd_sessions(args: argparse.Namespace) -> int:
+    """Print the session ids tagged `args.tag`, one per line.
+
+    A MACHINE CONTRACT (the nvim stall-watch picker reads it): bare ids,
+    newline-separated, nothing else on stdout. An unknown tag -- or no tags.db
+    at all -- is an empty answer with exit 0, not an error: "nobody carries
+    this tag" is a legitimate state. Only an invalid tag exits non-zero.
+
+    Tags are stored on ROOT sessions (`set` resolves a subagent to its root),
+    so these are root ids. This reads tags.db only; resolving an id to its
+    tree is oc-session-list's job (`--ids`), not this tool's.
+    """
+    try:
+        tag = normalise_tag(args.tag)
+    except ValueError as e:
+        sys.stderr.write(f"Error: {e}\n")
+        return 1
+    with open_store(args.tags_db, readonly=True) as st:
+        warn_retired_dir_tags(st)
+        ids = tagged_sessions(st, tag)
+    for sid in ids:
+        print(sid)
+    return 0
+
+
 def cmd_rm(args: argparse.Namespace) -> int:
     if args.target:
         with open_store(args.tags_db) as st:
@@ -1531,7 +1573,7 @@
     except SystemExit as e:
         return e.code if isinstance(e.code, int) else 2
 
-    if args.command in ("report", "top", "ls", "which"):
+    if args.command in ("report", "top", "ls", "which", "sessions"):
         try:
             if args.command == "report":
                 return cmd_report(args)
@@ -1541,6 +1583,8 @@
                 return cmd_ls(args)
             elif args.command == "which":
                 return cmd_which(args)
+            elif args.command == "sessions":
+                return cmd_sessions(args)
         except BrokenPipeError:
             try:
                 devnull = os.open(os.devnull, os.O_WRONLY)
```

And add one usage line to `pkgs/oc-tags/README.md` after line 15 (`oc-tags which ses_abc123 ...`):

```
oc-tags sessions billing        # root session ids carrying a tag, one per line
```

**Step 4: Run to verify they pass**

Run: `python3 pkgs/oc-tags/test_oc_tags.py 2>&1 | tail -3`
Expected: `Ran 186 tests` (prototype) and `OK`.

**Step 5: Re-pin and run the check**

In `flake.nix:1118-1119` replace both `181`s with your measured count (prototype: `186`).

```bash
git add pkgs/oc-tags/oc_tags.py pkgs/oc-tags/test_oc_tags.py pkgs/oc-tags/README.md flake.nix
nix build .#checks.aarch64-linux.oc-tags-tests -L --no-link
```

Expected: builds.

**Step 6: Privacy gate, then commit**

```bash
git commit -m "[NO-JIRA] oc-tags: sessions <tag> prints the root session ids carrying a tag (workstation-p8ch)"
```

---

### Task 3: Session-switcher prep — `cli` `ids` option and an exported `dispatch`

**Files:**
- Modify: `assets/nvim/lua/user/session_switcher/cli.lua:73-77`
- Modify: `assets/nvim/lua/user/session_switcher/init.lua` (insert `M.dispatch` before line 144; replace the accept callback body at lines 287-348)
- Test: `assets/nvim/test-session-switcher.sh` (after line 179, inside the cli heredoc)
- Test: `assets/nvim/test-session-switcher-spec.lua` (before the final `print` at line 2837)
- Modify: `flake.nix:1578-1593` (cli and spec counts)

Context: `init.lua:287-348` is the `controller:accept(row, function(desc) ... end)` body that turns a descriptor from `act.decide` into `exec.focus_here` / `exec.switch_pane(desc, client)` / `exec.attach(desc, {scroll_to_message_id})` / `exec.refuse_dir_missing`, plus the one-shot `exec.scroll_to_message` for warm paths. `client` is captured once at open (`init.lua:151`, `exec.tmux_client()` at `exec.lua:73-91`). The extraction is verbatim (comments move with it); only the enclosing function changes. Calls go through the `exec` module table, so the existing spec tests that stub `exec.*` keep intercepting them.

**Step 1: Write the failing tests**

In `assets/nvim/test-session-switcher.sh`, after line 179 (`check(not vim.tbl_contains(cli.build_argv({}), "--fold"), ...)`):

```lua
  -- 10c. `--ids` (workstation-p8ch): comma-joined, and OMITTED when empty --
  --      an empty `--ids ""` would ask the CLI for nothing in a way that reads
  --      like a request for everything.
  local with_ids = cli.build_argv({ fold = true, ids = { "ses_x", "ses_y" } })
  local at = vim.fn.index(with_ids, "--ids")
  check(at >= 0 and with_ids[at + 2] == "ses_x,ses_y", "ids -> --ids ses_x,ses_y")
  check(not vim.tbl_contains(cli.build_argv({ ids = {} }), "--ids"), "empty ids -> no --ids")
```

In `assets/nvim/test-session-switcher-spec.lua`, immediately before the final `print("LUA_TEST_OK " .. N)`:

```diff
--- a/assets/nvim/test-session-switcher-spec.lua
+++ b/assets/nvim/test-session-switcher-spec.lua
@@ -2834,4 +2834,19 @@
     "the in-flight title says id search is on, got " .. tostring(picker.prompt_title))
 end
 
+-- DISPATCH IS PUBLIC (workstation-p8ch). The stall-watch picker jumps through
+-- init_mod.dispatch rather than a copy of the <CR> handler, so pin that it is
+-- exported and routes through the exec module table (stubs still intercept).
+do
+  check(type(init_mod.dispatch) == "function", "session_switcher exports dispatch")
+  local orig_switch = exec.switch_pane
+  local got_client
+  exec.switch_pane = function(_desc, client) got_client = client; return true end
+  init_mod.dispatch({ kind = "switch_pane", pane = "%9" }, { id = "ses_dispatch" }, "client_dispatch", {})
+  exec.switch_pane = orig_switch
+  check(got_client == "client_dispatch", "dispatch hands switch_pane the client it was given")
+  local ok = pcall(init_mod.dispatch, nil, nil, nil, nil)
+  check(ok, "dispatch(nil, ...) is a no-op, not an error")
+end
+
 print("LUA_TEST_OK " .. N)
```

**Step 2: Run to verify they fail**

Run: `bash assets/nvim/test-session-switcher.sh 2>&1 | tail -4`
Expected: `FAIL  session_switcher.cli unit tests (missing or unnumbered LUA_TEST_OK token)` with `ids -> --ids ses_x,ses_y` in the output. (After fixing cli, the spec suite fails on `session_switcher exports dispatch`.)

**Step 3: Implement**

`cli.lua`:

```diff
--- a/assets/nvim/lua/user/session_switcher/cli.lua
+++ b/assets/nvim/lua/user/session_switcher/cli.lua
@@ -74,6 +74,14 @@
     table.insert(argv, "--limit")
     table.insert(argv, tostring(opts.limit))
   end
+  -- `--ids` (workstation-p8ch) asks for exactly these sessions' root trees,
+  -- bypassing the recency window. An EMPTY list is omitted rather than sent
+  -- as `--ids ""`: the caller asked for nothing, and the stall-watch source
+  -- skips the call entirely in that case.
+  if type(opts.ids) == "table" and #opts.ids > 0 then
+    table.insert(argv, "--ids")
+    table.insert(argv, table.concat(opts.ids, ","))
+  end
   return argv
 end
 
```

`session_switcher/init.lua` (verbatim move):

```diff
--- a/assets/nvim/lua/user/session_switcher/init.lua
+++ b/assets/nvim/lua/user/session_switcher/init.lua
@@ -141,6 +141,82 @@
   return sorter
 end
 
+--- Carry out an accept-time action descriptor from flow:accept.
+---
+--- Extracted from M.open's <CR> handler unchanged so the stall-watch picker
+--- (workstation-p8ch) jumps through the SAME code rather than a copy that
+--- could drift. Every exec.* call goes through the module table, so tests that
+--- stub exec.focus_here / switch_pane / attach / scroll_to_message still
+--- intercept it.
+---
+--- @param desc table|nil descriptor from act.decide
+--- @param row table the displayed row that was accepted
+--- @param client string|nil tmux client captured at picker OPEN (Contract 9)
+--- @param opts table|nil picker opts (frontdoor_url etc. for scroll_to_message)
+function M.dispatch(desc, row, client, opts)
+  row = (type(row) == "table") and row or {}
+  if not desc or type(desc) ~= "table" then
+    return
+  end
+  -- JUMPING DELIBERATELY CLEARS NOTHING.
+  --
+  -- This used to fire a watermark write whenever a jump succeeded. It was
+  -- wrong for a reason no amount of care in THIS function could fix: the
+  -- stated purpose of a jump is often to PEEK -- to look at a session and
+  -- decide you are not ready to read it. Clearing on that destroys the
+  -- record of where you had stopped, and the watermark is a MAX() upsert,
+  -- so it cannot be moved back.
+  --
+  -- Clearing now follows evidence of PRESENCE instead, and lives in the
+  -- pigeon daemon where the evidence actually is (pigeon #131): a human
+  -- authoring a turn, or resolving a question, in either the TUI or
+  -- Telegram. Asking a follow-up question is close to proof you read what
+  -- came before it. Arriving somewhere is not.
+  --
+  -- The case neither signal can see -- reading a session and never typing --
+  -- is covered by the explicit <C-r> gesture below, not by guessing here.
+  local anchor = row.anchor_msg_id
+  local has_anchor = anchor ~= nil and anchor ~= vim.NIL and anchor ~= ""
+
+  if desc.kind == "focus_here" then
+    exec.focus_here(desc)
+  elseif desc.kind == "switch_pane" then
+    exec.switch_pane(desc, client)
+  elseif desc.kind == "attach" then
+    -- COLD path: hand the target to the launch itself (workstation-swws).
+    -- There is nothing subscribed to publish to yet -- this call is what
+    -- creates the TUI -- so the request the warm paths send would be
+    -- dropped, which is precisely the bug that was reported.
+    exec.attach(desc, { scroll_to_message_id = has_anchor and anchor or nil })
+  elseif desc.kind == "refuse_dir_missing" then
+    exec.refuse_dir_missing(desc)
+  end
+
+  -- ALLOWLIST, not "anything but refuse_dir_missing". A future descriptor
+  -- kind should have to opt in to firing a scroll rather than inherit it
+  -- by default; refuse_dir_missing deliberately does not navigate.
+  --
+  -- `attach` is NOT in this list any more: it carries its target in the
+  -- launched process's environment instead. Leaving it here as well would
+  -- re-introduce a POST whose only effects are the ones we are removing --
+  -- a request nobody is subscribed to receive, and a front-door sticky
+  -- pin to a serve that may never own the session (workstation-5obe).
+  local navigates = desc.kind == "focus_here" or desc.kind == "switch_pane"
+  if has_anchor and navigates then
+    -- ONE request, not four. These targets are already subscribed, so the
+    -- retry schedule was only ever covering for the cold path -- which no
+    -- longer uses this route at all.
+    --
+    -- The response is ignored deliberately: the door 503s when pigeon is
+    -- down, which means "no scroll" and is not worth a feedback loop.
+    exec.scroll_to_message({
+      sid = row.id,
+      message_id = anchor,
+      force = true,
+    }, opts)
+  end
+end
+
 --- Open the session switcher Telescope picker.
 ---
 --- @param opts table|nil Options passed to telescope and flow controller
@@ -285,66 +361,7 @@
           end
           local row = entry.value or entry
           controller:accept(row, function(desc)
-            if not desc or type(desc) ~= "table" then
-              return
-            end
-            -- JUMPING DELIBERATELY CLEARS NOTHING.
-            --
-            -- This used to fire a watermark write whenever a jump succeeded. It was
-            -- wrong for a reason no amount of care in THIS function could fix: the
-            -- stated purpose of a jump is often to PEEK -- to look at a session and
-            -- decide you are not ready to read it. Clearing on that destroys the
-            -- record of where you had stopped, and the watermark is a MAX() upsert,
-            -- so it cannot be moved back.
-            --
-            -- Clearing now follows evidence of PRESENCE instead, and lives in the
-            -- pigeon daemon where the evidence actually is (pigeon #131): a human
-            -- authoring a turn, or resolving a question, in either the TUI or
-            -- Telegram. Asking a follow-up question is close to proof you read what
-            -- came before it. Arriving somewhere is not.
-            --
-            -- The case neither signal can see -- reading a session and never typing --
-            -- is covered by the explicit <C-r> gesture below, not by guessing here.
-            local anchor = row.anchor_msg_id
-            local has_anchor = anchor ~= nil and anchor ~= vim.NIL and anchor ~= ""
-
-            if desc.kind == "focus_here" then
-              exec.focus_here(desc)
-            elseif desc.kind == "switch_pane" then
-              exec.switch_pane(desc, client)
-            elseif desc.kind == "attach" then
-              -- COLD path: hand the target to the launch itself (workstation-swws).
-              -- There is nothing subscribed to publish to yet -- this call is what
-              -- creates the TUI -- so the request the warm paths send would be
-              -- dropped, which is precisely the bug that was reported.
-              exec.attach(desc, { scroll_to_message_id = has_anchor and anchor or nil })
-            elseif desc.kind == "refuse_dir_missing" then
-              exec.refuse_dir_missing(desc)
-            end
-
-            -- ALLOWLIST, not "anything but refuse_dir_missing". A future descriptor
-            -- kind should have to opt in to firing a scroll rather than inherit it
-            -- by default; refuse_dir_missing deliberately does not navigate.
-            --
-            -- `attach` is NOT in this list any more: it carries its target in the
-            -- launched process's environment instead. Leaving it here as well would
-            -- re-introduce a POST whose only effects are the ones we are removing --
-            -- a request nobody is subscribed to receive, and a front-door sticky
-            -- pin to a serve that may never own the session (workstation-5obe).
-            local navigates = desc.kind == "focus_here" or desc.kind == "switch_pane"
-            if has_anchor and navigates then
-              -- ONE request, not four. These targets are already subscribed, so the
-              -- retry schedule was only ever covering for the cold path -- which no
-              -- longer uses this route at all.
-              --
-              -- The response is ignored deliberately: the door 503s when pigeon is
-              -- down, which means "no scroll" and is not worth a feedback loop.
-              exec.scroll_to_message({
-                sid = row.id,
-                message_id = anchor,
-                force = true,
-              }, opts)
-            end
+            M.dispatch(desc, row, client, opts)
           end)
         end)
 
```

**Step 4: Run to verify they pass**

Run: `bash assets/nvim/test-session-switcher.sh 2>&1 | grep '^PASS  session_switcher'`
Expected: `cli ... (33 assertions ...)`, `spec ... (659 assertions ...)`, discovery 69 and model 114 unchanged. The unchanged-behaviour proof is that all 656 pre-existing spec assertions still pass.

**Step 5: Re-pin and run the check**

In `flake.nix`, change `31` → measured (33) in both places on lines 1578-1579, and `656` → measured (659) on lines 1590-1591.

```bash
git add assets/nvim/lua/user/session_switcher/cli.lua assets/nvim/lua/user/session_switcher/init.lua \
  assets/nvim/test-session-switcher.sh assets/nvim/test-session-switcher-spec.lua flake.nix
nix build .#checks.aarch64-linux.nvim-lua -L --no-link
```

**Step 6: Privacy gate, then commit**

```bash
git commit -m "[NO-JIRA] session switcher: cli --ids option; export dispatch for reuse (workstation-p8ch)"
```

---

### Task 4: Synthetic fixture + `model.lua`

**Files:**
- Create: `assets/nvim/stallwatch-picker-fixture.json` (deliberately NOT named `test-*`: the reachability guard would demand it be executed)
- Create: `assets/nvim/lua/user/stallwatch_picker/model.lua`
- Test: `assets/nvim/test-stallwatch-picker-model.lua`
- Modify: `assets/nvim/test-session-switcher.sh` (after line 240, the `session_switcher.spec` PASS line)
- Modify: `flake.nix:1573-1593`

Context: mirror `session_switcher/model.lua`: pure, no telescope/`vim.fn`/`vim.api`, loaded by tests with `loadfile(...)()` under `nvim --clean -l`, tests count assertions through `check()` and end with `print("LUA_TEST_OK " .. N)`. The runner's `parse_lua_ok` (`test-session-switcher.sh:215-224`) turns that into a `PASS  <name> (<n> assertions via nvim -l)` line.

**Step 1: Create the fixture** — the v1 contract shape (`{version, generated_at, latest_digest, programs:[{tag, armed, enabled, last_tick_activity, items:[{program, fingerprint, kind, text, status, what_changed, stale, first_seen, updated_at, last_sent, shadow_last_sent, sessions:[{id, directory, title, directory_exists}]}]}]}`), synthetic values only. It encodes: a session named by two items (`ses_fixture_a1`: decision + blocker), a session the CLI will not return because it is archived (`ses_fixture_arch`), one deleted with `directory_exists: false` and an empty title (`ses_fixture_gone`), a session named by a different program than its tag (`ses_fixture_a2` under `beta`), a `changed`+`stale` item, multi-line text, and a program that is neither armed nor enabled with a null `last_tick_activity`.

`assets/nvim/stallwatch-picker-fixture.json`:

```json
{
  "version": 1,
  "generated_at": "2026-01-01T12:00:00.000000+00:00",
  "latest_digest": "/nonexistent/stallwatch-fixture/digest.txt",
  "programs": [
    {
      "tag": "alpha",
      "armed": true,
      "enabled": true,
      "last_tick_activity": "2026-01-01T11:48:00.000000+00:00",
      "items": [
        {
          "program": "alpha",
          "fingerprint": "fp-alpha-decision",
          "kind": "decision",
          "text": "Pick option one or option two for the widget.",
          "status": "new",
          "what_changed": null,
          "stale": false,
          "first_seen": "2026-01-01T10:00:00.000000+00:00",
          "updated_at": "2026-01-01T11:00:00.000000+00:00",
          "last_sent": null,
          "shadow_last_sent": "2026-01-01T11:00:00.000000+00:00",
          "sessions": [
            { "id": "ses_fixture_a1", "directory": "/fixture/alpha/one", "title": "Fixture A1 (item title)", "directory_exists": true },
            { "id": "ses_fixture_a2", "directory": "/fixture/alpha/two", "title": "Fixture A2 (item title)", "directory_exists": true }
          ]
        },
        {
          "program": "alpha",
          "fingerprint": "fp-alpha-blocker",
          "kind": "blocker",
          "text": "Waiting on a credential for the gadget.",
          "status": "changed",
          "what_changed": "text reworded",
          "stale": true,
          "first_seen": "2026-01-01T09:00:00.000000+00:00",
          "updated_at": "2026-01-01T11:30:00.000000+00:00",
          "last_sent": null,
          "shadow_last_sent": null,
          "sessions": [
            { "id": "ses_fixture_a1", "directory": "/fixture/alpha/one", "title": "Fixture A1 (item title)", "directory_exists": true }
          ]
        },
        {
          "program": "alpha",
          "fingerprint": "fp-alpha-follow",
          "kind": "follow_up",
          "text": "Archived session still has an open thread.",
          "status": "new",
          "what_changed": null,
          "stale": false,
          "first_seen": "2026-01-01T08:00:00.000000+00:00",
          "updated_at": "2026-01-01T08:00:00.000000+00:00",
          "last_sent": null,
          "shadow_last_sent": null,
          "sessions": [
            { "id": "ses_fixture_arch", "directory": "/fixture/alpha/arch", "title": "Fixture archived", "directory_exists": true }
          ]
        },
        {
          "program": "alpha",
          "fingerprint": "fp-alpha-info",
          "kind": "info",
          "text": "A deleted session was mentioned.\nSecond line of the note.",
          "status": "new",
          "what_changed": null,
          "stale": false,
          "first_seen": "2026-01-01T07:00:00.000000+00:00",
          "updated_at": "2026-01-01T07:00:00.000000+00:00",
          "last_sent": null,
          "shadow_last_sent": null,
          "sessions": [
            { "id": "ses_fixture_gone", "directory": "/fixture/alpha/gone", "title": "", "directory_exists": false }
          ]
        }
      ]
    },
    {
      "tag": "beta",
      "armed": false,
      "enabled": false,
      "last_tick_activity": null,
      "items": [
        {
          "program": "beta",
          "fingerprint": "fp-beta-stalled",
          "kind": "stalled",
          "text": "Beta session idle for a while.",
          "status": "new",
          "what_changed": null,
          "stale": false,
          "first_seen": "2026-01-01T06:00:00.000000+00:00",
          "updated_at": "2026-01-01T06:00:00.000000+00:00",
          "last_sent": null,
          "shadow_last_sent": null,
          "sessions": [
            { "id": "ses_fixture_b1", "directory": "/fixture/beta/one", "title": "Fixture B1 (item title)", "directory_exists": true },
            { "id": "ses_fixture_a2", "directory": "/fixture/alpha/two", "title": "Fixture A2 (item title)", "directory_exists": true }
          ]
        }
      ]
    }
  ]
}
```

**Step 2: Write the failing test** — `assets/nvim/test-stallwatch-picker-model.lua` (includes the field-presence test driven by `model.READS`):

```lua
-- Unit tests for stallwatch_picker/model.lua (pure).
-- Driven via `nvim --clean -l assets/nvim/test-stallwatch-picker-model.lua`.
--
-- SYNTHETIC DATA ONLY. This repo is public and the stall-watcher is private:
-- programs are `alpha`/`beta`, text is invented, ids are ses_fixture_*.

local N = 0
local function check(cond, msg) N = N + 1; assert(cond, msg) end

local model = loadfile("assets/nvim/lua/user/stallwatch_picker/model.lua")()

local function read_fixture()
  local f = assert(io.open("assets/nvim/stallwatch-picker-fixture.json", "r"))
  local s = f:read("*a")
  f:close()
  -- Same decode options source.lua uses: JSON null -> Lua nil.
  return vim.json.decode(s, { luanil = { object = true } })
end

local doc = read_fixture()

-- CLI rows, in oc-session-list order. ses_fixture_arch (archived) and
-- ses_fixture_gone (deleted) are ABSENT, exactly as the CLI drops them.
-- ses_fixture_a2 is automated (lgtm origin): it must still appear.
local CLI_ROWS = {
  { id = "ses_fixture_t1", title = "Tagged one", directory = "/fixture/alpha/t1", effective_state = "idle", lastActivity = 1000, dir_missing = false, automated = false },
  { id = "ses_fixture_a2", title = "A2 from CLI", directory = "/fixture/alpha/two", effective_state = "working", lastActivity = 2000, dir_missing = false, automated = true, anchor_msg_id = "msg_fixture1" },
  { id = "ses_fixture_a1", title = "A1 from CLI", directory = "/fixture/alpha/one", effective_state = "blocked", lastActivity = 3000, dir_missing = true, automated = false },
  { id = "ses_fixture_b1", title = "B1 from CLI", directory = "/fixture/beta/one", effective_state = "idle", lastActivity = 4000, dir_missing = false, automated = false },
  { id = "ses_fixture_t2", title = "Tagged two", directory = "/fixture/alpha/t2", effective_state = "idle", lastActivity = 5000, dir_missing = false, automated = false },
}
local TAGGED = {
  alpha = { "ses_fixture_t1", "ses_fixture_a1", "ses_fixture_t2" },
  beta = { "ses_fixture_b1" },
}

local function ids(rows)
  local out = {}
  for _, r in ipairs(rows) do table.insert(out, r.id) end
  return table.concat(out, ",")
end

-- 1. FIELD PRESENCE: every field the picker reads exists in the fixture.
--    Contract drift must be a deliberate fixture edit, not a silent blank.
do
  local function present(node, segs, i)
    if i > #segs then return node ~= nil end
    local seg = segs[i]
    local each = seg:sub(-2) == "[]"
    local key = each and seg:sub(1, -3) or seg
    local child = type(node) == "table" and node[key] or nil
    if each then
      if type(child) ~= "table" then return false end
      for _, el in ipairs(child) do
        if present(el, segs, i + 1) then return true end
      end
      return false
    end
    return present(child, segs, i + 1)
  end
  check(#model.READS > 0, "model.READS is non-empty")
  for _, path in ipairs(model.READS) do
    local segs = vim.split(path, ".", { plain = true })
    check(present(doc, segs, 1), "fixture carries a non-null value for read field " .. path)
  end
end

-- 2. KIND ORDER mirrors the contract, and unknown kinds rank last.
do
  check(table.concat(model.KIND_ORDER, ">") == "decision>blocker>error>stalled>follow_up>declared_wait>info",
    "KIND_ORDER is the contract order")
  check(model.kind_rank("decision") < model.kind_rank("info"), "decision outranks info")
  check(model.kind_rank("brand_new_kind") > model.kind_rank("info"), "unknown kind ranks after info")
  check(model.kind_rank(nil) > model.kind_rank("info"), "nil kind ranks after info")
end

-- 3. ISO timestamps -> epoch ms, independent of the local zone.
do
  check(model.iso_ms("2026-01-01T00:00:00+00:00") == 1767225600000, "UTC midnight")
  check(model.iso_ms("2026-01-01T00:00:00Z") == 1767225600000, "Z suffix")
  check(model.iso_ms("2026-01-01T02:00:00+02:00") == 1767225600000, "positive offset")
  check(model.iso_ms("2025-12-31T19:00:00-05:00") == 1767225600000, "negative offset")
  check(model.iso_ms("2026-01-01T00:00:00.250000+00:00") == 1767225600250, "fractional seconds")
  check(model.iso_ms("2024-03-01T00:00:00+00:00") == 1709251200000, "leap-year March 1st")
  check(model.iso_ms(nil) == nil, "nil -> nil")
  check(model.iso_ms("yesterday") == nil, "garbage -> nil")
end

-- 4. PROGRAM ROWS keep source order and carry counts.
local prows = model.program_rows(doc)
do
  check(#prows == 2, "two programs")
  check(prows[1].tag == "alpha" and prows[2].tag == "beta", "source order kept (alpha, beta)")
  check(prows[1].counts.total == 4, "alpha has 4 open items")
  local kinds = {}
  for _, kn in ipairs(prows[1].counts.by_kind) do table.insert(kinds, kn.kind .. "=" .. kn.n) end
  check(table.concat(kinds, ",") == "decision=1,blocker=1,follow_up=1,info=1", "alpha counts in kind order, got " .. table.concat(kinds, ","))
  check(prows[1].last_tick_ms == model.iso_ms("2026-01-01T11:48:00.000000+00:00"), "last tick parsed")
  check(prows[2].last_tick_ms == nil, "null last tick -> nil, not a crash")
  check(prows[2].armed == false and prows[2].enabled == false, "armed/enabled carried")
  check(#model.program_rows({ version = 1, programs = {} }) == 0, "zero programs -> zero rows")
  check(#model.program_rows(nil) == 0, "nil doc -> zero rows")
  local odd = model.program_rows({ programs = { { tag = "alpha" } } })
  check(#odd == 1 and odd[1].counts.total == 0 and #odd[1].items == 0, "missing items tolerated")
end

-- 5. FLAGGED ROWS: item-driven, deduped, most urgent badge, left-join.
local by_id = model.index_rows(CLI_ROWS)
local flagged = model.flagged_rows(prows[1], by_id)
do
  check(ids(flagged) == "ses_fixture_a1,ses_fixture_a2,ses_fixture_arch,ses_fixture_gone",
    "flagged order = first appearance in contract-ordered items, got " .. ids(flagged))
  local a1 = flagged[1]
  check(a1.badge_kind == "decision", "a1 named by decision+blocker -> decision badge")
  check(#a1.items == 2, "a1 carries both items")
  check(a1.joined == true and a1.title == "A1 from CLI", "a1 joined: CLI title wins")
  check(a1.effective_state == "blocked", "a1 joined: CLI state")
  check(a1.dir_missing == true, "a1 joined: CLI dir_missing wins over directory_exists")
  local a2 = flagged[2]
  check(a2.automated == true, "automated (lgtm) session still appears in flagged view")
  check(a2.anchor_msg_id == "msg_fixture1", "joined row keeps every CLI field (anchor for the jump)")
  local arch = flagged[3]
  check(arch.joined == false, "archived (CLI-dropped) session still rendered from item data")
  check(arch.title == "Fixture archived", "unjoined: item title")
  check(arch.dir_missing == false, "unjoined: directory_exists=true -> not missing")
  local gone = flagged[4]
  check(gone.title == "ses_fixture_gone", "unjoined + empty item title -> id")
  check(gone.dir_missing == true, "unjoined: directory_exists=false -> dir_missing")
  check(gone.effective_state == nil and gone.lastActivity == nil, "unjoined: no state/age invented")
  check(CLI_ROWS[3].items == nil and CLI_ROWS[3].badge_kind == nil, "join copies; CLI rows not mutated")

  -- Badge precedence regardless of item order.
  local rev = model.flagged_rows({ items = {
    { kind = "info", sessions = { { id = "ses_fixture_x" } } },
    { kind = "error", sessions = { { id = "ses_fixture_x" } } },
    { kind = "stalled", sessions = { { id = "ses_fixture_x" } } },
  } }, {})
  check(#rev == 1 and rev[1].badge_kind == "error", "error beats stalled beats info")

  -- A session tagged to ANOTHER program still appears if this program's item names it.
  local beta_flagged = model.flagged_rows(prows[2], by_id)
  check(ids(beta_flagged) == "ses_fixture_b1,ses_fixture_a2", "beta flags a2 (tagged alpha)")
  check(#model.flagged_rows(prows[2], nil) == 2, "no CLI rows at all -> flagged view still built")

  -- Missing optional fields tolerated.
  local sparse = model.flagged_rows({ items = { { sessions = { { id = "ses_fixture_s" }, {}, { id = "" } } } } }, {})
  check(#sparse == 1 and sparse[1].title == "ses_fixture_s", "missing kind/title/directory tolerated; empty ids skipped")
  check(sparse[1].dir_missing == false, "missing directory_exists is not treated as gone")
end

-- 6. ALL VIEW: stable partition of the CLI result.
do
  local all = model.all_rows(flagged, CLI_ROWS, TAGGED.alpha)
  check(ids(all) == "ses_fixture_a2,ses_fixture_a1,ses_fixture_arch,ses_fixture_gone,ses_fixture_t1,ses_fixture_t2",
    "flagged (CLI order, then unjoined) | rest (CLI order), got " .. ids(all))
  check(all[5].badge_kind == nil and #all[5].items == 0, "unflagged rows carry no badge")
  check(all[1] == flagged[2], "flagged rows are the same objects in both views")
  local none = model.all_rows(flagged, {}, TAGGED.alpha)
  check(ids(none) == ids(flagged), "CLI failed -> all view degrades to the flagged rows")
end

-- 7. UNION of ids for the one oc-session-list call.
do
  local u = model.union_ids(doc, TAGGED)
  check(table.concat(u, ",") ==
    "ses_fixture_a1,ses_fixture_a2,ses_fixture_arch,ses_fixture_gone,ses_fixture_b1,ses_fixture_t1,ses_fixture_t2",
    "union: item ids then tagged ids, deduped, got " .. table.concat(u, ","))
  check(#model.union_ids(doc, nil) == 5, "no tagged map -> item ids only")
end

print("LUA_TEST_OK " .. N)
```

**Step 3: Wire it into the runner** — after line 240 of `assets/nvim/test-session-switcher.sh`:

```bash
# stall-watch picker (workstation-p8ch). Same harness, same gate: it reuses the
# switcher's cli/spec/flow/dispatch, so a switcher change that breaks it fails
# this same check. One literal line per unit, NOT a loop over "$unit": the
# reachability guard (users/dev/test-unwired-tests.sh) only credits a runner
# followed by a literal path, so a loop would report every unit as unwired.
swm_out="$(nvim --clean -l assets/nvim/test-stallwatch-picker-model.lua 2>&1 || true)"
swm_count="$(parse_lua_ok "$swm_out" "stallwatch_picker.model unit tests")" || exit 1
printf 'PASS  stallwatch_picker.model unit tests (%s assertions via nvim -l)\n' "$swm_count"
```

(The loop warning is measured: `refs_in_text` in `users/dev/test-unwired-tests.sh:205-209` only matches `nvim --clean -l <literal path>`.)

**Step 4: Run to verify it fails**

Run: `nvim --clean -l assets/nvim/test-stallwatch-picker-model.lua`
Expected: `E5113: Error while calling lua chunk: ...: attempt to call a nil value` (model.lua does not exist yet).

**Step 5: Implement** — `assets/nvim/lua/user/stallwatch_picker/model.lua`:

```lua
-- stallwatch_picker/model.lua
--
-- Pure row model for the stall-watch picker (workstation-p8ch).
--
-- Input is ONE snapshot fetched at open by source.lua:
--   { doc = <items.sh --json v1>, tagged = { [tag] = { sid, ... } },
--     rows = <oc-session-list --with-state --fold --ids rows>, warnings = {...} }
-- Everything here is a pure function of that snapshot, so moving between
-- screens never waits on I/O.
--
-- PURE: MUST NOT require telescope.* or plenary.*. No vim.system, no vim.fn,
-- no vim.api, no vim.notify. CI loads this under `nvim --clean -l`.

local M = {}

--- Urgency order of item kinds, mirrored from the read command's contract
--- ("decision > blocker > error > stalled > follow_up > declared_wait > info").
--- Used for the badge of a session named by several items, and for the order
--- of kinds in a program row's count breakdown.
M.KIND_ORDER = { "decision", "blocker", "error", "stalled", "follow_up", "declared_wait", "info" }

M.KIND_RANK = {}
for i, k in ipairs(M.KIND_ORDER) do
  M.KIND_RANK[k] = i
end

--- Every field of the v1 contract this picker reads, as a dotted path where
--- `[]` means "each element". The field-presence test walks the fixture with
--- this list, so a field the picker starts reading must be added here AND to
--- the fixture -- contract drift becomes a deliberate fixture edit.
M.READS = {
  "version",
  "latest_digest",
  "programs[].tag",
  "programs[].armed",
  "programs[].enabled",
  "programs[].last_tick_activity",
  "programs[].items[].kind",
  "programs[].items[].text",
  "programs[].items[].status",
  "programs[].items[].what_changed",
  "programs[].items[].stale",
  "programs[].items[].sessions[].id",
  "programs[].items[].sessions[].title",
  "programs[].items[].sessions[].directory",
  "programs[].items[].sessions[].directory_exists",
}

--- Rank of a kind; unknown kinds sort after every known one (additive contract
--- fields must not crash the picker, and an unknown kind is not more urgent
--- than a known one).
function M.kind_rank(kind)
  return M.KIND_RANK[kind] or (#M.KIND_ORDER + 1)
end

local function nonempty(s)
  if type(s) == "string" and s ~= "" then
    return s
  end
  return nil
end

local function list(t)
  if type(t) == "table" and vim.islist(t) then
    return t
  end
  return {}
end

--- Parse the contract's ISO-8601 timestamps ("2026-01-01T12:00:00.123456+00:00",
--- also "Z" or no offset) to epoch MILLISECONDS. Pure arithmetic: os.time()
--- would interpret the fields in the LOCAL zone. Returns nil on anything else.
function M.iso_ms(s)
  if type(s) ~= "string" then
    return nil
  end
  local y, mo, d, h, mi, sec, frac, tz =
    s:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)[T ](%d%d):(%d%d):(%d%d)(%.?%d*)(.*)$")
  if not y then
    return nil
  end
  y, mo, d = tonumber(y), tonumber(mo), tonumber(d)
  -- days_from_civil (H. Hinnant), valid for the proleptic Gregorian calendar.
  local yy = (mo <= 2) and (y - 1) or y
  local era = math.floor(yy / 400)
  local yoe = yy - era * 400
  local mp = (mo + 9) % 12
  local doy = math.floor((153 * mp + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  local days = era * 146097 + doe - 719468
  local secs = days * 86400 + tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(sec)
  if tz ~= "" and tz ~= "Z" then
    local sign, oh, om = tz:match("^([+-])(%d%d):?(%d%d)$")
    if not sign then
      return nil
    end
    local off = tonumber(oh) * 3600 + tonumber(om) * 60
    secs = (sign == "+") and (secs - off) or (secs + off)
  end
  local ms = 0
  if frac ~= "" and frac ~= "." then
    ms = math.floor(tonumber("0" .. frac) * 1000)
  end
  return secs * 1000 + ms
end

--- Open-item counts for one program: total, and per kind in KIND_ORDER
--- (unknown kinds after, alphabetically). Zero-count kinds are omitted.
--- @return { total: integer, by_kind: { kind: string, n: integer }[] }
function M.counts(program)
  local items = list(type(program) == "table" and program.items)
  local n = {}
  for _, it in ipairs(items) do
    local k = (type(it) == "table" and nonempty(it.kind)) or "unknown"
    n[k] = (n[k] or 0) + 1
  end
  local by_kind = {}
  for _, k in ipairs(M.KIND_ORDER) do
    if n[k] then
      table.insert(by_kind, { kind = k, n = n[k] })
      n[k] = nil
    end
  end
  local rest = vim.tbl_keys(n)
  table.sort(rest)
  for _, k in ipairs(rest) do
    table.insert(by_kind, { kind = k, n = n[k] })
  end
  return { total = #items, by_kind = by_kind }
end

--- Screen 1 rows: one per program, in the READ COMMAND'S ORDER (stable
--- between opens, so cursor restore by position is meaningful). Urgency is
--- carried in the row text, never by re-sorting.
function M.program_rows(doc)
  local out = {}
  for _, p in ipairs(list(type(doc) == "table" and doc.programs)) do
    if type(p) == "table" then
      table.insert(out, {
        tag = nonempty(p.tag) or "(unnamed)",
        armed = p.armed,
        enabled = p.enabled,
        last_tick_ms = M.iso_ms(p.last_tick_activity),
        items = list(p.items),
        counts = M.counts(p),
      })
    end
  end
  return out
end

--- id -> CLI row, for the left-join.
function M.index_rows(rows)
  local by_id = {}
  for _, r in ipairs(list(rows)) do
    if type(r) == "table" and nonempty(r.id) then
      by_id[r.id] = r
    end
  end
  return by_id
end

--- Screen 2 flagged view: ITEM-DRIVEN rows.
---
--- Built from items[].sessions and LEFT-JOINED to CLI rows by id. A session
--- the CLI did not return (archived, deleted, filtered) still gets a row from
--- item data alone -- that is the whole reason the rows are item-driven.
---
--- Order: first appearance while walking items in contract order, which is
--- already most-urgent-first. A session named by several items appears ONCE,
--- carrying every item that names it and the most urgent kind as its badge.
---
--- Joined rows are a shallow copy of the CLI row (so act.decide and the jump
--- dispatch see every field they normally do: id, dir_missing, directory,
--- anchor_msg_id, ...). Unjoined rows fall back to:
---   title       = item session title, else the id
---   directory   = item session directory
---   dir_missing = (directory_exists == false)
--- and carry no effective_state / lastActivity (rendered blank).
---
--- @param prow table a row from M.program_rows
--- @param by_id table from M.index_rows
--- @return table[]
function M.flagged_rows(prow, by_id)
  by_id = type(by_id) == "table" and by_id or {}
  local out, seen = {}, {}
  for _, item in ipairs(list(type(prow) == "table" and prow.items)) do
    if type(item) == "table" then
      for _, s in ipairs(list(item.sessions)) do
        local sid = type(s) == "table" and nonempty(s.id)
        if sid then
          local row = seen[sid]
          if not row then
            local cli = by_id[sid]
            if cli then
              row = vim.tbl_extend("force", {}, cli)
              row.joined = true
            else
              row = {
                id = sid,
                title = nonempty(s.title) or sid,
                directory = s.directory,
                dir_missing = s.directory_exists == false,
                joined = false,
              }
            end
            row.badge_kind = item.kind
            row.items = {}
            seen[sid] = row
            table.insert(out, row)
          elseif M.kind_rank(item.kind) < M.kind_rank(row.badge_kind) then
            row.badge_kind = item.kind
          end
          table.insert(row.items, item)
        end
      end
    end
  end
  return out
end

--- Screen 2 all view: a STABLE PARTITION of the one CLI result.
---
--- flagged rows first, then the program's other tagged roots, each group in
--- oc-session-list order -- the CLI still owns ordering. Flagged rows the CLI
--- did not return are appended to the flagged group in item order, so
--- toggling views never makes a flagged session vanish.
---
--- @param flagged table[] from M.flagged_rows
--- @param cli_rows table[] snapshot rows, CLI order
--- @param tagged_ids string[]|nil root ids carrying this program's tag
function M.all_rows(flagged, cli_rows, tagged_ids)
  local flagged_by_id = {}
  for _, f in ipairs(list(flagged)) do
    flagged_by_id[f.id] = f
  end
  local tagged = {}
  for _, sid in ipairs(list(tagged_ids)) do
    tagged[sid] = true
  end
  local head, tail, placed = {}, {}, {}
  for _, r in ipairs(list(cli_rows)) do
    local sid = type(r) == "table" and r.id
    if sid and flagged_by_id[sid] then
      table.insert(head, flagged_by_id[sid])
      placed[sid] = true
    elseif sid and tagged[sid] then
      local copy = vim.tbl_extend("force", {}, r)
      copy.joined = true
      copy.items = {}
      table.insert(tail, copy)
    end
  end
  for _, f in ipairs(list(flagged)) do
    if not placed[f.id] then
      table.insert(head, f)
    end
  end
  vim.list_extend(head, tail)
  return head
end

--- Union of every session id the snapshot needs from oc-session-list: item
--- sessions of every program plus every program's tagged ids. Deduped,
--- first-seen order (deterministic argv).
function M.union_ids(doc, tagged)
  local out, seen = {}, {}
  local function add(sid)
    if nonempty(sid) and not seen[sid] then
      seen[sid] = true
      table.insert(out, sid)
    end
  end
  for _, p in ipairs(list(type(doc) == "table" and doc.programs)) do
    for _, it in ipairs(list(type(p) == "table" and p.items)) do
      for _, s in ipairs(list(type(it) == "table" and it.sessions)) do
        add(type(s) == "table" and s.id)
      end
    end
  end
  for _, p in ipairs(list(type(doc) == "table" and doc.programs)) do
    local tag = type(p) == "table" and p.tag
    for _, sid in ipairs(list(type(tagged) == "table" and tagged[tag])) do
      add(sid)
    end
  end
  return out
end

return M
```

**Step 6: Run to verify it passes**

Run: `bash assets/nvim/test-session-switcher.sh 2>&1 | grep -E 'stallwatch|all session'`
Expected: `PASS  stallwatch_picker.model unit tests (64 assertions via nvim -l)` and the final pass line.

**Step 7: Mutation spot-check (1 minute, do not commit it).** Temporarily change `M.kind_rank(item.kind) < M.kind_rank(row.badge_kind)` to `>` in `model.lua` and rerun: the badge-precedence checks must fail. Temporarily delete `"what_changed": "text reworded",` from the fixture: the field-presence check for `programs[].items[].what_changed` must fail. Revert both by hand.

**Step 8: Re-pin and run the check**

In `flake.nix`'s `nvim-lua` check: PASS-line count `6` → `7` (both occurrences on lines 1573-1575), and add after the spec grep (line 1593):

```nix
        grep -q '^PASS  stallwatch_picker\.model unit tests (64 assertions via nvim -l)' "$TMPDIR/out.txt" || {
          echo "GATE FAILURE: stallwatch_picker.model did not report expected 64 assertions." >&2
          exit 1
        }
```

(use your measured count), then:

```bash
git add assets/nvim/stallwatch-picker-fixture.json assets/nvim/lua/user/stallwatch_picker/model.lua \
  assets/nvim/test-stallwatch-picker-model.lua assets/nvim/test-session-switcher.sh flake.nix
nix build .#checks.aarch64-linux.nvim-lua .#checks.aarch64-linux.test-reachability -L --no-link
```

**Step 9: Privacy gate, then commit**

```bash
git commit -m "[NO-JIRA] stall-watch picker: pure row model and synthetic v1 fixture (workstation-p8ch)"
```

---

### Task 5: `spec.lua` (presentation)

**Files:**
- Create: `assets/nvim/lua/user/stallwatch_picker/spec.lua`
- Test: `assets/nvim/test-stallwatch-picker-spec.lua`
- Modify: `assets/nvim/test-session-switcher.sh` (after the model block from Task 4), `flake.nix` (nvim-lua)

Context: reuse, don't copy, the switcher's presentation: `ss_spec.glyph_of` / `ss_spec.GLYPHS` (`session_switcher/spec.lua:25-53`), `ss_spec.idle_age` (`:69-99`), `ss_spec.DIR_MISSING_MARK` (`:36`), and `ss_spec.picker_opts()` (`:424-431`, `sorting_strategy = "descending"` + order-preserving `tiebreak`). The test preloads the REAL switcher modules into `package.preload` (as `test-session-switcher-spec.lua:26-33` does) so a switcher change breaks these tests instead of drifting past them.

**Step 1: Write the failing test** — `assets/nvim/test-stallwatch-picker-spec.lua` (section 5 is the design's required pin of `default_selection_index` vs `sorting_strategy = "descending"`):

```lua
-- Unit tests for stallwatch_picker/spec.lua (pure presentation).
-- Driven via `nvim --clean -l assets/nvim/test-stallwatch-picker-spec.lua`.
--
-- SYNTHETIC DATA ONLY (public repo): programs alpha/beta, invented text.

local N = 0
local function check(cond, msg) N = N + 1; assert(cond, msg) end

-- Preload the REAL switcher modules spec.lua reuses, so a change to the
-- switcher's glyphs/ages breaks these tests instead of drifting past them.
local ss_model = loadfile("assets/nvim/lua/user/session_switcher/model.lua")()
package.preload["user.session_switcher.model"] = function() return ss_model end
local ss_spec = loadfile("assets/nvim/lua/user/session_switcher/spec.lua")()
package.preload["user.session_switcher.spec"] = function() return ss_spec end

local model = loadfile("assets/nvim/lua/user/stallwatch_picker/model.lua")()
local spec = loadfile("assets/nvim/lua/user/stallwatch_picker/spec.lua")()

local f = assert(io.open("assets/nvim/stallwatch-picker-fixture.json", "r"))
local doc = vim.json.decode(f:read("*a"), { luanil = { object = true } })
f:close()

local NOW = model.iso_ms("2026-01-01T12:00:00+00:00")
local prows = model.program_rows(doc)

-- 1. PROGRAM ROW TEXT.
do
  local a = spec.program_display(prows[1], NOW)
  check(a == "alpha · 4 open (1 decision, 1 blocker, 1 follow_up, 1 info) · checked 12m ago",
    "alpha row text, got: " .. a)
  check(not a:find(spec.NOT_ARMED_MARK, 1, true) and not a:find(spec.NOT_ENABLED_MARK, 1, true),
    "armed+enabled program carries no marker")
  local b = spec.program_display(prows[2], NOW)
  check(b:find("^beta · 1 open %(1 stalled%)") ~= nil, "beta counts, got: " .. b)
  check(not b:find("checked", 1, true), "null last tick -> no 'checked' clause")
  check(b:find(spec.NOT_ARMED_MARK, 1, true) ~= nil, "not armed -> log-only marker")
  check(b:find(spec.NOT_ENABLED_MARK, 1, true) ~= nil, "not enabled -> disabled marker")
  check(spec.program_display({ tag = "alpha", armed = true, enabled = true, counts = { total = 0, by_kind = {} } }, NOW)
    == "alpha · 0 open", "zero items -> '0 open', no parentheses")
  check(spec.program_display({ tag = "alpha", counts = { total = 0, by_kind = {} } }, NOW) == "alpha · 0 open",
    "missing armed/enabled -> blank, not a marker")
  check(spec.program_ordinal(prows[1]) == "alpha", "program ordinal is the tag")
end

-- 2. SESSION ROW TEXT: badge, reused glyph, title, dir, age, dir-gone mark.
local by_id = model.index_rows({
  { id = "ses_fixture_a1", title = "A1 from CLI", directory = "/fixture/alpha/one", effective_state = "blocked", lastActivity = NOW - 180000, dir_missing = false },
})
local flagged = model.flagged_rows(prows[1], by_id)
do
  local a1 = spec.session_display(flagged[1], NOW)
  check(a1 == "[decision] · " .. ss_spec.GLYPHS.blocked .. " A1 from CLI │ one │ 3m", "joined flagged row, got: " .. a1)
  local gone = spec.session_display(flagged[4], NOW)
  check(gone == "[info] ·   ses_fixture_gone │ gone │ " .. ss_spec.DIR_MISSING_MARK,
    "unjoined row: blank glyph and age, dir-gone mark, got: " .. gone)
  check(not gone:find(ss_spec.GLYPHS.unknown, 1, true), "unjoined row does NOT claim the unknown glyph")
  local rest = spec.session_display({ id = "ses_fixture_t1", title = "Tagged one", directory = "/x/t1", effective_state = "idle", lastActivity = NOW, joined = true, items = {} }, NOW)
  check(rest == ss_spec.GLYPHS.idle .. " Tagged one │ t1 │ now", "unflagged all-view row has no badge, got: " .. rest)
  check(spec.session_ordinal(flagged[1]) == "A1 from CLI one", "ordinal = title + dir basename only")
  check(not spec.session_ordinal(flagged[1]):find("decision", 1, true), "badge kept out of the ordinal")
  check(spec.session_display(nil, NOW):find("(untitled)", 1, true) ~= nil, "nil row does not crash")
end

-- 3. PREVIEWERS.
do
  local lines = spec.program_preview_lines(prows[1])
  local text = table.concat(lines, "\n")
  check(lines[1] == "[decision] Pick option one or option two for the widget. (new)", "first item line, got: " .. lines[1])
  check(text:find("    - Fixture A1 (item title)", 1, true) ~= nil, "names the sessions' titles")
  check(text:find("[blocker] Waiting on a credential for the gadget. (changed: text reworded) (stale)", 1, true) ~= nil,
    "changed + what_changed + stale marks")
  check(text:find("[info] A deleted session was mentioned.\n       Second line of the note. (new)", 1, true) ~= nil,
    "multi-line text split and indented; marks on the last line")
  check(text:find("    - ses_fixture_gone", 1, true) ~= nil, "empty session title -> id in preview")
  for _, l in ipairs(lines) do
    check(not l:find("\n", 1, true), "no preview line contains a newline")
  end
  local p1, p2 = text:find("[decision]", 1, true), text:find("[info]", 1, true)
  check(p1 < p2, "items in contract order")
  check(spec.program_preview_lines({ items = {} })[1] == "(no open items)", "empty program preview")

  local s = spec.session_preview_lines(flagged[1])
  check(#s == 3 and s[1]:find("^%[decision%]") and s[3]:find("^%[blocker%]"), "session preview: every item naming it")
  check(not table.concat(s, "\n"):find("    - ", 1, true), "session preview does not list sessions")
  check(spec.session_preview_lines({ items = {} })[1]:find("no open items", 1, true) ~= nil, "unflagged session preview")
end

-- 4. TITLES.
do
  check(spec.programs_title({}) == "Stall-watch programs", "programs title")
  check(spec.programs_title({ "x", "y" }) == "Stall-watch programs [⚠ 2]", "programs title warns")
  check(spec.sessions_title("alpha", "flagged", {}) == "alpha · flagged", "flagged title")
  check(spec.sessions_title("alpha", "all", { "x" }) == "alpha · all tagged [⚠ 1]", "all title warns")
  check(spec.digest_title(NOW - 3600000, NOW) == "stall-watch digest · 1h old", "digest title age")
  check(spec.digest_title(nil, NOW) == "stall-watch digest", "digest title without mtime")
end

-- 5. CURSOR RESTORE vs sorting_strategy = "descending" (the pin the design asks for).
do
  local o = spec.programs_picker_opts(prows, "beta")
  check(o.sorting_strategy == "descending", "inherits the switcher's descending strategy")
  check(o.sorting_strategy == ss_spec.picker_opts().sorting_strategy, "same strategy object as the switcher")
  check(o.default_selection_index == 2,
    "index is the RESULTS position (2 for beta), NOT inverted for descending; telescope's get_row does that")
  check(o.selection_strategy == "closest", "index applies only on an empty prompt")
  check(type(o.tiebreak) == "function" and o.tiebreak() == false, "order-preserving tiebreak kept")
  local fresh = spec.programs_picker_opts(prows, nil)
  check(fresh.default_selection_index == nil and fresh.selection_strategy == nil, "first open: no forced selection")
  check(spec.programs_picker_opts(prows, "no-such").default_selection_index == nil, "unknown tag -> no index")
  check(spec.sessions_picker_opts().sorting_strategy == "descending", "Screen 2 uses the same ordering controls")
end

print("LUA_TEST_OK " .. N)
```

Add to the runner after the model block:

```bash
sws_out="$(nvim --clean -l assets/nvim/test-stallwatch-picker-spec.lua 2>&1 || true)"
sws_count="$(parse_lua_ok "$sws_out" "stallwatch_picker.spec unit tests")" || exit 1
printf 'PASS  stallwatch_picker.spec unit tests (%s assertions via nvim -l)\n' "$sws_count"
```

**Step 2: Run to verify it fails**

Run: `nvim --clean -l assets/nvim/test-stallwatch-picker-spec.lua`
Expected: `attempt to call a nil value` (spec.lua missing).

**Step 3: Implement** — `assets/nvim/lua/user/stallwatch_picker/spec.lua`:

```lua
-- stallwatch_picker/spec.lua
--
-- Pure presentation for the stall-watch picker (workstation-p8ch): entry
-- text, ordinals, previewer lines, titles, and the pure subset of picker
-- options.
--
-- PURE: MUST NOT require telescope.* or plenary.*. No vim.system, no vim.fn,
-- no vim.api, no side effects. State glyphs, idle ages and the dir-gone mark
-- are the session switcher's, reused rather than copied so the two pickers
-- cannot drift.

local ss_spec = require("user.session_switcher.spec")

local M = {}

M.SEP = "│"
M.NOT_ARMED_MARK = "[log-only]"
M.NOT_ENABLED_MARK = "[disabled]"

local function nonempty(s)
  if type(s) == "string" and s ~= "" then
    return s
  end
  return nil
end

local function basename(dir)
  if not nonempty(dir) then
    return "(no dir)"
  end
  local cleaned = dir:gsub("/+$", "")
  if cleaned == "" then
    return "/"
  end
  return cleaned:match("([^/]+)$") or cleaned
end

--- "5 open (2 decision, 1 blocker, 2 info)" / "0 open".
function M.counts_text(counts)
  counts = type(counts) == "table" and counts or { total = 0, by_kind = {} }
  local s = string.format("%d open", counts.total or 0)
  local parts = {}
  for _, kn in ipairs(counts.by_kind or {}) do
    table.insert(parts, string.format("%d %s", kn.n, kn.kind))
  end
  if #parts > 0 then
    s = s .. " (" .. table.concat(parts, ", ") .. ")"
  end
  return s
end

--- Screen 1 row: `name · N open (k decision, m blocker) · checked 12m ago`,
--- plus a marker when the program is not armed (log-only) or not enabled.
--- A missing last_tick_activity drops the "checked" part rather than lying.
function M.program_display(prow, now_ms)
  prow = type(prow) == "table" and prow or {}
  local parts = { prow.tag or "(unnamed)", M.counts_text(prow.counts) }
  if type(prow.last_tick_ms) == "number" then
    table.insert(parts, "checked " .. ss_spec.idle_age(prow.last_tick_ms, now_ms) .. " ago")
  end
  local s = table.concat(parts, " · ")
  -- `== false`, not `~= true`: a MISSING field is "tolerated; that part of
  -- the row is blank" (design), and a marker would assert something unknown.
  if prow.armed == false then
    s = s .. " " .. M.NOT_ARMED_MARK
  end
  if prow.enabled == false then
    s = s .. " " .. M.NOT_ENABLED_MARK
  end
  return s
end

function M.program_ordinal(prow)
  return (type(prow) == "table" and prow.tag) or ""
end

--- `[kind]` for a flagged row, "" for an unflagged (all-view) row.
function M.badge(row)
  local k = type(row) == "table" and nonempty(row.badge_kind)
  return k and ("[" .. k .. "]") or ""
end

--- Screen 2 row: `kind badge · state glyph · title │ dir │ age [dir gone]`.
--- An unjoined row (the CLI did not return it) has no state or age: those
--- cells are blank, never a guessed glyph -- `~` would claim "stale data from
--- a dead source", which is a different statement.
function M.session_display(row, now_ms)
  row = type(row) == "table" and row or {}
  local glyph = row.joined and ss_spec.glyph_of(row) or " "
  local age = row.joined and ss_spec.idle_age(row.lastActivity, now_ms) or ""
  local title = nonempty(row.title) or nonempty(row.id) or "(untitled)"
  local lead = { glyph }
  local badge = M.badge(row)
  if badge ~= "" then
    table.insert(lead, 1, badge)
  end
  local s = table.concat(lead, " · ") .. " " .. title .. " " .. M.SEP .. " " .. basename(row.directory) .. " " .. M.SEP
  if age ~= "" then
    s = s .. " " .. age
  end
  if row.dir_missing == true then
    s = s .. " " .. ss_spec.DIR_MISSING_MARK
  end
  return s
end

--- Same exclusion rule as the switcher's ordinal: title and dir only, so
--- typing digits or a kind name does not match badges.
function M.session_ordinal(row)
  row = type(row) == "table" and row or {}
  return (nonempty(row.title) or nonempty(row.id) or "") .. " " .. basename(row.directory)
end

local function push_text(lines, prefix, text)
  local first = true
  for line in tostring(text or ""):gmatch("[^\r\n]+") do
    table.insert(lines, (first and prefix or string.rep(" ", #prefix)) .. line)
    first = false
  end
  if first then
    table.insert(lines, prefix)
  end
end

--- `(new)`, `(changed: <what_changed>)`, `(stale)` markers for one item.
function M.item_marks(item)
  local marks = {}
  if item.status == "new" then
    table.insert(marks, "(new)")
  elseif item.status == "changed" then
    local wc = nonempty(item.what_changed)
    table.insert(marks, wc and ("(changed: " .. wc .. ")") or "(changed)")
  end
  if item.stale == true then
    table.insert(marks, "(stale)")
  end
  return table.concat(marks, " ")
end

local function item_lines(lines, item, with_sessions)
  local marks = M.item_marks(item)
  push_text(lines, "[" .. (nonempty(item.kind) or "?") .. "] ", item.text)
  if marks ~= "" then
    lines[#lines] = lines[#lines] .. " " .. marks
  end
  if with_sessions then
    for _, s in ipairs(type(item.sessions) == "table" and item.sessions or {}) do
      if type(s) == "table" then
        table.insert(lines, "    - " .. (nonempty(s.title) or nonempty(s.id) or "?"))
      end
    end
  end
end

--- Screen 1 previewer: the program's open items in contract order, each
--- `[kind] text` with new/changed/stale marks and the titles of the sessions
--- it names. Item text is split on newlines (nvim_buf_set_lines rejects them).
function M.program_preview_lines(prow)
  local items = type(prow) == "table" and prow.items or {}
  if #items == 0 then
    return { "(no open items)" }
  end
  local lines = {}
  for i, item in ipairs(items) do
    if i > 1 then
      table.insert(lines, "")
    end
    item_lines(lines, item, true)
  end
  return lines
end

--- Screen 2 previewer: the text of every item naming this session.
function M.session_preview_lines(row)
  local items = type(row) == "table" and row.items or {}
  if #items == 0 then
    return { "(no open items name this session)" }
  end
  local lines = {}
  for i, item in ipairs(items) do
    if i > 1 then
      table.insert(lines, "")
    end
    item_lines(lines, item, false)
  end
  return lines
end

local function warn_suffix(warnings)
  if type(warnings) == "table" and #warnings > 0 then
    return string.format(" [⚠ %d]", #warnings)
  end
  return ""
end

function M.programs_title(warnings)
  return "Stall-watch programs" .. warn_suffix(warnings)
end

--- @param view "flagged"|"all"
function M.sessions_title(tag, view, warnings)
  return string.format("%s · %s", tag or "(unnamed)", view == "all" and "all tagged" or "flagged") .. warn_suffix(warnings)
end

function M.digest_title(mtime_ms, now_ms)
  if type(mtime_ms) ~= "number" then
    return "stall-watch digest"
  end
  return "stall-watch digest · " .. ss_spec.idle_age(mtime_ms, now_ms) .. " old"
end

--- 1-based position of `tag` in the Screen 1 results, or nil.
function M.selection_index(prows, tag)
  if tag == nil then
    return nil
  end
  for i, p in ipairs(type(prows) == "table" and prows or {}) do
    if p.tag == tag then
      return i
    end
  end
  return nil
end

--- Pure picker options for Screen 1.
---
--- Ordering controls are the switcher's (sorting_strategy = "descending",
--- order-preserving tiebreak), so both pickers render the same way.
---
--- CURSOR RESTORE on <C-b>: telescope's `default_selection_index` is an index
--- into the RESULTS list, and Picker:get_row maps it through
--- sorting_strategy (descending: row = max_results - index). So passing the
--- program's position in the results is correct under "descending" and must
--- NOT be inverted by hand -- the test pins that.
---
--- selection_strategy = "closest" applies that index only while the prompt
--- is empty. Under the default "reset" telescope re-applies the index on
--- every keystroke, pinning the cursor to a row position a filter has
--- already emptied.
function M.programs_picker_opts(prows, select_tag)
  local opts = ss_spec.picker_opts()
  local idx = M.selection_index(prows, select_tag)
  if idx then
    opts.default_selection_index = idx
    opts.selection_strategy = "closest"
  end
  return opts
end

function M.sessions_picker_opts()
  return ss_spec.picker_opts()
end

return M
```

**Step 4: Run to verify it passes**

Run: `bash assets/nvim/test-session-switcher.sh 2>&1 | grep stallwatch`
Expected: `PASS  stallwatch_picker.spec unit tests (53 assertions via nvim -l)`.

**Step 5: Re-pin (PASS lines 7 → 8; add the spec grep with the measured count), check, privacy gate, commit**

```bash
git add assets/nvim/lua/user/stallwatch_picker/spec.lua assets/nvim/test-stallwatch-picker-spec.lua \
  assets/nvim/test-session-switcher.sh flake.nix
nix build .#checks.aarch64-linux.nvim-lua .#checks.aarch64-linux.test-reachability -L --no-link
git commit -m "[NO-JIRA] stall-watch picker: row text, previews, titles, cursor-restore opts (workstation-p8ch)"
```

---

### Task 6: `source.lua` (the async snapshot fetch)

**Files:**
- Create: `assets/nvim/lua/user/stallwatch_picker/source.lua`
- Test: `assets/nvim/test-stallwatch-picker-source.lua`
- Modify: `assets/nvim/test-session-switcher.sh`, `flake.nix` (nvim-lua)

Context: the settle discipline is `session_switcher/cli.lua:94-180`'s: `pcall` the spawn (a missing binary raises ENOENT instead of calling back), funnel every exit through one `settle` that fires once via `vim.schedule` (vim.system's `on_exit` runs in a fast event context), and bound the wait with `vim.defer_fn`. The test fakes follow `test-session-switcher.sh:55-88` (scheduled / synchronous reply, "never replies" for the timeout). Step 3 goes through the real `cli.fetch` (preloaded), so the `--ids` argv built in Task 3 is exercised end to end. Env override name: `STALLWATCH_ITEMS_CMD`.

**Step 1: Write the failing test** — `assets/nvim/test-stallwatch-picker-source.lua`:

```lua
-- Unit tests for stallwatch_picker/source.lua (async snapshot fetch).
-- Driven via `nvim --clean -l assets/nvim/test-stallwatch-picker-source.lua`.
--
-- No real binaries: every spawn goes through a fake `system`, in the shape of
-- the fakes in test-session-switcher.sh. SYNTHETIC DATA ONLY (public repo).

local N = 0
local function check(cond, msg) N = N + 1; assert(cond, msg) end

local model = loadfile("assets/nvim/lua/user/stallwatch_picker/model.lua")()
package.preload["user.stallwatch_picker.model"] = function() return model end
-- The REAL switcher cli.fetch serves step 3, so its --ids argv is exercised.
local cli = loadfile("assets/nvim/lua/user/session_switcher/cli.lua")()
package.preload["user.session_switcher.cli"] = function() return cli end
local source = loadfile("assets/nvim/lua/user/stallwatch_picker/source.lua")()

local f = assert(io.open("assets/nvim/stallwatch-picker-fixture.json", "r"))
local FIXTURE = f:read("*a")
f:close()

local ITEMS = "/fixture/bin/items.sh"
local ENV = { [source.ENV] = ITEMS }
local ROWS = vim.json.encode({
  { id = "ses_fixture_a1", title = "A1", directory = "/fixture/alpha/one", effective_state = "idle", dir_missing = false },
  { id = "ses_fixture_t1", title = "T1", directory = "/fixture/alpha/t1", effective_state = "idle", dir_missing = false },
})

-- Routes by argv; records every argv. `replies[key] = {code, stdout, stderr}`
-- or "hang" (never calls back) or "raise" (vim.system ENOENT behaviour).
local function router(replies, calls)
  return function(argv, _o, on_exit)
    table.insert(calls, argv)
    local key = argv[1] == "oc-tags" and ("oc-tags:" .. argv[3]) or argv[1]
    local r = replies[key]
    if r == "raise" then error("ENOENT: no such file or directory") end
    if r ~= "hang" then
      r = r or { 0, "", "" }
      vim.schedule(function()
        on_exit({ code = r[1], signal = 0, stdout = r[2] or "", stderr = r[3] or "" })
      end)
    end
    return { pid = 1, kill = function() end }
  end
end

local function collect(replies, extra)
  local calls = {}
  local n, snap, err = 0, nil, nil
  local opts = vim.tbl_extend("force", { env = ENV, system = router(replies, calls), items_timeout_ms = 100, tags_timeout_ms = 100, list_timeout_ms = 100 }, extra or {})
  source.fetch(opts, function(s, e) n = n + 1; snap, err = s, e end)
  vim.wait(2000, function() return n > 0 end)
  vim.wait(150) -- a second (illegal) callback would land in here
  check(n == 1, "callback fired exactly once, got " .. n)
  return snap, err, calls
end

local HAPPY = {
  [ITEMS] = { 0, FIXTURE },
  ["oc-tags:alpha"] = { 0, "ses_fixture_t1\nses_fixture_a1\n" },
  ["oc-tags:beta"] = { 0, "" },
  ["oc-session-list"] = { 0, ROWS },
}

-- 1. Command path: env override, else the default under $HOME.
do
  check(source.items_cmd({ [source.ENV] = "/x/items.sh" }) == "/x/items.sh", "env override wins")
  check(source.items_cmd({}) == vim.fn.expand("~/projects/eng-agent-platform/stallwatch/items.sh"), "default path")
  check(source.items_cmd({ [source.ENV] = "" }) == source.items_cmd({}), "empty env var -> default")
  check(source.available({ [source.ENV] = "/definitely/not/here/items.sh" }) == false, "missing command -> unavailable")
end

-- 2. Happy path: one snapshot, three steps, the right argv.
do
  local snap, err, calls = collect(HAPPY)
  check(err == nil and snap ~= nil, "happy path -> snapshot")
  check(snap.doc.version == 1 and #snap.doc.programs == 2, "doc carried")
  check(table.concat(snap.tagged.alpha, ",") == "ses_fixture_t1,ses_fixture_a1", "tagged ids per program")
  check(#snap.tagged.beta == 0, "empty oc-tags output -> empty list")
  check(#snap.rows == 2, "CLI rows carried")
  check(#snap.warnings == 0, "no warnings")
  check(calls[1][1] == ITEMS and calls[1][2] == "--json", "step 1 runs the read command with --json")
  local list_argv
  for _, c in ipairs(calls) do if c[1] == "oc-session-list" then list_argv = c end end
  check(list_argv ~= nil, "step 3 ran oc-session-list exactly via cli.fetch")
  check(vim.tbl_contains(list_argv, "--fold") and vim.tbl_contains(list_argv, "--with-state"), "--with-state --fold")
  check(not vim.tbl_contains(list_argv, "--limit"), "ids mode sends no --limit")
  local i = vim.fn.index(list_argv, "--ids")
  check(i >= 0, "--ids present")
  check(list_argv[i + 2] == "ses_fixture_a1,ses_fixture_a2,ses_fixture_arch,ses_fixture_gone,ses_fixture_b1,ses_fixture_t1",
    "--ids is the deduped union of item and tagged ids, got " .. tostring(list_argv[i + 2]))
end

-- 3. `error` is checked BEFORE version and exit code.
do
  local snap, err = collect({ [ITEMS] = { 1, '{"version":1,"error":"db is locked"}' } })
  check(snap == nil and err.kind == "error", "error doc -> kind=error")
  check(err.message:find("db is locked", 1, true) ~= nil, "error text surfaced")
end

-- 4. Non-zero exit without JSON -> its stderr.
do
  local _, err = collect({ [ITEMS] = { 2, "", "Traceback: something broke\n" } })
  check(err.kind == "exit" and err.message:find("Traceback: something broke", 1, true), "stderr surfaced")
end

-- 5. Timeout -> "stall-watch busy, retry".
do
  local _, err = collect({ [ITEMS] = "hang" })
  check(err.kind == "timeout" and err.message == source.BUSY_MESSAGE, "timeout -> busy message")
end

-- 6. Missing command -> spawn error, not an exception.
do
  local _, err = collect({ [ITEMS] = "raise" })
  check(err.kind == "spawn", "raise -> kind=spawn")
end

-- 7. version ~= 1 -> refuse, say so.
do
  local _, err = collect({ [ITEMS] = { 0, '{"version":2,"programs":[]}' } })
  check(err.kind == "version" and err.message:find("version 2", 1, true), "version 2 refused")
end

-- 8. Zero programs -> "no programs registered".
do
  local _, err = collect({ [ITEMS] = { 0, '{"version":1,"generated_at":null,"latest_digest":null,"programs":[]}' } })
  check(err.kind == "empty" and err.message:find("no programs registered", 1, true), "zero programs")
end

-- 9. Garbage stdout with exit 0 -> decode error.
do
  local _, err = collect({ [ITEMS] = { 0, "not json" } })
  check(err.kind == "decode", "garbage -> decode")
  local _, err2 = collect({ [ITEMS] = { 0, "[]" } })
  check(err2.kind == "decode", "top-level array is not a document")
end

-- 10. oc-tags fails -> snapshot still delivered, with a warning.
do
  local r = vim.deepcopy(HAPPY)
  r["oc-tags:alpha"] = { 1, "", "boom" }
  local snap, err = collect(r)
  check(err == nil and snap ~= nil, "oc-tags failure is not fatal")
  check(#snap.tagged.alpha == 0, "failed program has no tagged ids")
  check(#snap.warnings == 1 and snap.warnings[1]:find("oc-tags", 1, true), "warning names oc-tags")
end

-- 11. oc-session-list fails -> snapshot with no rows, with a warning.
do
  local r = vim.deepcopy(HAPPY)
  r["oc-session-list"] = { 1, "", "Error querying database" }
  local snap, err = collect(r)
  check(err == nil and #snap.rows == 0, "CLI failure -> empty rows, not an error")
  check(#snap.warnings == 1 and snap.warnings[1]:find("oc-session-list failed", 1, true), "warning names oc-session-list")
end

-- 12. CLI exit 0 + stderr -> rows AND the stderr lines as warnings.
do
  local r = vim.deepcopy(HAPPY)
  r["oc-session-list"] = { 0, ROWS, "oc-session-list: no live writer is reporting\n" }
  local snap = collect(r)
  check(#snap.rows == 2 and snap.warnings[1]:find("no live writer", 1, true), "S3 tripwire surfaced")
end

-- 13. ASYNC even with a synchronous system.
do
  local ran = false
  source.fetch({ env = ENV, system = function(_a, _o, on_exit)
    on_exit({ code = 1, signal = 0, stdout = '{"version":1,"error":"x"}', stderr = "" })
    return { pid = 1, kill = function() end }
  end }, function() ran = true end)
  check(ran == false, "fetch is async")
  vim.wait(500, function() return ran end)
  check(ran, "and does call back")
end

-- 14. Pure helpers.
do
  check(table.concat(source.parse_ids("a\n\n b \r\nc"), ",") == "a,b,c", "parse_ids trims and drops blanks")
  check(#source.parse_ids(nil) == 0, "parse_ids(nil)")
end

print("LUA_TEST_OK " .. N)
```

Runner lines (after the spec block):

```bash
swsrc_out="$(nvim --clean -l assets/nvim/test-stallwatch-picker-source.lua 2>&1 || true)"
swsrc_count="$(parse_lua_ok "$swsrc_out" "stallwatch_picker.source unit tests")" || exit 1
printf 'PASS  stallwatch_picker.source unit tests (%s assertions via nvim -l)\n' "$swsrc_count"
```

**Step 2: Run to verify it fails**

Run: `nvim --clean -l assets/nvim/test-stallwatch-picker-source.lua`
Expected: `attempt to call a nil value`.

**Step 3: Implement** — `assets/nvim/lua/user/stallwatch_picker/source.lua`:

```lua
-- stallwatch_picker/source.lua
--
-- The one async snapshot fetch behind the stall-watch picker (workstation-p8ch).
--
-- At open, in order, all async:
--   1. the private read command `items.sh --json` (explicit timeout)
--   2. `oc-tags sessions <tag>` for each program -> tagged root ids
--   3. ONE `oc-session-list --with-state --fold --ids <union>`
-- and the callback receives ONE snapshot; both screens are pure functions of
-- it. Step 1 failing means no picker. Steps 2-3 failing degrade: the flagged
-- view still works from item data alone, and the failure is a warning.
--
-- The read command is invoked by ABSOLUTE PATH and never read around: this
-- module does not know where the stall-watcher keeps its database.
--
-- Must NOT require telescope.*. Every spawn goes through `opts.system` (default
-- vim.system) so tests need no real binaries -- the same seam as
-- session_switcher/cli.lua.

local model = require("user.stallwatch_picker.model")

local M = {}

M.ENV = "STALLWATCH_ITEMS_CMD"
M.DEFAULT_CMD = "~/projects/eng-agent-platform/stallwatch/items.sh"
M.ITEMS_TIMEOUT_MS = 5000
M.TAGS_TIMEOUT_MS = 5000
M.LIST_TIMEOUT_MS = 5000
M.BUSY_MESSAGE = "stall-watch busy, retry"

--- Absolute path of the read command: $STALLWATCH_ITEMS_CMD, else the default.
--- @param env table|nil injection seam (defaults to vim.env)
function M.items_cmd(env)
  env = env or vim.env
  local v = env[M.ENV]
  if type(v) == "string" and v ~= "" then
    return vim.fn.expand(v)
  end
  return vim.fn.expand(M.DEFAULT_CMD)
end

--- Whether the read command is executable (gates the <leader>fp keymap).
function M.available(env)
  return vim.fn.executable(M.items_cmd(env)) == 1
end

local function trim(s)
  if type(s) ~= "string" then
    return nil
  end
  local t = s:match("^%s*(.-)%s*$")
  return t ~= "" and t or nil
end

--- Spawn argv; call cb(out, err) EXACTLY ONCE, always via vim.schedule.
--- out = {code, stdout, stderr}; err = {kind = "spawn"|"timeout", message}.
--- Same settle discipline as session_switcher/cli.lua's fetch: a missing
--- binary raises instead of calling back (pcall), vim.system's on_exit runs
--- in a fast event context (schedule), and a late reply after a timeout must
--- not deliver a second answer (settled flag).
function M.run(system, argv, timeout_ms, cb)
  local settled = false
  local function settle(out, err)
    if settled then
      return
    end
    settled = true
    vim.schedule(function()
      cb(out, err)
    end)
  end
  local ok, handle = pcall(system, argv, { text = true }, function(out)
    settle(out, nil)
  end)
  if not ok then
    settle(nil, { kind = "spawn", message = string.format("could not run %s: %s", argv[1], tostring(handle)) })
    return
  end
  vim.defer_fn(function()
    if settled then
      return
    end
    pcall(function()
      if handle and handle.kill then
        handle:kill(15)
      end
    end)
    settle(nil, { kind = "timeout", message = string.format("%s did not respond within %dms", argv[1], timeout_ms) })
  end, timeout_ms)
end

--- Classify the read command's result. Pure.
---
--- ORDER IS THE CONTRACT: `error` is checked BEFORE the exit code and BEFORE
--- `version`, because the error document is `{version: 1, error}` with exit 1
--- -- checking version first would accept it, checking the exit code first
--- would throw its message away for a bare "exited 1".
---
--- @return table|nil doc, table|nil err  err = {kind, message}
function M.decode_items(out)
  out = type(out) == "table" and out or {}
  local ok, doc = pcall(vim.json.decode, out.stdout or "", { luanil = { object = true } })
  local is_obj = ok and type(doc) == "table" and not vim.islist(doc)
  if is_obj and doc.error ~= nil then
    return nil, { kind = "error", message = "stall-watch: " .. tostring(doc.error) }
  end
  if out.code ~= 0 then
    local msg = trim(out.stderr) or string.format("read command exited %s", tostring(out.code))
    return nil, { kind = "exit", message = "stall-watch: " .. msg }
  end
  if not is_obj then
    return nil, { kind = "decode", message = "stall-watch: read command returned unparseable output" }
  end
  if doc.version ~= 1 then
    return nil, {
      kind = "version",
      message = string.format("stall-watch: unsupported items version %s (this picker reads version 1)", tostring(doc.version)),
    }
  end
  if type(doc.programs) ~= "table" or #doc.programs == 0 then
    return nil, { kind = "empty", message = "stall-watch: no programs registered" }
  end
  return doc, nil
end

--- `oc-tags sessions <tag>` stdout -> ids. Pure.
function M.parse_ids(stdout)
  local out = {}
  for line in tostring(stdout or ""):gmatch("[^\r\n]+") do
    local t = trim(line)
    if t then
      table.insert(out, t)
    end
  end
  return out
end

local function default_list_fetch(opts, cb)
  return require("user.session_switcher.cli").fetch(opts, cb)
end

--- Fetch the snapshot.
---
--- @param opts table|nil {
---   system?: function   -- vim.system seam, threaded to every spawn
---   env?: table         -- vim.env seam for the command path
---   list_fetch?: function(opts, cb) -- defaults to session_switcher.cli.fetch
---   items_timeout_ms?, tags_timeout_ms?, list_timeout_ms?: integer
--- }
--- @param cb function(snapshot|nil, err|nil) -- exactly once, on the main loop.
---   snapshot = { doc, tagged = {[tag] = ids}, rows, warnings = string[] }
---   err      = { kind, message }  (message is user-facing)
function M.fetch(opts, cb)
  opts = opts or {}
  local system = opts.system or vim.system
  local list_fetch = opts.list_fetch or default_list_fetch
  local warnings = {}

  local cmd = M.items_cmd(opts.env)
  M.run(system, { cmd, "--json" }, opts.items_timeout_ms or M.ITEMS_TIMEOUT_MS, function(out, run_err)
    if run_err then
      if run_err.kind == "timeout" then
        return cb(nil, { kind = "timeout", message = M.BUSY_MESSAGE })
      end
      return cb(nil, { kind = run_err.kind, message = "stall-watch: " .. run_err.message })
    end
    local doc, err = M.decode_items(out)
    if err then
      return cb(nil, err)
    end

    -- Step 2: tagged ids per program, in parallel; join on a counter.
    local tagged = {}
    local tags = {}
    for _, p in ipairs(doc.programs) do
      if type(p) == "table" and type(p.tag) == "string" and p.tag ~= "" and not tagged[p.tag] then
        tagged[p.tag] = {}
        table.insert(tags, p.tag)
      end
    end

    local function step3()
      local ids = model.union_ids(doc, tagged)
      if #ids == 0 then
        return cb({ doc = doc, tagged = tagged, rows = {}, warnings = warnings }, nil)
      end
      list_fetch({
        fold = true,
        ids = ids,
        system = system,
        timeout_ms = opts.list_timeout_ms or M.LIST_TIMEOUT_MS,
      }, function(result, lerr)
        local rows = {}
        if lerr then
          table.insert(warnings, "oc-session-list failed (" .. tostring(lerr.message) .. "); showing item data only")
        else
          rows = (result and result.rows) or {}
          -- exit 0 + stderr is SUCCESS WITH WARNINGS (the S3 tripwire): surface it.
          for line in tostring(result and result.warnings or ""):gmatch("[^\r\n]+") do
            local t = trim(line)
            if t then
              table.insert(warnings, t)
            end
          end
        end
        cb({ doc = doc, tagged = tagged, rows = rows, warnings = warnings }, nil)
      end)
    end

    local pending = #tags
    if pending == 0 then
      return step3()
    end
    for _, tag in ipairs(tags) do
      M.run(system, { "oc-tags", "sessions", tag }, opts.tags_timeout_ms or M.TAGS_TIMEOUT_MS, function(tout, terr)
        if terr then
          table.insert(warnings, string.format("oc-tags sessions failed for a program (%s)", terr.message))
        elseif tout.code ~= 0 then
          table.insert(warnings, string.format("oc-tags sessions exited %s: %s", tostring(tout.code), trim(tout.stderr) or ""))
        else
          tagged[tag] = M.parse_ids(tout.stdout)
        end
        pending = pending - 1
        if pending == 0 then
          step3()
        end
      end)
    end
  end)
end

return M
```

**Step 4: Run to verify it passes**

Run: `bash assets/nvim/test-session-switcher.sh 2>&1 | grep stallwatch`
Expected: `PASS  stallwatch_picker.source unit tests (47 assertions via nvim -l)`.

**Step 5: Re-pin (PASS lines 8 → 9; add the source grep), check, privacy gate, commit**

```bash
git add assets/nvim/lua/user/stallwatch_picker/source.lua assets/nvim/test-stallwatch-picker-source.lua \
  assets/nvim/test-session-switcher.sh flake.nix
nix build .#checks.aarch64-linux.nvim-lua .#checks.aarch64-linux.test-reachability -L --no-link
git commit -m "[NO-JIRA] stall-watch picker: async snapshot fetch with degraded-mode warnings (workstation-p8ch)"
```

---

### Task 7: `init.lua` (telescope layer)

**Files:**
- Create: `assets/nvim/lua/user/stallwatch_picker/init.lua`
- Test: `assets/nvim/test-stallwatch-picker-init.lua`
- Modify: `assets/nvim/test-session-switcher.sh`, `flake.nix` (nvim-lua)

Context: copy the switcher's glue conventions from `session_switcher/init.lua`: capture the tmux client once at open (`:151`); read the selection BEFORE `actions.close` (`:269-282`); pass `conf.generic_sorter(opts)` explicitly (without it telescope's empty sorter never filters — `spec.lua:416-421`); in-place view changes via `picker:refresh(finder, { reset_prompt = false })` plus `prompt_border:change_title` (`:184-194`, `:213`). Back-navigation is close + `vim.schedule` reopen (building a picker during teardown is the hazard). The jump is `state.controller:accept(row, cb)` (`flow.lua:160-171`: fresh `discovery.locate` → `act.decide`, which needs only `row.id`/`row.dir_missing`/`row.directory`) and then `session_switcher.dispatch(desc, row, client, opts)` from Task 3. The test stubs telescope exactly as `test-session-switcher-spec.lua:56-161` does, plus a `telescope.previewers` stub, and stubs `user.session_switcher` (dispatch itself is covered by the switcher's own suite).

**Step 1: Write the failing test** — `assets/nvim/test-stallwatch-picker-init.lua`:

```lua
-- Unit tests for stallwatch_picker/init.lua (the telescope layer), against
-- telescope STUBS in the shape of test-session-switcher-spec.lua's.
-- Driven via `nvim --clean -l assets/nvim/test-stallwatch-picker-init.lua`.
--
-- Proves the glue against OUR MODEL of telescope's API: what reaches
-- pickers.new, what the mappings do, how back-navigation restores the cursor.
-- It cannot catch telescope changing its API; the manual acceptance run does.
-- SYNTHETIC DATA ONLY (public repo).

local N = 0
local function check(cond, msg) N = N + 1; assert(cond, msg) end

local ss_model = loadfile("assets/nvim/lua/user/session_switcher/model.lua")()
package.preload["user.session_switcher.model"] = function() return ss_model end
local ss_spec = loadfile("assets/nvim/lua/user/session_switcher/spec.lua")()
package.preload["user.session_switcher.spec"] = function() return ss_spec end
local flow = loadfile("assets/nvim/lua/user/session_switcher/flow.lua")()
package.preload["user.session_switcher.flow"] = function() return flow end

-- exec: only tmux_client and notify_warnings are reached from this layer.
local tmux_calls = 0
local notified = {}
local exec_stub = {
  tmux_client = function() tmux_calls = tmux_calls + 1; return "client_fixture" end,
  notify_warnings = function(lines) for _, l in ipairs(lines or {}) do table.insert(notified, l) end end,
}
package.preload["user.session_switcher.exec"] = function() return exec_stub end

-- The switcher's dispatch is tested in test-session-switcher-spec.lua; here we
-- only prove the stall-watch picker hands it the right arguments.
local dispatched = {}
package.preload["user.session_switcher"] = function()
  return { dispatch = function(desc, row, client, opts) table.insert(dispatched, { desc = desc, row = row, client = client, opts = opts }) end }
end

local model = loadfile("assets/nvim/lua/user/stallwatch_picker/model.lua")()
package.preload["user.stallwatch_picker.model"] = function() return model end
local spec = loadfile("assets/nvim/lua/user/stallwatch_picker/spec.lua")()
package.preload["user.stallwatch_picker.spec"] = function() return spec end
package.preload["user.stallwatch_picker.source"] = function()
  return { fetch = function() error("tests inject opts.fetch") end }
end

-- ---- telescope stubs ------------------------------------------------------
local new_calls, closed = {}, {}
local select_default_fn
local selected_entry
local current_picker
local stub_actions = {
  close = function(bufnr) table.insert(closed, bufnr) end,
  select_default = { replace = function(_, fn) select_default_fn = fn end },
}
local stub_state = {
  get_selected_entry = function() return selected_entry end,
  get_current_picker = function() return current_picker end,
}
package.preload["telescope.pickers"] = function()
  return { new = function(opts, defaults)
    local p = { opts = opts, defaults = defaults, prompt_title = defaults.prompt_title,
      find = function(self) self.found = true end,
      refresh = function(self, finder, ro) self.refreshed = finder; self.refresh_opts = ro end }
    table.insert(new_calls, p)
    return p
  end }
end
package.preload["telescope.finders"] = function()
  return { new_table = function(o) return { results = o.results, entry_maker = o.entry_maker } end }
end
package.preload["telescope.previewers"] = function()
  return { new_buffer_previewer = function(o) return { stub = "previewer", define_preview = o.define_preview, title = o.title } end }
end
package.preload["telescope.config"] = function()
  return { values = { generic_sorter = function() return { stub = "sorter" } end } }
end
package.preload["telescope.actions"] = function() return stub_actions end
package.preload["telescope.actions.state"] = function() return stub_state end

local init = loadfile("assets/nvim/lua/user/stallwatch_picker/init.lua")()

local f = assert(io.open("assets/nvim/stallwatch-picker-fixture.json", "r"))
local doc = vim.json.decode(f:read("*a"), { luanil = { object = true } })
f:close()
local SNAP = {
  doc = doc,
  tagged = { alpha = { "ses_fixture_t1" }, beta = {} },
  rows = {
    { id = "ses_fixture_t1", title = "T1", directory = "/fixture/alpha/t1", effective_state = "idle", dir_missing = false },
    { id = "ses_fixture_a1", title = "A1", directory = "/fixture/alpha/one", effective_state = "blocked", dir_missing = false },
  },
  warnings = { "oc-tags sessions exited 1: fixture" },
}

-- Record mappings handed to `map`.
local function mappings_of(picker, bufnr)
  local maps = {}
  picker.defaults.attach_mappings(bufnr, function(modes, lhs, fn)
    maps[lhs] = { modes = modes, fn = fn }
  end)
  return maps
end

local accepted = {}
local ctrl = { accept = function(_, row, cb) table.insert(accepted, row); cb({ kind = "attach", sid = row.id }) end }

-- 1. OPEN: fetch once, capture tmux client once, Screen 1 with source order.
local fetch_calls = 0
init.open({ flow = ctrl, fetch = function(_o, cb) fetch_calls = fetch_calls + 1; cb(SNAP, nil) end })
check(fetch_calls == 1, "snapshot fetched once at open")
check(tmux_calls == 1, "tmux client captured once at open")
check(#new_calls == 1 and new_calls[1].found, "Screen 1 opened")
local s1 = new_calls[1]
check(s1.defaults.finder.results[1].tag == "alpha" and s1.defaults.finder.results[2].tag == "beta", "Screen 1 keeps source order")
check(s1.defaults.sorting_strategy == "descending", "Screen 1 uses the switcher's descending strategy")
check(s1.defaults.default_selection_index == nil, "first open forces no selection")
check(s1.defaults.sorter and s1.defaults.sorter.stub == "sorter", "a real sorter reaches pickers.new (else no filtering)")
check(s1.defaults.previewer and s1.defaults.previewer.stub == "previewer", "previewer wired")
check(s1.prompt_title == "Stall-watch programs [⚠ 1]", "partial failure shows ⚠ in the title")
check(#notified == 1, "warnings notified once")

-- previewer writes the program's lines into the preview buffer.
do
  local buf = vim.api.nvim_create_buf(false, true)
  s1.defaults.previewer.define_preview({ state = { bufnr = buf } }, { value = s1.defaults.finder.results[1] })
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  check(lines[1]:find("^%[decision%]") ~= nil, "program previewer renders items")
end

-- 2. <CR> on a program -> close, then (scheduled) Screen 2 flagged view.
local m1 = mappings_of(s1, 11)
check(m1["<C-d>"] ~= nil, "Screen 1 maps <C-d>")
selected_entry = { value = s1.defaults.finder.results[2] } -- beta
select_default_fn()
check(closed[#closed] == 11, "Screen 1 closed on <CR>")
vim.wait(200, function() return #new_calls == 2 end)
local s2 = new_calls[2]
check(s2 ~= nil, "Screen 2 opened after the close")
check(s2.defaults.prompt_title == "beta · flagged [⚠ 1]", "Screen 2 title names program + view")
local rows = s2.defaults.finder.results
check(#rows == 2 and rows[1].id == "ses_fixture_b1" and rows[2].id == "ses_fixture_a2", "flagged rows item-driven")

-- 3. <C-b> -> close, reopen Screen 1 with the cursor on beta, and pin the
--    interaction with sorting_strategy = "descending".
local m2 = mappings_of(s2, 22)
check(m2["<C-b>"] and m2["<C-f>"], "Screen 2 maps <C-b> and <C-f>")
check(m2["<C-d>"] == nil, "Screen 2 leaves <C-d> to telescope (digest is a Screen 1 key)")
m2["<C-b>"].fn()
check(closed[#closed] == 22, "Screen 2 closed on <C-b>")
check(#new_calls == 2, "reopen is DEFERRED (vim.schedule), not built during teardown")
vim.wait(200, function() return #new_calls == 3 end)
local back = new_calls[3]
check(back.defaults.default_selection_index == 2, "cursor restored to beta: results index 2")
check(back.defaults.sorting_strategy == "descending", "under descending, index passed un-inverted")
check(back.defaults.selection_strategy == "closest", "restore applies only on an empty prompt")
check(tmux_calls == 1 and fetch_calls == 1, "back-navigation does no I/O")

-- 4. <C-f> toggles flagged <-> all in place, CLI order partition.
do
  -- Drill into alpha for a richer all view.
  mappings_of(back, 33) -- registers Screen 1's <CR> handler
  selected_entry = { value = back.defaults.finder.results[1] } -- alpha
  select_default_fn()
  vim.wait(200, function() return #new_calls == 4 end)
  local sa = new_calls[4]
  current_picker = sa
  local ma = mappings_of(sa, 44)
  ma["<C-f>"].fn()
  local ids = {}
  for _, r in ipairs(sa.refreshed.results) do table.insert(ids, r.id) end
  check(table.concat(ids, ",") == "ses_fixture_a1,ses_fixture_a2,ses_fixture_arch,ses_fixture_gone,ses_fixture_t1",
    "all view = flagged (CLI order, then CLI-absent) | rest, got " .. table.concat(ids, ","))
  check(sa.refresh_opts.reset_prompt == false, "toggle keeps the prompt")
  check(sa.prompt_title == "alpha · all tagged [⚠ 1]", "title follows the view")
  ma["<C-f>"].fn()
  check(#sa.refreshed.results == 4, "toggle back to flagged")

  -- 5. <CR> on a session -> flow:accept -> switcher.dispatch with the client
  --    captured at OPEN.
  selected_entry = { value = sa.refreshed.results[1] }
  select_default_fn()
  check(closed[#closed] == 44, "Screen 2 closed on <CR>")
  check(#accepted == 1 and accepted[1].id == "ses_fixture_a1", "flow:accept got the row")
  check(#dispatched == 1 and dispatched[1].desc.kind == "attach", "dispatch got the descriptor")
  check(dispatched[1].client == "client_fixture", "dispatch got the client captured at open")
  check(dispatched[1].row.id == "ses_fixture_a1", "dispatch got the row")
end

-- 6. Fetch error -> notification, no picker.
do
  local before = #new_calls
  local seen
  local orig = vim.notify
  vim.notify = function(msg) seen = msg end
  init.open({ flow = ctrl, fetch = function(_o, cb) cb(nil, { kind = "empty", message = "stall-watch: no programs registered" }) end })
  vim.notify = orig
  check(#new_calls == before, "error -> no picker")
  check(seen == "stall-watch: no programs registered", "error -> notified")
end

-- 7. DIGEST: nofile, nomodifiable, readfile'd, never :edit'ed.
do
  local path = vim.fn.tempname()
  vim.fn.writefile({ "digest line one", "digest line two" }, path)
  local buf = init.show_digest(path)
  check(buf ~= nil, "digest buffer created")
  check(vim.bo[buf].buftype == "nofile", "buftype=nofile")
  check(vim.bo[buf].modifiable == false, "nomodifiable")
  check(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "|") == "digest line one|digest line two", "content read")
  check(vim.api.nvim_buf_get_name(buf) ~= path and not vim.api.nvim_buf_get_name(buf):find(path, 1, true), "buffer NOT named after the private path")
  check(vim.fn.bufnr(path) == -1, "no buffer was :edit'ed for the path")
  check(vim.wo.winbar:find("stall-watch digest", 1, true) ~= nil, "title shows in the winbar")
  vim.cmd("bwipeout! " .. buf)
  local seen
  local orig = vim.notify
  vim.notify = function(msg) seen = msg end
  check(init.show_digest(nil) == nil and seen == "stall-watch: no digest yet", "null digest -> 'no digest yet'")
  check(init.show_digest("/nonexistent/fixture/digest") == nil, "missing file -> 'no digest yet'")
  vim.notify = orig
  os.remove(path)
end

print("LUA_TEST_OK " .. N)
```

Runner lines (after the source block):

```bash
swi_out="$(nvim --clean -l assets/nvim/test-stallwatch-picker-init.lua 2>&1 || true)"
swi_count="$(parse_lua_ok "$swi_out" "stallwatch_picker.init unit tests")" || exit 1
printf 'PASS  stallwatch_picker.init unit tests (%s assertions via nvim -l)\n' "$swi_count"
```

**Step 2: Run to verify it fails**

Run: `nvim --clean -l assets/nvim/test-stallwatch-picker-init.lua`
Expected: `attempt to call a nil value`.

**Step 3: Implement** — `assets/nvim/lua/user/stallwatch_picker/init.lua`:

```lua
-- stallwatch_picker/init.lua
--
-- Thin telescope layer for the stall-watch picker (workstation-p8ch).
--
-- Screen 1 (programs) and Screen 2 (sessions of one program) are two pickers
-- over ONE snapshot fetched at open (source.lua). Moving between them never
-- does I/O, so there is no in-flight callback to race.
--
-- Keys:
--   Screen 1: <CR> drill into a program, <C-d> latest digest.
--   Screen 2: <CR> jump, <C-f> flagged/all, <C-b> back (cursor restored).
-- <C-d> (Screen 1) and <C-f> (Screen 2) shadow telescope's
-- preview_scrolling_down/_left defaults in those pickers only; the session
-- switcher already shadows <C-f> the same way.
--
-- Jumping is the session switcher's own path, not a copy of it:
-- flow:accept (fresh discovery re-resolve + act.decide) and then
-- session_switcher.dispatch (the exec.* side effects), with the tmux client
-- captured ONCE at open, as the switcher does (its Contract 9).

local pickers = require("telescope.pickers")
local finders = require("telescope.finders")
local previewers = require("telescope.previewers")
local conf = require("telescope.config").values
local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")

local switcher = require("user.session_switcher")
local exec = require("user.session_switcher.exec")
local flow = require("user.session_switcher.flow")

local model = require("user.stallwatch_picker.model")
local spec = require("user.stallwatch_picker.spec")
local source = require("user.stallwatch_picker.source")

local M = {}

local function set_preview(bufnr, lines)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
end

local function now_ms()
  return os.time() * 1000
end

--- Show `latest_digest` in a scratch buffer.
---
--- readfile into a `nofile` buffer, NEVER :edit -- :edit would put the
--- private path into the jumplist/oldfiles and hence shada. The buffer is not
--- named after the path for the same reason.
function M.show_digest(path)
  if type(path) ~= "string" or path == "" or vim.fn.filereadable(path) ~= 1 then
    vim.notify("stall-watch: no digest yet", vim.log.levels.INFO)
    return nil
  end
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    vim.notify("stall-watch: could not read the digest", vim.log.levels.WARN)
    return nil
  end
  local stat = vim.uv.fs_stat(path)
  local mtime_ms = stat and (stat.mtime.sec * 1000) or nil
  vim.cmd("botright new")
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.wo.winbar = spec.digest_title(mtime_ms, now_ms())
  return buf
end

local function digest_mapping(state, prompt_bufnr)
  return function()
    actions.close(prompt_bufnr)
    vim.schedule(function()
      M.show_digest(state.snap.doc.latest_digest)
    end)
    return true
  end
end

--- Screen 1.
--- @param state table { snap, prows, by_id, client, controller, opts }
--- @param select_tag string|nil program to put the cursor on (after <C-b>)
function M.programs(state, select_tag)
  local now = now_ms()
  local picker_opts = vim.tbl_extend("force", spec.programs_picker_opts(state.prows, select_tag), {
    prompt_title = spec.programs_title(state.snap.warnings),
    finder = finders.new_table({
      results = state.prows,
      entry_maker = function(p)
        return { value = p, display = spec.program_display(p, now), ordinal = spec.program_ordinal(p) }
      end,
    }),
    sorter = conf.generic_sorter(state.opts),
    previewer = previewers.new_buffer_previewer({
      title = "Open items",
      define_preview = function(self, entry)
        set_preview(self.state.bufnr, spec.program_preview_lines(entry.value))
      end,
    }),
    attach_mappings = function(prompt_bufnr, map)
      actions.select_default:replace(function()
        -- Read the selection BEFORE closing (see session_switcher/init.lua).
        local entry = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if not entry then
          return
        end
        vim.schedule(function()
          M.sessions(state, entry.value, "flagged")
        end)
      end)
      map({ "i", "n" }, "<C-d>", digest_mapping(state, prompt_bufnr))
      return true
    end,
  })
  local picker = pickers.new(state.opts, picker_opts)
  picker:find()
  return picker
end

local function session_rows(state, prow, view)
  local flagged = model.flagged_rows(prow, state.by_id)
  if view == "all" then
    return model.all_rows(flagged, state.snap.rows, state.snap.tagged[prow.tag])
  end
  return flagged
end

local function session_finder(rows)
  local now = now_ms()
  return finders.new_table({
    results = rows,
    entry_maker = function(r)
      return { value = r, display = spec.session_display(r, now), ordinal = spec.session_ordinal(r) }
    end,
  })
end

--- Screen 2.
--- @param view "flagged"|"all"
function M.sessions(state, prow, view)
  local picker_opts = vim.tbl_extend("force", spec.sessions_picker_opts(), {
    prompt_title = spec.sessions_title(prow.tag, view, state.snap.warnings),
    finder = session_finder(session_rows(state, prow, view)),
    sorter = conf.generic_sorter(state.opts),
    previewer = previewers.new_buffer_previewer({
      title = "Items naming this session",
      define_preview = function(self, entry)
        set_preview(self.state.bufnr, spec.session_preview_lines(entry.value))
      end,
    }),
    attach_mappings = function(prompt_bufnr, map)
      actions.select_default:replace(function()
        local entry = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if not entry then
          return
        end
        local row = entry.value or entry
        state.controller:accept(row, function(desc)
          switcher.dispatch(desc, row, state.client, state.opts)
        end)
      end)

      map({ "i", "n" }, "<C-f>", function()
        view = (view == "all") and "flagged" or "all"
        local picker = action_state.get_current_picker(prompt_bufnr)
        if picker then
          local title = spec.sessions_title(prow.tag, view, state.snap.warnings)
          picker.prompt_title = title
          if picker.prompt_border and picker.prompt_border.change_title then
            picker.prompt_border:change_title(title)
          end
          picker:refresh(session_finder(session_rows(state, prow, view)), { reset_prompt = false })
        end
        return true
      end)

      -- BACK: close, then reopen Screen 1 on the next tick with the cursor on
      -- this program. Reopening from inside the mapping would build a picker
      -- while telescope is still tearing this one down.
      map({ "i", "n" }, "<C-b>", function()
        actions.close(prompt_bufnr)
        vim.schedule(function()
          M.programs(state, prow.tag)
        end)
        return true
      end)
      return true
    end,
  })
  local picker = pickers.new(state.opts, picker_opts)
  picker:find()
  return picker
end

--- Open the picker: fetch the snapshot once, then Screen 1.
--- @param opts table|nil {
---   fetch?: function(source_opts, cb)  -- defaults to source.fetch
---   source_opts?: table
---   flow?: table                        -- controller with :accept(row, cb)
--- } plus telescope options.
function M.open(opts)
  opts = opts or {}
  -- Contract 9 (as in the switcher): capture the invoking tmux client at
  -- OPEN, not at accept, so a jump targets the terminal the user is in.
  local client = exec.tmux_client()
  local controller = opts.flow or flow.new({})
  local fetch = opts.fetch or source.fetch
  fetch(opts.source_opts or {}, function(snap, err)
    if err then
      vim.notify(err.message, err.kind == "timeout" and vim.log.levels.INFO or vim.log.levels.WARN)
      return
    end
    exec.notify_warnings(snap.warnings)
    local state = {
      snap = snap,
      prows = model.program_rows(snap.doc),
      by_id = model.index_rows(snap.rows),
      client = client,
      controller = controller,
      opts = opts,
    }
    M.programs(state, nil)
  end)
end

return M
```

**Step 4: Run to verify it passes**

Run: `bash assets/nvim/test-session-switcher.sh 2>&1 | tail -12`
Expected: `PASS  stallwatch_picker.init unit tests (44 assertions via nvim -l)`, 10 `PASS  ` lines in total, final `all session_switcher lua tests passed`.

**Step 5: Headless smoke test against REAL telescope (synthetic data, not committed)**

```bash
cat > /tmp/sw-smoke.lua <<'EOF'
local ok, err = pcall(function()
  local init = require("user.stallwatch_picker")
  local f = io.open(vim.fn.getcwd() .. "/assets/nvim/stallwatch-picker-fixture.json")
  local doc = vim.json.decode(f:read("*a"), { luanil = { object = true } }); f:close()
  init.open({ fetch = function(_, cb) cb({ doc = doc, tagged = { alpha = {}, beta = {} }, rows = {}, warnings = {} }, nil) end,
              flow = { accept = function() end } })
  vim.wait(300)
  local st = require("telescope.actions.state")
  local b = vim.api.nvim_get_current_buf()
  require("telescope.actions").move_selection_next(b); vim.wait(100)
  io.stdout:write("moved_to=" .. st.get_selected_entry().value.tag .. "\n")
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false); vim.wait(500)
  local p = st.get_current_picker(vim.api.nvim_get_current_buf())
  io.stdout:write("screen2=" .. p.prompt_title .. "\n")
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-f>", true, false, true), "x", false); vim.wait(300)
  io.stdout:write("toggled=" .. p.prompt_title .. "\n")
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-b>", true, false, true), "x", false); vim.wait(500)
  io.stdout:write("back_on=" .. st.get_selected_entry().value.tag .. "\n")
end)
io.stdout:write("ok=" .. tostring(ok) .. " " .. tostring(err) .. "\n"); vim.cmd("qa!")
EOF
timeout 60 nvim --headless --cmd "set rtp^=$PWD/assets/nvim" -c "luafile /tmp/sw-smoke.lua" 2>&1 | tail -5; rm /tmp/sw-smoke.lua
```

Expected (verified on the prototype): `moved_to=beta`, `screen2=beta · flagged`, `toggled=beta · all tagged`, `back_on=beta`, `ok=true nil`.

**Step 6: Re-pin (PASS lines 9 → 10; add the init grep), check, privacy gate, commit**

```bash
git add assets/nvim/lua/user/stallwatch_picker/init.lua assets/nvim/test-stallwatch-picker-init.lua \
  assets/nvim/test-session-switcher.sh flake.nix
nix build .#checks.aarch64-linux.nvim-lua .#checks.aarch64-linux.test-reachability -L --no-link
git commit -m "[NO-JIRA] stall-watch picker: telescope screens, back-nav, digest, jump via switcher (workstation-p8ch)"
```

After this task the `nvim-lua` block should read (counts = your measured ones):

```nix
        [ "$(grep -c '^PASS  ' "$TMPDIR/out.txt")" = 10 ] || {
          echo "GATE FAILURE: expected 10 'PASS  ' lines, got" \
               "$(grep -c '^PASS  ' "$TMPDIR/out.txt")." >&2
          exit 1
        }
        # ... session_switcher.cli 33, discovery + .rpc 69, model 114, spec 659 ...
        # ... stallwatch_picker.model 64, .spec 53, .source 47, .init 44 ...
```

---

### Task 8: `<leader>fp` keymap

**Files:**
- Modify: `assets/nvim/lua/user/telescope.lua` (insert after line 42, the end of the `<leader>fs` mapping)

Context: `<leader>fs` (`telescope.lua:36-42`) is always bound and checks `vim.fn.executable` at press time. The design requires `<leader>fp` to be **registered only if** the read command is executable, so the check runs once at startup through `source.available()` (which honours `STALLWATCH_ITEMS_CMD`). `telescope.lua` has no unit harness (it requires nvim-treesitter/telescope), so the test is a headless probe with the worktree prepended to `runtimepath` (verified: `--cmd "set rtp^=..."` makes the worktree's `user.*` modules win over `~/.config/nvim`).

**Step 1: Write the failing probe**

```bash
probe() { timeout 30 nvim --headless --cmd "set rtp^=$PWD/assets/nvim" \
  -c 'lua io.stdout:write((vim.fn.maparg("<leader>fp","n") ~= "" and "mapped" or "unmapped") .. "\n")' -c 'qa!' 2>&1 | tail -1; }
probe                                          # default path (exists on cloudbox)
STALLWATCH_ITEMS_CMD=/nonexistent/items.sh probe
```

**Step 2: Run it to verify it fails**

Expected before the change: `unmapped` / `unmapped`.

**Step 3: Implement**

```diff
--- a/assets/nvim/lua/user/telescope.lua
+++ b/assets/nvim/lua/user/telescope.lua
@@ -41,4 +41,19 @@
   require("user.session_switcher").open()
 end, { desc = "OC sessions" })
 
+-- Stall-watch programs picker (workstation-p8ch). Registered ONLY when the
+-- private read command is executable on this host: unlike <leader>fs, which is
+-- always bound and explains itself, a host without the stall-watcher gets no
+-- key at all (design: "the keymap is registered only if the command is
+-- executable"). Checked once, at startup; set $STALLWATCH_ITEMS_CMD to point
+-- it elsewhere.
+do
+  local ok, sw_source = pcall(require, "user.stallwatch_picker.source")
+  if ok and sw_source.available() then
+    vim.keymap.set("n", "<leader>fp", function()
+      require("user.stallwatch_picker").open()
+    end, { desc = "Stall-watch programs" })
+  end
+end
+
 require("telescope").load_extension("fzy_native")
\ No newline at end of file
```

**Step 4: Run to verify it passes**

Expected: `mapped` (default path executable) / `unmapped` (override points nowhere).

**Step 5: Privacy gate, then commit**

```bash
git add assets/nvim/lua/user/telescope.lua
git commit -m "[NO-JIRA] nvim: <leader>fp opens the stall-watch picker where the read command exists (workstation-p8ch)"
```

---

### Task 9: Manual acceptance against the live command (nothing from this run is committed)

**Files:** none. Do not paste any output of this task into files, commits, beads or PR text; report pass/fail per line only.

**Step 1: Launch an nvim that uses the branch's Lua and the branch's CLIs, inside tmux**

```bash
OSL=$(nix build .#oc-session-list --no-link --print-out-paths)
OTG=$(nix build .#oc-tags --no-link --print-out-paths)
PATH="$OSL/bin:$OTG/bin:$PATH" nvim --cmd "set rtp^=$PWD/assets/nvim"
```

(The installed `oc-session-list`/`oc-tags` do not have the new flags until home-manager is switched; do not switch it for this.)

**Step 2: Checklist** — tick each:

- [ ] `<leader>fp` opens Screen 1 within ~1–2 s; one row per program in the read command's order; counts match `items.sh --json` (`jq '.programs[] | {tag, n: (.items|length)}'`, viewed in the terminal only).
- [ ] Non-armed / non-enabled programs show `[log-only]` / `[disabled]`; "checked Nm ago" looks right.
- [ ] Moving the cursor updates the previewer: items in contract order, `(new)`/`(changed: …)`/`(stale)` marks, session titles listed.
- [ ] `<C-d>` opens the digest in a bottom split; `:set buftype? modifiable?` → `nofile`, `nomodifiable`; winbar shows the age; `:echo v:oldfiles[0:4]` does not contain the digest path. `:q` closes it.
- [ ] `<CR>` on a program with items → Screen 2 flagged view; each flagged session appears once with its most urgent badge; state glyph and age present for sessions the CLI knows; the previewer shows every item naming the session.
- [ ] `<C-f>` → "all tagged": flagged rows first, then the rest; `<C-f>` again → back to flagged.
- [ ] `<C-b>` → Screen 1 with the cursor on the program you came from (try one that is not the first row).
- [ ] `<CR>` on a session attached in another pane switches the tmux pane; on an unattached one, `oc-auto-attach` opens it; a `[dir gone]` row refuses with the "no longer exists" warning.
- [ ] Degraded mode: relaunch with only `$OSL/bin` prepended (so the installed `oc-tags`, which has no `sessions` subcommand, is used) → picker still opens; ⚠ in both titles; flagged view still works; the all view shows only flagged rows.
- [ ] `STALLWATCH_ITEMS_CMD=/nonexistent nvim ...` → `<leader>fp` unmapped. `STALLWATCH_ITEMS_CMD=/bin/false` → `:lua require("user.stallwatch_picker").open()` notifies an error, no picker.

**Step 3:** If anything fails, fix it in a new commit (with a test where the failure is reproducible synthetically), re-run the relevant task's check, then repeat this checklist.

---

### Task 10: Final verification and push

**Files:** none (beyond fixes).

**Step 1: Whole-flake check, the way CI runs it (never `--no-build`)**

```bash
git status --short          # must be clean: every change committed
nix flake check --keep-going 2>&1 | tail -30
```

Expected: exit 0. If something unrelated to this branch fails, confirm it also fails on `origin/main` in a throwaway worktree before calling it pre-existing (`wt=$(mktemp -d); git worktree add --detach "$wt" origin/main; (cd "$wt" && nix flake check --keep-going); git worktree remove --force "$wt"`).

**Step 2: Privacy gate across the whole branch**

```bash
git diff origin/main...HEAD > /tmp/sw-branch.diff
# Re-run the PRIVACY GATE step 2 with "$priv/added.txt" built from this file:
#   grep '^+' /tmp/sw-branch.diff > "$priv/added.txt"
git log origin/main..HEAD --format='%B'   # commit messages: synthetic names only
rm /tmp/sw-branch.diff
```

**Step 3: Push the branch**

```bash
git push -u origin stallwatch-picker
git status   # "Your branch is up to date with 'origin/stallwatch-picker'"
```

Opening the PR is a separate step: load the `shepherding-pull-requests` skill first and follow it (pre-PR checks, adversarial review, monitoring). Do not remove this worktree while the PR is open.
