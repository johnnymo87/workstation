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

local discovery = loadfile("assets/nvim/lua/user/session_switcher/discovery.lua")()
package.preload["user.session_switcher.discovery"] = function() return discovery end

local spec = loadfile("assets/nvim/lua/user/session_switcher/spec.lua")()
local act = loadfile("assets/nvim/lua/user/session_switcher/act.lua")()
package.preload["user.session_switcher.act"] = function() return act end

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

-- 26. WATERMARK: refuse_dir_missing returns nil (Contract 6: read-only row fires NO write).
do
  local row = { id = "ses_ro", last_event_id = 42, dir_missing = true }
  local desc = { kind = "refuse_dir_missing", directory = "/gone" }
  local wm = act.watermark(row, desc)
  check(wm == nil, "watermark for refuse_dir_missing MUST be nil (contract 6: read-only row fires no write)")
end

-- 27. WATERMARK: nil last_event_id returns nil for BOTH absent and unavailable (Contract 11).
-- Explicitly test both unread_state == 'absent' and 'unavailable' where last_event_id is nil.
do
  -- Case A: absent (pigeon has no ledger)
  local row_absent = { id = "ses_absent", unread_state = "absent", last_event_id = nil }
  local desc = { kind = "attach", sid = "ses_absent" }
  check(act.watermark(row_absent, desc) == nil, "watermark is nil when last_event_id is nil (unread_state='absent')")

  -- Case B: unavailable (routing DB unreadable)
  local row_unavail = { id = "ses_unavail", unread_state = "unavailable", last_event_id = nil }
  check(act.watermark(row_unavail, desc) == nil, "watermark is nil when last_event_id is nil (unread_state='unavailable')")

  -- Case C: vim.NIL userdata
  local row_vim_nil = { id = "ses_vim_nil", last_event_id = vim.NIL }
  check(act.watermark(row_vim_nil, desc) == nil, "watermark is nil when last_event_id is vim.NIL")

  -- Case D: non-number (e.g. string)
  local row_str = { id = "ses_str", last_event_id = "123" }
  check(act.watermark(row_str, desc) == nil, "watermark is nil when last_event_id is string")
end

-- 28. WATERMARK: missing or invalid row.id returns nil.
do
  local desc = { kind = "attach", sid = "ses_x" }
  check(act.watermark({ last_event_id = 10 }, desc) == nil, "watermark is nil when row.id is nil")
  check(act.watermark({ id = "", last_event_id = 10 }, desc) == nil, "watermark is nil when row.id is empty string")
  check(act.watermark({ id = vim.NIL, last_event_id = 10 }, desc) == nil, "watermark is nil when row.id is vim.NIL")
  check(act.watermark(nil, desc) == nil, "watermark is nil when row is nil")
  check(act.watermark({ id = "ses_1", last_event_id = 10 }, nil) == nil, "watermark is nil when desc is nil")
end

-- 29. WATERMARK: REJECTS IMPLAUSIBLY LARGE VALUES (>= 1e12 is a timestamp, not an event id).
-- Prevents catastrophic mix-up with lastActivity timestamp (~1.7e12) which would permanently hide future events.
do
  local row_ts = {
    id = "ses_ts",
    last_event_id = 1724500000000, -- epoch ms timestamp mistakenly in last_event_id
    lastActivity = 1724500000000,
  }
  local desc = { kind = "attach", sid = "ses_ts" }
  check(act.watermark(row_ts, desc) == nil, "watermark REJECTS timestamp-magnitude last_event_id >= 1e12 (defensive guard)")
end

-- 30. WATERMARK: produces correct payload for attach, switch_pane, and focus_here.
-- focusing an already-open unread row MUST still produce a watermark payload (viewing = seen).
do
  -- attach
  local row_att = { id = "ses_att", last_event_id = 15 }
  local desc_att = { kind = "attach", sid = "ses_att" }
  local wm_att = act.watermark(row_att, desc_att)
  check(type(wm_att) == "table", "watermark returns table for attach")
  check(wm_att.sid == "ses_att", "wm_att.sid equals row.id ('ses_att')")
  check(wm_att.last_event_id == 15, "wm_att.last_event_id equals row.last_event_id (15)")

  -- switch_pane
  local row_sw = { id = "ses_sw", last_event_id = 200 }
  local desc_sw = { kind = "switch_pane", pane = "%2", sock = "/tmp/a.sock" }
  local wm_sw = act.watermark(row_sw, desc_sw)
  check(type(wm_sw) == "table", "watermark returns table for switch_pane")
  check(wm_sw.sid == "ses_sw", "wm_sw.sid equals row.id ('ses_sw')")
  check(wm_sw.last_event_id == 200, "wm_sw.last_event_id equals row.last_event_id (200)")

  -- focus_here on unread row
  local row_foc = { id = "ses_foc", last_event_id = 77, unread_state = "counted", unread = 5 }
  local desc_foc = { kind = "focus_here", buffer = 3, tabpage = 1 }
  local wm_foc = act.watermark(row_foc, desc_foc)
  check(type(wm_foc) == "table", "watermark returns table for focus_here on unread row")
  check(wm_foc.sid == "ses_foc", "wm_foc.sid equals row.id ('ses_foc')")
  check(wm_foc.last_event_id == 77, "wm_foc.last_event_id equals row.last_event_id (77)")
  -- Proven exact equality
  check(wm_foc.last_event_id == row_foc.last_event_id, "wm.last_event_id is exactly row.last_event_id")
end

print("LUA_TEST_OK " .. N)
