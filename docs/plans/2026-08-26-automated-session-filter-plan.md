# Hide Automated Sessions From The Picker — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Hide lgtm auto-review sessions from the nvim telescope session-switcher, so the picker shows work the human cares about instead of 62% machine noise.

**Architecture:** The `oc-session-list` CLI gains a third read-only builder (`buildOriginMap`) that annotates every row with `origin` and `automated`, reading pigeon's `session_origin` table from the same SQLite file it already opens. The nvim picker drops `automated` rows in `model.build` and reports how many it dropped in the prompt title. No CLI behaviour changes; annotation only.

**Tech Stack:** TypeScript on bun (`bun:sqlite`), Lua for Neovim, Nix flake checks with pinned assertion counts.

**Design doc:** `docs/plans/2026-08-26-automated-session-filter-design.md` (PR #416). Read it before starting — it explains *why* the predicate is an allowlist and why the filter must sit above the pierce.

---

## Before you start

**Worktree:** `/home/dev/projects/workstation/.worktrees/auto-filter`, branch `feat/filter-automated-sessions`. Work only here. Never run `git pull`, `stash`, `reset`, `restore`, `clean`, or `checkout <ref>` in `/home/dev/projects/workstation` — it is shared by many agents.

**Two test suites, both gated by pinned counts:**

```bash
# TypeScript (from assets/opencode/plugins)
bun test test/oc-session-list.spec.ts

# Lua (from repo root)
bash assets/nvim/test-session-switcher.sh
```

**The pins will fail you on purpose.** `flake.nix` asserts exact assertion counts: bun `expected_expects=262`, and Lua stages cli 31 / discovery 69 / model 87 / spec 407 with exactly 6 `PASS  ` lines. Adding tests changes these numbers, and the gate fails until you update them. That is the intended workflow — never delete a test to make a count match.

**Never `| tail` or `| head` a test command.** It masks the exit code, and a failed patch followed by a chained test prints green on unpatched code.

---

## Task 1: `buildOriginMap` and the allowlist

**Files:**
- Modify: `assets/opencode/plugins/oc-session-list-state.ts`
- Test: `assets/opencode/plugins/test/oc-session-list.spec.ts`

Mirror `buildUnreadMap` exactly: same `existsSync` guard, same `{ readonly: true }` open, same `sqlite_master` existence check, same `onWarn` on every degraded path, same `return null` to mean "unavailable". **No injection seam** — the file already explains that an unused seam is untested surface free to drift, so tests drive the real builder against a real temp SQLite DB.

**Step 1: Write the failing tests**

Add a new `describe` block to `test/oc-session-list.spec.ts`. Follow the existing `buildUnreadMap & unread counts (Task 9)` block for how it makes a temp DB.

```ts
describe("buildOriginMap & the automated allowlist", () => {
  function makeOriginDb(rows: Array<{ sid: string; origin: string; policy?: string }>): string {
    const dir = mkdtempSync(join(tmpdir(), "origin-test-"));
    const path = join(dir, "pigeon-daemon.db");
    const db = new Database(path);
    db.run(`CREATE TABLE session_origin (
      session_id TEXT PRIMARY KEY, origin TEXT NOT NULL, notify_policy TEXT NOT NULL,
      source TEXT NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
      declared_at INTEGER)`);
    for (const r of rows) {
      db.run(
        `INSERT INTO session_origin VALUES (?, ?, ?, 'declared', 0, 0, 0)`,
        [r.sid, r.origin, r.policy ?? "errors-only"],
      );
    }
    db.close();
    return path;
  }

  it("marks an lgtm-origin session automated", () => {
    const p = makeOriginDb([{ sid: "ses_a", origin: "lgtm" }]);
    const m = buildOriginMap(p, [{ id: "ses_a", root_id: "ses_a" } as any]);
    expect(m).not.toBeNull();
    expect(m!.get("ses_a")).toBe("lgtm");
  });

  it("does NOT mark an unknown origin automated, and warns exactly once for it", () => {
    const p = makeOriginDb([
      { sid: "ses_a", origin: "pr-triage" },
      { sid: "ses_b", origin: "pr-triage" },
      { sid: "ses_c", origin: "pr-triage" },
    ]);
    const warnings: string[] = [];
    const m = buildOriginMap(p, [], (w) => warnings.push(w));
    expect(m!.get("ses_a")).toBe("pr-triage");
    expect(isAutomatedOrigin("pr-triage")).toBe(false);
    const tripwires = warnings.filter((w) => w.includes("pr-triage"));
    expect(tripwires.length).toBe(1);
  });

  it("does NOT warn for an origin in KNOWN_VISIBLE_ORIGINS", () => {
    // Guards the tripwire against becoming chronic noise. Seed the set for the
    // test rather than relying on it being non-empty in production.
    const warnings: string[] = [];
    expect(shouldTripwire("lgtm", warnings)).toBe(false);
  });

  it("notify_policy does NOT affect the verdict", () => {
    for (const policy of ["all", "errors-only", "none"]) {
      const p = makeOriginDb([{ sid: "ses_a", origin: "lgtm", policy }]);
      const m = buildOriginMap(p, []);
      expect(isAutomatedOrigin(m!.get("ses_a"))).toBe(true);
    }
  });

  it("returns null and warns when the table is absent", () => {
    const dir = mkdtempSync(join(tmpdir(), "origin-test-"));
    const path = join(dir, "pigeon-daemon.db");
    new Database(path).close();
    const warnings: string[] = [];
    expect(buildOriginMap(path, [], (w) => warnings.push(w))).toBeNull();
    expect(warnings.some((w) => w.includes("session_origin"))).toBe(true);
  });

  it("returns null and warns when the db is missing", () => {
    const warnings: string[] = [];
    expect(buildOriginMap("/nonexistent/x.db", [], (w) => warnings.push(w))).toBeNull();
    expect(warnings.length).toBeGreaterThan(0);
  });
});
```

**Step 2: Run to verify they fail**

```bash
cd assets/opencode/plugins && bun test test/oc-session-list.spec.ts
```
Expected: FAIL — `buildOriginMap is not defined`.

**Step 3: Implement**

In `oc-session-list-state.ts`, near the other builders:

```ts
/**
 * Origins whose sessions are hidden from the picker.
 *
 * An ALLOWLIST, deliberately, not "any row in session_origin". `origin` is
 * free-form TEXT in pigeon with no enum, and `notify_policy: "all"` is a legal
 * value meaning "show every event" -- so hiding on row presence is broader than
 * the daemon's own semantics. With no reveal mechanism in the picker, a false
 * hide is unrecoverable while a false show is noise that announces itself via
 * the tripwire below. Narrow beats extensible here.
 *
 * The literal "lgtm" is written by lgtm/src/dispatch.ts. Renaming it there
 * silently un-hides every review session -- which the tripwire will catch.
 */
export const HIDDEN_ORIGINS: ReadonlySet<string> = new Set(["lgtm"]);

/**
 * Origins that are known and deliberately VISIBLE. Exists so the tripwire has
 * an acknowledgement channel: without it, the first automation someone decides
 * should stay visible would warn on every picker open forever, and a chronic
 * pin trains the eye to ignore it.
 */
export const KNOWN_VISIBLE_ORIGINS: ReadonlySet<string> = new Set([]);

export type OriginMap = Map<string, string>;

export function isAutomatedOrigin(origin: string | null | undefined): boolean {
  return typeof origin === "string" && HIDDEN_ORIGINS.has(origin);
}

export function buildOriginMap(
  routingDbPath: string,
  _baseRows: SessionRow[],
  onWarn?: (msg: string) => void,
): OriginMap | null {
  if (!routingDbPath || !existsSync(routingDbPath)) {
    onWarn?.(
      `routing db not found at ${routingDbPath || "<unset>"} -- automated-session ` +
        `filtering unavailable, ALL sessions will be listed`,
    );
    return null;
  }
  let db: Database | undefined;
  try {
    db = new Database(routingDbPath, { readonly: true });
    const tableExists = db
      .query(`SELECT 1 FROM sqlite_master WHERE type='table' AND name='session_origin'`)
      .get();
    if (!tableExists) {
      db.close();
      onWarn?.(
        `routing db ${routingDbPath} has no session_origin table -- automated-session ` +
          `filtering unavailable, ALL sessions will be listed`,
      );
      return null;
    }
    const rows = db
      .query<{ session_id: string; origin: string }, []>(
        `SELECT session_id, origin FROM session_origin;`,
      )
      .all();
    db.close();

    const map: OriginMap = new Map();
    const unknown = new Set<string>();
    for (const r of rows) {
      if (!r.session_id || typeof r.origin !== "string") continue;
      map.set(r.session_id, r.origin);
      if (!HIDDEN_ORIGINS.has(r.origin) && !KNOWN_VISIBLE_ORIGINS.has(r.origin)) {
        unknown.add(r.origin);
      }
    }
    // Dedup per DISTINCT value, not per row: there are ~700 rows.
    for (const o of unknown) {
      onWarn?.(
        `unrecognised session origin ${JSON.stringify(o)} -- these sessions are ` +
          `NOT hidden. Add it to HIDDEN_ORIGINS or KNOWN_VISIBLE_ORIGINS in ` +
          `oc-session-list-state.ts to silence this.`,
      );
    }
    return map;
  } catch (e) {
    try { db?.close(); } catch { /* already closed */ }
    onWarn?.(
      `failed reading session_origin from ${routingDbPath}: ${String(e)} -- ` +
        `automated-session filtering unavailable, ALL sessions will be listed`,
    );
    return null;
  }
}
```

Add a `shouldTripwire` export only if the test above needs it; prefer deleting that test case and asserting through `buildOriginMap` with a seeded `KNOWN_VISIBLE_ORIGINS` if exporting a helper feels like test-only surface.

**Step 4: Run to verify pass**

```bash
cd assets/opencode/plugins && bun test test/oc-session-list.spec.ts
```
Expected: PASS, `0 fail`.

**Step 5: Commit**

```bash
git add assets/opencode/plugins/oc-session-list-state.ts assets/opencode/plugins/test/oc-session-list.spec.ts
git commit -m "feat(session-list): read session_origin into an allowlist-backed origin map"
```

---

## Task 2: Annotate rows, after the union

**Files:**
- Modify: `assets/opencode/plugins/oc-session-list-state.ts` (type at ~:8-31, builders at ~:457-462, merges at ~:529 and ~:564)
- Test: `assets/opencode/plugins/test/oc-session-list.spec.ts`

**The placement is load-bearing.** `buildOriginMap` must be called where `buildUnreadMap` is called — *after* the union block that appends attention rows from outside the recency window. Called earlier, unioned rows arrive unannotated, `automated` is undefined, and Lua keeps them: a silent under-hide in exactly the path that matters most.

**Step 1: Write the failing tests**

```ts
it("annotates origin and automated on every row", async () => {
  // ... build a temp routing db with ses_a origin 'lgtm', and a base db with
  // ses_a and ses_b, then call queryWithState
  const rows = await queryWithState(/* ... */);
  const a = rows.find((r) => r.id === "ses_a")!;
  const b = rows.find((r) => r.id === "ses_b")!;
  expect(a.origin).toBe("lgtm");
  expect(a.automated).toBe(true);
  expect(b.origin).toBeNull();
  expect(b.automated).toBe(false);
});

it("keys on root_id, not id: a child of an lgtm root is automated", async () => {
  // Production has ZERO child origin rows, so a realistic fixture would never
  // catch an id-vs-root_id mutation. Seed one deliberately.
  const rows = await queryWithState(/* child ses_c with root_id ses_a */);
  expect(rows.find((r) => r.id === "ses_c")!.automated).toBe(true);
});

it("annotates rows that arrive via the UNION path", async () => {
  // An attention row whose root is outside the recency window. If buildOriginMap
  // ever moves above the union block, this row loses its annotation and is
  // silently kept.
  const rows = await queryWithState(/* unionLookup returning an lgtm root */);
  expect(rows.find((r) => r.id === "ses_union")!.automated).toBe(true);
});

it("degrades to automated=false for every row when the origin map is unavailable", async () => {
  const rows = await queryWithState(/* routingDbPath pointing at nothing */);
  expect(rows.every((r) => r.automated === false)).toBe(true);
  expect(rows.every((r) => r.origin === null)).toBe(true);
});
```

**Step 2: Run to verify they fail.** Expected: FAIL — `origin`/`automated` undefined.

**Step 3: Implement**

Extend the interface:

```ts
  unread: number | null;
  unread_state: "counted" | "absent" | "unavailable";
  last_event_id: number | null;
  /**
   * Provenance from pigeon's session_origin, or null when there is no row or
   * the table is unreadable. Carried purely for debuggability: hiding is
   * invisible by nature, so this is the only way to answer "why isn't X in my
   * list" without a manual SQL query.
   */
  origin: string | null;
  /** True when `origin` is in HIDDEN_ORIGINS. False on any degraded path. */
  automated: boolean;
```

Call the builder beside the others (note the comment — it is the guard against a future refactor):

```ts
  // MUST run here, AFTER the union block above, over post-union baseRows.
  // A row appended by the union that arrives unannotated is kept by the picker,
  // which is a silent under-hide in the attention path.
  const originMap = buildOriginMap(options.routingDbPath ?? "", baseRows, options.onWarn);
```

Then in **both** merge branches (the `st`-present one and the no-state one), alongside the existing `unread_state`:

```ts
        origin: originMap?.get(row.root_id) ?? null,
        automated: isAutomatedOrigin(originMap?.get(row.root_id)),
```

**Step 4: Run to verify pass.** Also run `node_modules/.bin/tsc --noEmit` — two new required fields will break every existing row fixture literal, and fixing them is the point: it is compile-time proof that no construction path forgets them.

**Step 5: Commit**

```bash
git add assets/opencode/plugins/
git commit -m "feat(session-list): annotate rows with origin and automated"
```

---

## Task 3: Bump the bun pin

**Files:** Modify `flake.nix` (`expected_expects=262`)

**Step 1:** Run `bun test test/oc-session-list.spec.ts` and read the actual `expect() calls` number from the output.

**Step 2:** Replace `262` in `flake.nix` with that number.

**Step 3:** Verify the gate:

```bash
nix build .#checks.aarch64-linux.plugin-bun --no-link
nix build .#checks.aarch64-linux.plugin-tsc --no-link
```
Expected: both succeed.

**Step 4: Commit**

```bash
git add flake.nix
git commit -m "test(flake): bump plugin-bun expect pin for origin-map coverage"
```

---

## Task 4: Drop automated rows above the pierce, and count them

**Files:**
- Modify: `assets/nvim/lua/user/session_switcher/model.lua`
- Test: `assets/nvim/test-session-switcher-model.lua`

**The ordering is the whole task.** `M.build`'s keep-chain opens with `if pierces then keep = true`. Adding the automated check as another `elseif` lets an errored automated row pierce through and appear, silently contradicting the user's explicit "no exception" decision.

**Step 1: Write the failing tests**

```lua
-- automated rows are dropped
local rows = { mk({ id = "a", automated = true }), mk({ id = "b" }) }
local out, hidden = model.build(rows, {}, {})
eq(1, #out, "automated row dropped")
eq("b", out[1].id, "the human row survives")
eq(1, hidden, "hidden count reports the drop")

-- THE ORDERING TEST: an errored automated row must NOT pierce through
local rows2 = { mk({ id = "a", automated = true, effective_state = "error" }) }
local out2, hidden2 = model.build(rows2, {}, {})
eq(0, #out2, "automated+error is dropped, NOT resurrected by the pierce")
eq(1, hidden2, "and it counts as hidden")

-- absent/false keeps the row (the degraded path must show everything)
eq(1, #model.build({ mk({ id = "a" }) }, {}, {}), "missing automated field keeps row")
eq(1, #model.build({ mk({ id = "a", automated = false }) }, {}, {}), "false keeps row")

-- the count is facet-independent
local mixed = { mk({ id = "a", automated = true }), mk({ id = "b" }) }
local _, h_all = model.build(mixed, {}, { facet = "all" })
local _, h_att = model.build(mixed, {}, { facet = "attached" })
local _, h_det = model.build(mixed, {}, { facet = "detached" })
eq(h_all, h_att, "hidden count identical across facets")
eq(h_all, h_det, "hidden count identical across facets")

-- order is preserved
local ordered = { mk({ id = "x" }), mk({ id = "auto", automated = true }), mk({ id = "y" }) }
local out3 = model.build(ordered, {}, {})
eq("x", out3[1].id); eq("y", out3[2].id)
```

**Step 2: Run to verify they fail**

```bash
bash assets/nvim/test-session-switcher.sh
```
Expected: FAIL on the automated assertions.

**Step 3: Implement**

In `M.build`, add a counter before the loop and an early drop **above** the `is_blocked`/`pierces` computation:

```lua
  local out = {}
  local hidden = 0

  for _, row in ipairs(rows) do
    if type(row) == "table" and type(row.id) == "string" and row.id ~= "" then
      -- ABOVE THE PIERCE, DELIBERATELY.
      --
      -- The keep-chain below starts with `if pierces then keep = true`, so an
      -- errored automated row placed after it would be resurrected into the
      -- list. The user chose hard exclusion with NO exception for errored or
      -- blocked sessions; this ordering is what enforces that choice.
      --
      -- Only `automated == true` drops. A missing or false field keeps the row,
      -- so an unreadable session_origin shows everything rather than hiding it.
      if row.automated == true then
        hidden = hidden + 1
        goto continue
      end
      -- ... existing body unchanged ...
    end
    ::continue::
  end

  return out, hidden
```

If `goto` reads badly against the file's style, invert to `if row.automated == true then hidden = hidden + 1 else ... end` — but keep the check textually above the pierce either way.

**Step 4: Run to verify pass.** Note the new model assertion count printed in the `PASS  session_switcher.model` line.

**Step 5: Commit**

```bash
git add assets/nvim/lua/user/session_switcher/model.lua assets/nvim/test-session-switcher-model.lua
git commit -m "feat(session-switcher): drop automated rows above the pierce"
```

---

## Task 5: Show the hidden count in the prompt title

**Files:**
- Modify: `assets/nvim/lua/user/session_switcher/spec.lua`
- Test: `assets/nvim/test-session-switcher-spec.lua`

**Step 1: Write the failing tests**

```lua
eq("Sessions (all)", spec.prompt_title("all", {}, 0), "no suffix at zero")
eq("Sessions (all) · 31 hidden", spec.prompt_title("all", {}, 31), "count shown")
eq("Sessions (all) · 31 hidden [⚠ 2]", spec.prompt_title("all", { "w", "x" }, 31),
   "count precedes the warning marker")
eq("Sessions (all)", spec.prompt_title("all", {}, nil), "nil count is not an error")
eq("Sessions (all)", spec.prompt_title("all", {}, "banana"), "non-number ignored")
eq("Sessions (all)", spec.prompt_title("all", {}, -3), "negative ignored")
```

**Step 2: Run to verify they fail.**

**Step 3: Implement**

```lua
--- @param facet string|nil
--- @param warning_lines string[]|nil
--- @param hidden integer|nil Count of automated rows dropped from the FETCHED
---        WINDOW -- not a fleet-wide total. Its job is attribution: it explains
---        why a short list is short, so an empty picker is never mistaken for a
---        broken tool. Wording it as a total would make it a lie.
--- @return string
function M.prompt_title(facet, warning_lines, hidden)
  local f = (facet and facet ~= "" and facet ~= vim.NIL) and tostring(facet) or "all"
  local base = string.format("Sessions (%s)", f)
  if type(hidden) == "number" and hidden > 0 then
    base = string.format("%s · %d hidden", base, hidden)
  end
  if type(warning_lines) == "table" and #warning_lines > 0 then
    return string.format("%s [⚠ %d]", base, #warning_lines)
  end
  return base
end
```

**Step 4: Run to verify pass.**

**Step 5: Commit**

```bash
git add assets/nvim/lua/user/session_switcher/spec.lua assets/nvim/test-session-switcher-spec.lua
git commit -m "feat(session-switcher): report hidden count in the prompt title"
```

---

## Task 6: Thread the count, and raise the fetch limit

**Files:**
- Modify: `assets/nvim/lua/user/session_switcher/flow.lua` (~:104), `init.lua` (both title sites, ~:69 and ~:144)
- Test: `assets/nvim/test-session-switcher-spec.lua`

**Two traps here.**

The count must be a **fourth callback argument**, never a field on the rows table. A non-integer key flips `vim.islist` false and trips the top-level-list guard in `cli.lua`.

**Both** title sites must consume it. Missing the `cycle_facet` one leaves a stale count after every facet change.

**Step 1: Write the failing tests**

```lua
-- flow passes the count through as a 4th arg
local got
controller:refresh("all", function(rows, result, err, hidden) got = hidden end)
eq(2, got, "flow threads model.build's hidden count to the callback")

-- the rows table stays a list
local rows_arg
controller:refresh("all", function(r) rows_arg = r end)
eq(true, vim.islist(rows_arg), "rows table is still a list (cli.lua guard)")

-- the picker asks for a deeper window than the CLI default of 50
local argv = captured_fetch_opts
eq(200, argv.limit, "picker requests limit=200")
```

**Step 2: Run to verify they fail.**

**Step 3: Implement**

`flow.lua` — capture the second return and pass it on. The error path passes `nil`:

```lua
      local built_rows, hidden = self.build(rows, hits, { facet = facet })
      cb(built_rows, result, nil, hidden)
```

`init.lua` — set the limit without mutating the caller's table:

```lua
  -- Deeper window than the CLI default of 50, because the automated filter runs
  -- AFTER the limit: at ~62% automated, 50 fetched leaves ~19 rows, and the
  -- longest consecutive run of automated roots is already 14 -- a batch filling
  -- the window would render an empty picker. Cost is flat (123ms at 50, 123ms at
  -- 200), and scoping it here rather than to the CLI default leaves ad-hoc CLI
  -- use unchanged.
  local flow_opts = vim.tbl_extend("force", opts, {
    fetch_opts = vim.tbl_extend("force", { limit = 200 }, opts.fetch_opts or {}),
  })
  local controller = opts.flow or flow.new(flow_opts)
```

Then both callbacks take `hidden` and pass it to `spec.prompt_title`:

```lua
  controller:refresh(current_facet, function(rows, result, err, hidden)
    ...
    local prompt_title = spec.prompt_title(current_facet, warning_lines, hidden)
```

```lua
          controller:refresh(current_facet, function(new_rows, new_result, new_err, new_hidden)
            ...
            local new_title = spec.prompt_title(current_facet, new_warnings, new_hidden)
```

**Step 4: Run to verify pass.**

**Step 5: Commit**

```bash
git add assets/nvim/lua/user/session_switcher/
git commit -m "feat(session-switcher): thread hidden count and deepen the fetch window"
```

---

## Task 7: The empty-window case

**Files:** Test only — `assets/nvim/test-session-switcher-spec.lua`

An all-automated window must yield an empty list, the count in the title, and **not** the "No open sessions found" line — because `spec.warning_lines` receives the raw pre-filter result. That currently holds as a property of call order. Pin it so a later cleanup that passes filtered rows cannot quietly invert it.

```lua
-- 200 fetched, all automated: empty picker, count explains why, and NOT the
-- "no sessions" message (which would be a lie -- there are sessions, they are
-- hidden).
local result = { rows = all_automated_rows }
eq(0, #built)
eq("Sessions (all) · 200 hidden", spec.prompt_title("all", spec.warning_lines(result, nil), 200))
eq(0, #spec.warning_lines(result, nil), "raw result is non-empty, so no 'No open sessions found'")
```

Run, then commit:

```bash
git add assets/nvim/test-session-switcher-spec.lua
git commit -m "test(session-switcher): pin the all-automated empty-window behaviour"
```

---

## Task 8: Bump the Lua pins

**Files:** Modify `flake.nix` (model `87`, spec `407`)

**Step 1:** Run `bash assets/nvim/test-session-switcher.sh` and read the actual counts from the `PASS  session_switcher.model` and `PASS  session_switcher.spec` lines.

**Step 2:** Update both numbers in `flake.nix`. Leave cli `31` and discovery `69` alone unless they genuinely changed.

**Step 3:** Verify:

```bash
nix build .#checks.aarch64-linux.nvim-lua --no-link
nix build .#checks.aarch64-linux.test-reachability --no-link
```

**Step 4: Commit**

```bash
git add flake.nix
git commit -m "test(flake): bump lua model and spec pins"
```

---

## Task 9: Cross-repo comments and the runbook line

**Files:**
- Modify: `/home/dev/projects/pigeon/packages/daemon/src/storage/session-origin-schema.ts` (separate PR — pigeon has no auto-merge)
- Modify: `/home/dev/projects/lgtm/src/dispatch.ts` (separate PR)
- Modify: `assets/opencode/plugins/oc-session-list-state.ts` (runbook line, this PR)

pigeon, on the table comment:

```
 * SECOND CONSUMER (workstation): the nvim session-switcher picker reads this
 * table to hide automated sessions. That suppression is NOT TTL-bounded, unlike
 * the notify-policy quiet window -- it keys on `origin` alone. Anyone changing
 * the quiet invariant should know this reader exists and does not honour it.
```

lgtm, at the `origin: "lgtm"` write:

```
// The literal "lgtm" is load-bearing beyond pigeon: workstation's session
// switcher hides sessions whose origin is in its HIDDEN_ORIGINS allowlist.
// Renaming this string un-hides every review session in that picker (its
// tripwire will warn, but the sessions reappear until the allowlist is updated).
```

workstation, next to `HIDDEN_ORIGINS`:

```
// Debugging "why isn't session X in my picker?": check the `origin` field in
// `oc-session-list --fold` output, or GET /session-origin?session_id=<sid>
// against the pigeon daemon. To un-hide a session you have adopted, delete its
// provenance: DELETE /session-origin?session_id=<sid>.
```

Commit the workstation one here; the other two are separate PRs in their own repos, and **pigeon does not support auto-merge** — merge it manually and remember `workstation-gcah` (the nightly restarts pigeon but never pulls, so the deploy root needs a manual `git pull --ff-only`).

---

## Task 10: Mutation testing

**Predict the survivors before you run each one.** A mutation you expected to be caught but which survives is a hole in the tests, not a curiosity.

| # | Mutation | Must be caught by |
|---|---|---|
| 1 | `HIDDEN_ORIGINS.has(origin)` → `origin != null` (row presence) | a test with a non-lgtm origin that must stay visible |
| 2 | Delete the `row.automated == true` drop in `model.build` | the basic drop test |
| 3 | Move the drop *below* the pierce | the `automated ∧ error` test — **this is the defect adversarial review caught** |
| 4 | `originMap?.get(row.root_id)` → `.get(row.id)` | the child-keyed fixture (production has zero child origin rows, so only a seeded fixture catches it) |
| 5 | Degrade path returns `automated: true` instead of `false` | the unavailable-db test |
| 6 | Move `buildOriginMap` above the union block | the union-path fixture |
| 7 | Tripwire warns per row instead of per distinct value | the "exactly once" assertion |
| 8 | Drop `hidden` from the `cycle_facet` callback | the stale-count test |

Record which survived and why in the bead.

---

## Task 11: Measure, then verify by hand

**Step 1:** Measure nvim-side decode cost at the new limit — CLI wall time was measured flat, but `vim.json.decode` runs on the main loop on every picker open and every facet cycle.

```vim
:lua local t=vim.loop.hrtime(); require("user.session_switcher").open(); print((vim.loop.hrtime()-t)/1e6 .. "ms")
```

If it exceeds ~150 ms, say so rather than shipping it quietly.

**Step 2:** Manual checks, which no test can reach:

1. `<leader>fs` — lgtm sessions are gone, and the title reads `Sessions (all) · N hidden`.
2. The `N` matches: compare against `oc-session-list --fold --limit 200 | jq '[.[]|select(.automated)]|length'`.
3. `<C-f>` cycles facets and the count **does not change** and does not go stale.
4. Typing still filters (the sorter is easy to break and no unit test can see it).
5. Point `OPENCODE_ROUTING_DB` at a nonexistent path: **everything shows**, with a visible warning. This is the failure direction — verify it directly rather than trusting it.

**Step 3:** Update the bead and open the PR.

---

## Landing

```bash
gh pr create --title "Hide lgtm auto-review sessions from the session-switcher picker" --body-file <file>
gh pr merge <n> --squash --auto
```

Then run `adversarial-reviewer-fable` **on the real diff** — that is where it earns its keep, and both design rounds explicitly deferred to it.

Verify the merge by content on `origin/main` before removing the worktree or any branch. A PR showing `OPEN` in your own output is a stop signal, not a slow merge.
