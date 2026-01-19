-- ccremote.lua - Claude Code Remote control via neovim RPC
--
-- This plugin enables remote control of Claude Code instances running in
-- neovim terminal buffers. It exposes a base64-JSON dispatcher that can be
-- called via `nvim --server <socket> --remote-expr`.
--
-- Usage:
--   1. Start nvim with: nvim --listen /tmp/nvim-claude.sock
--   2. Open a terminal and start Claude Code
--   3. Register the instance: :CCRegister backend
--   4. From outside nvim:
--      nvim --server /tmp/nvim-claude.sock \
--        --remote-expr "luaeval('require(\"ccremote\").dispatch(_A)', '<base64_payload>')"

local M = {}

-- Module-local storage for registered Claude instances
-- Maps instance name -> { bufnr: number, job_id: number }
local instances = {}

--- Register the current terminal buffer as a named Claude instance
--- @param name string The name to identify this instance
function M.register(name)
  if not name or name == "" then
    vim.notify("ccremote: name is required", vim.log.levels.ERROR)
    return false
  end

  local bufnr = vim.api.nvim_get_current_buf()

  -- Verify this is a terminal buffer
  if vim.bo[bufnr].buftype ~= "terminal" then
    vim.notify("ccremote: current buffer is not a terminal", vim.log.levels.ERROR)
    return false
  end

  local job_id = vim.b[bufnr].terminal_job_id
  if not job_id then
    vim.notify("ccremote: no terminal job found in current buffer", vim.log.levels.ERROR)
    return false
  end

  instances[name] = {
    bufnr = bufnr,
    job_id = job_id,
    registered_at = os.time(),
  }

  vim.notify(string.format("ccremote: registered instance '%s' (buf=%d, job=%d)", name, bufnr, job_id), vim.log.levels.INFO)
  return true
end

--- Unregister a Claude instance
--- @param name string The instance name to unregister
function M.unregister(name)
  if instances[name] then
    instances[name] = nil
    vim.notify(string.format("ccremote: unregistered instance '%s'", name), vim.log.levels.INFO)
    return true
  end
  return false
end

--- List all registered instances
--- @return table<string, {bufnr: number, job_id: number}>
function M.list()
  return vim.tbl_keys(instances)
end

--- Get the last N lines from a terminal buffer
--- Uses nvim_buf_line_count to compute correct start index (no negative indices)
--- @param bufnr number Buffer number
--- @param n number Number of lines to retrieve
--- @return string Concatenated lines
local function tail_buffer(bufnr, n)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return ""
  end

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local start_line = math.max(0, line_count - n)
  local lines = vim.api.nvim_buf_get_lines(bufnr, start_line, line_count, false)
  return table.concat(lines, "\n")
end

--- Send a command to a Claude instance
--- @param name string Instance name
--- @param command string Command to send
--- @return {ok: boolean, error?: string}
local function handle_send(name, command)
  local instance = instances[name]
  if not instance then
    return { ok = false, error = "unknown_instance" }
  end

  if not vim.api.nvim_buf_is_valid(instance.bufnr) then
    -- Clean up stale instance
    instances[name] = nil
    return { ok = false, error = "buffer_invalid" }
  end

  -- Send command to the terminal job
  -- Hybrid approach: nvim focuses the correct buffer, tmux sends text+Enter
  -- nvim can target specific terminal buffers within a pane, tmux handles input
  local job_id = instance.job_id
  local bufnr = instance.bufnr

  -- Send command to terminal, with delay before Enter to avoid Ink paste detection
  -- Ink treats multi-char input arriving at once as "paste" and Enter becomes newline.
  -- A synchronous sleep ensures Enter arrives in a separate read chunk.
  local success, err = pcall(function()
    -- Focus the terminal and enter insert mode
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(win) == bufnr then
        vim.api.nvim_set_current_win(win)
        vim.cmd("startinsert")
        break
      end
    end

    -- Send the text
    vim.fn.chansend(job_id, command)

    -- Synchronous sleep to ensure Enter arrives as separate chunk (avoids Ink paste detection)
    -- 100ms is reliable; shorter delays may work but this provides margin for safety
    vim.fn.system("sleep 0.1")
    vim.fn.chansend(job_id, "\r")
  end)

  if not success then
    return { ok = false, error = tostring(err) }
  end

  return { ok = true }
end

--- Get recent output from a Claude instance
--- @param name string Instance name
--- @param lines number Number of lines to retrieve (default 50)
--- @return {ok: boolean, output?: string, error?: string}
local function handle_tail(name, lines)
  local instance = instances[name]
  if not instance then
    return { ok = false, error = "unknown_instance" }
  end

  if not vim.api.nvim_buf_is_valid(instance.bufnr) then
    instances[name] = nil
    return { ok = false, error = "buffer_invalid" }
  end

  local output = tail_buffer(instance.bufnr, lines or 50)
  return { ok = true, output = output }
