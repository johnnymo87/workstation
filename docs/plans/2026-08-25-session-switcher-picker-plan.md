# Session switcher S7: the Telescope picker

**Bead:** `workstation-7w9z`. **Status:** plan, unstarted. **Revision 2** — see
"Correction" below; revision 1's headline finding was wrong.

This supersedes Tasks 9–12 of `2026-07-12-opencode-session-switcher-plan.md`,
which are **materially stale**: they describe a finder built from
`overlay.read()`, `tags`, and a `current_space` argument to `model.build`. None
of those exist. The CLI absorbed that work in S6 — `oc-session-list --fold`
already merges overlay state, resolves roots, unions in attention-worthy rows
outside the recency window, and emits the final order. The 2026-07-12 **design**
doc still holds and is cited throughout; it is the *plan's* task breakdown that
is out of date.

Everything below the picker exists and is tested: `cli.lua` (31 assertions),
`discovery.lua` + `rpc.lua` (69), `model.lua` (87). Missing: the entry point, the
telescope glue, the actions, a keymap. **There is no session switcher UI today**
— every part of this feature is currently invisible.

---

## Ordering: three controls, and a correction

The picker inherits S6 contract 1: **the CLI owns ordering; the picker must never
re-sort.** Telescope has three separate knobs that can break that, and revision 1
of this plan named the wrong one as the danger.

### Correction (recorded, not quietly fixed)

Revision 1 claimed, as a "measured fact", that telescope's default `tiebreak`
reorders equal-score entries by ordinal length and would drag the pinned
`blocked` row to the bottom. **That measurement was an artifact of a broken
probe.** Two mistakes:

- It drove `EntryManager:add_entry` directly with `score = 0`. A real picker
  scores through `Sorter:score` first (`pickers.lua:1441`), and `add_entry`
  coerces a nil score to 0 — so feeding 0 by hand simulates a path that never
  occurs.
- A follow-up probe passed a `cb_add` callback, and `Sorter:score` ends with
  `if cb_add then return cb_add(score, entry) end` (`sorters.lua:152`). It
  returned *the callback's* value, not the score. Every sorter appeared to
  return 0, including for a typed prompt — which should have been the tell,
  since a sorter that cannot discriminate on a typed prompt is obviously broken.

Measured correctly (`cb_add = nil`, a callable `cb_filter`):

| sorter | empty prompt | typed, matching | typed, non-matching |
|---|---|---|---|
| `conf.generic_sorter` | **1** | 0.063 | filtered |
| `conf.file_sorter` | **1** | 0.063 | filtered |
| `sorters.empty()` | 1 | **1** | **1** |

`EntryManager` consults `tiebreak` only when `score < 1`
(`entry_manager.lua:140`). Real sorters return exactly **1** on an empty prompt,
so **tiebreak is never reached in the default view** and arrival order is
preserved. Revision 1's alarm was false.

The lesson is kept rather than deleted: a claim labelled "measured" that does not
reproduce is worse than one labelled "assumed", and this one survived into a
written plan because the probe was never sanity-checked against a case whose
answer was already known.

### The three controls, as they actually are

**1. `sorter` — the live hazard, and it fails silently.**
`pickers.new` defaults to `sorter = opts.sorter or sorters.empty()`
(`pickers.lua:276`), and `sorters.empty()` returns **1 for every entry at every
prompt** (measured above). Omit the sorter and **typing filters nothing** — a
fuzzy finder that does not find. The picker must pass an explicit sorter
(`conf.generic_sorter`), and a manual step must type a query, because no unit
test can observe this.

**2. `sorting_strategy` — inverts what the user sees.**
Default is `"descending"` (`config.lua:144-148`), and `pickers.lua:377+` branches
on it to map index → screen row. Under `descending`, entry 1 renders at the
**bottom**, next to the prompt, and the list reads bottom-up. Internal order is
untouched, but the definition of done says "pinned on top", so this must be a
decision rather than a discovery at verification time. Note the user's other
pickers (`<leader>ff` etc.) all use the default, so bottom-up may be the
*consistent* choice — but pick one, write it in `picker_opts`, and assert it.

