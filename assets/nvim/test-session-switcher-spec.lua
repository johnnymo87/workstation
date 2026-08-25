-- Unit tests for session_switcher/spec.lua (pure presentation).
-- Driven via `nvim --clean -l assets/nvim/test-session-switcher-spec.lua`.

local N = 0
local function check(cond, msg) N = N + 1; assert(cond, msg) end

-- INJECT THE REAL model MODULE INTO package.preload BEFORE LOADING spec.lua.
--
-- Loading spec.lua via loadfile under `nvim --clean` means its internal
-- `require("user.session_switcher.model")` will fail without runtimepath.
-- We preload the real model.lua so spec.lua exercises the genuine model module
-- (including model.unread_badge and model.STATES). A mutation to model.lua
-- must break these tests -- avoiding the isolated-duplicate trap.
local model = loadfile("assets/nvim/lua/user/session_switcher/model.lua")()
package.preload["user.session_switcher.model"] = function() return model end

local spec = loadfile("assets/nvim/lua/user/session_switcher/spec.lua")()

-- 1. ORDERING CONTROLS: picker_opts returns explicit sorting_strategy and order-preserving tiebreak.
-- Prevents a telescope default change silently inverting the list, and prevents score ties reordering rows.
do
  local opts = spec.picker_opts()
  check(type(opts) == "table", "picker_opts returns a table")
  check(opts.sorting_strategy == "descending", "sorting_strategy explicitly pinned to 'descending'")
  check(type(opts.tiebreak) == "function", "tiebreak is a function")
  -- Crucial: call tiebreak() to verify it returns false (preserving arrival order)
  check(opts.tiebreak() == false, "tiebreak() returns false (preserves arrival order on score ties)")
  check(opts.tiebreak({}, {}) == false, "tiebreak(e1, e2) returns false when called with arguments")
end

-- 2. GLYPHS: all 7 states present in GLYPHS and pairwise distinct.
-- Prevents missing state mappings and collision between states.
do
  check(type(spec.GLYPHS) == "table", "GLYPHS table exists")
  local expected_states = { "error", "blocked", "retry", "working", "nodata", "unknown", "idle" }
  local seen_glyphs = {}
  for _, st in ipairs(expected_states) do
    local g = spec.GLYPHS[st]
    check(type(g) == "string" and g ~= "", "GLYPHS[" .. st .. "] is a non-empty string, got " .. tostring(g))
    check(seen_glyphs[g] == nil, "glyph for state '" .. st .. "' (" .. g .. ") is distinct from other states")
    seen_glyphs[g] = st
  end

  -- S3/S5 CONTRACT: nodata is an outage tripwire, must differ from BOTH idle and unknown
  check(spec.GLYPHS.nodata ~= spec.GLYPHS.idle, "nodata glyph MUST differ from idle glyph (contract 5)")
  check(spec.GLYPHS.nodata ~= spec.GLYPHS.unknown, "nodata glyph MUST differ from unknown glyph (contract 5)")
  check(spec.GLYPHS.idle ~= spec.GLYPHS.unknown, "idle glyph MUST differ from unknown glyph")

  -- Glyphs must not collide with unread badge characters '·' and '?'
  for st, g in pairs(spec.GLYPHS) do
    check(g ~= "·", "glyph for '" .. st .. "' must not collide with unread badge absent marker '·'")
    check(g ~= "?", "glyph for '" .. st .. "' must not collide with unread badge unavailable marker '?'")
  end
end