end

--- List all registered instances with metadata
--- @return {ok: boolean, instances: string[]}
local function handle_list()
  local result = {}
  for name, data in pairs(instances) do
    local valid = vim.api.nvim_buf_is_valid(data.bufnr)
    table.insert(result, {
      name = name,
      bufnr = data.bufnr,
      job_id = data.job_id,
      valid = valid,
      registered_at = data.registered_at,
    })
  end
  return { ok = true, instances = result }
end

--- Main dispatcher - accepts base64-encoded JSON, returns base64-encoded JSON
--- This is the entry point for external RPC calls.
---
--- Request format (JSON before base64 encoding):
---   { "type": "send", "name": "instance-name", "command": "..." }
---   { "type": "tail", "name": "instance-name", "lines": 50 }
---   { "type": "list" }
---
--- Response format (JSON before base64 encoding):
---   { "ok": true, ... }
---   { "ok": false, "error": "error_code" }
---
--- @param b64 string Base64-encoded JSON payload
--- @return string Base64-encoded JSON response
function M.dispatch(b64)
  -- Decode base64
  local decode_ok, payload_json = pcall(vim.base64.decode, b64)
  if not decode_ok or not payload_json then
    return vim.base64.encode(vim.json.encode({ ok = false, error = "bad_base64" }))
  end

  -- Parse JSON
  local parse_ok, payload = pcall(vim.json.decode, payload_json)
  if not parse_ok or type(payload) ~= "table" then
    return vim.base64.encode(vim.json.encode({ ok = false, error = "bad_json" }))
  end

  -- Dispatch based on request type
  local request_type = payload.type
  local response

  if request_type == "send" then
    if not payload.name or not payload.command then
      response = { ok = false, error = "missing_params" }
    else
      response = handle_send(payload.name, payload.command)
    end

  elseif request_type == "tail" then
    if not payload.name then
      response = { ok = false, error = "missing_params" }
    else
      response = handle_tail(payload.name, payload.lines)
    end

  elseif request_type == "list" then
    response = handle_list()

  else
    response = { ok = false, error = "unknown_request_type" }
  end

  -- Encode and return response
  return vim.base64.encode(vim.json.encode(response))
end

--- Setup function to create user commands
function M.setup()
  -- :CCRegister <name> - Register current terminal as a named Claude instance
  vim.api.nvim_create_user_command("CCRegister", function(opts)
    M.register(opts.args)
  end, {
    nargs = 1,
    desc = "Register current terminal as a Claude Code instance",
  })

  -- :CCUnregister <name> - Unregister an instance
  vim.api.nvim_create_user_command("CCUnregister", function(opts)
    M.unregister(opts.args)
  end, {
    nargs = 1,
    desc = "Unregister a Claude Code instance",
    complete = function()
      return vim.tbl_keys(instances)
    end,
  })

  -- :CCList - Show all registered instances
  vim.api.nvim_create_user_command("CCList", function()
    local names = M.list()
    if #names == 0 then
      vim.notify("ccremote: no instances registered", vim.log.levels.INFO)
    else
      vim.notify("ccremote: registered instances: " .. table.concat(names, ", "), vim.log.levels.INFO)
    end
  end, {
    desc = "List all registered Claude Code instances",
  })

  -- :CCSend <name> <command> - Send a command to an instance (for testing)
  vim.api.nvim_create_user_command("CCSend", function(opts)
    local args = vim.split(opts.args, " ", { plain = true, trimempty = true })
    local name = args[1]
    table.remove(args, 1)
    local command = table.concat(args, " ")

    if not name or command == "" then
      vim.notify("Usage: :CCSend <instance-name> <command>", vim.log.levels.ERROR)
      return
    end

    local result = handle_send(name, command)
    if result.ok then
      vim.notify(string.format("ccremote: sent command to '%s'", name), vim.log.levels.INFO)
    else
      vim.notify(string.format("ccremote: failed to send - %s", result.error), vim.log.levels.ERROR)
    end
  end, {
    nargs = "+",
    desc = "Send a command to a Claude Code instance",
    complete = function(arg_lead, cmd_line, cursor_pos)
      -- Complete instance names for first argument
      local args = vim.split(cmd_line, " ", { plain = true, trimempty = true })
      if #args <= 2 then
        return vim.tbl_keys(instances)
      end
      return {}
    end,
  })
end

return M