**3. `tiebreak` — latent insurance.**
Set `tiebreak = function() return false end` anyway. It costs one line, telescope
documents it as the order-preserving choice, and it is the correct behaviour if a
future sorter ever emits sub-1 ties (which typed prompts already do: 0.063).
Keep the test, but as insurance, not as the guard.

Fuzzy filtering on a **non-empty** prompt is search, not re-sorting, and contract
1 permits it.

---

## The other measured fact: `require("telescope")` fails in CI

`nvim --clean -l` does **not** strip telescope on this machine — the home-manager
wrapper bakes `vim-pack-dir` into the runtimepath ahead of `--clean`'s reset. But
`checks.nvim-lua` builds with `devboxPkgs.neovim`, bare nixpkgs neovim with no
plugin closure:

| interpreter | `require("telescope")` |
|---|---|
| PATH `nvim` (home-manager wrapped) | **succeeds** |
| `nixpkgs#neovim` (what CI uses) | **fails** |

So the obvious test passes locally and fails `nix flake check` — or gets wrapped
in a `pcall` and silently skips forever, which is this repo's most-repeated
failure and the exact shape of the `model.lua` `is_live` incident
(`model.lua:11-23`): a duplicated definition no test could reach, while the suite
printed success with the real function sabotaged.

**Consequence: no module that top-level `require`s telescope may hold logic.**

But "CI cannot load telescope" is *not* the same as "the glue is untestable". The
harness is `loadfile`-based, so `package.preload["telescope.pickers"] = <stub>`
makes glue loadable in CI. That is how the wiring gets covered — see Task 3.

---

## Architecture

Five modules. The split is driven by what CI can load and by where the
concurrency lives.

```
session_switcher/
  spec.lua   PURE. picker options table (sorter, sorting_strategy, tiebreak),
             row -> {display, ordinal}, warning-line composition.
  act.lua    PURE. (row, fresh hit) -> action descriptor; watermark payload or nil.
  flow.lua   PURE-ish, injected seams. Generation tokens and accept
             orchestration. This is where the races live, so it is testable.
  exec.lua   One side effect per function, no branching. pcall'd.
  init.lua   Telescope glue only. Trivial by construction.
```

Revision 1 put the generation token in `init.lua` while also declaring that any
decision reaching `init.lua` has become untestable. That was self-contradictory,
and it left the three contracts with actual concurrency teeth (3, 8, 9) with zero
coverage while the tested layers held the easy pure parts. `flow.lua` fixes it,
following the established local idiom — `cli.lua` and `discovery.lua` both take
injected seams (`opts.system`) for exactly this reason.

---

## Inherited contracts

1. **The CLI owns ordering.** Never re-sort, never re-apply `sort_rank`.
2. **Branch on `row.attached`, never the facet you asked for.** A `pierced` row
   survives `facet="attached"` while detached and pane-less
   (`model.lua:105-109`).
3. **`cli.fetch` has no cancellation**; its callback fires even if the picker
   closed (`cli.lua:46-49`). Generation token required.
4. **Warnings must be surfaced**, and "no sessions" must never look like "the
   tool broke" (`cli.lua:31-42`).
5. **`nodata` renders at least as loudly as `idle`**, distinct from `unknown`.
6. **`dir_missing` is READ-ONLY**: marked before selection, warned before
   opening, and **fires no watermark write**.
7. **Absence is not proof** (`workstation-095u`): sessions outside tmux or in
   nested nvims are invisible to discovery.
8. **Re-resolve on accept (TOCTOU).** Never act on the target embedded in the
   displayed row.
9. **Capture the invoking tmux client at open** (`tmux display -p
   '#{client_name}'`).
