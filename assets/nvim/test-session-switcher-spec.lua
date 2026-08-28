-- Unit tests for session_switcher/spec.lua (pure presentation).
-- Driven via `nvim --clean -l assets/nvim/test-session-switcher-spec.lua`.

local N = 0

-- Search an argv for a value rather than indexing it. Positional assertions on
-- curl's argv broke the moment a flag (--max-time) was inserted ahead of the
-- URL, which is a test-maintenance failure rather than a real defect; searching
-- expresses what we actually mean ("this argument is present").
local function argv_has(argv, want)
  for _, a in ipairs(argv or {}) do
    if a == want then return true end
  end
  return false
end

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

local discovery = loadfile("assets/nvim/lua/user/session_switcher/discovery.lua")()
package.preload["user.session_switcher.discovery"] = function() return discovery end

local spec = loadfile("assets/nvim/lua/user/session_switcher/spec.lua")()
package.preload["user.session_switcher.spec"] = function() return spec end
local act = loadfile("assets/nvim/lua/user/session_switcher/act.lua")()
package.preload["user.session_switcher.act"] = function() return act end

local flow_chunk = loadfile("assets/nvim/lua/user/session_switcher/flow.lua")
local flow = flow_chunk and flow_chunk()
package.preload["user.session_switcher.flow"] = function() return flow end

local exec_chunk = loadfile("assets/nvim/lua/user/session_switcher/exec.lua")
local exec = exec_chunk and exec_chunk()
package.preload["user.session_switcher.exec"] = function() return exec end

-- =========================================================================
-- TELESCOPE STUBS FOR CI LOADABILITY AND MERGE VERIFICATION
-- =========================================================================
-- WHAT THIS TEST DOES AND DOES NOT PROVE:
-- This test validates the glue wiring in init.lua against OUR MODEL of telescope's API.
-- It proves that spec.picker_opts() (sorting_strategy, tiebreak), generic_sorter,
-- finder, and attach_mappings are not dropped or misplaced in the table merge
-- handed to pickers.new. It closes the gap where a correct spec.lua still yields
-- a broken picker (e.g. missing sorter causing search to fail silently).
-- It CANNOT catch telescope changing its own internal API contracts.
-- Real telescope compatibility is verified via nvim -l on host and manual test.
local recorded_pickers_new = {}
local recorded_finders = {}
local recorded_select_default = nil
local recorded_keymaps = {}
local selected_entry_stub = nil
local current_picker_stub = nil
-- Records the ORDER of teardown-sensitive calls, so the test can prove the
-- selection is read before the picker is closed rather than after it.
local call_order = {}

local stub_actions = {
  close = setmetatable({ calls = {} }, {
    __call = function(t, bufnr)
      table.insert(t.calls, bufnr)
      table.insert(call_order, "close")
    end,
  }),
  select_default = {
    replace = function(self, fn)
      recorded_select_default = fn
    end,
  },
}

local stub_action_state = {
  get_selected_entry = function()
    table.insert(call_order, "get_selected_entry")
    return selected_entry_stub
  end,
  get_current_picker = function(bufnr)
    return current_picker_stub
  end,
}

local stub_config = {
  values = {
    generic_sorter = function(opts)
      return { id = "generic_sorter_stub", opts = opts }
    end,
  },
}

local stub_finders = {
  new_table = function(opts)
    table.insert(recorded_finders, opts)
    return { type = "finder_stub", opts = opts }
  end,
}

local stub_pickers = {
  new = function(opts, defaults)
    local p = {
      opts = opts,
      defaults = defaults,
      prompt_title = defaults and defaults.prompt_title,
      find_called = false,
      find = function(self)
        self.find_called = true
      end,
      refresh = function(self, finder, r_opts)
        self.refreshed_finder = finder
        self.refreshed_opts = r_opts
      end,
    }
    table.insert(recorded_pickers_new, p)
    return p
  end,
}

package.preload["telescope.pickers"] = function() return stub_pickers end
package.preload["telescope.finders"] = function() return stub_finders end
package.preload["telescope.config"] = function() return stub_config end
package.preload["telescope.actions"] = function() return stub_actions end
package.preload["telescope.actions.state"] = function() return stub_action_state end

local init_chunk = loadfile("assets/nvim/lua/user/session_switcher/init.lua")
local init_mod = init_chunk and init_chunk()
package.preload["user.session_switcher"] = function() return init_mod end

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