-- 3. GLYPH_OF: maps effective_state to glyph with robust fallback.
-- Prevents nil-deref and unhandled states from crashing or mis-rendering.
do
  check(spec.glyph_of({ effective_state = "error" }) == spec.GLYPHS.error, "glyph_of error")
  check(spec.glyph_of({ effective_state = "blocked" }) == spec.GLYPHS.blocked, "glyph_of blocked")
  check(spec.glyph_of({ effective_state = "retry" }) == spec.GLYPHS.retry, "glyph_of retry")
  check(spec.glyph_of({ effective_state = "working" }) == spec.GLYPHS.working, "glyph_of working")
  check(spec.glyph_of({ effective_state = "nodata" }) == spec.GLYPHS.nodata, "glyph_of nodata")
  check(spec.glyph_of({ effective_state = "unknown" }) == spec.GLYPHS.unknown, "glyph_of unknown")
  check(spec.glyph_of({ effective_state = "idle" }) == spec.GLYPHS.idle, "glyph_of idle")

  -- Fallbacks degrade to unknown ('~') without error
  check(spec.glyph_of(nil) == spec.GLYPHS.unknown, "glyph_of(nil) degrades to unknown")
  check(spec.glyph_of({}) == spec.GLYPHS.unknown, "glyph_of({}) degrades to unknown")
  check(spec.glyph_of({ effective_state = nil }) == spec.GLYPHS.unknown, "glyph_of({effective_state=nil}) degrades to unknown")
  check(spec.glyph_of({ effective_state = vim.NIL }) == spec.GLYPHS.unknown, "glyph_of({effective_state=vim.NIL}) degrades to unknown")
  check(spec.glyph_of({ effective_state = "unrecognised_state" }) == spec.GLYPHS.unknown, "glyph_of(unrecognised) degrades to unknown")
  check(spec.glyph_of("not a table") == spec.GLYPHS.unknown, "glyph_of(string) degrades to unknown")
end

-- 4. DIR_MISSING_MARK: visible marker constant.
do
  check(type(spec.DIR_MISSING_MARK) == "string" and spec.DIR_MISSING_MARK ~= "", "DIR_MISSING_MARK is a non-empty string")
  check(spec.DIR_MISSING_MARK == "[dir gone]", "DIR_MISSING_MARK equals '[dir gone]'")
end

-- 5. IDLE_AGE: pure elapsed time formatting across unit boundaries.
-- Prevents miscalculated time units and invalid clock calls.
do
  local now = 1000000000

  -- Nil / garbage / vim.NIL -> "?"
  check(spec.idle_age(nil, now) == "?", "idle_age(nil, now) -> '?'")
  check(spec.idle_age(now, nil) == "?", "idle_age(now, nil) -> '?'")
  check(spec.idle_age(vim.NIL, now) == "?", "idle_age(vim.NIL, now) -> '?'")
  check(spec.idle_age(now, vim.NIL) == "?", "idle_age(now, vim.NIL) -> '?'")
  check(spec.idle_age("not a number", now) == "?", "idle_age(string, now) -> '?'")
  check(spec.idle_age(now, "not a number") == "?", "idle_age(now, string) -> '?'")

  -- Zero or negative elapsed -> "now"
  check(spec.idle_age(now, now) == "now", "idle_age zero elapsed -> 'now'")
  check(spec.idle_age(now + 5000, now) == "now", "idle_age negative elapsed -> 'now'")

  -- Seconds (< 60s)
  check(spec.idle_age(now - 500, now) == "0s", "idle_age 500ms elapsed -> '0s'")
  check(spec.idle_age(now - 1000, now) == "1s", "idle_age 1s elapsed -> '1s'")
  check(spec.idle_age(now - 45000, now) == "45s", "idle_age 45s elapsed -> '45s'")
  check(spec.idle_age(now - 59999, now) == "59s", "idle_age 59.999s elapsed -> '59s'")

  -- Minutes (< 60m)
  check(spec.idle_age(now - 60000, now) == "1m", "idle_age 60s elapsed -> '1m'")
  check(spec.idle_age(now - 120000, now) == "2m", "idle_age 2m elapsed -> '2m'")
  check(spec.idle_age(now - 3599000, now) == "59m", "idle_age 59.98m elapsed -> '59m'")

  -- Hours (< 24h)
  check(spec.idle_age(now - 3600000, now) == "1h", "idle_age 1h elapsed -> '1h'")
  check(spec.idle_age(now - 7200000, now) == "2h", "idle_age 2h elapsed -> '2h'")
  check(spec.idle_age(now - 86399000, now) == "23h", "idle_age 23.99h elapsed -> '23h'")

  -- Days (>= 24h)
  check(spec.idle_age(now - 86400000, now) == "1d", "idle_age 24h elapsed -> '1d'")
  check(spec.idle_age(now - 172800000, now) == "2d", "idle_age 48h elapsed -> '2d'")
  check(spec.idle_age(now - 864000000, now) == "10d", "idle_age 10d elapsed -> '10d'")
