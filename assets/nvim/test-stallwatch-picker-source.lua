-- Unit tests for stallwatch_picker/source.lua (async snapshot fetch).
-- Driven via `nvim --clean -l assets/nvim/test-stallwatch-picker-source.lua`.
--
-- No real binaries: every spawn goes through a fake `system`, in the shape of
-- the fakes in test-session-switcher.sh. SYNTHETIC DATA ONLY (public repo).

local N = 0
local function check(cond, msg) N = N + 1; assert(cond, msg) end

local model = loadfile("assets/nvim/lua/user/stallwatch_picker/model.lua")()
package.preload["user.stallwatch_picker.model"] = function() return model end
-- The REAL switcher cli.fetch serves step 3, so its --ids argv is exercised.
local cli = loadfile("assets/nvim/lua/user/session_switcher/cli.lua")()
package.preload["user.session_switcher.cli"] = function() return cli end
local source = loadfile("assets/nvim/lua/user/stallwatch_picker/source.lua")()

local f = assert(io.open("assets/nvim/stallwatch-picker-fixture.json", "r"))
local FIXTURE = f:read("*a")
f:close()

local ITEMS = "/fixture/bin/items.sh"
local ENV = { [source and source.ENV or "STALLWATCH_ITEMS_CMD"] = ITEMS }
local ROWS = vim.json.encode({
  { id = "ses_fixture_a1", title = "A1", directory = "/fixture/alpha/one", effective_state = "idle", dir_missing = false },
  { id = "ses_fixture_t1", title = "T1", directory = "/fixture/alpha/t1", effective_state = "idle", dir_missing = false },
})

-- Routes by argv; records every argv. `replies[key] = {code, stdout, stderr}`
-- or "hang" (never calls back) or "raise" (vim.system ENOENT behaviour).
local function router(replies, calls)
  return function(argv, _o, on_exit)
    table.insert(calls, argv)
    local key = argv[1] == "oc-tags" and ("oc-tags:" .. (argv[3] == "--" and argv[4] or argv[3])) or argv[1]
    local r = replies[key]
    if r == "raise" then error("ENOENT: no such file or directory") end
    if r ~= "hang" then
      r = r or { 0, "", "" }
      local code = r[1] or 0
      local stdout = r[2] or ""
      local stderr = r[3] or ""
      local sig = r.signal or 0
      vim.schedule(function()
        on_exit({ code = code, signal = sig, stdout = stdout, stderr = stderr })
      end)
    end
    return { pid = 1, kill = function() end }
  end
end

local function collect(replies, extra)
  local calls = {}
  local n, snap, err = 0, nil, nil
  local opts = vim.tbl_extend("force", { env = ENV, system = router(replies, calls), items_timeout_ms = 100, tags_timeout_ms = 100, list_timeout_ms = 100 }, extra or {})
  source.fetch(opts, function(s, e) n = n + 1; snap, err = s, e end)
  vim.wait(2000, function() return n > 0 end)
  vim.wait(150) -- a second (illegal) callback would land in here
  check(n == 1, "callback fired exactly once, got " .. n)
  return snap, err, calls
end

local HAPPY = {
  [ITEMS] = { 0, FIXTURE },
  ["oc-tags:alpha"] = { 0, "ses_fixture_t1\nses_fixture_a1\n" },
  ["oc-tags:beta"] = { 0, "" },
  ["oc-session-list"] = { 0, ROWS },
}

-- 1. Command path: env override, else the default under $HOME.
do
  check(source.items_cmd({ [source.ENV] = "/x/items.sh" }) == "/x/items.sh", "env override wins")
  check(source.items_cmd({}) == vim.fn.expand("~/projects/eng-agent-platform/stallwatch/items.sh"), "default path")
  check(source.items_cmd({ [source.ENV] = "" }) == source.items_cmd({}), "empty env var -> default")
  check(source.available({ [source.ENV] = "/definitely/not/here/items.sh" }) == false, "missing command -> unavailable")
