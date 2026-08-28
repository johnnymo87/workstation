-- session_switcher/exec.lua
--
-- Side-effect execution layer for the session switcher (S7 / Tasks 3 & 4).
--
-- Performs navigation, focus switching, process execution, notifications,
-- and the explicit mark-read watermark write to the pigeon daemon. (Jumping no
-- longer writes a watermark at all; clearing follows evidence of presence and
-- lives in the daemon. See init.lua.)
-- One side effect per function, no branching beyond guards.
--
-- ERROR SURFACING:
-- Every `vim.system` call is `pcall`'d because `vim.system` raises synchronously
-- on missing binaries (ENOENT) rather than calling back.
-- NONE of the functions throw; all return a boolean success indicator.
--
-- Must NOT require telescope.* or plenary.* at any level.

local M = {}

local function trim(s)
  if type(s) ~= "string" then
    return nil
  end
  local trimmed = s:match("^%s*(.-)%s*$")
  return (trimmed ~= "") and trimmed or nil
end

local function url_encode(str)
  if type(str) ~= "string" then
    return ""
  end
  return (str:gsub("[^%w%-_%.~]", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

local function resolve_token(opts)
  opts = (type(opts) == "table") and opts or {}
  -- 1. opts.token or PIGEON_DAEMON_AUTH_TOKEN
  local env_token = trim(opts.token) or trim(vim.env.PIGEON_DAEMON_AUTH_TOKEN)
  if env_token then
    return env_token
  end

  -- 2. Secret file: opts.token_file or PIGEON_DAEMON_AUTH_TOKEN_FILE or /run/secrets/pigeon_daemon_auth_token
  local token_file = opts.token_file or vim.env.PIGEON_DAEMON_AUTH_TOKEN_FILE or "/run/secrets/pigeon_daemon_auth_token"
  local ok, content = pcall(function()
    local f = io.open(token_file, "r")
    if not f then
      return nil
    end
    local c = f:read("*a")
    f:close()
    return c
  end)
  if ok and type(content) == "string" then
    local file_token = trim(content)
    if file_token then
      return file_token
    end
  end

  return nil
end

--- Get the current tmux client name.
---
--- Captured at picker open (Contract 9) so that targeting explicitly focuses
--- the invoking terminal even when multiple tmux clients are attached.
--- Degrades safely to nil outside tmux or when tmux fails. Never throws.
---
--- @return string|nil
function M.tmux_client()
  if not vim.env.TMUX or vim.env.TMUX == "" then
    return nil
  end
  local ok, out = pcall(function()
    local obj = vim.system({ "tmux", "display", "-p", "#{client_name}" }, { text = true }):wait(1000)
    if obj and obj.code == 0 and obj.stdout then
      local client = obj.stdout:gsub("%s+$", "")
      if client ~= "" then
        return client
      end
    end
    return nil
  end)
  if ok and type(out) == "string" then
    return out
  end
  return nil
end

--- Focus a buffer/tabpage in THIS Neovim instance.
---
--- @param desc table { buffer?: integer, tabpage?: integer }
--- @return boolean
function M.focus_here(desc)
  if type(desc) ~= "table" then
    return false
  end
  local ok = pcall(function()
    if desc.tabpage and type(desc.tabpage) == "number" and desc.tabpage > 0 and vim.api.nvim_tabpage_is_valid(desc.tabpage) then
      vim.api.nvim_set_current_tabpage(desc.tabpage)
    end
    if desc.buffer and type(desc.buffer) == "number" and desc.buffer > 0 and vim.api.nvim_buf_is_valid(desc.buffer) then
      vim.api.nvim_set_current_buf(desc.buffer)
    end
  end)
  return ok
end

--- Switch tmux pane to focus an attachment running in another Neovim/pane,
--- and set current buffer in that Neovim instance via --remote-expr.
---
--- Degrades when not in tmux: if `client` is nil or empty, emits a warning notification
--- and returns false without throwing.
---
--- @param desc table { pane?: string, sock?: string, buffer?: integer }
--- @param client string|nil Invoking tmux client name (captured at picker open)
--- @return boolean
function M.switch_pane(desc, client)
  if type(desc) ~= "table" then
    return false
  end
  if client == nil or client == "" then
    vim.notify("cannot switch pane: not inside tmux or tmux client unknown", vim.log.levels.WARN)
    return false
  end
  local pane = desc.pane
  if not pane or pane == "" then
    vim.notify("cannot switch pane: missing pane target", vim.log.levels.WARN)
    return false
  end

  local ok, _ = pcall(function()
    local target_pane = pane:match("^%%") and pane or ("%" .. pane)
    vim.system({ "tmux", "switch-client", "-c", client, "-t", target_pane }, { stdin = false })

    if desc.sock and desc.sock ~= "" and desc.buffer and type(desc.buffer) == "number" then
      local expr = string.format("luaeval(\"pcall(vim.api.nvim_set_current_buf, %d)\")", desc.buffer)
      vim.system({ "nvim", "--server", desc.sock, "--remote-expr", expr }, { stdin = false })
    end
  end)
  return ok
end

--- Attach fresh to an opencode session via the oc-auto-attach binary.
---
--- Shells out to the oc-auto-attach binary (Contract 10) rather than calling Lua M.open(),
--- because the binary owns health probing, pre-placement, door URLs, and settle logic.
---
--- The keymap guard checks `oc-session-list` only, so `oc-auto-attach` may be absent.
--- Missing binary is handled with a warning notification without throwing.
---
--- @param desc table { sid: string }
--- @return boolean
function M.attach(desc)
  if type(desc) ~= "table" or not desc.sid or desc.sid == "" then
    return false
  end
  local ok, err_or_handle = pcall(function()
    return vim.system({ "oc-auto-attach", desc.sid }, { stdin = false })
  end)
  if not ok then
    vim.notify(string.format("could not run oc-auto-attach: %s", tostring(err_or_handle)), vim.log.levels.WARN)
    return false
  end
  return true
end

--- Refuse navigation to a session whose target directory is missing on disk.
---
--- WHY THIS MATTERS:
--- Attaching to a pruned worktree or deleted directory allows the TUI to render history,
--- but the session can NEVER complete a turn — user messages hang indefinitely with no error.
--- Refusing upfront and visibly warning the user prevents the silent turn hang.
---
--- @param desc table { directory?: string }
--- @return boolean
function M.refuse_dir_missing(desc)
  local dir = (type(desc) == "table" and desc.directory) and desc.directory or "(unknown)"
  vim.notify(
    string.format("session directory '%s' no longer exists on disk; session is read-only", dir),
    vim.log.levels.WARN
  )
  return true
end

--- Visibly surface warning lines to the user.
---
--- @param lines string[]|nil
--- @return boolean
function M.notify_warnings(lines)
  if type(lines) ~= "table" or #lines == 0 then
    return true
  end
  for _, line in ipairs(lines) do
    if type(line) == "string" and line ~= "" then
      vim.notify(line, vim.log.levels.WARN)
    end
  end
  return true
end

--- Clear unread badge by POSTing a watermark to the pigeon daemon (S7 / Task 4).
---
--- Fire-and-forget side effect. Handed nil, does nothing and returns false.
---
--- POST http://127.0.0.1:<port>/sessions/<url-encoded sid>/read
--- Body: {"last_event_id": N}
---
--- CONTRACTS & GUARDS:
--- - Nil or invalid payload does nothing and returns false.
--- - Port defaults to 4731 or $PIGEON_DAEMON_PORT, overridable via opts.port.
--- - Authorization: Bearer <token> is sent if resolved from opts.token, $PIGEON_DAEMON_AUTH_TOKEN,
---   opts.token_file, $PIGEON_DAEMON_AUTH_TOKEN_FILE, or /run/secrets/pigeon_daemon_auth_token.
---   Missing/unreadable token file never throws. If no token resolved, no Authorization header is sent.
--- - Never awaited, stdin = false, pcall'd to guard against missing curl binary.
--- - Returns boolean indicator: true if request was spawned, false otherwise.
---
--- @param payload table|nil { sid: string, last_event_id: number } from act.mark_read_watermark
--- @param opts table|nil Options:
---   port?: integer|string
---   token?: string
---   token_file?: string
---   system?: fun(cmd: table, opts: table): table
--- @return boolean True if request was spawned, false otherwise
function M.clear_unread(payload, opts)
  if type(payload) ~= "table"
    or type(payload.sid) ~= "string"
    or payload.sid == ""
    or type(payload.last_event_id) ~= "number"
  then
    return false
  end

  opts = (type(opts) == "table") and opts or {}

  local port = opts.port or (vim.env.PIGEON_DAEMON_PORT and tonumber(vim.env.PIGEON_DAEMON_PORT)) or 4731
  local token = resolve_token(opts)
  local url = string.format("http://127.0.0.1:%s/sessions/%s/read", tostring(port), url_encode(payload.sid))
  local body = vim.json.encode({ last_event_id = payload.last_event_id })

  local argv = {
    "curl",
    "-s",
    -- Bound the request. This is fire-and-forget and nothing ever reaps the
    -- handle, so an accepting-but-wedged daemon would leak one curl per jump
    -- for the lifetime of the editor.
    "--max-time",
    "5",
    "-X",
    "POST",
    url,
    "-H",
    "content-type: application/json",
  }

  if token then
    table.insert(argv, "-H")
    table.insert(argv, "Authorization: Bearer " .. token)
  end

  table.insert(argv, "--data")
  table.insert(argv, body)

  local ok, _ = pcall(function()
    local sys = opts.system or vim.system
    return sys(argv, { stdin = false })
  end)

  return ok
end

---
--- @param payload table|nil { sid: string, message_id: string, force?: boolean }
--- @param opts table|nil Options:
---   frontdoor_url?: string
---   system?: fun(cmd: table, opts: table): table
--- @return boolean True if request was spawned, false otherwise
function M.scroll_to_message(payload, opts)
  if type(payload) ~= "table"
    or type(payload.sid) ~= "string"
    or payload.sid == ""
    or type(payload.message_id) ~= "string"
    or payload.message_id == ""
  then
    return false
  end

  opts = (type(opts) == "table") and opts or {}

  local frontdoor_base = opts.frontdoor_url or vim.env.OPENCODE_FRONTDOOR_URL or "http://127.0.0.1:4700"
  frontdoor_base = frontdoor_base:gsub("/+$", "")
  local url = string.format("%s/session/%s/scroll-to-message", frontdoor_base, url_encode(payload.sid))
  local body = vim.json.encode({
    messageID = payload.message_id,
    force = payload.force == true,
  })

  local argv = {
    "curl",
    "-s",
    -- Bound the request. Fire-and-forget; bound prevents leaking handles.
    "--max-time",
    "5",
    "-X",
    "POST",
    url,
    "-H",
    "content-type: application/json",
    "--data",
    body,
  }

  local ok, _ = pcall(function()
    local sys = opts.system or vim.system
    return sys(argv, { stdin = false })
  end)

  return ok
end

return M