end

-- 6. FORMAT: display composition and ordinal exclusion.
-- Prevents badge digits from polluting ordinal search, and verifies display parts formatting.
do
  local now = 1000000
  local row = {
    id = "ses_1",
    title = "Work Session",
    directory = "/home/dev/projects/workstation",
    effective_state = "idle",
    unread_state = "counted",
    unread = 3,
    lastActivity = now - 60000, -- 1m ago
  }

  local formatted = spec.format(row, { now = now })
  check(type(formatted) == "table", "format returns a table")
  check(formatted.display == "○ (3) Work Session · workstation · 1m",
    "display contains glyph + badge + title + basename + age; got: " .. tostring(formatted.display))
  check(formatted.ordinal == "Work Session workstation",
    "ordinal contains title and basename only; got: " .. tostring(formatted.ordinal))

  -- Ordinal must NOT contain glyph, badge, or idle age
  check(not formatted.ordinal:find("○", 1, true), "ordinal does not contain glyph")
  check(not formatted.ordinal:find("%(3%)"), "ordinal does not contain badge")
  check(not formatted.ordinal:find("1m", 1, true), "ordinal does not contain age")
  check(not formatted.ordinal:find("·", 1, true), "ordinal does not contain middle dot separator")
end

-- 7. FORMAT: empty unread badge does NOT produce double spaces.
do
  local now = 1000000
  local row = {
    id = "ses_2",
    title = "Clean Session",
    directory = "/tmp/repo",
    effective_state = "working",
    unread_state = "counted",
    unread = 0, -- empty badge
    lastActivity = now - 5000,
  }

  local formatted = spec.format(row, { now = now })
  check(formatted.display == "● Clean Session · repo · 5s",
    "empty badge produces single space, no double space; got: " .. tostring(formatted.display))
  check(not formatted.display:find("  "), "display contains no double spaces")
  check(formatted.ordinal == "Clean Session repo", "ordinal is clean")
end

-- 8. FORMAT: dir_missing row is visibly marked with DIR_MISSING_MARK (contract 6).
do
  local now = 1000000
  local row = {
    id = "ses_gone",
    title = "Orphan Session",
    directory = "/tmp/deleted_dir",
    effective_state = "blocked",
    unread_state = "absent",
    dir_missing = true,
    lastActivity = now - 10000,
  }

  local formatted = spec.format(row, { now = now })
  check(formatted.display:find("%[dir gone%]$") ~= nil,
    "dir_missing row display ends with [dir gone]; got: " .. tostring(formatted.display))
  check(formatted.display == "■ · Orphan Session · deleted_dir · 10s [dir gone]",
    "exact dir_missing display format matches; got: " .. tostring(formatted.display))
  -- Ordinal still excludes the mark
  check(not formatted.ordinal:find("%[dir gone%]"), "ordinal does not contain [dir gone]")
  check(formatted.ordinal == "Orphan Session deleted_dir", "ordinal has title and basename only")
end

-- 9. FORMAT: digits in badge PROVE ordinal exclusion.
-- If ordinal mistakenly contained the badge, typing '42' would match unread count instead of titles.
do
  local row = {
    id = "ses_digits",
    title = "Alpha",
    directory = "/tmp/beta",
    effective_state = "idle",
    unread_state = "counted",
    unread = 42,
    lastActivity = 100,
  }

  local formatted = spec.format(row, { now = 1000 })
  check(formatted.display:find("%(42%)") ~= nil, "display contains badge (42)")
  check(formatted.ordinal:find("42") == nil, "ordinal does NOT contain digits 42 from badge")
  check(formatted.ordinal == "Alpha beta", "ordinal is strictly 'Alpha beta'")
end

