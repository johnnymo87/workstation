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

print("LUA_TEST_OK " .. N)
