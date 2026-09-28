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

  -- Hardening: vim.NIL and malformed inputs tolerated.
  check(spec.program_display(nil, NOW) == "(unnamed) · 0 open", "nil prow -> defaults safely")
  check(spec.program_display(vim.NIL, NOW) == "(unnamed) · 0 open", "vim.NIL prow -> defaults safely")
  check(spec.program_display({ tag = vim.NIL, counts = vim.NIL, armed = vim.NIL, enabled = vim.NIL, last_tick_ms = vim.NIL }, NOW)
    == "(unnamed) · 0 open", "vim.NIL fields render blank, never crash")
  check(spec.program_display({ tag = "gamma", armed = "false", enabled = 0 }, NOW) == "gamma · 0 open",
    "non-boolean falsey armed/enabled -> no markers")
  check(spec.program_display({ tag = "delta", armed = false, enabled = false }, NOW) == "delta · 0 open [log-only] [disabled]",
    "explicit false -> markers")
  check(spec.program_ordinal(nil) == "", "nil prow ordinal -> empty string")
  check(spec.program_ordinal(vim.NIL) == "", "vim.NIL prow ordinal -> empty string")
  check(spec.program_ordinal({ tag = vim.NIL }) == "", "vim.NIL tag ordinal -> empty string")
  check(spec.program_ordinal({ tag = 123 }) == "", "non-string tag ordinal -> empty string")

  -- Multi-line tag has newlines collapsed to a single space.
  local ml_prog = spec.program_display({ tag = "alpha\ncore\r\nservice", counts = { total = 0, by_kind = {} } }, NOW)
  check(ml_prog == "alpha core service · 0 open", "multi-line tag has newlines collapsed, got: " .. ml_prog)
  check(not ml_prog:find("[\r\n]"), "program_display contains no newlines")

  check(spec.counts_text(nil) == "0 open", "nil counts -> 0 open")
  check(spec.counts_text(vim.NIL) == "0 open", "vim.NIL counts -> 0 open")
  check(spec.counts_text({ total = vim.NIL, by_kind = vim.NIL }) == "0 open", "vim.NIL fields in counts -> 0 open")
  check(spec.counts_text({ total = 2, by_kind = { vim.NIL, { n = vim.NIL, kind = vim.NIL }, { n = 1, kind = "blocker" } } })
    == "2 open (0 unknown, 1 blocker)", "malformed by_kind elements tolerated")
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

  -- Hardening: vim.NIL and malformed row fields.
  check(spec.session_display(vim.NIL, NOW):find("(untitled)", 1, true) ~= nil, "vim.NIL row does not crash")
  check(spec.session_display({ id = "ses_nil", title = vim.NIL, directory = vim.NIL, dir_missing = vim.NIL }, NOW)
    == "  ses_nil │ (no dir) │", "vim.NIL fields in row render blank / fallback")
  check(spec.session_display({ id = "ses_dir", dir_missing = false }, NOW) == "  ses_dir │ (no dir) │",
    "dir_missing false -> no dir gone mark")
  check(spec.session_ordinal(nil) == " (no dir)", "nil session ordinal")
  check(spec.session_ordinal(vim.NIL) == " (no dir)", "vim.NIL session ordinal")
  check(spec.session_ordinal({ id = vim.NIL, title = vim.NIL, directory = vim.NIL }) == " (no dir)",
    "vim.NIL fields session ordinal")
  check(spec.badge(nil) == "", "nil badge -> empty")
  check(spec.badge(vim.NIL) == "", "vim.NIL badge -> empty")
  check(spec.badge({ badge_kind = vim.NIL }) == "", "vim.NIL badge_kind -> empty")

  -- Multi-line title in session_display has newlines collapsed to a single space.
  local ml_sess = spec.session_display({ id = "s1", title = "First line\nSecond line\r\nThird line", directory = "/x/y" }, NOW)
  check(ml_sess:find("First line Second line Third line", 1, true) ~= nil,
    "multi-line session title has newlines collapsed, got: " .. ml_sess)
  check(not ml_sess:find("[\r\n]"), "session_display contains no newlines")

  -- row.joined == true check (vim.NIL is truthy, must be treated as unjoined).
  local nil_joined = spec.session_display({
    id = "s_nil_joined",
    joined = vim.NIL,
    lastActivity = NOW,
    effective_state = "blocked",
  }, NOW)
  check(not nil_joined:find(ss_spec.GLYPHS.blocked, 1, true), "joined = vim.NIL does not render state glyph")
  check(not nil_joined:find(ss_spec.GLYPHS.unknown, 1, true), "joined = vim.NIL does not render unknown glyph")
  check(not nil_joined:find("?", 1, true), "joined = vim.NIL does not render ? age")
  check(nil_joined == "  s_nil_joined │ (no dir) │", "joined = vim.NIL treated as unjoined, got: " .. nil_joined)
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

  -- Hardening: vim.NIL and nil handling in previews.
  check(spec.program_preview_lines(nil)[1] == "(no open items)", "nil prow preview")
  check(spec.program_preview_lines(vim.NIL)[1] == "(no open items)", "vim.NIL prow preview")
  check(spec.program_preview_lines({ items = vim.NIL })[1] == "(no open items)", "vim.NIL items preview")
  check(spec.session_preview_lines(nil)[1] == "(no open items name this session)", "nil row preview")
  check(spec.session_preview_lines(vim.NIL)[1] == "(no open items name this session)", "vim.NIL row preview")
  check(spec.session_preview_lines({ items = vim.NIL })[1] == "(no open items name this session)", "vim.NIL row items preview")

  local nil_item_lines = spec.program_preview_lines({ items = {
    { kind = vim.NIL, text = vim.NIL, status = vim.NIL, what_changed = vim.NIL, stale = vim.NIL,
      sessions = { { id = vim.NIL, title = vim.NIL } } }
  } })
  check(nil_item_lines[1] == "[?] ", "nil item fields format safely")
  check(nil_item_lines[2] == "    - ?", "nil session fields format safely")

  check(spec.item_marks(nil) == "", "nil item_marks")
  check(spec.item_marks(vim.NIL) == "", "vim.NIL item_marks")
  check(spec.item_marks({ status = "changed", what_changed = vim.NIL }) == "(changed)", "changed without what_changed")
  check(spec.item_marks({ status = "changed", what_changed = "" }) == "(changed)", "changed with empty what_changed")
  check(spec.item_marks({ status = "changed", what_changed = "text\nreworded\r\nagain" })
    == "(changed: text reworded again)", "multi-line what_changed has newlines collapsed")
  check(spec.item_marks({ stale = vim.NIL }) == "", "stale vim.NIL -> no mark")

  local ml_prev = spec.program_preview_lines({
    items = {
      {
        kind = "decision",
        text = "Item with multi-line what_changed",
        status = "changed",
        what_changed = "split\nover\r\nlines",
        sessions = {
          { id = "ses_ml", title = "Multi\nLine\r\nSession Title" },
        },
      },
    },
  })
  check(ml_prev[1]:find("%(changed: split over lines%)") ~= nil,
    "multi-line what_changed in preview line, got: " .. ml_prev[1])
  check(ml_prev[2] == "    - Multi Line Session Title",
    "multi-line session title in preview line, got: " .. ml_prev[2])
  for _, l in ipairs(ml_prev) do
    check(not l:find("[\r\n]"), "no preview line contains carriage return or newline")
  end
