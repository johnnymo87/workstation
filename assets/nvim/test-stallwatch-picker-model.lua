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
