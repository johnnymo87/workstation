-- stallwatch_picker/source.lua
--
-- The one async snapshot fetch behind the stall-watch picker (workstation-p8ch).
--
-- At open, in order, all async:
--   1. the private read command `items.sh --json` (explicit timeout)
--   2. `oc-tags sessions <tag>` for each program -> tagged root ids
--   3. ONE `oc-session-list --with-state --fold --ids <union>`
-- and the callback receives ONE snapshot; both screens are pure functions of
-- it. Step 1 failing means no picker. Steps 2-3 failing degrade: the flagged
-- view still works from item data alone, and the failure is a warning.
--
-- The read command is invoked by ABSOLUTE PATH and never read around: this
-- module does not know where the stall-watcher keeps its database.
--
-- Must NOT require telescope.*. Every spawn goes through `opts.system` (default
-- vim.system) so tests need no real binaries -- the same seam as
-- session_switcher/cli.lua.

local model = require("user.stallwatch_picker.model")
local cli = require("user.session_switcher.cli")

local M = {}

M.ENV = "STALLWATCH_ITEMS_CMD"
M.DEFAULT_CMD = "~/projects/eng-agent-platform/stallwatch/items.sh"
M.ITEMS_TIMEOUT_MS = 5000
M.TAGS_TIMEOUT_MS = 5000
M.LIST_TIMEOUT_MS = 5000
M.BUSY_MESSAGE = "stall-watch busy, retry"

--- Absolute path of the read command: $STALLWATCH_ITEMS_CMD, else the default.
--- @param env table|nil injection seam (defaults to vim.env)
function M.items_cmd(env)
  env = env or vim.env
  local v = env[M.ENV]
  if type(v) == "string" and v ~= "" then
    return vim.fn.expand(v)
  end
  return vim.fn.expand(M.DEFAULT_CMD)
end

--- Whether the read command is executable (gates the <leader>fp keymap).
function M.available(env)
  return vim.fn.executable(M.items_cmd(env)) == 1
end

local function trim(s)
  if type(s) ~= "string" then
    return nil
  end
  local t = s:match("^%s*(.-)%s*$")
  return t ~= "" and t or nil
end

--- Spawn argv; call cb(out, err) EXACTLY ONCE, always via vim.schedule.
--- out = {code, stdout, stderr}; err = {kind = "spawn"|"timeout", message}.
--- Same settle discipline as session_switcher/cli.lua's fetch: a missing
--- binary raises instead of calling back (pcall), vim.system's on_exit runs
--- in a fast event context (schedule), and a late reply after a timeout must
--- not deliver a second answer (settled flag).
function M.run(system, argv, timeout_ms, cb)
  local settled = false
  local function settle(out, err)
    if settled then
      return
    end
    settled = true
    vim.schedule(function()
      cb(out, err)
    end)
  end
  local ok, handle = pcall(system, argv, { text = true }, function(out)
    settle(out, nil)
  end)
  if not ok then
    settle(nil, { kind = "spawn", message = string.format("could not run %s: %s", argv[1], tostring(handle)) })
    return
  end
  vim.defer_fn(function()
    if settled then
      return
    end
    pcall(function()
      if handle and handle.kill then
        handle:kill(15)
      end
    end)
    settle(nil, { kind = "timeout", message = string.format("%s did not respond within %dms", argv[1], timeout_ms) })
  end, timeout_ms)
end

--- Classify the read command's result. Pure.
---
--- ORDER IS THE CONTRACT: `error` is checked BEFORE the exit code and BEFORE
--- `version`, because the error document is `{version: 1, error}` with exit 1
--- -- checking version first would accept it, checking the exit code first
--- would throw its message away for a bare "exited 1".
---
--- @return table|nil doc, table|nil err  err = {kind, message}
function M.decode_items(out)
  out = type(out) == "table" and out or {}
  local ok, doc = pcall(vim.json.decode, out.stdout or "", { luanil = { object = true, array = true } })
  local is_obj = ok and type(doc) == "table" and not vim.islist(doc)
  if is_obj and doc.error ~= nil then
    return nil, { kind = "error", message = "stall-watch: " .. tostring(doc.error) }
  end
  if (out.signal and out.signal ~= 0) or (out.code and out.code ~= 0) then
    local msg
    if out.signal and out.signal ~= 0 then
      local s = string.format("read command killed by signal %s", tostring(out.signal))
      local err_txt = trim(out.stderr)
      msg = err_txt and string.format("%s: %s", s, err_txt) or s
    else
      msg = trim(out.stderr) or string.format("read command exited %s", tostring(out.code))
    end
    return nil, { kind = "exit", message = "stall-watch: " .. msg }
  end
  if not is_obj then
    return nil, { kind = "decode", message = "stall-watch: read command returned unparseable output" }
  end
  if doc.version ~= 1 then
    return nil, {
      kind = "version",
      message = string.format("stall-watch: unsupported items version %s (this picker reads version 1)", tostring(doc.version)),
    }
  end
  if type(doc.programs) ~= "table" or #doc.programs == 0 then
    return nil, { kind = "empty", message = "stall-watch: no programs registered" }
  end
  return doc, nil