-- 10. FORMAT: row missing every optional field (only id) formats safely without error.
do
  local row = { id = "ses_bare" }
  local ok, formatted = pcall(spec.format, row)
  check(ok, "format on bare row with only id does not throw")
  check(type(formatted) == "table", "bare row returns table")
  check(type(formatted.display) == "string", "bare row returns display string")
  check(type(formatted.ordinal) == "string", "bare row returns ordinal string")
  check(formatted.ordinal == "(untitled) (no dir)", "bare row ordinal is '(untitled) (no dir)'")
  check(formatted.display:find("%(untitled%)") ~= nil, "bare row display contains (untitled)")
  check(formatted.display:find("%(no dir%)") ~= nil, "bare row display contains (no dir)")
end

-- 11. WARNING_LINES: handles all 4 error kinds with kind and message included.
-- Contract 4: errors must surface distinctly.
do
  local kinds = { "spawn", "exit", "timeout", "decode" }
  for _, k in ipairs(kinds) do
    local err = { kind = k, message = "sample failure for " .. k }
    local lines = spec.warning_lines(nil, err)
    check(type(lines) == "table" and #lines == 1, "err kind=" .. k .. " returns 1 warning line")
    check(lines[1]:find(k, 1, true) ~= nil, "warning line contains kind '" .. k .. "'; got: " .. lines[1])
    check(lines[1]:find("sample failure for " .. k, 1, true) ~= nil, "warning line contains message; got: " .. lines[1])
  end
end

-- 12. WARNING_LINES: success-with-warnings splits newlines and drops empties (S3 tripwire).
do
  local res = {
    rows = { { id = "ses_1" } },
    warnings = "oc-session-list: no live writer reporting\nsecond warning line\n\n\n",
  }
  local lines = spec.warning_lines(res, nil)
  check(type(lines) == "table" and #lines == 2, "split warnings into exactly 2 lines; got: " .. #lines)
  check(lines[1] == "oc-session-list: no live writer reporting", "first warning line matches")
  check(lines[2] == "second warning line", "second warning line matches")
end

-- 13. WARNING_LINES: empty fleet vs failed fetch are TEXTUALLY DIFFERENT.
-- Crux of contract 4: "no sessions" and "the tool broke" must never look alike.
do
  local empty_res = { rows = {} }
  local empty_lines = spec.warning_lines(empty_res, nil)
  check(type(empty_lines) == "table" and #empty_lines == 1, "empty fleet returns 1 line")
  local empty_text = empty_lines[1]
  check(type(empty_text) == "string" and empty_text ~= "", "empty fleet line is non-empty string")

  -- Compare empty fleet text against all failure kinds
  local error_kinds = { "spawn", "exit", "timeout", "decode" }
  for _, k in ipairs(error_kinds) do
    local err_lines = spec.warning_lines(nil, { kind = k, message = "error msg" })
    check(empty_text ~= err_lines[1], "empty-fleet text MUST differ from " .. k .. " failure text")
  end

  -- Healthy fleet with rows and no warnings produces empty table
  local healthy_res = { rows = { { id = "ses_ok" } } }
  local healthy_lines = spec.warning_lines(healthy_res, nil)
  check(type(healthy_lines) == "table" and #healthy_lines == 0, "healthy fleet produces {} warning lines")
end

-- 14. PROMPT_TITLE: reflects facet and visibly indicates warnings when non-empty.
do
  local t_all = spec.prompt_title("all", {})
  check(t_all:find("all", 1, true) ~= nil, "prompt_title includes facet 'all'")
  check(not t_all:find("⚠"), "prompt_title has no warning icon when warnings empty")

  local t_att = spec.prompt_title("attached", {})
  check(t_att:find("attached", 1, true) ~= nil, "prompt_title includes facet 'attached'")

  local t_warn = spec.prompt_title("all", { "warning 1", "warning 2" })
  check(t_warn:find("all", 1, true) ~= nil, "prompt_title with warnings still includes facet")
  check(t_warn:find("⚠", 1, true) ~= nil, "prompt_title visibly indicates warnings with ⚠")
  check(t_warn:find("2", 1, true) ~= nil, "prompt_title indicates warning count (2)")
end

print("LUA_TEST_OK " .. N)