10. **Shell out to the `oc-auto-attach` BINARY**, never the Lua `M.open()`.
11. **Clear with the displayed snapshot's `last_event_id`, never "now"**, never
    when it is `nil`, fire-and-forget.

---

## Task 1: `spec.lua` — pure presentation

**Files:** create `.../spec.lua`, `assets/nvim/test-session-switcher-spec.lua`.

**Step 1: failing tests.**

- `M.picker_opts()` pins **all three ordering controls**:
  - `sorter` is present and is **not** `sorters.empty()`'s behaviour — assert a
    sorter is supplied at all (the name/identity is checked, since the object
    cannot be exercised without telescope)
  - `sorting_strategy` equals the chosen value, explicitly
  - `tiebreak` is a function returning **false** — assert by *calling* it
  Name this test for what it prevents: a fuzzy finder that does not filter, and
  a list whose order silently disagrees with the CLI.
- `M.format(row)` → `{ display, ordinal }`:
  - display carries glyph, `model.unread_badge(row)`, title, idle age
  - a `dir_missing` row is **visibly marked** (contract 6)
  - `nodata`'s glyph differs from **both** `idle` and `unknown` — assert all
    three pairwise (contract 5)
  - `ordinal` contains title + directory basename, and **not** the glyph or
    badge (or typing `3` matches unread counts)
- `M.warning_lines(result, err)` distinguishes contract 4's three cases: hard
  `err` (all four `kind`s), success-with-warnings, genuinely empty fleet. Assert
  empty-fleet and failed-fetch produce **different** text.
- A row missing every optional field formats without error.

**Step 2: implement.** May `require` `model`; must not touch `telescope.*` or
`plenary.*` at any level.

**Step 3:** wire the test file into `checks.nvim-lua` and **pin its assertion
count in the same commit**; update the PASS-line pin too.

---

## Task 2: `act.lua` — pure decisions

**Files:** create `.../act.lua`; extend the spec test file.

`M.decide(row, hit)` → descriptor:

| descriptor | when |
|---|---|
| `{ kind = "refuse_dir_missing", directory = ... }` | `row.dir_missing` — checked **first** |
| `{ kind = "focus_here", buffer, tabpage }` | live hit, `own == true` |
| `{ kind = "switch_pane", pane, sock, buffer }` | live hit elsewhere |
| `{ kind = "attach", sid }` | no live hit |

Field is `directory`, matching the row (`oc-session-list-fold.ts` uses
`row.directory`); pin the name in the test.

**Step 1: failing tests.**

- every branch, driven by hit shape
- **contract 2:** a `pierced`, detached, pane-less row yields `attach`, never
  `switch_pane`. Name it for the nil-deref it prevents.
- `dir_missing` beats attachment: a dir-gone **attached** session still refuses.
  The ordering is the point — assert it.
- `M.watermark(row, descriptor)` → payload or nil:
  - nil for `refuse_dir_missing` (contract 6)
  - nil when `row.last_event_id` is nil — assert for **both** `absent` and
    `unavailable` (contract 11)
  - otherwise `{ sid = row.id, last_event_id = row.last_event_id }`, from the
    **displayed row**, never recomputed
  - `focus_here` on an unread row **does** produce a payload

**Step 2: implement.** No side effects, no `vim.system`, no `vim.fn`.

---

## Task 3: `flow.lua` + stub-tested glue

**Files:** create `.../flow.lua`, `.../exec.lua`, `.../init.lua`; extend tests.

**Step 1: `flow.lua`, with injected seams** (`fetch`, `locate`, `now`), so every
race below is testable without telescope:

- a generation counter bumped on open and on every facet toggle
- **the generation is re-checked after EVERY async hop, not just the first.**
  Revision 1 guarded only `cli.fetch`. The pipeline is `cli.fetch →
  discovery.locate → model.build → render`, and `discovery.locate` is *also*
  async with a 1 s deadline (`discovery.lua:107-118`) and no staleness guard of
  its own. A facet toggle landing mid-`locate` otherwise clobbers the finder
  with stale-facet rows.