end

--- `oc-tags sessions <tag>` stdout -> ids. Pure.
function M.parse_ids(stdout)
  local out = {}
  for line in tostring(stdout or ""):gmatch("[^\r\n]+") do
    local t = trim(line)
    if t then
      table.insert(out, t)
    end
  end
  return out
end

local function default_list_fetch(opts, cb)
  return cli.fetch(opts, cb)
end

--- Fetch the snapshot.
---
--- @param opts table|nil {
---   system?: function   -- vim.system seam, threaded to every spawn
---   env?: table         -- vim.env seam for the command path
---   list_fetch?: function(opts, cb) -- defaults to session_switcher.cli.fetch
---   items_timeout_ms?, tags_timeout_ms?, list_timeout_ms?: integer
--- }
--- @param cb function(snapshot|nil, err|nil) -- exactly once, on the main loop.
---   snapshot = { doc, tagged = {[tag] = ids}, rows, warnings = string[] }
---   err      = { kind, message }  (message is user-facing)
function M.fetch(opts, cb)
  opts = opts or {}
  local system = opts.system or vim.system
  local list_fetch = opts.list_fetch or default_list_fetch
  local warnings = {}

  local cmd = M.items_cmd(opts.env)
  M.run(system, { cmd, "--json" }, opts.items_timeout_ms or M.ITEMS_TIMEOUT_MS, function(out, run_err)
    if run_err then
      if run_err.kind == "timeout" then
        return cb(nil, { kind = "timeout", message = M.BUSY_MESSAGE })
      end
      return cb(nil, { kind = run_err.kind, message = "stall-watch: " .. run_err.message })
    end
    local doc, err = M.decode_items(out)
    if err then
      return cb(nil, err)
    end

    -- Step 2: tagged ids per program, in parallel; join on a counter.
    local tagged = {}
    local tags = {}
    for _, p in ipairs(doc.programs) do
      if type(p) == "table" and type(p.tag) == "string" and p.tag ~= "" and not tagged[p.tag] then
        tagged[p.tag] = {}
        table.insert(tags, p.tag)
      end
    end

    local function step3()
      local ids = model.union_ids(doc, tagged)
      local valid_ids = cli.filter_valid_ids(ids)
      if #valid_ids == 0 then
        return cb({ doc = doc, tagged = tagged, rows = {}, warnings = warnings }, nil)
      end
      list_fetch({
        fold = true,
        ids = valid_ids,
        system = system,
        timeout_ms = opts.list_timeout_ms or M.LIST_TIMEOUT_MS,
      }, function(result, lerr)
        local rows = {}
        if lerr then
          table.insert(warnings, "oc-session-list failed (" .. tostring(lerr.message) .. "); showing item data only")
        else
          rows = (result and result.rows) or {}
          -- exit 0 + stderr is SUCCESS WITH WARNINGS (the S3 tripwire): surface it.
          for line in tostring(result and result.warnings or ""):gmatch("[^\r\n]+") do
            local t = trim(line)
            if t then
              table.insert(warnings, t)
            end
          end
        end
        cb({ doc = doc, tagged = tagged, rows = rows, warnings = warnings }, nil)
      end)
    end

    local pending = #tags
    if pending == 0 then
      return step3()
    end
    for _, tag in ipairs(tags) do
      M.run(system, { "oc-tags", "sessions", "--", tag }, opts.tags_timeout_ms or M.TAGS_TIMEOUT_MS, function(tout, terr)
        if terr then
          table.insert(warnings, string.format("oc-tags sessions failed for a program (%s)", terr.message))
        elseif tout.signal and tout.signal ~= 0 then
          local s = string.format("oc-tags sessions killed by signal %s", tostring(tout.signal))
          local err_txt = trim(tout.stderr)
          table.insert(warnings, err_txt and string.format("%s: %s", s, err_txt) or s)
        elseif tout.code and tout.code ~= 0 then
          table.insert(warnings, string.format("oc-tags sessions exited %s: %s", tostring(tout.code), trim(tout.stderr) or ""))
        else
          tagged[tag] = M.parse_ids(tout.stdout)
        end
        pending = pending - 1
        if pending == 0 then
          step3()
        end
      end)
    end
  end)
end

return M