-- 2. GLYPHS: every state in model.STATES has a distinct glyph.
-- Prevents missing state mappings and collision between states.
--
-- DRIVEN FROM model.STATES, NOT A LOCAL COPY OF THE LITERALS. This is the same
-- drift the cross-language vocabulary check in test-session-switcher.sh exists
-- to prevent, one seam further along the chain: CLI SEVERITY -> model.STATES ->
-- spec.GLYPHS. A hardcoded list here would let an 8th state be added CLI-side
-- and mirrored into model.STATES (both of which the .sh check would happily
-- confirm agree) while spec.GLYPHS had no entry for it -- and glyph_of would
-- silently render every such row as `~` unknown, asserting something false
-- about the session rather than failing loudly. Iterating the real table is
-- what makes that a test failure instead of a quiet mis-render.
do
  check(type(spec.GLYPHS) == "table", "GLYPHS table exists")
  check(vim.islist(model.STATES) and #model.STATES > 0, "model.STATES is a non-empty list to drive this check")
  local seen_glyphs = {}
  for _, st in ipairs(model.STATES) do
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
  check(formatted.display == "○ (3) Work Session │ workstation │ 1m",
    "display contains glyph + badge + title + basename + age; got: " .. tostring(formatted.display))

  -- THE SEPARATOR MUST NOT BE THE BADGE CHARACTER.
  -- model.unread_badge renders "·" for `absent`, the chronic majority case. When
  -- the separator was also "·", an absent row read `○ · Title · dir · age` and
  -- the badge was indistinguishable from punctuation -- contract 5 defeated in
  -- practice while every glyph-distinctness test still passed, because those
  -- compare glyphs against badges and never against the separator.
  local absent_row = { id = "s", title = "T", directory = "/a/b", effective_state = "idle",
    unread_state = "absent", lastActivity = now }
  local absent_display = spec.format(absent_row, { now = now }).display
  local badge_char = model.unread_badge(absent_row)
  check(badge_char == "·", "absent rows badge as '·' (pinning the character this test reasons about)")
  local _, sep_count = absent_display:gsub("│", "")
  check(sep_count == 2, "display uses a separator distinct from the badge, so the badge stays visible")
  local _, dot_count = absent_display:gsub("·", "")
  check(dot_count == 1, "the only '·' in an absent row is the BADGE, not a separator; got: " .. absent_display)
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
  check(formatted.display == "● Clean Session │ repo │ 5s",
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
  check(formatted.display == "■ · Orphan Session │ deleted_dir │ 10s [dir gone]",
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

-- 13b. WARNING_LINES + PROMPT_TITLE: all-automated empty window behaviour.
-- 200 fetched, all automated: empty picker, count explains why, and NOT the
-- "no sessions" message (which would be a lie -- there are sessions, they are
-- hidden). spec.warning_lines receives the raw pre-filter result.
do
  local all_automated_rows = {}
  for i = 1, 200 do
    table.insert(all_automated_rows, { id = "ses_auto_" .. i, automated = true })
  end
  local result = { rows = all_automated_rows }
  local built, hidden = model.build(result.rows, {}, {})
  check(#built == 0, "all-automated window yields 0 built rows")
  check(hidden == 200, "all 200 rows counted as hidden")

  local warnings = spec.warning_lines(result, nil)
  check(#warnings == 0, "raw result is non-empty, so no 'No open sessions found' warning line")
  check(
    spec.prompt_title("all", warnings, hidden) == "Sessions (all) · 200 hidden",
    "prompt_title explains why window is empty with '200 hidden'"
  )
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

-- 14b. PROMPT_TITLE: hidden count rendering, ordering relative to warnings, and robustness.
do
  check(spec.prompt_title("all", {}, 0) == "Sessions (all)", "no suffix at zero hidden count")
  check(spec.prompt_title("all", {}, 31) == "Sessions (all) · 31 hidden", "positive hidden count shown")
  check(
    spec.prompt_title("all", { "w", "x" }, 31) == "Sessions (all) · 31 hidden [⚠ 2]",
    "hidden count precedes warning marker"
  )
  check(spec.prompt_title("all", {}, nil) == "Sessions (all)", "nil count is not an error")
  check(spec.prompt_title("all", {}, "banana") == "Sessions (all)", "non-number count ignored")
  check(spec.prompt_title("all", {}, -3) == "Sessions (all)", "negative count ignored")
  check(spec.prompt_title("attached", {}, 5) == "Sessions (attached) · 5 hidden", "hidden count rendered with attached facet")
  check(spec.prompt_title("detached", { "warn" }, 12) == "Sessions (detached) · 12 hidden [⚠ 1]", "hidden count + warning with detached facet")
end

-- =========================================================================
-- ACT.LUA TESTS (Pure decision module - S7 Task 2)
-- =========================================================================

-- 15. DECIDE: focus_here on live hit in current editor (own == true).
-- Prevents unnecessary tmux pane switches when session is already open here.
do
  local row = { id = "ses_here", directory = "/path/here" }
  local hit = { sid = "ses_here", attach_status = "running", own = true, buffer = 12, tabpage = 2 }
  local desc = act.decide(row, hit)
  check(type(desc) == "table", "decide returns a table for focus_here")
  check(desc.kind == "focus_here", "kind is 'focus_here'")
  check(desc.buffer == 12, "desc.buffer matches hit.buffer (12)")
  check(desc.tabpage == 2, "desc.tabpage matches hit.tabpage (2)")
end

-- 16. DECIDE: switch_pane on live hit in another pane/editor (own ~= true).
-- Prevents attaching a new session when one is already running elsewhere in tmux.
do
  local row = { id = "ses_there", directory = "/path/there" }
  local hit = {
    sid = "ses_there",
    attach_status = "running",
    own = false,
    pane = "%5",
    sock = "/tmp/nvim-5.sock",
    buffer = 8,
    tabpage = 1,
  }
  local desc = act.decide(row, hit)
  check(type(desc) == "table", "decide returns a table for switch_pane")
  check(desc.kind == "switch_pane", "kind is 'switch_pane'")
  check(desc.pane == "%5", "desc.pane matches hit.pane ('%5')")
  check(desc.sock == "/tmp/nvim-5.sock", "desc.sock matches hit.sock")
  check(desc.buffer == 8, "desc.buffer matches hit.buffer (8)")
end

-- 17. DECIDE: switch_pane carries FRESH hit's pane/sock, NEVER stale displayed row (TOCTOU guard).
-- Prevents jumping to an outdated pane if a session was moved between render and keypress.
do
  local stale_row = {
    id = "ses_moved",
    directory = "/path/moved",
    pane = "%99",
    sock = "/tmp/nvim-99.sock",
    buffer = 1,
  }
  local fresh_hit = {
    sid = "ses_moved",
    attach_status = "running",
    own = false,
    pane = "%42",
    sock = "/tmp/nvim-42.sock",
    buffer = 17,
  }
  local desc = act.decide(stale_row, fresh_hit)
  check(desc.kind == "switch_pane", "kind is switch_pane")
  check(desc.pane == "%42", "desc.pane carries FRESH hit's pane (%42), NOT stale row's pane (%99)")
  check(desc.sock == "/tmp/nvim-42.sock", "desc.sock carries FRESH hit's sock, NOT stale row's sock")
  check(desc.buffer == 17, "desc.buffer carries FRESH hit's buffer (17), NOT stale row's buffer (1)")
end

-- 18. DECIDE: attach when no hit is present (hit == nil).
-- Opens fresh session attach when none exists.
do
  local row = { id = "ses_new", directory = "/path/new" }
  local desc = act.decide(row, nil)
  check(type(desc) == "table", "decide returns a table for attach")
  check(desc.kind == "attach", "kind is 'attach'")
  check(desc.sid == "ses_new", "desc.sid matches row.id ('ses_new')")
end

-- 19. DECIDE: CORPSE-JUMP GUARD 1 (hit exists but attach_status = 'failed').
-- Prevents jumping into a dead terminal buffer whose session has crashed.
do
  local row = { id = "ses_dead", directory = "/path/dead" }
  local dead_hit = {
    sid = "ses_dead",
    attach_status = "failed",
    own = false,
    pane = "%3",
    sock = "/tmp/nvim-3.sock",
    buffer = 4,
  }
  local desc = act.decide(row, dead_hit)
  check(desc.kind == "attach", "dead hit (attach_status='failed') yields 'attach', NOT 'switch_pane' (corpse-jump guard)")
  check(desc.sid == "ses_dead", "attach descriptor carries sid")
  check(desc.pane == nil, "attach descriptor does not carry dead pane")
end

-- 20. DECIDE: CORPSE-JUMP GUARD 2 (hit exists with job_dead = true even if attach_status = 'running').
-- Prevents resurrecting an old corpse buffer in an nvim where another session re-marked status running.
do
  local row = { id = "ses_job_dead", directory = "/path/job_dead" }
  local corpse_hit = {
    sid = "ses_job_dead",
    attach_status = "running",
    job_dead = true,
    own = true,
    buffer = 9,
  }
  local desc = act.decide(row, corpse_hit)
  check(desc.kind == "attach", "job_dead=true hit yields 'attach', NOT 'focus_here' (corpse-jump guard)")
  check(desc.sid == "ses_job_dead", "attach descriptor carries sid")
end

-- 21. DECIDE: CONTRACT 2 / NIL-DEREF GUARD (pierced, detached, pane-less row yields attach, never switch_pane).
-- Prevents nil dereference or jump into void when an errored/blocked session survives an 'attached' facet filter.
do
  local pierced_row = {
    id = "ses_blocked",
    directory = "/path/blocked",
    effective_state = "blocked",
    pierced = true,
    attached = false,
    pane = nil,
    sock = nil,
    buffer = nil,
  }
  -- No fresh hit since the session is detached
  local desc = act.decide(pierced_row, nil)
  check(desc.kind == "attach", "pierced detached pane-less row yields 'attach', NEVER 'switch_pane' (nil-deref guard)")
  check(desc.sid == "ses_blocked", "desc.sid matches pierced row.id")
  check(desc.pane == nil, "desc has no pane")
end

-- 22. DECIDE: DIR_MISSING BEATS ATTACHMENT (ordering is the point).
-- A row whose target directory is gone must refuse BEFORE inspecting attachment status.
do
  local missing_row = {
    id = "ses_orphan",
    directory = "/deleted/workspace",
    dir_missing = true,
    attached = true,
    pane = "%1",
  }
  -- Even if a live hit is actively reported:
  local live_hit = {
    sid = "ses_orphan",
    attach_status = "running",
    own = true,
    buffer = 2,
    tabpage = 1,
  }
  local desc = act.decide(missing_row, live_hit)
  check(desc.kind == "refuse_dir_missing", "dir_missing=true yields 'refuse_dir_missing' even when attached/live (ordering is the point)")
  check(desc.directory == "/deleted/workspace", "descriptor carries directory field matching row.directory")
end

-- 23. DECIDE: PINNED FIELD NAME IS 'directory' (not 'dir' or 'path').
-- Pin the field name so consumers cannot silently drift.
do
  local row = {
    id = "ses_pin_dir",
    directory = "/canonical/path/name",
    dir_missing = true,
  }
  local desc = act.decide(row, nil)
  check(desc.kind == "refuse_dir_missing", "kind is refuse_dir_missing")
  check(desc.directory == "/canonical/path/name", "field name is strictly 'directory'")
  check(desc.dir == nil, "field 'dir' is NOT present")
  check(desc.path == nil, "field 'path' is NOT present")
end

-- 24. DECIDE: Robustness with nil/missing row and hit (never throws).
do
  local ok, desc = pcall(act.decide, nil, nil)
  check(ok, "decide(nil, nil) does not throw")
  check(type(desc) == "table", "decide(nil, nil) returns a table")
  check(desc.kind == "attach", "decide(nil, nil) safely returns attach")

  local ok2, desc2 = pcall(act.decide, {}, nil)
  check(ok2, "decide({}, nil) does not throw")
  check(desc2.kind == "attach", "decide({}, nil) safely returns attach")

  -- "No hit means no jump" must hold STRUCTURALLY, not because is_live happens
  -- to return false for nil. An is_live that returned true for a nil hit would
  -- nil-deref on hit.own rather than merely misroute -- which is exactly how
  -- this surfaced, as a crash under mutation rather than a wrong descriptor.
  local ok3, desc3 = pcall(act.decide, { id = "ses_x" }, nil, { is_live = function() return true end })
  check(ok3, "decide(row, nil) does not throw even when is_live lies and returns true for nil")
  check(desc3.kind == "attach", "a nil hit yields attach regardless of what is_live says")
end

-- 25. DECIDE: Injected is_live seam works.
do
  local row = { id = "ses_custom" }
  local hit = { sid = "ses_custom" }
  local custom_called = false
  local desc = act.decide(row, hit, {
    is_live = function(h)
      custom_called = true
      return h == hit
    end,
  })
  check(custom_called, "custom opts.is_live was invoked")
  check(desc.kind == "switch_pane", "custom is_live returning true yields switch_pane")
end

-- 28b. MARK-READ WATERMARK: the explicit gesture's payload builder.
-- Jumping no longer clears (clearing follows evidence of PRESENCE, which the pigeon
-- daemon now derives from a human authoring a turn or resolving a question). The
-- picker's only remaining write is this deliberate keystroke, so it needs a payload
-- built from a row ALONE -- there is no jump descriptor to hand it.
--
-- It MUST inherit every guard act.watermark has, especially the >= 1e12 timestamp
-- rejection: this gesture is if anything MORE dangerous than the old auto-clear,
-- because it is aimed at exactly one session on purpose and the watermark cannot
-- move backwards.
do
  check(act.mark_read_watermark({ id = "ses_1", last_event_id = 10 }).sid == "ses_1",
    "mark_read_watermark returns sid from row.id")
  check(act.mark_read_watermark({ id = "ses_1", last_event_id = 10 }).last_event_id == 10,
    "mark_read_watermark returns last_event_id from row.last_event_id")

  -- Same guards as act.watermark, asserted independently rather than assumed by
  -- shared implementation: a refactor could silently unshare them.
  check(act.mark_read_watermark(nil) == nil, "mark_read_watermark is nil when row is nil")
  check(act.mark_read_watermark({ last_event_id = 10 }) == nil, "mark_read_watermark is nil when row.id is nil")
  check(act.mark_read_watermark({ id = "", last_event_id = 10 }) == nil, "mark_read_watermark is nil when row.id is empty")
  check(act.mark_read_watermark({ id = vim.NIL, last_event_id = 10 }) == nil, "mark_read_watermark is nil when row.id is vim.NIL")
  check(act.mark_read_watermark({ id = "ses_1" }) == nil, "mark_read_watermark is nil when last_event_id is nil (no ledger)")
  check(act.mark_read_watermark({ id = "ses_1", last_event_id = vim.NIL }) == nil,
    "mark_read_watermark is nil when last_event_id is vim.NIL")
  check(act.mark_read_watermark({ id = "ses_1", last_event_id = "10" }) == nil,
    "mark_read_watermark is nil when last_event_id is a string")
  check(act.mark_read_watermark({ id = "ses_1", last_event_id = 1724500000000 }) == nil,
    "mark_read_watermark REJECTS timestamp-magnitude last_event_id >= 1e12 (defensive guard)")
  check(act.mark_read_watermark({ id = "ses_1", last_event_id = -1 }) == nil,
    "mark_read_watermark rejects negative last_event_id")

  -- A dir-missing row is read-only for JUMPING, but marking it read is a pure
  -- watermark write that touches nothing on disk, so it is allowed. This is the one
  -- guard mark_read_watermark deliberately does NOT inherit.
  local ro = act.mark_read_watermark({ id = "ses_ro", last_event_id = 4, dir_missing = true })
  check(type(ro) == "table" and ro.last_event_id == 4,
    "mark_read_watermark ALLOWS a dir-missing row (marking read touches no directory)")
end

-- 31. FLOW: new controller instantiation and injected seams.
do
  check(flow ~= nil, "flow module loaded")
  local ctrl = flow.new()
  check(type(ctrl) == "table", "flow.new returns a table")
  check(type(ctrl.refresh) == "function", "controller has refresh method")
  check(type(ctrl.accept) == "function", "controller has accept method")
end

-- 32. FLOW: refresh pipeline (fetch -> locate -> build -> cb).
do
  local fetch_called = false
  local locate_called = false
  local build_called = false
  local cb_called = false

  local fake_rows = { { id = "ses_1", title = "T1" } }
  local fake_hits = { ses_1 = { sid = "ses_1", attach_status = "running", own = true } }

  local ctrl = flow.new({
    fetch = function(opts, cb)
      fetch_called = true
      cb({ rows = fake_rows, warnings = nil }, nil)
    end,
    locate = function(opts, cb)
      locate_called = true
      cb(fake_hits)
    end,
    build = function(rows, hits, opts)
      build_called = true
      check(opts.facet == "all", "facet passed through to build")
      return { { id = "ses_1", title = "T1", attached = true } }
    end,
  })

  ctrl:refresh("all", function(rows, result, err)
    cb_called = true
    check(err == nil, "refresh happy path err is nil")
    check(type(rows) == "table" and #rows == 1, "refresh yields built rows")
    check(rows[1].attached == true, "built row has attached=true")
    check(result ~= nil and result.rows == fake_rows, "refresh passes through result")
  end)

  check(fetch_called, "fetch was called")
  check(locate_called, "locate was called")
  check(build_called, "build was called")
  check(cb_called, "refresh callback was invoked")
end

-- 32b. FLOW: threads hidden count as 4th callback argument and keeps rows table a list.
do
  local captured_hidden = nil
  local captured_rows = nil

  local ctrl = flow.new({
    fetch = function(opts, cb)
      cb({ rows = { { id = "a" } } }, nil)
    end,
    locate = function(opts, cb)
      cb({})
    end,
    build = function(rows, hits, opts)
      return { { id = "a" } }, 5
    end,
  })

  ctrl:refresh("all", function(rows, result, err, hidden)
    captured_rows = rows
    captured_hidden = hidden
  end)

  check(captured_hidden == 5, "flow threads model.build hidden count as 4th arg, got " .. tostring(captured_hidden))
  check(vim.islist(captured_rows), "rows table is still a list (cli.lua guard)")
  check(type(captured_rows) == "table" and rawget(captured_rows, "hidden") == nil, "hidden count is NOT attached to rows table")
end

-- 33. FLOW RACE 1: Stale FETCH generation is dropped (cb NOT called).
-- Prevents race where a slow fetch from an earlier facet toggle arrives late and clobbers newer state.
do
  local pending_fetch_cbs = {}
  local cb_calls = 0

  local ctrl = flow.new({
    fetch = function(opts, cb)
      table.insert(pending_fetch_cbs, cb)
    end,
    locate = function(opts, cb)
      cb({})
    end,
    build = function(rows, hits, opts)
      return rows
    end,
  })

  -- Refresh 1: generation 1
  ctrl:refresh("all", function(rows, result, err)
    cb_calls = cb_calls + 1
  end)

  -- Refresh 2: generation 2 (user toggled facet before fetch 1 returned)
  ctrl:refresh("attached", function(rows, result, err)
    cb_calls = cb_calls + 1
  end)

  check(#pending_fetch_cbs == 2, "both fetches were dispatched")

  -- Now fetch 1 (stale) completes
  pending_fetch_cbs[1]({ rows = { { id = "ses_stale" } } }, nil)
  check(cb_calls == 0, "stale fetch generation 1 completion does NOT invoke callback")

  -- Now fetch 2 (current) completes
  pending_fetch_cbs[2]({ rows = { { id = "ses_fresh" } } }, nil)
  check(cb_calls == 1, "current fetch generation 2 completion DOES invoke callback")
end

-- 34. FLOW RACE 2: Stale LOCATE generation is dropped (cb NOT called).
-- Revision 1 missed this: discovery.locate is also async (1s deadline) and has no staleness guard.
-- A facet toggle landing mid-locate must NOT clobber finder with stale-facet rows.
do
  local pending_locate_cbs = {}
  local cb_calls = 0

  local ctrl = flow.new({
    fetch = function(opts, cb)
      -- fetch completes synchronously
      cb({ rows = { { id = "ses_1" } } }, nil)
    end,
    locate = function(opts, cb)
      table.insert(pending_locate_cbs, cb)
    end,
    build = function(rows, hits, opts)
      return rows
    end,
  })

  -- Refresh 1: fetch completes, locate is pending (gen 1)
  ctrl:refresh("all", function(rows, result, err)
    cb_calls = cb_calls + 1
  end)

  check(#pending_locate_cbs == 1, "first locate is pending")

  -- Refresh 2: user toggled facet mid-locate (gen 2)
  ctrl:refresh("attached", function(rows, result, err)
    cb_calls = cb_calls + 1
  end)

  check(#pending_locate_cbs == 2, "second locate is pending")

  -- Locate 1 (stale) completes
  pending_locate_cbs[1]({})
  check(cb_calls == 0, "stale locate generation 1 completion does NOT invoke callback (post-locate check)")

  -- Locate 2 (current) completes
  pending_locate_cbs[2]({})
  check(cb_calls == 1, "current locate generation 2 completion DOES invoke callback")
end

-- 35. FLOW: Fetch error still calls cb with err so warnings surface.
-- Prevents fetch errors leaving the picker silently empty (Contract 4).
do
  local cb_called = false
  local received_err = nil

  local ctrl = flow.new({
    fetch = function(opts, cb)
      cb(nil, { kind = "exit", code = 1, message = "CLI crashed", stderr = "DB locked" })
    end,
    locate = function(opts, cb)
      cb({})
    end,
  })

  ctrl:refresh("all", function(rows, result, err)
    cb_called = true
    received_err = err
  end)

  check(cb_called, "cb was called on fetch error")
  check(received_err ~= nil and received_err.kind == "exit", "cb received err object")
  check(received_err.message == "CLI crashed", "err message preserved")
end

-- 36. FLOW: Stale fetch error generation is dropped.
do
  local pending_fetch_cbs = {}
  local cb_calls = 0

  local ctrl = flow.new({
    fetch = function(opts, cb)
      table.insert(pending_fetch_cbs, cb)
    end,
  })

  ctrl:refresh("all", function(rows, result, err)
    cb_calls = cb_calls + 1
  end)
  ctrl:refresh("attached", function(rows, result, err)
    cb_calls = cb_calls + 1
  end)

  -- Error from stale fetch 1
  pending_fetch_cbs[1](nil, { kind = "timeout", message = "timed out" })
  check(cb_calls == 0, "error on stale fetch does not fire callback")
end

-- 37. FLOW: Accept pipeline (re-resolves via locate, calls decide, then cb).
do
  local locate_called = false
  local decide_called = false
  local cb_desc = nil

  local row = { id = "ses_jump", directory = "/tmp/proj" }
  local fresh_hit = { sid = "ses_jump", attach_status = "running", own = true, buffer = 5, tabpage = 1 }

  local ctrl = flow.new({
    locate = function(opts, cb)
      locate_called = true
      cb({ ses_jump = fresh_hit })
    end,
    decide = function(r, h)
      decide_called = true
      check(r == row, "decide received row")
      check(h == fresh_hit, "decide received FRESH hit from locate")
      return { kind = "focus_here", buffer = 5, tabpage = 1 }
    end,
  })

  ctrl:accept(row, function(desc)
    cb_desc = desc
  end)

  check(locate_called, "accept called locate to re-resolve (contract 8 TOCTOU)")
  check(decide_called, "accept called decide")
  check(cb_desc ~= nil and cb_desc.kind == "focus_here", "accept cb received descriptor")
end

-- 38. FLOW: Accept does NOT share render generation token (does not get cancelled if render generation moves).
-- Decided explicitly: reopening picker mid-accept must not silently swallow jump.
do
  local pending_locate_cbs = {}
  local accept_desc = nil

  local ctrl = flow.new({
    fetch = function(opts, cb)
      cb({ rows = {} }, nil)
    end,
    locate = function(opts, cb)
      table.insert(pending_locate_cbs, cb)
    end,
    decide = function(r, h)
      return { kind = "attach", sid = r.id }
    end,
  })

  -- Start accept (locate pending)
  local row = { id = "ses_target" }
  ctrl:accept(row, function(desc)
    accept_desc = desc
  end)

  check(#pending_locate_cbs == 1, "accept locate is pending")

  -- Now user reopens/refreshes the picker, bumping render generation
  ctrl:refresh("all", function() end)

  -- Now the accept-time locate completes
  pending_locate_cbs[1]({})

  check(accept_desc ~= nil, "accept callback STILL completes even when render generation moved (token NOT shared)")
  check(accept_desc.kind == "attach", "accept descriptor is correct")
  check(accept_desc.sid == "ses_target", "accept descriptor sid is correct")
end

-- =========================================================================
-- EXEC.LUA TESTS (Side-Effect Layer - S7 Task 3)
-- =========================================================================

-- 39. EXEC: module loaded and exposes all required functions.
do
  check(exec ~= nil, "exec module loaded")
  check(type(exec.tmux_client) == "function", "exec.tmux_client is a function")
  check(type(exec.focus_here) == "function", "exec.focus_here is a function")
  check(type(exec.switch_pane) == "function", "exec.switch_pane is a function")
  check(type(exec.attach) == "function", "exec.attach is a function")
  check(type(exec.refuse_dir_missing) == "function", "exec.refuse_dir_missing is a function")
  check(type(exec.notify_warnings) == "function", "exec.notify_warnings is a function")
end

-- 40. EXEC: tmux_client degrades to nil when outside tmux or on failure (never throws).
do
  local saved_tmux = vim.env.TMUX
  vim.env.TMUX = nil
  local ok, res = pcall(exec.tmux_client)
  check(ok, "tmux_client() does not throw when TMUX is unset")
  check(res == nil, "tmux_client() returns nil outside tmux")
  vim.env.TMUX = saved_tmux
end

-- 41. EXEC: focus_here sets buffer/tabpage and never throws.
do
  local ok, res = pcall(exec.focus_here, nil)
  check(ok, "focus_here(nil) does not throw")
  check(res == false, "focus_here(nil) returns false")

  local ok2, res2 = pcall(exec.focus_here, { buffer = -999, tabpage = -999 })
  check(ok2, "focus_here with invalid IDs does not throw")
  check(type(res2) == "boolean", "focus_here returns boolean")
end

-- 42. EXEC: switch_pane degrades gracefully with notification when client is nil.
do
  local notifications = {}
  local orig_notify = vim.notify
  vim.notify = function(msg, level)
    table.insert(notifications, { msg = msg, level = level })
  end

  local ok, res = pcall(exec.switch_pane, { pane = "%2", sock = "/tmp/a.sock", buffer = 1 }, nil)
  check(ok, "switch_pane does not throw when client is nil")
  check(res == false, "switch_pane returns false when client is nil")
  check(#notifications > 0, "notification emitted explaining tmux client missing")
  check(notifications[1].level == vim.log.levels.WARN, "notification is WARN level")

  vim.notify = orig_notify
end

-- 43. EXEC: switch_pane runs tmux switch-client and nvim --remote-expr.
do
  local system_calls = {}
  local orig_system = vim.system
  vim.system = function(cmd, opts, on_exit)
    table.insert(system_calls, { cmd = cmd, opts = opts })
    return { pid = 1, wait = function() return { code = 0, stdout = "" } end }
  end

  local desc = { pane = "3", sock = "/tmp/nvim-3.sock", buffer = 7 }
  local ok, res = pcall(exec.switch_pane, desc, "client_0")
  check(ok, "switch_pane with client succeeds without throwing")
  check(res == true, "switch_pane returns true on success")
  check(#system_calls == 2, "switch_pane made 2 system calls (tmux switch-client + nvim remote-expr)")

  -- Check tmux command
  local tmux_cmd = system_calls[1].cmd
  check(tmux_cmd[1] == "tmux" and tmux_cmd[2] == "switch-client", "first cmd is tmux switch-client")
  check(tmux_cmd[4] == "client_0", "tmux client matches captured client")
  check(tmux_cmd[6] == "%3", "tmux target pane has % prefix (%3)")
  check(system_calls[1].opts.stdin == false, "tmux call has stdin=false")

  -- Check nvim --remote-expr command
  local nvim_cmd = system_calls[2].cmd
  check(nvim_cmd[1] == "nvim" and nvim_cmd[2] == "--server" and nvim_cmd[3] == "/tmp/nvim-3.sock", "second cmd is nvim --server")
  check(nvim_cmd[4] == "--remote-expr", "second cmd uses --remote-expr")
  check(nvim_cmd[5]:find("nvim_set_current_buf") ~= nil, "remote-expr calls nvim_set_current_buf")
  check(nvim_cmd[5]:find("7") ~= nil, "remote-expr passes buffer 7")
  check(system_calls[2].opts.stdin == false, "nvim call has stdin=false")

  vim.system = orig_system
end

-- 44. EXEC: attach shells out to oc-auto-attach binary with stdin=false (Contract 10).
do
  local system_calls = {}
  local orig_system = vim.system
  vim.system = function(cmd, opts, on_exit)
    table.insert(system_calls, { cmd = cmd, opts = opts })
    return { pid = 1 }
  end

  local ok, res = pcall(exec.attach, { sid = "ses_attach_test" })
  check(ok, "attach does not throw")
  check(res == true, "attach returns true on success")
  check(#system_calls == 1, "attach spawned 1 process")
  check(system_calls[1].cmd[1] == "oc-auto-attach", "spawned oc-auto-attach binary (contract 10)")
  check(system_calls[1].cmd[2] == "ses_attach_test", "passed session id argument")
  check(system_calls[1].opts.stdin == false, "spawned with stdin=false")

  vim.system = orig_system
end

-- 45. EXEC: attach handles missing binary (vim.system error) with notification without throwing.
do
  local notifications = {}
  local orig_notify = vim.notify
  vim.notify = function(msg, level)
    table.insert(notifications, { msg = msg, level = level })
  end
  local orig_system = vim.system
  vim.system = function(cmd, opts, on_exit)
    error("ENOENT: oc-auto-attach not found")
  end

  local ok, res = pcall(exec.attach, { sid = "ses_missing_bin" })
  check(ok, "attach does not throw even when vim.system raises ENOENT")
  check(res == false, "attach returns false when binary fails to spawn")
  check(#notifications > 0, "notification emitted for missing binary")
  check(notifications[1].msg:find("oc-auto-attach", 1, true) ~= nil, "notification mentions oc-auto-attach")

  vim.system = orig_system
  vim.notify = orig_notify
end

-- 46. EXEC: refuse_dir_missing notifies warning naming directory and saying read-only.
do
  local notifications = {}
  local orig_notify = vim.notify
  vim.notify = function(msg, level)
    table.insert(notifications, { msg = msg, level = level })
  end

  local ok, res = pcall(exec.refuse_dir_missing, { directory = "/tmp/deleted_worktree" })
  check(ok, "refuse_dir_missing does not throw")
  check(res == true, "refuse_dir_missing returns true")
  check(#notifications == 1, "emitted 1 notification")
  check(notifications[1].level == vim.log.levels.WARN, "notification is WARN level")
  check(notifications[1].msg:find("/tmp/deleted_worktree", 1, true) ~= nil, "notification names directory")
  check(notifications[1].msg:find("read%-only") ~= nil or notifications[1].msg:find("read-only") ~= nil, "notification states session is read-only")

  vim.notify = orig_notify
end

-- 47. EXEC: notify_warnings surfaces all lines visibly.
do
  local notifications = {}
  local orig_notify = vim.notify
  vim.notify = function(msg, level)
    table.insert(notifications, { msg = msg, level = level })
  end

  local ok, res = pcall(exec.notify_warnings, { "warning line 1", "warning line 2" })
  check(ok, "notify_warnings does not throw")
  check(res == true, "notify_warnings returns true")
  check(#notifications == 2, "emitted 2 notifications")
  check(notifications[1].msg == "warning line 1", "first line notified")
  check(notifications[2].msg == "warning line 2", "second line notified")

  -- Empty / nil lines table is safe no-op
  check(exec.notify_warnings(nil) == true, "notify_warnings(nil) is safe")
  check(exec.notify_warnings({}) == true, "notify_warnings({}) is safe")

  vim.notify = orig_notify
end

-- =========================================================================
-- INIT.LUA MERGE TESTS (Telescope Glue Verification - S7 Task 3)
-- =========================================================================

-- 48. INIT: init module loaded and exposes open().
do
  check(init_mod ~= nil, "init module loaded successfully")
  check(type(init_mod.open) == "function", "init module exposes open function")
end

-- 49. INIT MERGE: pickers.new receives the merged spec.picker_opts() table.
-- THIS IS THE POINT OF TASK 3:
-- Proves that tiebreak, sorting_strategy, sorter, finder, and attach_mappings
-- all reach pickers.new in the correct argument position and are not dropped.
do
  recorded_pickers_new = {}
  recorded_finders = {}

  local fake_ctrl = flow.new({
    fetch = function(opts, cb)
      cb({ rows = { { id = "ses_alpha", title = "Alpha", directory = "/tmp/a" } }, warnings = nil }, nil)
    end,
    locate = function(opts, cb)
      cb({})
    end,
  })

  init_mod.open({
    flow = fake_ctrl,
    custom_user_opt = "preserved",
  })

  check(#recorded_pickers_new == 1, "pickers.new was invoked exactly once")
  local picker_inst = recorded_pickers_new[1]
  check(picker_inst.find_called == true, "picker:find() was invoked")

  local merged = picker_inst.defaults
  check(type(merged) == "table", "pickers.new defaults argument is a table")

  -- 1. TIEBREAK from spec: MUST BE PRESENT AND RETURN FALSE (Insurance)
  check(type(merged.tiebreak) == "function", "tiebreak is present in merged table")
  check(merged.tiebreak() == false, "tiebreak() explicitly called and returns false")
  check(merged.tiebreak({}, {}) == false, "tiebreak(e1, e2) returns false")

  -- 2. SORTING_STRATEGY from spec: MUST BE "descending"
  check(merged.sorting_strategy == "descending", "sorting_strategy in merged table is 'descending'")

  -- 3. SORTER: MUST BE NON-NIL (LIVE HAZARD: omitting sorter causes silent non-filtering finder)
  check(merged.sorter ~= nil, "sorter is present and non-nil in merged table")
  check(type(merged.sorter) == "table" and merged.sorter.id == "generic_sorter_stub", "sorter is generic_sorter from conf")

  -- 4. FINDER: MUST BE PRESENT
  check(merged.finder ~= nil, "finder is present in merged table")
  check(merged.finder.type == "finder_stub", "finder was built via finders.new_table")
  check(#recorded_finders > 0, "finders.new_table was called")

  -- 5. ATTACH_MAPPINGS: MUST BE PRESENT AND CALLABLE
  check(type(merged.attach_mappings) == "function", "attach_mappings is a function in merged table")

  -- 6. PROMPT_TITLE: reflects facet
  check(type(merged.prompt_title) == "string", "prompt_title is present")
  check(merged.prompt_title:find("all", 1, true) ~= nil, "prompt_title contains facet 'all'")

  -- 7. User opts passed through in first argument
  check(picker_inst.opts.custom_user_opt == "preserved", "user opts passed through to pickers.new")
end

-- 49b. INIT: fetch limit is 200 by default, without mutating caller's opts table.
do
  local caller_opts = { custom = "opt" }
  local captured_flow_opts = nil

  local saved_flow_new = flow.new
  flow.new = function(opts)
    captured_flow_opts = opts
    return saved_flow_new(opts)
  end

  init_mod.open(caller_opts)

  check(type(captured_flow_opts) == "table", "flow.new received options table")
  check(type(captured_flow_opts.fetch_opts) == "table", "flow.new received fetch_opts")
  check(captured_flow_opts.fetch_opts.limit == 200, "picker requests limit=200 by default (deeper window)")
  check(caller_opts.fetch_opts == nil, "caller opts table was NOT mutated")

  flow.new = saved_flow_new
end

-- 50. INIT: entry_maker formats row with spec.format.
do
  check(#recorded_finders > 0, "finders recorded")
  local finder_opts = recorded_finders[#recorded_finders]
  check(type(finder_opts.entry_maker) == "function", "finder has entry_maker")

  local row = {
    id = "ses_entry_test",
    title = "Test Entry",
    directory = "/tmp/test_dir",
    effective_state = "working",
    unread_state = "counted",
    unread = 2,
    lastActivity = os.time() * 1000 - 5000,
  }
  local entry = finder_opts.entry_maker(row)
  check(type(entry) == "table", "entry_maker returns a table")
  check(entry.value == row, "entry.value holds raw row")
  check(entry.display ~= nil and entry.display:find("Test Entry") ~= nil, "entry.display contains title")
  check(entry.ordinal == "Test Entry test_dir", "entry.ordinal matches spec format")
end

-- 51. INIT: attach_mappings default select dispatches accept through exec.
do
  recorded_pickers_new = {}
  recorded_select_default = nil
  stub_actions.close.calls = {}
  call_order = {}

  local executed_action = nil
  local orig_switch = exec.switch_pane
  exec.switch_pane = function(desc, client)
    executed_action = { kind = "switch_pane", desc = desc, client = client }
    return true
  end

  local fake_ctrl = flow.new({
    fetch = function(opts, cb)
      cb({ rows = { { id = "ses_mapped", directory = "/tmp/mapped" } } }, nil)
    end,
    locate = function(opts, cb)
      cb({ ses_mapped = { sid = "ses_mapped", attach_status = "running", own = false, pane = "%4", sock = "/tmp/n.sock", buffer = 3 } })
    end,
  })

  init_mod.open({ flow = fake_ctrl })

  local picker_inst = recorded_pickers_new[1]
  local map_fn = function(mode, key, fn) end
  picker_inst.defaults.attach_mappings(101, map_fn)

  check(type(recorded_select_default) == "function", "select_default:replace registered a callback")

  -- Set selected entry stub
  selected_entry_stub = { value = { id = "ses_mapped", directory = "/tmp/mapped" } }

  -- Fire select_default
  recorded_select_default()

  check(#stub_actions.close.calls == 1 and stub_actions.close.calls[1] == 101, "actions.close was invoked on prompt buffer 101")
  check(executed_action ~= nil, "exec action was dispatched")
  check(executed_action.kind == "switch_pane", "dispatched switch_pane")
  check(executed_action.desc.pane == "%4", "pane matches re-resolved hit")

  -- ORDERING: the selection must be read BEFORE the picker is closed.
  -- get_selected_entry() reads a telescope GLOBAL, and actions.close only
  -- clears per-prompt status, so reading after close works today purely by
  -- accident of teardown order -- and that global is shared across pickers.
  -- Pin the order so a future edit (or a telescope that clears the key on
  -- close) cannot turn Enter into a silent no-op that no unit test notices.
  local idx_entry, idx_close
  for i, name in ipairs(call_order) do
    if name == "get_selected_entry" and not idx_entry then idx_entry = i end
    if name == "close" and not idx_close then idx_close = i end
  end
  check(idx_entry ~= nil, "get_selected_entry was called during accept")
  check(idx_close ~= nil, "actions.close was called during accept")
  check(idx_entry < idx_close, "selection is read BEFORE actions.close, not after it")

  exec.switch_pane = orig_switch
end

-- 52. INIT: <C-f> keymap cycles facet and refreshes current picker.
do
  recorded_pickers_new = {}
  local registered_maps = {}

  local fake_ctrl = flow.new({
    fetch = function(opts, cb)
      cb({ rows = { { id = "ses_cycle" } } }, nil)
    end,
    locate = function(opts, cb)
      cb({})
    end,
    build = function(rows, hits, opts)
      return { { id = "ses_cycle", facet = opts.facet } }
    end,
  })

  init_mod.open({ flow = fake_ctrl })

  local picker_inst = recorded_pickers_new[1]
  local map_fn = function(modes, key, fn)
    table.insert(registered_maps, { modes = modes, key = key, fn = fn })
  end

  picker_inst.defaults.attach_mappings(202, map_fn)

  -- Find <C-f> mapping
  local cf_map = nil
  for _, m in ipairs(registered_maps) do
    if m.key == "<C-f>" then
      cf_map = m
      break
    end
  end

  check(cf_map ~= nil, "<C-f> keymap was registered")

  -- Set up current_picker stub
  current_picker_stub = picker_inst

  -- Trigger <C-f> (cycle from "all" to "attached")
  cf_map.fn()

  check(picker_inst.refreshed_finder ~= nil, "current_picker:refresh was invoked")
  check(picker_inst.prompt_title:find("attached", 1, true) ~= nil, "prompt_title updated to 'attached'")
  check(picker_inst.refreshed_opts.reset_prompt == false, "refresh passed reset_prompt=false")
end

-- 52b. INIT: hidden count is rendered at picker open and remains accurate after <C-f> facet cycling.
do
  recorded_pickers_new = {}
  local registered_maps = {}

  local fake_ctrl = flow.new({
    fetch = function(opts, cb)
      cb({ rows = { { id = "ses_cycle" } } }, nil)
    end,
    locate = function(opts, cb)
      cb({})
    end,
    build = function(rows, hits, opts)
      return { { id = "ses_cycle", facet = opts.facet } }, 7
    end,
  })

  init_mod.open({ flow = fake_ctrl })

  local picker_inst = recorded_pickers_new[1]
  check(picker_inst.prompt_title == "Sessions (all) · 7 hidden", "initial prompt_title includes hidden count at open")

  local map_fn = function(modes, key, fn)
    table.insert(registered_maps, { modes = modes, key = key, fn = fn })
  end
  picker_inst.defaults.attach_mappings(203, map_fn)

  local cf_map = nil
  for _, m in ipairs(registered_maps) do
    if m.key == "<C-f>" then cf_map = m break end
  end
  check(cf_map ~= nil, "<C-f> keymap was registered")

  current_picker_stub = picker_inst
  cf_map.fn()

  check(picker_inst.prompt_title == "Sessions (attached) · 7 hidden", "prompt_title still includes hidden count after facet cycling")
end

-- 53. INIT: warnings are surfaced in prompt_title and via exec.notify_warnings.
do
  recorded_pickers_new = {}
  local notified_warnings = nil
  local orig_notify = exec.notify_warnings
  exec.notify_warnings = function(lines)
    notified_warnings = lines
    return true
  end

  local fake_ctrl = flow.new({
    fetch = function(opts, cb)
      cb({ rows = { { id = "ses_w" } }, warnings = "outage alert: no live writer" }, nil)
    end,
    locate = function(opts, cb)
      cb({})
    end,
  })

  init_mod.open({ flow = fake_ctrl })

  local picker_inst = recorded_pickers_new[1]
  check(picker_inst.prompt_title:find("⚠", 1, true) ~= nil, "prompt_title includes warning indicator ⚠")
  check(notified_warnings ~= nil and #notified_warnings > 0, "exec.notify_warnings was called with warning lines")
  check(notified_warnings[1]:find("outage alert", 1, true) ~= nil, "warning text preserved")

  exec.notify_warnings = orig_notify
end

-- =========================================================================
-- EXEC.LUA CLEAR_UNREAD TESTS (Clear-on-Jump Side Effect - S7 Task 4)
-- =========================================================================

-- 54. CLEAR_UNREAD: nil or invalid payload does nothing and returns false (fake system never called).
-- Prevents spurious HTTP requests or runtime errors when no watermark is due.
do
  local sys_calls = {}
  local fake_sys = function(cmd, opts)
    table.insert(sys_calls, { cmd = cmd, opts = opts })
    return { pid = 1 }
  end

  check(exec.clear_unread(nil, { system = fake_sys }) == false, "clear_unread(nil) returns false")
  check(#sys_calls == 0, "fake system never called for nil payload")

  check(exec.clear_unread({}, { system = fake_sys }) == false, "clear_unread({}) returns false")
  check(#sys_calls == 0, "fake system never called for empty table payload")

  check(exec.clear_unread({ sid = "" }, { system = fake_sys }) == false, "clear_unread({sid=''}) returns false")
  check(#sys_calls == 0, "fake system never called for empty sid")

  check(exec.clear_unread({ sid = "ses_1" }, { system = fake_sys }) == false, "clear_unread without last_event_id returns false")
  check(#sys_calls == 0, "fake system never called when last_event_id is missing")

  check(exec.clear_unread({ sid = "ses_1", last_event_id = "not_a_num" }, { system = fake_sys }) == false, "clear_unread with non-number last_event_id returns false")
  check(#sys_calls == 0, "fake system never called when last_event_id is not a number")
end

-- 55. CLEAR_UNREAD: real payload invokes curl with correct URL, path, method, and stdin=false.
do
  local sys_calls = {}
  local fake_sys = function(cmd, opts)
    table.insert(sys_calls, { cmd = cmd, opts = opts })
    return { pid = 1 }
  end

  local payload = { sid = "ses_basic", last_event_id = 12 }
  local res = exec.clear_unread(payload, { system = fake_sys, port = 4731 })
  check(res == true, "clear_unread returns true when request spawned")
  check(#sys_calls == 1, "system invoked exactly once")

  local call = sys_calls[1]
  check(call.opts ~= nil and call.opts.stdin == false, "invoked with stdin = false")
  check(call.cmd[1] == "curl", "cmd[1] is curl")
  check(vim.tbl_contains(call.cmd, "-X"), "cmd contains -X flag")
  check(vim.tbl_contains(call.cmd, "POST"), "cmd contains POST method")

  -- Find URL in argv
  local url = nil
  for _, arg in ipairs(call.cmd) do
    if arg:find("^http://") then
      url = arg
      break
    end
  end
  check(url ~= nil, "URL found in argv")
  check(url == "http://127.0.0.1:4731/sessions/ses_basic/read", "URL matches http://127.0.0.1:4731/sessions/ses_basic/read, got: " .. tostring(url))
  check(vim.tbl_contains(call.cmd, "content-type: application/json"), "contains content-type: application/json header")
end

-- 56. CLEAR_UNREAD: body contains exact last_event_id and nothing resembling a timestamp.
-- Prevents catastrophic watermark corruption where epoch ms timestamp (~1.7e12) hides future events.
do
  local sys_calls = {}
  local fake_sys = function(cmd, opts)
    table.insert(sys_calls, { cmd = cmd, opts = opts })
    return { pid = 1 }
  end

  local payload = { sid = "ses_exact", last_event_id = 99 }
  exec.clear_unread(payload, { system = fake_sys })
  check(#sys_calls == 1, "system invoked")

  local body = nil
  for i, arg in ipairs(sys_calls[1].cmd) do
    if arg == "--data" then
      body = sys_calls[1].cmd[i + 1]
      break
    end
  end
  check(body ~= nil, "--data argument present")
  local decoded = vim.json.decode(body)
  check(type(decoded) == "table", "body is valid JSON")
  check(decoded.last_event_id == 99, "body contains exact last_event_id = 99")
  check(decoded.last_event_id < 1e12, "last_event_id does not resemble a timestamp (< 1e12)")
end

-- 57. CLEAR_UNREAD: URL-encodes session ID in path.
-- Prevents malformed HTTP paths when session ID contains special characters or spaces.
do
  local sys_calls = {}
  local fake_sys = function(cmd, opts)
    table.insert(sys_calls, { cmd = cmd, opts = opts })
    return { pid = 1 }
  end

  local payload = { sid = "ses/with spaces&special?100%", last_event_id = 5 }
  exec.clear_unread(payload, { system = fake_sys })
  check(#sys_calls == 1, "system invoked")

  local url = nil
  for _, arg in ipairs(sys_calls[1].cmd) do
    if arg:find("^http://") then
      url = arg
      break
    end
  end
  check(url ~= nil, "URL present")
  check(url:find("ses%2Fwith%20spaces%26special%3F100%25", 1, true) ~= nil, "URL has properly percent-encoded sid; got: " .. tostring(url))
  check(not url:find(" "), "URL contains no unencoded spaces")
  check(not url:find("ses/with"), "URL contains no unencoded slashes in sid")
end

-- 58. CLEAR_UNREAD: Authorization: Bearer <token> header present when token resolved.
-- PREVENTS 401-SILENTLY-NEVER-CLEARS: Missing auth returns HTTP 401, which is fire-and-forget silent and leaves unread badge permanently stuck.
do
  local sys_calls = {}
  local fake_sys = function(cmd, opts)
    table.insert(sys_calls, { cmd = cmd, opts = opts })
    return { pid = 1 }
  end

  local payload = { sid = "ses_auth", last_event_id = 7 }
  exec.clear_unread(payload, { system = fake_sys, token = "test-secret-bearer-token-123" })
  check(#sys_calls == 1, "system invoked")

  local auth_header = nil
  for _, arg in ipairs(sys_calls[1].cmd) do
    if arg:find("^Authorization:%s*Bearer") then
      auth_header = arg
      break
    end
  end
  check(auth_header ~= nil, "Authorization: Bearer header present (prevents silent 401 unread badge never clears)")
  check(auth_header == "Authorization: Bearer test-secret-bearer-token-123", "Authorization header contains exact token")
end

-- 59. CLEAR_UNREAD: NO Authorization header when no token can be resolved.
-- Ensures no 'Bearer ' header with empty value is sent when auth is disabled.
do
  local sys_calls = {}
  local fake_sys = function(cmd, opts)
    table.insert(sys_calls, { cmd = cmd, opts = opts })
    return { pid = 1 }
  end

  local saved_env_tok = vim.env.PIGEON_DAEMON_AUTH_TOKEN
  local saved_env_file = vim.env.PIGEON_DAEMON_AUTH_TOKEN_FILE
  vim.env.PIGEON_DAEMON_AUTH_TOKEN = nil
  vim.env.PIGEON_DAEMON_AUTH_TOKEN_FILE = "/nonexistent/token/path"

  local payload = { sid = "ses_no_auth", last_event_id = 8 }
  exec.clear_unread(payload, { system = fake_sys, token = nil, token_file = "/nonexistent/token/path" })
  check(#sys_calls == 1, "system invoked")

  for _, arg in ipairs(sys_calls[1].cmd) do
    check(not arg:find("Bearer", 1, true), "argv contains no 'Bearer' when no token resolved; found: " .. tostring(arg))
    check(not arg:find("Authorization", 1, true), "argv contains no 'Authorization' header when no token resolved")
  end

  vim.env.PIGEON_DAEMON_AUTH_TOKEN = saved_env_tok
  vim.env.PIGEON_DAEMON_AUTH_TOKEN_FILE = saved_env_file
end

-- 60. CLEAR_UNREAD: token resolution precedence (opts.token/env beats file; file read trimmed; missing file safe).
do
  local sys_calls = {}
  local fake_sys = function(cmd, opts)
    table.insert(sys_calls, { cmd = cmd, opts = opts })
    return { pid = 1 }
  end

  -- Create a temporary token file
  local tmp_token_file = os.tmpname()
  local f = io.open(tmp_token_file, "w")
  assert(f, "could not create tmp token file")
  f:write("  file-token-456\n\n")
  f:close()

  local payload = { sid = "ses_prec", last_event_id = 1 }

  -- Case A: opts.token takes precedence over file
  sys_calls = {}
  exec.clear_unread(payload, { system = fake_sys, token = "override-token", token_file = tmp_token_file })
  check(#sys_calls == 1, "system invoked")
  check(vim.tbl_contains(sys_calls[1].cmd, "Authorization: Bearer override-token"), "opts.token beats token_file")

  -- Case B: env var beats file
  local saved_tok = vim.env.PIGEON_DAEMON_AUTH_TOKEN
  vim.env.PIGEON_DAEMON_AUTH_TOKEN = "env-token-789"
  sys_calls = {}
  exec.clear_unread(payload, { system = fake_sys, token_file = tmp_token_file })
  check(#sys_calls == 1, "system invoked")
  check(vim.tbl_contains(sys_calls[1].cmd, "Authorization: Bearer env-token-789"), "env var beats token_file")
  vim.env.PIGEON_DAEMON_AUTH_TOKEN = saved_tok

  -- Case C: fallback to trimmed file token when env var absent
  local saved_file = vim.env.PIGEON_DAEMON_AUTH_TOKEN_FILE
  vim.env.PIGEON_DAEMON_AUTH_TOKEN = nil
  vim.env.PIGEON_DAEMON_AUTH_TOKEN_FILE = nil
  sys_calls = {}
  exec.clear_unread(payload, { system = fake_sys, token_file = tmp_token_file })
  check(#sys_calls == 1, "system invoked")
  check(vim.tbl_contains(sys_calls[1].cmd, "Authorization: Bearer file-token-456"), "file token read and trimmed")
  vim.env.PIGEON_DAEMON_AUTH_TOKEN_FILE = saved_file

  -- Case D: missing token file does not throw
  sys_calls = {}
  local ok, res = pcall(exec.clear_unread, payload, { system = fake_sys, token_file = "/nonexistent/unreadable/file" })
  check(ok, "missing token file does not throw")
  check(res == true, "clear_unread succeeds without token")
  for _, arg in ipairs(sys_calls[1].cmd) do
    check(not arg:find("Bearer", 1, true), "missing token file yields no Bearer header")
  end

  os.remove(tmp_token_file)
end

-- 61. CLEAR_UNREAD: port resolution ($PIGEON_DAEMON_PORT honoured, opts.port override, default 4731).
do
  local sys_calls = {}
  local fake_sys = function(cmd, opts)
    table.insert(sys_calls, { cmd = cmd, opts = opts })
    return { pid = 1 }
  end
  local payload = { sid = "ses_port", last_event_id = 10 }

  -- Default port is 4731
  local saved_port = vim.env.PIGEON_DAEMON_PORT
  vim.env.PIGEON_DAEMON_PORT = nil
  sys_calls = {}
  exec.clear_unread(payload, { system = fake_sys })
  check(#sys_calls == 1, "invoked default")
  check(argv_has(sys_calls[1].cmd, "http://127.0.0.1:4731/sessions/ses_port/read"), "default port is 4731")

  -- PIGEON_DAEMON_PORT env var
  vim.env.PIGEON_DAEMON_PORT = "5555"
  sys_calls = {}
  exec.clear_unread(payload, { system = fake_sys })
  check(#sys_calls == 1, "invoked env port")
  local url_env = nil
  for _, a in ipairs(sys_calls[1].cmd) do if a:find("^http://") then url_env = a break end end
  check(url_env == "http://127.0.0.1:5555/sessions/ses_port/read", "env var PIGEON_DAEMON_PORT honoured; got: " .. tostring(url_env))

  -- opts.port override beats env var
  sys_calls = {}
  exec.clear_unread(payload, { system = fake_sys, port = 8080 })
  check(#sys_calls == 1, "invoked opts.port")
  local url_opts = nil
  for _, a in ipairs(sys_calls[1].cmd) do if a:find("^http://") then url_opts = a break end end
  check(url_opts == "http://127.0.0.1:8080/sessions/ses_port/read", "opts.port beats env var; got: " .. tostring(url_opts))

  vim.env.PIGEON_DAEMON_PORT = saved_port
end

-- 62. CLEAR_UNREAD: vim.system error (missing binary / exception) is pcall'd, does not throw, returns false.
do
  local payload = { sid = "ses_err", last_event_id = 3 }
  local fake_sys_raise = function(cmd, opts)
    error("ENOENT: curl not found")
  end

  local ok, res = pcall(exec.clear_unread, payload, { system = fake_sys_raise })
  check(ok, "clear_unread does not throw when vim.system raises")
  check(res == false, "clear_unread returns false when system raises")
end

-- 63. INTEGRATION: JUMPING FIRES NO WATERMARK WRITE.
--
-- This assertion is INVERTED from what it used to be. It previously proved that the
-- pure layer withheld the payload for a dir_missing row while still calling
-- exec.clear_unread -- i.e. that the ONE read-only case did not write. Jumping now
-- writes for NO case at all, so the interesting claim is the absence of the call
-- itself, and it is asserted through the full dispatch path rather than by reading
-- init.lua and believing it.
do
  recorded_pickers_new = {}
  recorded_select_default = nil
  stub_actions.close.calls = {}

  local clear_calls = {}
  local orig_clear = exec.clear_unread
  exec.clear_unread = function(payload, opts)
    table.insert(clear_calls, { payload = payload, opts = opts })
    return orig_clear(payload, opts)
  end

  local fake_ctrl = flow.new({
    fetch = function(opts, cb)
      cb({ rows = { { id = "ses_ro_int", directory = "/tmp/nonexistent", dir_missing = true, last_event_id = 50 } } }, nil)
    end,
    locate = function(opts, cb)
      cb({})
    end,
  })

  init_mod.open({ flow = fake_ctrl })

  local picker_inst = recorded_pickers_new[1]
  picker_inst.defaults.attach_mappings(303, function() end)

  -- Select the dir_missing row
  selected_entry_stub = { value = { id = "ses_ro_int", directory = "/tmp/nonexistent", dir_missing = true, last_event_id = 50 } }
  recorded_select_default()

  check(#clear_calls == 0, "jumping fires NO watermark write, for a dir_missing row or any other")

  exec.clear_unread = orig_clear
end

-- 64. INTEGRATION: attach, switch_pane and focus_here pass NO watermark payload.
-- INVERTED from the original assertion, which read "DO pass watermark payload".
do
  local clear_calls = {}
  local orig_clear = exec.clear_unread
  exec.clear_unread = function(payload, opts)
    table.insert(clear_calls, { payload = payload, opts = opts })
    return orig_clear(payload, opts)
  end

  local fake_ctrl = flow.new({
    fetch = function(opts, cb)
      cb({ rows = { { id = "ses_ok_int", directory = "/tmp/ok", last_event_id = 88 } } }, nil)
    end,
    locate = function(opts, cb)
      cb({})
    end,
  })

  recorded_pickers_new = {}
  -- INJECT A FAKE SYSTEM. Without it this test calls through to the real
  -- clear_unread with a real payload, which resolves the real bearer token
  -- from /run/secrets and fires a real authenticated POST at the live pigeon
  -- daemon on 4731 -- on every local run of the unit suite. It was harmless
  -- only because the daemon-side clamp rejects an unknown sid, i.e. a unit
  -- test whose safety depended on a server-side guard in a different repo.
  local real_system_calls = {}
  -- STUB exec.attach TOO. It is not covered by the `system` seam above:
  -- exec.attach calls vim.system directly, and oc-auto-attach IS installed on
  -- this host (/home/dev/.nix-profile/bin/oc-auto-attach), so an unstubbed run
  -- spawns a real attach for a fabricated session id every time anyone runs
  -- the unit suite. A unit test must not launch the production binary it is
  -- reasoning about.
  local orig_attach = exec.attach
  local attach_calls = {}
  exec.attach = function(desc)
    table.insert(attach_calls, desc)
    return true
  end
  init_mod.open({ flow = fake_ctrl, system = function(argv, o)
    table.insert(real_system_calls, argv)
    return { pid = 1, kill = function() end }
  end })
  local picker_inst = recorded_pickers_new[1]
  picker_inst.defaults.attach_mappings(404, function() end)

  selected_entry_stub = { value = { id = "ses_ok_int", directory = "/tmp/ok", last_event_id = 88 } }
  recorded_select_default()

  -- THE CENTRAL BEHAVIOUR OF THIS CHANGE, asserted through the full dispatch path.
  -- A successful attach to a session carrying unread events (last_event_id = 88) must
  -- dispatch the jump and write NOTHING. Peeking is not reading. If this assertion is
  -- ever flipped back, the user-visible symptom is a badge that vanishes when you
  -- glance at a session and cannot be recovered, because the daemon's watermark is a
  -- MAX() upsert.
  check(#clear_calls == 0, "exec.clear_unread was NOT called for a successful attach (jumping never clears)")
  check(#attach_calls == 1, "exec.attach was dispatched (stubbed, so no real oc-auto-attach was spawned)")

  exec.clear_unread = orig_clear
  exec.attach = orig_attach
end

-- 65. THE JUMP MUST SUCCEED BEFORE THE BADGE IS CLEARED.
-- A failed jump that still clears unread marks events read that the user never
-- saw. That is unrecoverable -- unlike a badge that fails to clear, which the
-- next jump fixes. The realistic trigger is mundane: the keymap guard checks
-- only `oc-session-list`, so a host without oc-auto-attach takes exec.attach's
-- failure path, and switch_pane fails whenever the picker runs outside tmux.
do
  local clear_calls = {}
  local orig_clear = exec.clear_unread
  local orig_attach = exec.attach
  exec.clear_unread = function(payload) table.insert(clear_calls, payload); return true end
  exec.attach = function() return false end -- simulate oc-auto-attach missing

  local fake_ctrl = flow.new({
    fetch = function(o, cb) cb({ rows = { { id = "ses_failjump", directory = "/tmp/f", last_event_id = 42 } } }, nil) end,
    locate = function(o, cb) cb({}) end,
  })

  recorded_pickers_new = {}
  init_mod.open({ flow = fake_ctrl })
  recorded_pickers_new[1].defaults.attach_mappings(505, function() end)
  selected_entry_stub = { value = { id = "ses_failjump", directory = "/tmp/f", last_event_id = 42 } }
  recorded_select_default()

  check(#clear_calls == 0, "a FAILED jump fires NO watermark write")

  -- Successful jump: also no write. Jump outcome is now irrelevant to clearing.
  exec.attach = function() return true end
  recorded_pickers_new = {}
  init_mod.open({ flow = fake_ctrl })
  recorded_pickers_new[1].defaults.attach_mappings(506, function() end)
  recorded_select_default()
  check(#clear_calls == 0, "a SUCCESSFUL jump ALSO fires no watermark write")

  -- EVERY jump kind, not just attach.
  --
  -- Mutation testing caught this gap: re-adding exec.clear_unread to the focus_here
  -- branch of dispatch passed the entire suite, because every assertion above drives
  -- the ATTACH path. focus_here is the common case for a session already open in this
  -- Neovim -- exactly the one you peek at most -- so it was the worst path to leave
  -- unpinned. Each kind is dispatched through the real init.lua branch here.
  local orig_focus, orig_switch = exec.focus_here, exec.switch_pane
  for _, kind in ipairs({ "focus_here", "switch_pane", "attach" }) do
    -- Distinct counters per exec, not one shared tally: a shared counter proves only
    -- that SOME branch ran, so a dispatch that routed every kind to attach would pass.
    local calls = { focus_here = 0, switch_pane = 0, attach = 0 }
    exec.focus_here = function() calls.focus_here = calls.focus_here + 1; return true end
    exec.switch_pane = function() calls.switch_pane = calls.switch_pane + 1; return true end
    exec.attach = function() calls.attach = calls.attach + 1; return true end

    local row_k = { id = "ses_" .. kind, directory = "/tmp/k", last_event_id = 7 }
    local ctrl_k = flow.new({
      fetch = function(o, cb) cb({ rows = { row_k } }, nil) end,
      locate = function(o, cb) cb({}) end,
      decide = function() return { kind = kind, buffer = 1, tabpage = 1, pane = "%1", sock = "/tmp/s" } end,
    })

    clear_calls = {}
    recorded_pickers_new = {}
    init_mod.open({ flow = ctrl_k })
    recorded_pickers_new[1].defaults.attach_mappings(508, function() end)
    selected_entry_stub = { value = row_k }
    recorded_select_default()

    check(calls[kind] == 1, kind .. " was dispatched through init.lua's own branch")
    local others = 0
    for k, v in pairs(calls) do if k ~= kind then others = others + v end end
    check(others == 0, kind .. " dispatched ONLY its own exec (no cross-routing)")
    check(#clear_calls == 0, kind .. " fires NO watermark write")
  end
  exec.focus_here, exec.switch_pane = orig_focus, orig_switch

  -- POSITIVE CONTROL, and it has to be a real one.
  --
  -- The two assertions above are now both "nothing happened", so on their own they
  -- would pass just as happily if exec.clear_unread had been renamed, the stub never
  -- installed, or dispatch silently broken. The old version of this block used a
  -- successful jump as its control; that control is exactly what this change deleted.
  -- <C-r> replaces it: the ONE path that must still write, proving the harness can
  -- observe a write when one is supposed to occur.
  local registered = {}
  recorded_pickers_new = {}
  init_mod.open({ flow = fake_ctrl })
  recorded_pickers_new[1].defaults.attach_mappings(507, function(modes, key, fn)
    table.insert(registered, { key = key, fn = fn })
  end)
  local cr = nil
  for _, m in ipairs(registered) do
    if m.key == "<M-r>" then cr = m break end
  end
  check(cr ~= nil, "<M-r> mark-read keymap was registered")

  -- <C-r> must NOT be taken: telescope maps <C-r><C-w>/<C-a>/<C-f>/<C-l> in insert
  -- mode and plain <C-r>{reg} is vim's register paste, so binding it would let a
  -- paste gesture fire an irreversible mark-read on the highlighted row.
  local ctrl_r = nil
  for _, m in ipairs(registered) do
    if m.key == "<C-r>" then ctrl_r = m break end
  end
  check(ctrl_r == nil, "<C-r> is NOT mapped (it shadows telescope's register-paste prefix)")

  current_picker_stub = recorded_pickers_new[1]
  current_picker_stub.refreshed_finder = nil
  selected_entry_stub = { value = { id = "ses_failjump", directory = "/tmp/f", last_event_id = 42 } }
  cr.fn()

  check(#clear_calls == 1, "<M-r> DOES fire the watermark write (positive control: the harness can see a write)")
  check(clear_calls[1] ~= nil and clear_calls[1].sid == "ses_failjump", "<M-r> payload sid is the highlighted row")
  check(clear_calls[1].last_event_id == 42, "<M-r> payload carries the row's last_event_id, not a clock")
  check(current_picker_stub.refreshed_finder ~= nil, "<M-r> refreshes the picker in place after a successful write")

  -- FAILURE PATH: clear_unread returning false must not throw and must not refresh.
  -- Discarding that boolean is exactly the mistake the deleted auto-clear warned about.
  exec.clear_unread = function() return false end
  current_picker_stub.refreshed_finder = nil
  local ok_fail = pcall(cr.fn)
  check(ok_fail, "<M-r> does not throw when the write fails")
  check(current_picker_stub.refreshed_finder == nil, "<M-r> does NOT refresh when the write failed")

  -- NO-LEDGER ROW: nil payload, no write attempted, no throw.
  exec.clear_unread = function(payload) table.insert(clear_calls, payload); return true end
  clear_calls = {}
  selected_entry_stub = { value = { id = "ses_noledger", directory = "/tmp/f" } }
  local ok_nil = pcall(cr.fn)
  check(ok_nil, "<M-r> does not throw on a row with no ledger")
  check(#clear_calls == 0, "<M-r> attempts NO write for a row with no last_event_id")

  exec.clear_unread = orig_clear
  exec.attach = orig_attach
end

-- 66. SCROLL_TO_MESSAGE: payload validation (invalid payloads return false without invoking system).
do
  local sys_calls = {}
  local fake_sys = function(cmd, opts)
    table.insert(sys_calls, { cmd = cmd, opts = opts })
    return { pid = 1 }
  end

  -- Non-table payload
  check(exec.scroll_to_message(nil, { system = fake_sys }) == false, "nil payload returns false")
  check(exec.scroll_to_message("invalid", { system = fake_sys }) == false, "string payload returns false")

  -- Missing or invalid sid
  check(exec.scroll_to_message({ message_id = "msg_1" }, { system = fake_sys }) == false, "missing sid returns false")
  check(exec.scroll_to_message({ sid = "", message_id = "msg_1" }, { system = fake_sys }) == false, "empty sid returns false")
  check(exec.scroll_to_message({ sid = 123, message_id = "msg_1" }, { system = fake_sys }) == false, "non-string sid returns false")

  -- Missing or invalid message_id
  check(exec.scroll_to_message({ sid = "ses_1" }, { system = fake_sys }) == false, "missing message_id returns false")
  check(exec.scroll_to_message({ sid = "ses_1", message_id = "" }, { system = fake_sys }) == false, "empty message_id returns false")
  check(exec.scroll_to_message({ sid = "ses_1", message_id = 123 }, { system = fake_sys }) == false, "non-string message_id returns false")

  check(#sys_calls == 0, "no system call spawned for invalid payloads")

  -- Valid payload succeeds
  check(exec.scroll_to_message({ sid = "ses_1", message_id = "msg_1" }, { system = fake_sys }) == true, "valid payload returns true")
  check(#sys_calls == 1, "system invoked exactly once for valid payload")
end

-- 67. SCROLL_TO_MESSAGE: URL resolution (default 4700, opts.frontdoor_url, env var, targets 4700 not 4731, no auth).
do
  local sys_calls = {}
  local fake_sys = function(cmd, opts)
    table.insert(sys_calls, { cmd = cmd, opts = opts })
    return { pid = 1 }
  end

  local payload = { sid = "ses_url_test", message_id = "msg_100" }

  -- Case A: Default URL targets front door (4700), NOT pigeon (4731)
  local saved_env = vim.env.OPENCODE_FRONTDOOR_URL
  vim.env.OPENCODE_FRONTDOOR_URL = nil
  sys_calls = {}
  exec.scroll_to_message(payload, { system = fake_sys })
  check(#sys_calls == 1, "system invoked for default URL")
  local default_url = nil
  for _, a in ipairs(sys_calls[1].cmd) do if a:find("^http://") then default_url = a break end end
  check(default_url == "http://127.0.0.1:4700/session/ses_url_test/scroll-to-message", "default URL targets 4700 at /session/ses_url_test/scroll-to-message; got: " .. tostring(default_url))
  check(not default_url:find(":4731"), "does NOT target pigeon port 4731")

  -- No auth header in argv
  for _, a in ipairs(sys_calls[1].cmd) do
    check(not a:find("Authorization", 1, true), "no Authorization header sent to front door")
    check(not a:find("Bearer", 1, true), "no Bearer token sent to front door")
  end

  -- Case B: OPENCODE_FRONTDOOR_URL env var honoured
  vim.env.OPENCODE_FRONTDOOR_URL = "http://127.0.0.1:9999"
  sys_calls = {}
  exec.scroll_to_message(payload, { system = fake_sys })
  check(#sys_calls == 1, "system invoked for env URL")
  local env_url = nil
  for _, a in ipairs(sys_calls[1].cmd) do if a:find("^http://") then env_url = a break end end
  check(env_url == "http://127.0.0.1:9999/session/ses_url_test/scroll-to-message", "env URL honoured; got: " .. tostring(env_url))

  -- Case C: opts.frontdoor_url overrides env var, and trailing slash is trimmed
  sys_calls = {}
  exec.scroll_to_message(payload, { system = fake_sys, frontdoor_url = "http://localhost:8888/" })
  check(#sys_calls == 1, "system invoked for opts.frontdoor_url")
  local opts_url = nil
  for _, a in ipairs(sys_calls[1].cmd) do if a:find("^http://") then opts_url = a break end end
  check(opts_url == "http://localhost:8888/session/ses_url_test/scroll-to-message", "opts.frontdoor_url overrides env and trims trailing slash; got: " .. tostring(opts_url))

  vim.env.OPENCODE_FRONTDOOR_URL = saved_env
end

-- 68. SCROLL_TO_MESSAGE: body shape and `force` parameter (true on attempt 0, false otherwise).
do
  local sys_calls = {}
  local fake_sys = function(cmd, opts)
    table.insert(sys_calls, { cmd = cmd, opts = opts })
    return { pid = 1 }
  end

  -- Case A: force = true
  sys_calls = {}
  exec.scroll_to_message({ sid = "ses_f_true", message_id = "msg_t1", force = true }, { system = fake_sys })
  check(#sys_calls == 1, "system invoked")
  local body_true = nil
  for i, a in ipairs(sys_calls[1].cmd) do if a == "--data" then body_true = sys_calls[1].cmd[i + 1] break end end
  check(body_true ~= nil, "--data argument present")
  local dec_true = vim.json.decode(body_true)
  check(dec_true.messageID == "msg_t1", "messageID is msg_t1")
  check(dec_true.force == true, "force is boolean true")

  -- Case B: force = false
  sys_calls = {}
  exec.scroll_to_message({ sid = "ses_f_false", message_id = "msg_t2", force = false }, { system = fake_sys })
  check(#sys_calls == 1, "system invoked")
  local body_false = nil
  for i, a in ipairs(sys_calls[1].cmd) do if a == "--data" then body_false = sys_calls[1].cmd[i + 1] break end end
  check(body_false ~= nil, "--data argument present")
  local dec_false = vim.json.decode(body_false)
  check(dec_false.messageID == "msg_t2", "messageID is msg_t2")
  check(dec_false.force == false, "force is boolean false")

  -- Case C: force omitted / nil defaults to false
  sys_calls = {}
  exec.scroll_to_message({ sid = "ses_f_nil", message_id = "msg_t3" }, { system = fake_sys })
  check(#sys_calls == 1, "system invoked")
  local body_nil = nil
  for i, a in ipairs(sys_calls[1].cmd) do if a == "--data" then body_nil = sys_calls[1].cmd[i + 1] break end end
  local dec_nil = vim.json.decode(body_nil)
  check(dec_nil.force == false, "omitted force defaults to false")
end

-- 69. SCROLL_TO_MESSAGE: URL-encodes session ID in path and checks curl arguments.
do
  local sys_calls = {}
  local fake_sys = function(cmd, opts)
    table.insert(sys_calls, { cmd = cmd, opts = opts })
    return { pid = 1 }
  end

  local payload = { sid = "ses/with spaces&special?100%", message_id = "msg_enc" }
  exec.scroll_to_message(payload, { system = fake_sys })
  check(#sys_calls == 1, "system invoked")

  local url = nil
  for _, a in ipairs(sys_calls[1].cmd) do if a:find("^http://") then url = a break end end
  check(url ~= nil, "URL present")
  check(url:find("ses%2Fwith%20spaces%26special%3F100%25", 1, true) ~= nil, "URL has properly percent-encoded sid; got: " .. tostring(url))
  check(not url:find(" "), "URL contains no unencoded spaces")

  -- Curl flags and opts
  check(argv_has(sys_calls[1].cmd, "curl"), "argv has curl")
  check(argv_has(sys_calls[1].cmd, "-s"), "argv has -s")
  check(argv_has(sys_calls[1].cmd, "--max-time"), "argv has --max-time")
  check(argv_has(sys_calls[1].cmd, "5"), "argv has 5s timeout")
  check(argv_has(sys_calls[1].cmd, "-X"), "argv has -X")
  check(argv_has(sys_calls[1].cmd, "POST"), "argv has POST")
  check(argv_has(sys_calls[1].cmd, "content-type: application/json"), "argv has json content-type")
  check(sys_calls[1].opts ~= nil and sys_calls[1].opts.stdin == false, "stdin is false in system opts")
end

-- 70. SCROLL_TO_MESSAGE: vim.system error (missing binary / exception) is pcall'd, does not throw, returns false.
do
  local payload = { sid = "ses_raise", message_id = "msg_err" }
  local fake_sys_raise = function()
    error("ENOENT: curl not found")
  end

  local ok, res = pcall(exec.scroll_to_message, payload, { system = fake_sys_raise })
  check(ok, "scroll_to_message does not throw when vim.system raises")
  check(res == false, "scroll_to_message returns false when system raises")
end

-- 71. INTEGRATION: jump on row with anchor schedules 4 attempts at 0 / 300 / 900 / 2000 ms with force=true on attempt 0 only.
do
  local deferred = {}
  local orig_defer = vim.defer_fn
  vim.defer_fn = function(fn, delay)
    table.insert(deferred, { fn = fn, delay = delay })
  end

  local scroll_calls = {}
  local orig_scroll = exec.scroll_to_message
  exec.scroll_to_message = function(payload, opts)
    table.insert(scroll_calls, { payload = payload, opts = opts })
    return true
  end

  local orig_attach = exec.attach
  exec.attach = function() return true end

  local row = { id = "ses_scroll_1", directory = "/tmp/s1", anchor_msg_id = "msg_target_456" }
  local fake_ctrl = flow.new({
    fetch = function(o, cb) cb({ rows = { row } }, nil) end,
    locate = function(o, cb) cb({}) end,
  })

  recorded_pickers_new = {}
  init_mod.open({ flow = fake_ctrl })
  recorded_pickers_new[1].defaults.attach_mappings(601, function() end)
  selected_entry_stub = { value = row }
  recorded_select_default()

  check(#deferred == 4, "4 scroll attempts scheduled via vim.defer_fn")
  check(deferred[1].delay == 0, "attempt 0 delay is 0 ms")
  check(deferred[2].delay == 300, "attempt 1 delay is 300 ms")
  check(deferred[3].delay == 900, "attempt 2 delay is 900 ms")
  check(deferred[4].delay == 2000, "attempt 3 delay is 2000 ms")

  -- Execute the scheduled callbacks
  for _, item in ipairs(deferred) do
    item.fn()
  end

  check(#scroll_calls == 4, "4 scroll_to_message calls executed")
  check(scroll_calls[1].payload.sid == "ses_scroll_1", "attempt 0 target sid matches row.id")
  check(scroll_calls[1].payload.message_id == "msg_target_456", "attempt 0 message_id matches anchor_msg_id")
  check(scroll_calls[1].payload.force == true, "attempt 0 has force = true (user's explicit jump)")

  check(scroll_calls[2].payload.force == false, "attempt 1 has force = false (speculative retry)")
  check(scroll_calls[3].payload.force == false, "attempt 2 has force = false (speculative retry)")
  check(scroll_calls[4].payload.force == false, "attempt 3 has force = false (speculative retry)")

  vim.defer_fn = orig_defer
  exec.scroll_to_message = orig_scroll
  exec.attach = orig_attach
end

-- 72. INTEGRATION: jump on row without anchor (nil, vim.NIL, empty string) fires NO scroll attempts.
do
  local deferred = {}
  local orig_defer = vim.defer_fn
  vim.defer_fn = function(fn, delay)
    table.insert(deferred, { fn = fn, delay = delay })
  end
  local orig_attach = exec.attach
  exec.attach = function() return true end

  for _, test_anchor in ipairs({ nil, vim.NIL, "" }) do
    deferred = {}
    local row = { id = "ses_no_anchor", directory = "/tmp/s2", anchor_msg_id = test_anchor }
    local fake_ctrl = flow.new({
      fetch = function(o, cb) cb({ rows = { row } }, nil) end,
      locate = function(o, cb) cb({}) end,
    })

    recorded_pickers_new = {}
    init_mod.open({ flow = fake_ctrl })
    recorded_pickers_new[1].defaults.attach_mappings(602, function() end)
    selected_entry_stub = { value = row }
    recorded_select_default()

    check(#deferred == 0, "no scroll attempts scheduled when anchor is " .. tostring(test_anchor))
  end

  vim.defer_fn = orig_defer
  exec.attach = orig_attach
end

-- 73. INTEGRATION: refuse_dir_missing descriptor fires NO scroll attempts even if anchor is present.
do
  local deferred = {}
  local orig_defer = vim.defer_fn
  vim.defer_fn = function(fn, delay)
    table.insert(deferred, { fn = fn, delay = delay })
  end
  local orig_refuse = exec.refuse_dir_missing
  local refuse_calls = 0
  exec.refuse_dir_missing = function() refuse_calls = refuse_calls + 1; return true end

  local row = { id = "ses_dir_missing", directory = "/tmp/nonexistent", dir_missing = true, anchor_msg_id = "msg_anchor_dm" }
  local fake_ctrl = flow.new({
    fetch = function(o, cb) cb({ rows = { row } }, nil) end,
    locate = function(o, cb) cb({}) end,
    decide = function() return { kind = "refuse_dir_missing", directory = "/tmp/nonexistent" } end,
  })

  recorded_pickers_new = {}
  init_mod.open({ flow = fake_ctrl })
  recorded_pickers_new[1].defaults.attach_mappings(603, function() end)
  selected_entry_stub = { value = row }
  recorded_select_default()

  check(refuse_calls == 1, "exec.refuse_dir_missing was called")
  check(#deferred == 0, "no scroll attempts scheduled on refuse_dir_missing path")

  vim.defer_fn = orig_defer
  exec.refuse_dir_missing = orig_refuse
end

-- 74. INTEGRATION: navigating descriptors (focus_here, switch_pane, attach) all fire the scroll attempts.
do
  local orig_defer = vim.defer_fn
  local orig_focus, orig_switch, orig_attach = exec.focus_here, exec.switch_pane, exec.attach

  for _, kind in ipairs({ "focus_here", "switch_pane", "attach" }) do
    local deferred = {}
    vim.defer_fn = function(fn, delay)
      table.insert(deferred, { fn = fn, delay = delay })
    end
    exec.focus_here = function() return true end
    exec.switch_pane = function() return true end
    exec.attach = function() return true end

    local row = { id = "ses_nav_" .. kind, directory = "/tmp/nav", anchor_msg_id = "msg_nav_" .. kind }
    local fake_ctrl = flow.new({
      fetch = function(o, cb) cb({ rows = { row } }, nil) end,
      locate = function(o, cb) cb({}) end,
      decide = function() return { kind = kind, buffer = 1, tabpage = 1, pane = "%1", sock = "/tmp/s" } end,
    })

    recorded_pickers_new = {}
    init_mod.open({ flow = fake_ctrl })
    recorded_pickers_new[1].defaults.attach_mappings(604, function() end)
    selected_entry_stub = { value = row }
    recorded_select_default()

    check(#deferred == 4, kind .. " schedules 4 scroll attempts")
  end

  vim.defer_fn = orig_defer
  exec.focus_here, exec.switch_pane, exec.attach = orig_focus, orig_switch, orig_attach
end

print("LUA_TEST_OK " .. N)