- **the accept-time re-resolve does NOT share the render token.** Decided
  explicitly: sharing it means reopening the picker mid-accept silently swallows
  the jump, which is worse than acting slightly late. Write this down in the
  module; it is the kind of choice that gets "fixed" in either direction later.
- two pickers open at once is last-opener-wins; acceptable, stated.

**Step 1 tests** (pure, with fake async seams): a stale fetch generation is
dropped; a stale *locate* generation is dropped; accept still completes when the
render generation has moved on.

**Step 2: `exec.lua`** — one side effect per function, **every `vim.system` call
`pcall`'d**. `vim.system` *raises* on a missing binary rather than calling back —
`cli.lua` documents and guards this exact hazard, and revision 1 left the accept
path able to throw after the jump was already wired.

- `focus_here` → set buffer/tabpage here, no tmux round-trip
- `switch_pane` → `tmux switch-client -c <captured client> -t %<pane>` on the
  **re-resolved** pane, then `nvim --server <sock> --remote-expr` (`stdin=false`)
- `attach` → `vim.system({ "oc-auto-attach", sid }, { stdin = false })`
  (contract 10)
- `refuse_dir_missing` → `vim.notify` naming the directory, saying read-only
  because a turn hangs with no error
- **degrade when not in tmux**: `tmux display -p` fails; `switch_pane` must
  notify rather than throw. The keymap guard checks `oc-session-list` only, so
  `oc-auto-attach` may also be absent — handle it.

**Step 3: `init.lua`** — thin. Capture the tmux client at open (contract 9), call
`flow`, merge `spec.picker_opts()` into the table handed to `pickers.new`, wire
`attach_mappings` to `flow`'s accept.

`spec.picker_opts()` cannot be the *whole* options table — `finder`,
`entry_maker`, `sorter` and `attach_mappings` need telescope-typed values that a
pure module cannot construct. `init.lua` merges. **That merge is exactly where an
option can be silently dropped or land in the wrong argument position**, and no
pure test can see it.

**Step 4: stub test for the merge.** With
`package.preload["telescope.pickers"]` (and friends) set to stubs that record
their arguments, `loadfile` `init.lua` in the harness and assert:
`pickers.new` received the tiebreak, the sorter and the `sorting_strategy` from
`spec`. This validates wiring against our model of telescope's API, not against
telescope — limited, and worth saying so in the test — but it closes the only
gap where a correct `spec.lua` still produces a wrong picker.

**Step 5: facet toggles** — `all` / `attached` / `detached` only. The old plan's
`lgtm only` / `all spaces` need a `space` concept that does not exist:
out of scope.

**Step 6: keymap** in `telescope.lua`, guarded for cross-host degrade:

```lua
vim.keymap.set("n", "<leader>fs", function()
  if vim.fn.executable("oc-session-list") == 0 then
    vim.notify("session switcher unavailable on this host", vim.log.levels.WARN)
    return
  end
  require("user.session_switcher").open()
end, { desc = "OC sessions" })
```

`<leader>fs` is free. `telescope.lua` already calls `setup{}` — do not call it
again.

**Warnings must be visible**, not just emitted: `vim.notify` under an open
telescope float is easy to miss, and the unread ordering decision was accepted on
the premise that warnings are actually seen. Render them in the prompt title or
as a pinned first line; decide in Task 1's `warning_lines` and verify in Task 5.

---

## Task 4: clear-on-jump

**Files:** `.../exec.lua`.

Discharges the deferral in `2026-08-19-session-switcher-unread-plan.md` Task 11.