end

-- 2. Happy path: one snapshot, three steps, the right argv.
do
  local snap, err, calls = collect(HAPPY)
  check(err == nil and snap ~= nil, "happy path -> snapshot")
  check(snap.doc.version == 1 and #snap.doc.programs == 2, "doc carried")
  check(table.concat(snap.tagged.alpha, ",") == "ses_fixture_t1,ses_fixture_a1", "tagged ids per program")
  check(#snap.tagged.beta == 0, "empty oc-tags output -> empty list")
  check(#snap.rows == 2, "CLI rows carried")
  check(#snap.warnings == 0, "no warnings")
  check(calls[1][1] == ITEMS and calls[1][2] == "--json", "step 1 runs the read command with --json")
  local tags_argv
  for _, c in ipairs(calls) do if c[1] == "oc-tags" then tags_argv = c break end end
  check(tags_argv ~= nil and tags_argv[2] == "sessions" and tags_argv[3] == "--", "oc-tags runs with sessions -- <tag>")
  local list_argv
  for _, c in ipairs(calls) do if c[1] == "oc-session-list" then list_argv = c end end
  check(list_argv ~= nil, "step 3 ran oc-session-list exactly via cli.fetch")
  check(vim.tbl_contains(list_argv, "--fold") and vim.tbl_contains(list_argv, "--with-state"), "--with-state --fold")
  check(not vim.tbl_contains(list_argv, "--limit"), "ids mode sends no --limit")
  local i = vim.fn.index(list_argv, "--ids")
  check(i >= 0, "--ids present")
  check(list_argv[i + 2] == "ses_fixture_a1,ses_fixture_a2,ses_fixture_arch,ses_fixture_gone,ses_fixture_b1,ses_fixture_t1",
    "--ids is the deduped union of item and tagged ids, got " .. tostring(list_argv[i + 2]))
end

-- 3. `error` is checked BEFORE version and exit code.
do
  local snap, err = collect({ [ITEMS] = { 1, '{"version":1,"error":"db is locked"}' } })
  check(snap == nil and err.kind == "error", "error doc -> kind=error")
  check(err.message:find("db is locked", 1, true) ~= nil, "error text surfaced")
end

-- 4. Non-zero exit without JSON -> its stderr.
do
  local _, err = collect({ [ITEMS] = { 2, "", "Traceback: something broke\n" } })
  check(err.kind == "exit" and err.message:find("Traceback: something broke", 1, true) ~= nil, "stderr surfaced")
end

-- 4b. Signal-killed read command -> exit-style error naming the signal.
do
  local snap, err = collect({ [ITEMS] = { 0, "", "", signal = 9 } })
  check(snap == nil and err.kind == "exit", "signal killed read command -> kind=exit")
  check(err.message:find("signal 9", 1, true) ~= nil, "signal message names signal 9")
end

-- 5. Timeout -> "stall-watch busy, retry".
do
  local _, err = collect({ [ITEMS] = "hang" })
  check(err.kind == "timeout" and err.message == source.BUSY_MESSAGE, "timeout -> busy message")
end

-- 6. Missing command -> spawn error, not an exception.
do
  local _, err = collect({ [ITEMS] = "raise" })
  check(err.kind == "spawn", "raise -> kind=spawn")
end

-- 7. version ~= 1 -> refuse, say so.
do
  local _, err = collect({ [ITEMS] = { 0, '{"version":2,"programs":[]}' } })
  check(err.kind == "version" and err.message:find("version 2", 1, true) ~= nil, "version 2 refused")
end

-- 8. Zero programs -> "no programs registered".
do
  local _, err = collect({ [ITEMS] = { 0, '{"version":1,"generated_at":null,"latest_digest":null,"programs":[]}' } })
  check(err.kind == "empty" and err.message:find("no programs registered", 1, true) ~= nil, "zero programs")
end

-- 9. Garbage stdout with exit 0 -> decode error.
do
  local _, err = collect({ [ITEMS] = { 0, "not json" } })
  check(err.kind == "decode", "garbage -> decode")
  local _, err2 = collect({ [ITEMS] = { 0, "[]" } })
  check(err2.kind == "decode", "top-level array is not a document")
end

-- 10. oc-tags fails -> snapshot still delivered, with a warning.
do
  local r = vim.deepcopy(HAPPY)
  r["oc-tags:alpha"] = { 1, "", "boom" }
  local snap, err = collect(r)
  check(err == nil and snap ~= nil, "oc-tags failure is not fatal")
  check(#snap.tagged.alpha == 0, "failed program has no tagged ids")
  check(#snap.warnings == 1 and snap.warnings[1]:find("oc-tags", 1, true) ~= nil, "warning names oc-tags")
end

-- 10b. oc-tags timeout -> snapshot still delivered with warning, join completes.
do
  local r = vim.deepcopy(HAPPY)
  r["oc-tags:alpha"] = "hang"
  local snap, err = collect(r)
  check(err == nil and snap ~= nil, "oc-tags timeout is not fatal")
  check(#snap.tagged.alpha == 0, "timed out program has no tagged ids")
  check(#snap.warnings == 1 and snap.warnings[1]:find("did not respond within", 1, true) ~= nil, "warning names timeout")
end

-- 10c. oc-tags spawn failure (ENOENT) -> snapshot still delivered with warning, join completes.
do
  local r = vim.deepcopy(HAPPY)
  r["oc-tags:alpha"] = "raise"
  local snap, err = collect(r)
  check(err == nil and snap ~= nil, "oc-tags spawn failure is not fatal")
  check(#snap.tagged.alpha == 0, "failed spawn program has no tagged ids")
  check(#snap.warnings == 1 and snap.warnings[1]:find("could not run oc-tags", 1, true) ~= nil, "warning names spawn failure")
end

-- 10d. oc-tags killed by signal -> warning names signal.
do
  local r = vim.deepcopy(HAPPY)
  r["oc-tags:alpha"] = { 0, "", "", signal = 15 }
  local snap, err = collect(r)
  check(err == nil and snap ~= nil, "oc-tags signal kill is not fatal")
  check(#snap.tagged.alpha == 0, "signal killed program has no tagged ids")
  check(#snap.warnings == 1 and snap.warnings[1]:find("signal 15", 1, true) ~= nil, "warning names signal 15")
end

-- 11. oc-session-list fails -> snapshot with no rows, with a warning.
do
  local r = vim.deepcopy(HAPPY)
  r["oc-session-list"] = { 1, "", "Error querying database" }
  local snap, err = collect(r)
  check(err == nil and #snap.rows == 0, "CLI failure -> empty rows, not an error")
  check(#snap.warnings == 1 and snap.warnings[1]:find("oc-session-list failed", 1, true) ~= nil, "warning names oc-session-list")
end

-- 11b. CLI killed by signal -> snapshot with no rows, warning naming signal.
do
  local r = vim.deepcopy(HAPPY)
  r["oc-session-list"] = { 0, "", "", signal = 9 }
  local snap, err = collect(r)
  check(err == nil and #snap.rows == 0, "CLI signal failure -> empty rows")
  check(#snap.warnings == 1 and snap.warnings[1]:find("signal 9", 1, true) ~= nil, "warning names signal 9")
end

-- 12. CLI exit 0 + stderr -> rows AND the stderr lines as warnings.
do
  local r = vim.deepcopy(HAPPY)
  r["oc-session-list"] = { 0, ROWS, "oc-session-list: no live writer is reporting\n" }
  local snap = collect(r)
  check(#snap.rows == 2 and snap.warnings[1]:find("no live writer", 1, true) ~= nil, "S3 tripwire surfaced")
end

-- 13. ASYNC even with a synchronous system.
do
  local ran = false
  source.fetch({ env = ENV, system = function(_a, _o, on_exit)
    on_exit({ code = 1, signal = 0, stdout = '{"version":1,"error":"x"}', stderr = "" })
    return { pid = 1, kill = function() end }
  end }, function() ran = true end)
  check(ran == false, "fetch is async")
  vim.wait(500, function() return ran end)
  check(ran, "and does call back")
end

-- 14. Pure helpers.
do
  check(table.concat(source.parse_ids("a\n\n b \r\nc"), ",") == "a,b,c", "parse_ids trims and drops blanks")
  check(#source.parse_ids(nil) == 0, "parse_ids(nil)")
end

-- 15. Valid id filter & skipping oc-session-list when no valid ids remain.
do
  check(cli.is_valid_id("ses_123") == true, "valid id accepted")
  check(cli.is_valid_id("") == false, "empty string rejected")
  check(cli.is_valid_id("-flag") == false, "leading dash rejected")
  check(cli.is_valid_id("foo,bar") == false, "comma rejected")
  check(cli.is_valid_id(123) == false, "number rejected")
  check(cli.is_valid_id(nil) == false, "nil rejected")
  local filtered = cli.filter_valid_ids({ "ses_ok", "", "-dash", "has,comma", 99, "ses_ok2" })
  check(table.concat(filtered, ",") == "ses_ok,ses_ok2", "filter_valid_ids keeps only valid ids")

  -- When ALL candidate ids are invalid, oc-session-list call is SKIPPED entirely.
  local invalid_fixture = vim.json.encode({
    version = 1,
    programs = {
      {
        tag = "gamma",
        items = {
          {
            kind = "info",
            sessions = {
              { id = "-invalid_dash" },
              { id = "invalid,comma" },
              { id = "" },
            },
          },
        },
      },
    },
  })
  local snap, err, calls = collect({
    [ITEMS] = { 0, invalid_fixture },
    ["oc-tags:gamma"] = { 0, "-bad_tag_id\n" },
    ["oc-session-list"] = { 0, ROWS },
  })
  check(err == nil and snap ~= nil, "snapshot delivered even with no valid ids")
  check(#snap.rows == 0, "rows is empty table when oc-session-list was skipped")
  local list_called = false
  for _, c in ipairs(calls) do
    if c[1] == "oc-session-list" then list_called = true end
  end
  check(list_called == false, "oc-session-list was not called when all ids were invalid")

  -- When candidate ids are empty (no items and no tagged ids), oc-session-list call is also SKIPPED.
  local empty_ids_fixture = vim.json.encode({
    version = 1,
    programs = {
      {
        tag = "gamma",
        items = {},
      },
    },
  })
  local snap2, err2, calls2 = collect({
    [ITEMS] = { 0, empty_ids_fixture },
    ["oc-tags:gamma"] = { 0, "" },
    ["oc-session-list"] = { 0, ROWS },
  })
  check(err2 == nil and snap2 ~= nil, "snapshot delivered with empty ids")
  check(#snap2.rows == 0, "rows is empty table when no candidate ids exist")
  local list_called2 = false
  for _, c in ipairs(calls2) do
    if c[1] == "oc-session-list" then list_called2 = true end
  end
  check(list_called2 == false, "oc-session-list was not called when candidate ids list was empty")
end

-- 16. JSON decode with luanil array=true and object=true.
do
  local null_array_fixture = vim.json.encode({
    version = 1,
    programs = {
      {
        tag = "delta",
        items = {},
      },
    },
  })
  -- Insert raw json null in an array
  local raw = '{"version":1,"programs":[{"tag":"delta","items":[]}],"arr_with_null":[null,"val"]}'
  local doc, err = source.decode_items({ code = 0, stdout = raw, stderr = "" })
  check(err == nil and doc ~= nil, "decode_items handles array nulls")
  check(doc.arr_with_null[1] == nil and doc.arr_with_null[2] == "val", "array null decodes to nil")
end

print("LUA_TEST_OK " .. N)
