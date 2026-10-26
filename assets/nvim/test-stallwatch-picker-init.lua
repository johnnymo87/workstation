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
local cli = loadfile("assets/nvim/lua/user/session_switcher/cli.lua")()
package.preload["user.session_switcher.cli"] = function() return cli end
local act = loadfile("assets/nvim/lua/user/session_switcher/act.lua")()
package.preload["user.session_switcher.act"] = function() return act end

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
local source = loadfile("assets/nvim/lua/user/stallwatch_picker/source.lua")()
package.preload["user.stallwatch_picker.source"] = function()
  return {
    fetch = function() error("tests inject opts.fetch") end,
    wake = source.wake,
    wake_cmd = source.wake_cmd,
    run = source.run,
    coordinator_id = source.coordinator_id,
    items_cmd = source.items_cmd,
    decode_items = source.decode_items,
    WAKE_ENV = source.WAKE_ENV,
    DEFAULT_WAKE_CMD = source.DEFAULT_WAKE_CMD,
    ENV = source.ENV,
    DEFAULT_CMD = source.DEFAULT_CMD,
    REREAD_TIMEOUT_MS = source.REREAD_TIMEOUT_MS,
    export = source.export,
    EXPORT_TIMEOUT_MS = source.EXPORT_TIMEOUT_MS,
  }
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
init.open({
  flow = ctrl,
  fetch = function(_o, cb) fetch_calls = fetch_calls + 1; cb(SNAP, nil) end,
  system = function() return { pid = 1, kill = function() end } end,
})
check(fetch_calls == 1, "snapshot fetched once at open")
check(tmux_calls == 1, "tmux client captured once at open")
check(#new_calls == 1 and new_calls[1].found, "Screen 1 opened")
local s1 = new_calls[1]
check(s1.defaults.finder.results[1].tag == "alpha" and s1.defaults.finder.results[2].tag == "beta", "Screen 1 keeps source order")
check(s1.defaults.sorting_strategy == "descending", "Screen 1 uses the switcher's descending strategy")
check(s1.defaults.default_selection_index == nil, "first open forces no selection")
check(s1.defaults.sorter and s1.defaults.sorter.stub == "sorter", "a real sorter reaches pickers.new (else no filtering)")
check(s1.defaults.previewer and s1.defaults.previewer.stub == "previewer", "previewer wired")
check(s1.prompt_title == "Stall-watch programs  <C-o> coordinator [⚠ 1]", "partial failure shows ⚠ in the title")
check(#notified == 1, "warnings notified once")

-- previewer writes the program's lines into the preview buffer.
do
  local buf = vim.api.nvim_create_buf(false, true)
  s1.defaults.previewer.define_preview({ state = { bufnr = buf } }, { value = s1.defaults.finder.results[1] })
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  check(lines[1]:find("coordinator goose:20990101_1", 1, true) ~= nil and lines[4]:find("^%[decision%]") ~= nil,
    "program previewer renders coordinator block above items")
end

-- previewers soft-wrap long item text at word boundaries (both screens).
do
  local buf = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_open_win(buf, false, { relative = "editor", row = 0, col = 0, width = 20, height = 5 })
  vim.wo[win].wrap = false
  s1.defaults.previewer.define_preview({ state = { bufnr = buf, winid = win } }, { value = s1.defaults.finder.results[1] })
  check(vim.wo[win].wrap == true, "program preview window wraps")
  check(vim.wo[win].linebreak == true, "program preview wraps at word boundaries")
  -- no winid (or a dead one) must not error
  local ok = pcall(s1.defaults.previewer.define_preview, { state = { bufnr = buf } }, { value = s1.defaults.finder.results[1] })
  check(ok, "preview without a window does not error")
  vim.api.nvim_win_close(win, true)
end

-- 2. <CR> on a program -> close, then (scheduled) Screen 2 flagged view.
local m1 = mappings_of(s1, 11)
check(m1["<C-d>"] ~= nil, "Screen 1 maps <C-d>")
check(m1["<C-g>"] ~= nil, "Screen 1 maps <C-g>")
check(vim.tbl_contains(m1["<C-g>"].modes, "i") and vim.tbl_contains(m1["<C-g>"].modes, "n"),
  "Screen 1 maps <C-g> in insert and normal mode")
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
  local q_map = vim.fn.maparg("q", "n", false, true)
  check(q_map.buffer == 1 and q_map.rhs == "<cmd>close<CR>", "buffer-local q mapped to <cmd>close<CR>")
  local win_count = #vim.api.nvim_list_wins()
  vim.cmd("normal q")
  check(#vim.api.nvim_list_wins() == win_count - 1, "q closes the digest window")
  check(not vim.api.nvim_buf_is_valid(buf), "closing wipes the digest buffer")

  local orig_uv = vim.uv
  local orig_loop = vim.loop
  local loop_called = false
  vim.uv = nil
  vim.loop = {
    fs_stat = function(p)
      loop_called = true
      return orig_uv.fs_stat(p)
    end,
  }
  local buf_loop = init.show_digest(path)
  check(loop_called, "fs_stat falls back to vim.loop when vim.uv is nil")
  if buf_loop and vim.api.nvim_buf_is_valid(buf_loop) then
    vim.cmd("bwipeout! " .. buf_loop)
  end
  vim.uv = orig_uv
  vim.loop = orig_loop

  local seen
  local orig = vim.notify
  vim.notify = function(msg) seen = msg end
  check(init.show_digest(nil) == nil and seen == "stall-watch: no digest yet", "null digest -> 'no digest yet'")
  check(init.show_digest("/nonexistent/fixture/digest") == nil, "missing file -> 'no digest yet'")
  vim.notify = orig
  os.remove(path)
end

-- 8. <C-g> wakes the selected program, notifications, picker stays open.
do
  local wake_calls = {}
  local fake_sys = function(argv, _o, on_exit)
    table.insert(wake_calls, argv)
    local code = 0
    local stderr = ""
    if argv[2] == "fail_prog" then
      code = 2
      stderr = "unknown program tag 'fail_prog'\n"
    elseif argv[2] == "hang_prog" then
      return { pid = 1, kill = function() end }
    end
    vim.schedule(function()
      on_exit({ code = code, signal = 0, stdout = "", stderr = stderr })
    end)
    return { pid = 1, kill = function() end }
  end

  local notify_calls = {}
  local orig_notify = vim.notify
  vim.notify = function(msg, level)
    table.insert(notify_calls, { msg = msg, level = level })
  end

  init.open({
    flow = ctrl,
    fetch = function(_o, cb) cb(SNAP, nil) end,
    system = fake_sys,
    wake_timeout_ms = 50,
  })
  local wake_picker = new_calls[#new_calls]
  local wm = mappings_of(wake_picker, 99)
  check(wm["<C-g>"] ~= nil, "Screen 1 maps <C-g>")

  -- (a) Success: exit 0 -> INFO notification "stall-watch: waking <tag>", picker stays open
  local closed_before = #closed
  selected_entry = { value = { tag = "alpha" } }
  wm["<C-g>"].fn()
  vim.wait(200, function() return #wake_calls == 1 end)
  check(#wake_calls == 1, "wake spawned")
  check(wake_calls[1][2] == "alpha" and wake_calls[1][3] == "--source" and wake_calls[1][4] == "picker",
    "wake argv: tag --source picker")
  vim.wait(200, function() return #notify_calls == 1 end)
  check(#notify_calls == 1, "notify called on exit 0")
  check(notify_calls[1].msg == "stall-watch: waking alpha" and notify_calls[1].level == vim.log.levels.INFO,
    "exit 0 -> INFO 'stall-watch: waking alpha'")
  check(#closed == closed_before, "picker stays open on wake")

  -- (b) Error: exit non-zero -> WARN notification with trimmed stderr
  selected_entry = { value = { tag = "fail_prog" } }
  wm["<C-g>"].fn()
  vim.wait(200, function() return #wake_calls == 2 end)
  vim.wait(200, function() return #notify_calls == 2 end)
  check(#notify_calls == 2, "notify called on exit 2")
  check(notify_calls[2].msg == "unknown program tag 'fail_prog'" and notify_calls[2].level == vim.log.levels.WARN,
    "exit non-zero -> WARN with trimmed stderr")
  check(#closed == closed_before, "picker stays open on wake error")

  -- (c) Timeout -> WARN notification "timed out"
  selected_entry = { value = { tag = "hang_prog" } }
  wm["<C-g>"].fn()
  vim.wait(200, function() return #wake_calls == 3 end)
  vim.wait(300, function() return #notify_calls == 3 end)
  check(#notify_calls == 3, "notify called on timeout")
  check(notify_calls[3].msg == "timed out" and notify_calls[3].level == vim.log.levels.WARN,
    "timeout -> WARN 'timed out'")
  check(#closed == closed_before, "picker stays open on timeout")

  vim.notify = orig_notify
end

-- 9. <C-o> coordinator mapping
do
  local test_doc = {
    version = 1,
    programs = {
      { tag = "alpha", coordinator = { goose_id = "20990101_1" }, items = {} },
      { tag = "beta", coordinator = {}, items = {} },
      { tag = "gamma", coordinator = { goose_id = "20990101_2" }, items = {} },
      { tag = "delta", coordinator = { goose_id = "20990101_3" }, items = {} },
      { tag = "epsilon", items = {} }, -- coordinator key absent -> unsupported
    },
  }
  local test_rows = {
    { id = "goose:20990101_1", title = "Coord Alpha", directory = "/fixture/alpha/coord", dir_missing = false },
    { id = "goose:20990101_3", title = "Coord Delta", directory = "/fixture/delta/coord", dir_missing = true },
  }
  local test_snap = {
    doc = test_doc,
    tagged = { alpha = {}, beta = {}, gamma = {}, delta = {}, epsilon = {} },
    rows = test_rows,
    warnings = {},
  }

  local shared_order_log = {}
  local spawn_calls = {}
  local fake_sys_response
  local fake_sys = function(argv, _o, on_exit)
    table.insert(spawn_calls, argv)
    table.insert(shared_order_log, { event = "spawn", argv = argv })
    local resp = fake_sys_response or { code = 0, stdout = vim.json.encode(test_doc), stderr = "" }
    vim.schedule(function()
      on_exit(resp)
    end)
    return { pid = 1, kill = function() end }
  end

  local notify_calls = {}
  local orig_notify = vim.notify
  vim.notify = function(msg, level)
    table.insert(notify_calls, { msg = msg, level = level })
  end

  local orig_close = stub_actions.close
  stub_actions.close = function(bufnr)
    table.insert(shared_order_log, { event = "close", bufnr = bufnr })
    orig_close(bufnr)
  end

  local coord_accepted = {}
  local coord_ctrl = {
    accept = function(_, row, cb)
      table.insert(coord_accepted, row)
      cb({ kind = "attach", sid = row.id })
    end,
  }

  init.open({
    flow = coord_ctrl,
    fetch = function(_o, cb) cb(test_snap, nil) end,
    system = fake_sys,
  })

  local coord_picker = new_calls[#new_calls]
  local prompt_bufnr = 150
  local cm = mappings_of(coord_picker, prompt_bufnr)

  -- 1. Screen 1 maps <C-o> (i and n).
  check(cm["<C-o>"] ~= nil, "Screen 1 maps <C-o>")
  check(vim.tbl_contains(cm["<C-o>"].modes, "i") and vim.tbl_contains(cm["<C-o>"].modes, "n"),
    "Screen 1 maps <C-o> in insert and normal mode")

  local prows = coord_picker.defaults.finder.results

  -- 2. On beta (none): exactly one notify containing 'no coordinator session bound for beta';
  --    the picker is NOT closed (actions.close not called); fake system saw no spawn.
  local closed_before = #closed
  local spawn_before = #spawn_calls
  local notify_before = #notify_calls
  selected_entry = { value = prows[2] } -- beta
  cm["<C-o>"].fn()
  check(#notify_calls == notify_before + 1, "beta (none): exactly one notify")
  check(notify_calls[#notify_calls].msg:find("no coordinator session bound for beta", 1, true) ~= nil,
    "beta notify says 'no coordinator session bound for beta'")
  check(notify_calls[#notify_calls].level == vim.log.levels.INFO, "beta notify is INFO")
  check(#closed == closed_before, "beta (none): picker is NOT closed")
  check(#spawn_calls == spawn_before, "beta (none): fake system saw no spawn")

  -- 3. On alpha (live), with fake system answering items.sh with alpha-bound doc:
  --    actions.close is called BEFORE items.sh spawn (record order in one shared log);
  --    ctrl.accept receives the snapshot's joined row (same table, rawequal);
  --    dispatched has sid == "goose:20990101_1".
  shared_order_log = {}
  fake_sys_response = { code = 0, stdout = vim.json.encode(test_doc), stderr = "" }
  selected_entry = { value = prows[1] } -- alpha
  cm["<C-o>"].fn()
  vim.wait(200, function() return #coord_accepted == 1 end)
  check(#shared_order_log >= 2, "alpha (live): close and spawn logged")
  check(shared_order_log[1].event == "close" and shared_order_log[2].event == "spawn",
    "alpha (live): actions.close is called BEFORE items.sh spawn")
  check(shared_order_log[1].bufnr == prompt_bufnr, "actions.close called with prompt_bufnr")
  check(#coord_accepted == 1, "alpha (live): ctrl.accept called once")
  check(rawequal(coord_accepted[1], test_rows[1]), "alpha (live): ctrl.accept receives snapshot's joined row (rawequal)")
  check(dispatched[#dispatched] ~= nil and dispatched[#dispatched].desc.sid == "goose:20990101_1",
    "alpha (live): dispatched sid == goose:20990101_1")
  check(dispatched[#dispatched].row.id == "goose:20990101_1",
    "alpha (live): dispatched row.id == goose:20990101_1")

  -- 4. Re-read returns a different id (20990101_7) ->
  --    accept receives a row equal to model.minimal_coord_row("alpha", "20990101_7") (compare fields).
  local diff_doc = {
    version = 1,
    programs = {
      { tag = "alpha", coordinator = { goose_id = "20990101_7" } },
    },
  }
  fake_sys_response = { code = 0, stdout = vim.json.encode(diff_doc), stderr = "" }
  selected_entry = { value = prows[1] }
  cm["<C-o>"].fn()
  vim.wait(200, function() return #coord_accepted == 2 end)
  check(#coord_accepted == 2, "re-read different id: accept called")
  local exp_diff = model.minimal_coord_row("alpha", "20990101_7")
  check(coord_accepted[2].id == exp_diff.id and coord_accepted[2].title == exp_diff.title,
    "re-read different id -> minimal row matching 20990101_7")
  check(not rawequal(coord_accepted[2], test_rows[1]),
    "re-read different id -> not the snapshot row")

  -- 5. Re-read fails (items exits 1) -> accept receives the snapshot row for 20990101_1.
  fake_sys_response = { code = 1, stdout = "", stderr = "read error" }
  selected_entry = { value = prows[1] }
  cm["<C-o>"].fn()
  vim.wait(200, function() return #coord_accepted == 3 end)
  check(#coord_accepted == 3, "re-read fails: accept called")
  check(rawequal(coord_accepted[3], test_rows[1]),
    "re-read fails -> accept receives snapshot row for 20990101_1 (rawequal)")

  -- 6. Re-read returns unbound -> a notify follows, no accept, and the picker was already closed.
  local unbound_doc = {
    version = 1,
    programs = {
      { tag = "alpha", coordinator = {} },
    },
  }
  fake_sys_response = { code = 0, stdout = vim.json.encode(unbound_doc), stderr = "" }
  closed_before = #closed
  notify_before = #notify_calls
  local accept_before = #coord_accepted
  selected_entry = { value = prows[1] }
  cm["<C-o>"].fn()
  check(#closed == closed_before + 1, "re-read returns unbound: picker was already closed")
  vim.wait(200, function() return #notify_calls > notify_before end)
  check(#notify_calls == notify_before + 1, "re-read returns unbound: a notify follows")
  check(notify_calls[#notify_calls].msg:find("no coordinator session bound for alpha", 1, true) ~= nil,
    "unbound notify contains 'no coordinator session bound for alpha'")
  check(notify_calls[#notify_calls].level == vim.log.levels.INFO, "unbound notify is INFO")
  check(#coord_accepted == accept_before, "re-read returns unbound: no accept")

  -- 7. unresolved (alpha/gamma bound but not in rows) -> still accepts and dispatches a minimal row.
  fake_sys_response = { code = 0, stdout = vim.json.encode(test_doc), stderr = "" }
  selected_entry = { value = prows[3] } -- gamma
  cm["<C-o>"].fn()
  vim.wait(200, function() return #coord_accepted == 4 end)
  check(#coord_accepted == 4, "unresolved: accept called")
  local exp_gamma = model.minimal_coord_row("gamma", "20990101_2")
  check(coord_accepted[4].id == exp_gamma.id and coord_accepted[4].title == exp_gamma.title,
    "unresolved -> minimal row matches gamma 20990101_2")
  check(dispatched[#dispatched] ~= nil and dispatched[#dispatched].desc.sid == "goose:20990101_2",
    "unresolved -> dispatched sid == goose:20990101_2")

  -- 8. dir_missing: run the REAL require("user.session_switcher.act").decide(row, nil) on the accepted row
  --    (snapshot row with dir_missing=true) and expect kind == "refuse_dir_missing".
  fake_sys_response = { code = 0, stdout = vim.json.encode(test_doc), stderr = "" }
  selected_entry = { value = prows[4] } -- delta
  cm["<C-o>"].fn()
  vim.wait(200, function() return #coord_accepted == 5 end)
  check(#coord_accepted == 5, "dir_missing: accept called")
  check(rawequal(coord_accepted[5], test_rows[2]), "dir_missing: accept receives snapshot row")
  local real_act = require("user.session_switcher.act")
  local act_desc = real_act.decide(coord_accepted[5], nil)
  check(type(act_desc) == "table" and act_desc.kind == "refuse_dir_missing",
    "dir_missing: real act.decide yields kind == refuse_dir_missing")

  -- 9. unsupported (coordinator key absent): notify contains "does not report coordinators", no close, no spawn.
  closed_before = #closed
  spawn_before = #spawn_calls
  notify_before = #notify_calls
  selected_entry = { value = prows[5] } -- epsilon
  cm["<C-o>"].fn()
  check(#notify_calls == notify_before + 1, "unsupported: exactly one notify")
  check(notify_calls[#notify_calls].msg:find("does not report coordinators", 1, true) ~= nil,
    "unsupported: notify contains 'does not report coordinators'")
  check(notify_calls[#notify_calls].level == vim.log.levels.INFO, "unsupported notify is INFO")
  check(#closed == closed_before, "unsupported: picker is NOT closed")
  check(#spawn_calls == spawn_before, "unsupported: no spawn")

  -- 10. Across every case, no spawn whose argv[1] ends in wake.sh, and no spawn other than items.sh.
  check(#spawn_calls > 0, "fake system was called for items.sh re-reads")
  for _, argv in ipairs(spawn_calls) do
    check(not tostring(argv[1]):match("wake%.sh$"), "fake system: no spawn ends in wake.sh")
    check(tostring(argv[1]):match("items%.sh$") ~= nil or argv[2] == "--json",
      "fake system: no spawn other than items.sh")
  end

  stub_actions.close = orig_close
  vim.notify = orig_notify
end

-- 10. Screen 1 async coordinator preview
do
  local orig_debounce = init.PREVIEW_DEBOUNCE_MS
  init.PREVIEW_DEBOUNCE_MS = 20

  local export_doc = {
    conversation = {
      {
        role = "assistant",
        content = {
          { type = "text", text = "Coordinator assistant message for alpha" },
        },
      },
    },
  }
  local export_json = vim.json.encode(export_doc)

  local alpha_prog = {
    tag = "alpha",
    coord = {
      state = "live",
      goose_id = "20990101_1",
      row = { effective_state = "idle", lastActivity = os.time() * 1000 - 60000 },
    },
    items = {
      { kind = "decision", text = "Fix the widget", status = "open", sessions = {} },
    },
  }

  local beta_prog = {
    tag = "beta",
    coord = { state = "none" },
    items = {
      { kind = "review", text = "Review the patch", status = "open", sessions = {} },
    },
  }

  local gamma_prog = {
    tag = "gamma",
    coord = {
      state = "live",
      goose_id = "20990101_3",
      row = { effective_state = "working" },
    },
    items = {
      { kind = "question", text = "Is this broken?", status = "open", sessions = {} },
    },
  }

  local all_spawns = {}
  local goose_spawns = {}
  local pending_replies = {}
  local fake_sys = function(argv, _o, on_exit)
    table.insert(all_spawns, argv)
    if argv[1] == "goose" then
      local call = { argv = argv, on_exit = on_exit }
      table.insert(goose_spawns, call)
      local reply_fn = pending_replies[argv[5]]
      if reply_fn then
        reply_fn(on_exit)
      else
        vim.schedule(function()
          on_exit({ code = 0, signal = 0, stdout = export_json, stderr = "" })
        end)
      end
    end
    return { pid = 1, kill = function() end }
  end

  local test_ctrl = { accept = function() end }
  local test_state = {
    snap = { doc = { programs = {} }, rows = {}, tagged = {}, warnings = {} },
    prows = { alpha_prog, beta_prog, gamma_prog },
    by_id = {},
    client = "client_fixture",
    controller = test_ctrl,
    opts = { system = fake_sys },
    coord_cache = {},
    coord_inflight = {},
    preview = nil,
  }

  local picker1 = init.programs(test_state, nil)
  local previewer = picker1.defaults.previewer

  -- 1. Select alpha (live): buffer immediately shows "(loading…)" above items.
  -- After debounce + reply, exactly one goose spawn happened, buffer shows extracted text,
  -- and item lines are still below.
  local buf1 = vim.api.nvim_create_buf(false, true)
  previewer.define_preview({ state = { bufnr = buf1 } }, { value = alpha_prog })

  local lines_imm = vim.api.nvim_buf_get_lines(buf1, 0, -1, false)
  check(#lines_imm >= 4, "alpha preview immediately has lines")
  check(lines_imm[1]:find("coordinator goose:20990101_1", 1, true) ~= nil, "alpha preview header shows goose id")
  check(lines_imm[2] == "(loading…)", "alpha preview line 2 is (loading…)")
  check(lines_imm[4]:find("^%[decision%]") ~= nil, "alpha preview line 4 has decision item")
  check(#goose_spawns == 0, "no goose spawn before debounce window")

  vim.wait(500, function() return #goose_spawns == 1 end, 5)
  check(#goose_spawns == 1, "exactly one goose spawn after debounce")
  check(goose_spawns[1].argv[1] == "goose" and goose_spawns[1].argv[3] == "export" and goose_spawns[1].argv[5] == "20990101_1",
    "goose export argv has correct session id")

  vim.wait(500, function()
    local l = vim.api.nvim_buf_get_lines(buf1, 0, -1, false)
    return l[2] ~= "(loading…)"
  end, 5)
  local lines_done = vim.api.nvim_buf_get_lines(buf1, 0, -1, false)
  check(lines_done[2] == "Coordinator assistant message for alpha", "alpha preview line 2 shows extracted text")
  check(lines_done[4]:find("^%[decision%]") ~= nil, "alpha preview items still below")

  -- 2. Debounce: select alpha, then beta, then alpha within debounce window -> exactly 1 export spawn for alpha.
  test_state.coord_cache = {}
  test_state.coord_inflight = {}
  test_state.preview = nil
  goose_spawns = {}

  local buf2_a = vim.api.nvim_create_buf(false, true)
  local buf2_b = vim.api.nvim_create_buf(false, true)
  local buf2_c = vim.api.nvim_create_buf(false, true)

  previewer.define_preview({ state = { bufnr = buf2_a } }, { value = alpha_prog })
  previewer.define_preview({ state = { bufnr = buf2_b } }, { value = beta_prog })
  previewer.define_preview({ state = { bufnr = buf2_c } }, { value = alpha_prog })

  vim.wait(500, function() return #goose_spawns > 0 end, 5)
  vim.wait(80, function() return false end, 10) -- wait extra past debounce
  check(#goose_spawns == 1, "debounce: exactly one export spawn for alpha")
  check(goose_spawns[1].argv[5] == "20990101_1", "debounce: spawn was for alpha")
  vim.wait(500, function()
    local l = vim.api.nvim_buf_get_lines(buf2_c, 0, -1, false)
    return l[2] ~= "(loading…)"
  end, 5)
  local lines_2c = vim.api.nvim_buf_get_lines(buf2_c, 0, -1, false)
  check(lines_2c[2] == "Coordinator assistant message for alpha", "debounce: final buffer updated")

  -- 3. Dedupe + render-on-completion: select alpha (export hangs), wait past debounce (spawn #1),
  -- move to beta, move back to alpha with a NEW scratch bufnr, wait past debounce again ->
  -- still exactly one spawn; release the hang -> text lands in the NEW buffer.
  test_state.coord_cache = {}
  test_state.coord_inflight = {}
  test_state.preview = nil
  goose_spawns = {}

  local alpha_hung_exit
  pending_replies["20990101_1"] = function(on_exit)
    alpha_hung_exit = on_exit
  end

  local buf3_old = vim.api.nvim_create_buf(false, true)
  local buf3_beta = vim.api.nvim_create_buf(false, true)
  local buf3_new = vim.api.nvim_create_buf(false, true)

  previewer.define_preview({ state = { bufnr = buf3_old } }, { value = alpha_prog })
  vim.wait(500, function() return #goose_spawns == 1 end, 5)
  check(#goose_spawns == 1, "alpha export spawned while hanging")
  check(alpha_hung_exit ~= nil, "alpha reply callback captured")

  previewer.define_preview({ state = { bufnr = buf3_beta } }, { value = beta_prog })
  previewer.define_preview({ state = { bufnr = buf3_new } }, { value = alpha_prog })

  vim.wait(80, function() return false end, 10) -- wait past debounce again
  check(#goose_spawns == 1, "still exactly one spawn while alpha in flight")

  -- Release hang
  local rel_exit = alpha_hung_exit
  alpha_hung_exit = nil
  pending_replies["20990101_1"] = nil
  vim.schedule(function()
    rel_exit({ code = 0, signal = 0, stdout = export_json, stderr = "" })
  end)

  vim.wait(500, function()
    local l = vim.api.nvim_buf_get_lines(buf3_new, 0, -1, false)
    return l[2] ~= "(loading…)"
  end, 5)
  local lines_3new = vim.api.nvim_buf_get_lines(buf3_new, 0, -1, false)
  check(lines_3new[2] == "Coordinator assistant message for alpha", "text landed in the NEW buffer")

  local lines_3old = vim.api.nvim_buf_get_lines(buf3_old, 0, -1, false)
  check(lines_3old[2] == "(loading…)", "old buffer was not overwritten")

  -- 4. Moving away before completion: alpha export hangs, move to beta (beta buffer), release ->
  -- result cached (later selecting alpha renders text immediately with no new spawn), and beta
  -- buffer is not overwritten with alpha's text.
  test_state.coord_cache = {}
  test_state.coord_inflight = {}
  test_state.preview = nil
  goose_spawns = {}

  local alpha4_exit
  pending_replies["20990101_1"] = function(on_exit)
    alpha4_exit = on_exit
  end

  local buf4_alpha = vim.api.nvim_create_buf(false, true)
  local buf4_beta = vim.api.nvim_create_buf(false, true)

  previewer.define_preview({ state = { bufnr = buf4_alpha } }, { value = alpha_prog })
  vim.wait(500, function() return #goose_spawns == 1 end, 5)
  check(#goose_spawns == 1, "alpha export spawned")

  previewer.define_preview({ state = { bufnr = buf4_beta } }, { value = beta_prog })

  -- Release
  local r4 = alpha4_exit
  alpha4_exit = nil
  pending_replies["20990101_1"] = nil
  vim.schedule(function()
    r4({ code = 0, signal = 0, stdout = export_json, stderr = "" })
  end)

  vim.wait(500, function() return test_state.coord_cache["20990101_1"] ~= nil end, 5)
  check(test_state.coord_cache["20990101_1"] ~= nil, "alpha result cached despite moving away")

  -- Beta buffer is not overwritten with alpha's text
  local lines_4b = vim.api.nvim_buf_get_lines(buf4_beta, 0, -1, false)
  check(lines_4b[1]:find("no coordinator session", 1, true) ~= nil, "beta buffer preserved header")
  check(lines_4b[3]:find("^%[review%]") ~= nil, "beta buffer preserved items")

  -- Later selecting alpha renders immediately with no new spawn
  local spawns_before_4 = #goose_spawns
  local buf4_alpha_later = vim.api.nvim_create_buf(false, true)
  previewer.define_preview({ state = { bufnr = buf4_alpha_later } }, { value = alpha_prog })
  local lines_4later = vim.api.nvim_buf_get_lines(buf4_alpha_later, 0, -1, false)
  check(lines_4later[2] == "Coordinator assistant message for alpha", "later select renders cached text immediately")
  check(#goose_spawns == spawns_before_4, "no new spawn when cached")

  -- 5. Cache across <C-b>: after alpha's text is cached, call M.programs(state, "alpha") again
  -- (fresh previewer) and preview alpha -> no new spawn, text shown immediately.
  local picker2 = init.programs(test_state, "alpha")
  local previewer2 = picker2.defaults.previewer
  local spawns_before_5 = #goose_spawns
  local buf5 = vim.api.nvim_create_buf(false, true)
  previewer2.define_preview({ state = { bufnr = buf5 } }, { value = alpha_prog })
  check(#goose_spawns == spawns_before_5, "cache across <C-b>: no new spawn")
  local lines_5 = vim.api.nvim_buf_get_lines(buf5, 0, -1, false)
  check(lines_5[2] == "Coordinator assistant message for alpha", "cache across <C-b>: text shown immediately")

  -- 6. A none program never spawns an export (even after waiting past debounce).
  local buf6 = vim.api.nvim_create_buf(false, true)
  local spawns_before_6 = #goose_spawns
  previewer.define_preview({ state = { bufnr = buf6 } }, { value = beta_prog })
  vim.wait(80, function() return false end, 10)
  check(#goose_spawns == spawns_before_6, "none program never spawns an export")
  local lines_6 = vim.api.nvim_buf_get_lines(buf6, 0, -1, false)
  check(lines_6[1]:find("no coordinator session", 1, true) ~= nil, "none shows no coordinator session")

  -- 7. Export failure (exit 1, stderr "boom") shows "(transcript unavailable: boom)" and item lines are still present.
  pending_replies["20990101_3"] = function(on_exit)
    vim.schedule(function()
      on_exit({ code = 1, signal = 0, stdout = "", stderr = "boom\n" })
    end)
  end
  local buf7 = vim.api.nvim_create_buf(false, true)
  previewer.define_preview({ state = { bufnr = buf7 } }, { value = gamma_prog })
  local lines_7imm = vim.api.nvim_buf_get_lines(buf7, 0, -1, false)
  check(lines_7imm[2] == "(loading…)", "gamma preview immediately loading")

  vim.wait(500, function()
    local l = vim.api.nvim_buf_get_lines(buf7, 0, -1, false)
    return l[2] ~= "(loading…)"
  end, 5)
  local lines_7done = vim.api.nvim_buf_get_lines(buf7, 0, -1, false)
  check(lines_7done[2] == "(transcript unavailable: boom)", "failure shows (transcript unavailable: boom)")
  check(lines_7done[4]:find("^%[question%]") ~= nil, "gamma items still present below")
  check(test_state.coord_cache["20990101_3"] ~= nil and test_state.coord_cache["20990101_3"].err == "boom",
    "error is cached")

  -- 8. No spawn of wake.sh anywhere.
  for _, argv in ipairs(all_spawns) do
    check(not tostring(argv[1]):match("wake%.sh$"), "no spawn of wake.sh anywhere in preview tests")
  end

  init.PREVIEW_DEBOUNCE_MS = orig_debounce
end

print("LUA_TEST_OK " .. N)
