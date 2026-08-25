-- session_switcher/exec.lua
--
-- Side-effect execution layer for the session switcher (S7 / Task 3).
--
-- Performs navigation, focus switching, process execution, and notifications.
-- One side effect per function, no branching beyond guards.
--
-- ERROR SURFACING:
-- Every `vim.system` call is `pcall`'d because `vim.system` raises synchronously
-- on missing binaries (ENOENT) rather than calling back.
-- NONE of the functions throw; all return a boolean success indicator.
--
-- Must NOT require telescope.* or plenary.* at any level.

local M = {}

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

return M
