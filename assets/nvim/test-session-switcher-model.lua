-- Unit tests for session_switcher/model.lua
-- Driven via `nvim --clean -l assets/nvim/test-session-switcher-model.lua`.

local N = 0
local function check(cond, msg) N = N + 1; assert(cond, msg) end

local model = loadfile("assets/nvim/lua/user/session_switcher/model.lua")()
local discovery = loadfile("assets/nvim/lua/user/session_switcher/discovery.lua")()

-- INJECT THE REAL discovery.is_live INTO EVERY TEST BELOW.
--
-- Without this these tests are vacuous with respect to liveness: `nvim --clean`
-- has no runtimepath entry for user.session_switcher.*, so model.lua's internal
-- `require` cannot resolve and every hit degrades to "not attached". Measured
-- 2026-08-04 on the first draft: the whole suite printed LUA_TEST_OK with
-- discovery.is_live sabotaged to `return true`. Injecting the loadfile'd module
-- makes a mutation of discovery.lua fail these tests, which is the point.
local raw_build = model.build
model.build = function(rows, hits, opts)
  opts = opts or {}
  if opts.is_live == nil then opts.is_live = discovery.is_live end
  return raw_build(rows, hits, opts)
end

-- Helper to make a dummy row
local function make_row(id, state, child_state, sort_rank)
  return {
    id = id,
    root_id = id,
    title = "Session " .. id,
    directory = "/tmp/dir",
    time_updated = 100,
    lastActivity = 100,
    updatedAt = 100,
    activity = "idle",
    error = false,
    pendingPermissions = {},
    pendingQuestions = {},
    effective_state = state or "idle",
    child_state = child_state,
    child_count = child_state and 1 or 0,
    -- Overridable, and test 8 DOES override it. See the note there: with a
    -- constant sort_rank, a mutant that sorts by sort_rank is a no-op.
    sort_rank = sort_rank or 0,
  }
end