end

-- 4. TITLES.
do
  check(spec.programs_title({}) == "Stall-watch programs", "programs title")
  check(spec.programs_title({ "x", "y" }) == "Stall-watch programs [⚠ 2]", "programs title warns")
  check(spec.sessions_title("alpha", "flagged", {}) == "alpha · flagged", "flagged title")
  check(spec.sessions_title("alpha", "all", { "x" }) == "alpha · all tagged [⚠ 1]", "all title warns")
  check(spec.digest_title(NOW - 3600000, NOW) == "stall-watch digest · 1h old", "digest title age")
  check(spec.digest_title(nil, NOW) == "stall-watch digest", "digest title without mtime")

  -- Hardening: vim.NIL and nil title handling.
  check(spec.programs_title(nil) == "Stall-watch programs", "nil warnings")
  check(spec.programs_title(vim.NIL) == "Stall-watch programs", "vim.NIL warnings")
  check(spec.sessions_title(nil, nil, nil) == "(unnamed) · flagged", "nil sessions_title")
  check(spec.sessions_title(vim.NIL, vim.NIL, vim.NIL) == "(unnamed) · flagged", "vim.NIL sessions_title")
  check(spec.digest_title(vim.NIL, NOW) == "stall-watch digest", "vim.NIL mtime")
  check(spec.digest_title(NOW, vim.NIL) == "stall-watch digest · ? old", "vim.NIL now_ms")
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

  -- Hardening: nil/vim.NIL options handling.
  check(spec.programs_picker_opts(nil, nil).sorting_strategy == "descending", "nil prows picker opts")
  check(spec.programs_picker_opts(vim.NIL, vim.NIL).sorting_strategy == "descending", "vim.NIL prows picker opts")
  check(spec.selection_index(prows, vim.NIL) == nil, "vim.NIL tag selection index")
  check(spec.selection_index(vim.NIL, "beta") == nil, "vim.NIL prows selection index")
end

print("LUA_TEST_OK " .. N)