`POST http://127.0.0.1:<port>/sessions/<url-encoded sid>/read` with
`{"last_event_id": N}`, fire-and-forget via `vim.system` + `curl`,
`stdin = false`, never awaited, **`pcall`'d** (curl may be absent). Port from
`$PIGEON_DAEMON_PORT`, default **4731** (`packages/daemon/src/config.ts`
`DEFAULT_PORT`, verified against the running daemon). On a host with no pigeon
daemon this is a refused connection that nobody waits for — acceptable.

The payload comes from `act.watermark` and is already guarded, so this function
decides nothing: **handed nil, it does nothing.** That safety property lives in
the tested layer on purpose.

The daemon-side clamp (`workstation-cqit`, pigeon #128) rejects an id above the
session's own max and logs it. **Verify the clamp is live before this ships** —
merged and pulled, but it only takes effect on the daemon's next restart.

---

## PR boundary

**Tasks 1–4 land as one PR.** Bead `workstation-7w9z` is explicit: *"a visible
badge that jumping never clears can only be created HERE. A picker that renders
the badge without clearing it is incomplete, not a first step."* Task 3 wires the
keymap and renders badges; Task 4 clears them. Shipping Task 3 alone would create
precisely the forbidden state. If the work must be split, the **keymap moves to
Task 4** so nothing is reachable until clearing exists.

---

## Task 5: manual verification — the real gate

The tests cannot load telescope, so this is where the picker is actually proven.
It must be executed by hand on cloudbox and **its output recorded on the bead**,
not deferred.

1. `<leader>fs` opens and lists real sessions.
2. **Order matches the CLI exactly** — diff the picker's id order against
   `oc-session-list --fold`. The end-to-end proof for contract 1.
3. A blocked/errored session is pinned, **with a long title**, and appears where
   `sorting_strategy` says it should.
4. **Type a query: the list filters.** Then type a directory basename and confirm
   it matches. This is the only gate that catches a missing sorter, which no unit
   test can see.
5. Unread badges render; `·` and `?` are distinguishable in practice.
6. Jump to a session attached in **this** nvim → focuses, no tmux round-trip.
7. Jump to one in another pane → the **invoking** client moves.
8. Select a detached session → `oc-auto-attach` runs, it opens.
9. Select a `dir_missing` row → warned, read-only, and **no `[read]` line appears
   in the daemon log** (contract 6, checked at the daemon, not inferred).
10. Jump to an unread session → badge clears on next open.
11. Point `OPENCODE_ROUTING_DB` at nothing → rows render `?` **and a warning is
    visible**, not a silent empty picker.
12. Facet toggle across all three; a pierced blocked row still appears under
    `attached`, and selecting it **attaches** rather than erroring (contract 2,
    end to end).
13. Run outside tmux → degrades with a notification, does not throw.

Latency note so nobody invents an optimisation: the accept-time re-resolve is a
**full re-scan**. `discovery.locate` fans out to every socket and each nvim
reports all its sessions; it cannot be scoped to one sid, and scoping
`opts.sockets` to the stale hit's socket would miss a session that moved. Worst
case adds ~1 s (async, UI not blocked).

---

## Definition of done

- `<leader>fs` lists sessions with glyphs, badges and idle ages in the CLI's
  order, verified by diff.
- Typing filters the list.
- All three jump branches work; `dir_missing` refuses and writes no watermark.
- Jumping clears the badge.
- `checks.nvim-lua` runs the new tests with pinned counts;
  `checks.test-reachability` passes.
- The manual matrix is executed and recorded on `workstation-7w9z`.

## Out of scope

- **The previewer / transcript tail** (old Task 11) — needs a nonexistent
  `oc-session-list --tail`. File separately. The picker is useful without it.
- **`lgtm only` / `all spaces` facets** — no `space` concept in `model.build`.
- **Re-rooting a `dir_missing` session** (old Option B, already deferred).
- **`workstation-095u`** — undiscoverable non-tmux/nested sessions. Pre-existing;
  contract 7 requires only that the picker not *claim* otherwise, which is
  presentational: the empty/detached rendering must not offer a fresh attach as
  though nothing were running.