-- 1. POSITIVE attachment: a row whose hit has attach_status="running" gets attached == true.
-- Keyed by id on row and sid on hit.
do
  local rows = { make_row("ses_1", "idle") }
  local hits = { ses_1 = { sid = "ses_1", attach_status = "running", pane = "%1" } }
  local out = model.build(rows, hits)
  check(#out == 1, "POSITIVE attachment: output has 1 row")
  check(out[1].attached == true, "POSITIVE attachment: attach_status='running' -> attached == true")
end

-- 2. attach_status="failed" => attached == false
do
  local rows = { make_row("ses_2", "idle") }
  local hits = { ses_2 = { sid = "ses_2", attach_status = "failed", pane = "%2" } }
  local out = model.build(rows, hits)
  check(#out == 1, "attach_status='failed': output has 1 row")
  check(out[1].attached == false, "attach_status='failed' -> attached == false")
end

-- 3. job_dead == true with attach_status="running" => attached == false
do
  local rows = { make_row("ses_3", "idle") }
  local hits = { ses_3 = { sid = "ses_3", attach_status = "running", job_dead = true, pane = "%3" } }
  local out = model.build(rows, hits)
  check(#out == 1, "job_dead=true: output has 1 row")
  check(out[1].attached == false, "job_dead=true with attach_status='running' -> attached == false")
end

-- 4. facet "detached" excludes attached rows; facet "attached" excludes detached ones.
-- Nonzero expected count assertions on both.
do
  local rows = {
    make_row("ses_att", "idle"),
    make_row("ses_det", "idle"),
  }
  local hits = {
    ses_att = { sid = "ses_att", attach_status = "running" },
  }

  local att_only = model.build(rows, hits, { facet = "attached" })
  check(#att_only == 1, "facet='attached' keeps attached row (expected 1, got " .. #att_only .. ")")
  check(att_only[1].id == "ses_att", "facet='attached' kept correct row id")

  local det_only = model.build(rows, hits, { facet = "detached" })
  check(#det_only == 1, "facet='detached' keeps detached row (expected 1, got " .. #det_only .. ")")
  check(det_only[1].id == "ses_det", "facet='detached' kept correct row id")
end

-- 5. blocked pierces: a DETACHED row with effective_state == "blocked" survives facet="attached".
-- Paired with negative check (ordinary idle detached row does NOT survive).
do
  local rows = {
    make_row("ses_idle_det", "idle"),
    make_row("ses_blocked_det", "blocked"),
    make_row("ses_error_det", "error"),
  }
  local hits = {}

  local out = model.build(rows, hits, { facet = "attached", blocked_pierces = true })
  check(#out == 2, "blocked/error pierces: expected 2 surviving rows (blocked & error), got " .. #out)
  local ids = { out[1].id, out[2].id }
  check(ids[1] == "ses_blocked_det" and ids[2] == "ses_error_det", "blocked/error pierces kept blocked & error rows")
end

-- 6. child_blocked pierces: a DETACHED row with effective_state == "idle" and child_state == "blocked" survives facet="attached".
-- Paired with negative check.
do
  local rows = {
    make_row("ses_normal_idle", "idle", nil),
    make_row("ses_child_blocked", "idle", "blocked"),
    make_row("ses_child_error", "idle", "error"),
  }
  local hits = {}

  local out = model.build(rows, hits, { facet = "attached", blocked_pierces = true })
  check(#out == 2, "child_state pierces: expected 2 surviving rows, got " .. #out)
  check(out[1].id == "ses_child_blocked" and out[2].id == "ses_child_error", "child blocked/error survived facet='attached'")
end

-- 7. blocked_pierces = false => that same row is filtered out (proves pierce is doing the work).
do
  local rows = {
    make_row("ses_blocked_det", "blocked"),
    make_row("ses_child_blocked", "idle", "blocked"),
  }
  local hits = {}

  local out = model.build(rows, hits, { facet = "attached", blocked_pierces = false })
  check(#out == 0, "blocked_pierces=false: detached blocked/child_blocked rows filtered out by facet='attached'")
end

-- 8. Order preservation: feed rows in a deliberately non-sorted order (e.g. idle first, blocked last)
-- and assert output id sequence EQUALS input id sequence.
do
  -- These fixtures carry DISTINCT sort_rank values, unlike every other test
  -- here, and that is load-bearing: measured 2026-08-04, a mutant adding
  -- `table.sort(out, by sort_rank)` SURVIVED while the fixtures were all-zero,
  -- because sorting an all-equal list changes nothing.
  -- sort_rank DESCENDING in input order: the CLI's own ordering key, fed in
  -- backwards. Any re-sort by attention tier -- the tempting "helpful" mutation
  -- -- reverses this list and fails. The module must trust the CLI's order.
  local rows = {
    make_row("ses_z_idle", "idle", nil, 6),
    make_row("ses_a_blocked", "blocked", nil, 1),
    make_row("ses_m_working", "working", nil, 3),
  }
  local hits = {}
  local out = model.build(rows, hits)
  check(#out == 3, "order test output count matches input count")
  check(out[1].id == "ses_z_idle", "order preserved row 1")
  check(out[2].id == "ses_a_blocked", "order preserved row 2")
  check(out[3].id == "ses_m_working", "order preserved row 3")
end

-- 9. Order preservation THROUGH filtering: assert exact surviving id sequence.
do
  local rows = {
    make_row("ses_1_att", "idle"),
    make_row("ses_2_det", "idle"),
    make_row("ses_3_att", "idle"),
    make_row("ses_4_det", "idle"),
  }
  local hits = {
    ses_1_att = { sid = "ses_1_att", attach_status = "running" },
    ses_3_att = { sid = "ses_3_att", attach_status = "running" },
  }
  local out = model.build(rows, hits, { facet = "attached" })
  check(#out == 2, "order through filtering: count is 2")
  check(out[1].id == "ses_1_att" and out[2].id == "ses_3_att", "order preserved through attached filter")

  local out_det = model.build(rows, hits, { facet = "detached" })
  check(#out_det == 2, "order through filtering detached: count is 2")
  check(out_det[1].id == "ses_2_det" and out_det[2].id == "ses_4_det", "order preserved through detached filter")
end

-- 10. Empty hits => every row attached == false AND #out == #rows with #rows > 0.
do
  local rows = {
    make_row("ses_a", "idle"),
    make_row("ses_b", "working"),
  }
  local out = model.build(rows, {})
  check(#rows > 0, "test fixture has #rows > 0")
  check(#out == #rows, "empty hits: #out == #rows")
  check(out[1].attached == false and out[2].attached == false, "empty hits: all attached == false")
end

-- 11. M.build(nil, nil) returns {} (no crash).
do
  local out1 = model.build(nil, nil)
  check(type(out1) == "table" and #out1 == 0, "M.build(nil, nil) returns {}")

  local out2 = model.build("not a list", {})
  check(type(out2) == "table" and #out2 == 0, "M.build(non-table, {}) returns {}")
end

-- 12. Non-mutation: after build, ORIGINAL row table has no `attached` key.
do
  local orig_row = make_row("ses_orig", "idle")
  local rows = { orig_row }
  local hits = { ses_orig = { sid = "ses_orig", attach_status = "running" } }
  local out = model.build(rows, hits)
  check(#out == 1, "build returns 1 row")
  check(rawget(orig_row, "attached") == nil, "original row table was not mutated (attached key is nil)")
  check(out[1] ~= orig_row, "returned row is a shallow copy, not original table reference")
end

-- 13. pane/buffer/tabpage/sock/own carried through from hit onto row.
do
  local rows = { make_row("ses_meta", "idle") }
  local hits = {
    ses_meta = {
      sid = "ses_meta",
      attach_status = "failed", -- dead hit, but pane/buffer/etc still carried over!
      pane = "%42",
      sock = "/tmp/nvim-42.sock",
      buffer = 12,
      tabpage = 2,
      own = true,
    }
  }
  local out = model.build(rows, hits)
  check(#out == 1, "meta test output count 1")
  check(out[1].attached == false, "attach_status failed -> attached == false")
  check(out[1].pane == "%42", "pane carried through from hit")
  check(out[1].sock == "/tmp/nvim-42.sock", "sock carried through from hit")
  check(out[1].buffer == 12, "buffer carried through from hit")
  check(out[1].tabpage == 2, "tabpage carried through from hit")
  check(out[1].own == true, "own carried through from hit")
end

-- 14. THE UNINJECTED DEFAULT PATH DEGRADES SAFELY.
-- Every test above injects is_live. This one exercises the real default, where
-- `require("user.session_switcher.discovery")` cannot resolve under --clean. The
-- module must then report NOT attached -- never "attached" by accident, which
-- would send the user into a terminal nobody verified. Paired with a positive
-- assertion (the row survives, so the join demonstrably ran) to keep it honest.
do
  local rows = { make_row("ses_dflt", "idle") }
  local hits = { ses_dflt = { sid = "ses_dflt", attach_status = "running", pane = "%9" } }
  local out = raw_build(rows, hits, {})
  check(#out == 1, "unresolvable discovery: the row still renders (join ran)")
  check(out[1].attached == false,
    "unresolvable discovery -> NOT attached (a false 'live' teleports the user into a corpse)")
  check(out[1].pane == "%9", "unresolvable discovery: diagnostic hit fields still carried")
end

-- 15. A PIERCED row is marked as such.
-- Task 9 jumps to `pane`, and a pierced row can be in the "attached" facet
-- while being detached and pane-less. The picker must be able to tell those
-- apart without re-deriving the filter, so the reason for survival is a field.
-- Paired with an ordinary attached row asserting pierced == false, so this
-- cannot pass by marking everything.
do
  local blocked = make_row("ses_pierced", "blocked")
  local normal = make_row("ses_normal", "idle")
  local hits = { ses_normal = { sid = "ses_normal", attach_status = "running", pane = "%3" } }
  local out = model.build({ blocked, normal }, hits, { facet = "attached" })
  check(#out == 2, "pierced test: blocked row survives alongside the attached one")
  check(out[1].id == "ses_pierced", "pierced test: order still preserved")
  check(out[1].pierced == true, "blocked+detached row is marked pierced")
  check(out[1].attached == false, "pierced row is still reported as DETACHED")
  check(out[1].pane == nil, "pierced row has no pane -- the landmine this field warns about")
  check(out[2].pierced == false, "an ordinary attached row is NOT marked pierced")
end

-- 16. unread_badge: "counted" with positive count renders "(N)".
do
  local row = { unread_state = "counted", unread = 3 }
  local badge = model.unread_badge(row)
  check(badge == "(3)", "counted with positive unread renders '(3)', got " .. tostring(badge))

  local row_large = { unread_state = "counted", unread = 42 }
  check(model.unread_badge(row_large) == "(42)", "counted with 42 unread renders '(42)'")
end

-- 17. unread_badge: "counted" with 0 renders empty string (no badge).
do
  local row = { unread_state = "counted", unread = 0 }
  local badge = model.unread_badge(row)
  check(badge == "", "counted with unread=0 renders empty string (no badge), got " .. tostring(badge))
end

-- 18. unread_badge: "absent" renders "·" (and NOT "?", and NOT "(0)").
do
  local row = { unread_state = "absent", unread = nil }
  local badge = model.unread_badge(row)
  check(badge == "·", "absent renders '·', got " .. tostring(badge))
  check(badge ~= "?", "absent must NOT render '?'")
  check(badge ~= "(0)", "absent must NOT render '(0)'")
  check(badge ~= "", "absent must NOT render empty string")
end

-- 19. unread_badge: "unavailable" renders "?" (and NOT "·").
do
  local row = { unread_state = "unavailable", unread = nil }
  local badge = model.unread_badge(row)
  check(badge == "?", "unavailable renders '?', got " .. tostring(badge))
  check(badge ~= "·", "unavailable must NOT render '·'")
end

-- 20. Glyph distinctness: "·" and "?" are strictly different strings.
-- Explicit review invariant: per-session absence is chronic; outage is noisy.
do
  local absent_row = { unread_state = "absent" }
  local unavail_row = { unread_state = "unavailable" }
  local absent_badge = model.unread_badge(absent_row)
  local unavail_badge = model.unread_badge(unavail_row)
  check(absent_badge ~= unavail_badge, "absent glyph and unavailable glyph MUST be distinguishable")
  check(absent_badge == "·" and unavail_badge == "?", "glyphs match expected constants")
end

-- 21. Robustness: row from old CLI (no unread fields, unread_state is nil) degrades to "?" without error.
do
  local old_row = make_row("ses_old", "idle")
  check(rawget(old_row, "unread_state") == nil, "fixture row unread_state is nil")
  local ok, badge = pcall(model.unread_badge, old_row)
  check(ok, "unread_badge does not throw on old CLI row")
  check(badge == "?", "old CLI row (missing unread_state) renders '?', got " .. tostring(badge))

  local nil_row_ok, nil_badge = pcall(model.unread_badge, nil)
  check(nil_row_ok and nil_badge == "?", "nil row degrades to '?' without error")

  local empty_row_badge = model.unread_badge({})
  check(empty_row_badge == "?", "empty table degrades to '?'")

  local unknown_state_badge = model.unread_badge({ unread_state = "corrupted_state" })
  check(unknown_state_badge == "?", "unrecognised unread_state degrades to '?'")
end

-- 22. Robustness: vim.NIL in unread_state or unread does not take wrong branches.
do
  local row_vim_nil_state = { unread_state = vim.NIL, unread = 5 }
  local badge1 = model.unread_badge(row_vim_nil_state)
  check(badge1 == "?", "vim.NIL unread_state degrades to '?', got " .. tostring(badge1))

  local row_vim_nil_unread = { unread_state = "counted", unread = vim.NIL }
  local badge2 = model.unread_badge(row_vim_nil_unread)
  check(badge2 == "?", "counted with vim.NIL unread degrades to '?', got " .. tostring(badge2))
end

-- 23. Robustness: "counted" with non-number unread does not render "(nil)" or error.
do
  local test_cases = {
    { unread_state = "counted", unread = nil },
    { unread_state = "counted", unread = "three" },
    { unread_state = "counted", unread = {} },
    { unread_state = "counted", unread = true },
  }
  for i, tc in ipairs(test_cases) do
    local ok, badge = pcall(model.unread_badge, tc)
    check(ok, "counted with non-number unread does not throw (case " .. i .. ")")
    check(badge ~= "(nil)", "counted with non-number unread must NOT render '(nil)' (case " .. i .. ")")
    check(badge == "?", "counted with non-number unread degrades to '?' (case " .. i .. ")")
  end
end

-- 24. M.build carries last_event_id, unread, unread_state, and attention through to output rows.
do
  local row = make_row("ses_fields", "idle")
  row.unread = 7
  row.unread_state = "counted"
  row.last_event_id = 142
  row.attention = true

  local out = model.build({ row }, {})
  check(#out == 1, "build returns 1 row")
  check(out[1].last_event_id == 142, "last_event_id preserved on output row")
  check(out[1].unread == 7, "unread count preserved on output row")
  check(out[1].unread_state == "counted", "unread_state preserved on output row")
  check(out[1].attention == true, "attention preserved on output row")
end

-- 25. Order preservation: unread count does NOT alter CLI row ordering.
do
  local rows = {
    make_row("ses_first", "idle"),
    make_row("ses_second", "idle"),
    make_row("ses_third", "idle"),
  }
  rows[1].unread = 0
  rows[1].unread_state = "counted"
  rows[2].unread = 999
  rows[2].unread_state = "counted"
  rows[3].unread = nil
  rows[3].unread_state = "absent"

  local out = model.build(rows, {})
  check(#out == 3, "count matches")
  check(out[1].id == "ses_first", "first row kept in 1st place despite unread=0")
  check(out[2].id == "ses_second", "second row kept in 2nd place despite unread=999")
  check(out[3].id == "ses_third", "third row kept in 3rd place despite unread=nil")
end

print("LUA_TEST_OK " .. N)
