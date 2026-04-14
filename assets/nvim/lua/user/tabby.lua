-- OpenCode session titles as tab labels via tabby.nvim
-- Reads b:term_title set by OpenCode's TUI, displays session name directly.

local M = {}

-- Per-tab cache: { [tabid_string] = title_string }
-- Preserves last-known title when OpenCode temporarily clears b:term_title
-- (e.g. during compaction or state transitions).
local cache = {}

-- Scan a tab's windows for a terminal buffer with an OpenCode title.
-- Returns:
--   oc_title: the raw session title (prefix stripped), or nil
--   term_title: the raw b:term_title of the last terminal buffer found,
--               or nil if no terminal buffer exists in the tab.
-- This lets the caller distinguish "no terminal" from "terminal exists
-- but title is empty/non-OpenCode" (e.g. OpenCode temporarily cleared it).
local function find_opencode_title(tabid)
  local ok, wins = pcall(vim.api.nvim_tabpage_list_wins, tabid)
  if not ok then return nil, nil end
  local last_term_title = nil
  for _, win in ipairs(wins) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.bo[buf].buftype == "terminal" then
      local title = vim.b[buf].term_title or ""
      last_term_title = title
      local session_name = title:match("^OC | (.+)$")
      if session_name then
        return session_name, title
      end
      if title == "OpenCode" then
        return "OpenCode", title
      end
    end
  end
  return nil, last_term_title
end

-- The override function called by tabby on every tabline render.
-- Returns a tab label string, or nil to fall through to tabby defaults.
local function opencode_tab_override(tabid)
  local raw_title, term_title = find_opencode_title(tabid)
  local key = tostring(tabid)

  if raw_title then
    cache[key] = raw_title
    return raw_title
  end

  -- No OpenCode title found. Decide whether to keep cached title.
  local cached = cache[key]
  if cached then
    if term_title == "" then
      -- Terminal still running but title is empty (OpenCode temporarily
      -- cleared it, e.g. during compaction or state transition). Keep the
      -- last known good title.
      return cached
    end
    -- Either no terminal buffer (process exited) or terminal has a
    -- non-OpenCode title (bash regained control). Clear stale cache.
    cache[key] = nil
  end

  return nil
end

-- Clean up cache entries for closed tabs
local function cleanup_cache()
  local valid = {}
  for _, tabid in ipairs(vim.api.nvim_list_tabpages()) do
    valid[tostring(tabid)] = true
  end
  for key in pairs(cache) do
    if not valid[key] then
      cache[key] = nil
    end
  end
end

function M.setup()
  local ok, tabby = pcall(require, "tabby")
  if not ok then return end

  tabby.setup({
    line = function(line)
      return {
        line.tabs().foreach(function(tab)
          local hl = tab.is_current() and "TabLineSel" or "TabLine"
          return {
            line.sep("", hl, "TabLineFill"),
            tab.name(),
            line.sep("", hl, "TabLineFill"),
            hl = hl,
            margin = " ",
          }
        end),
        line.spacer(),
        hl = "TabLineFill",
      }
    end,
    option = {
      tab_name = {
        override = opencode_tab_override,
        name_fallback = function(tabid)
          -- Default: show buffer name of current window
          local win = vim.api.nvim_tabpage_get_win(tabid)
          local buf = vim.api.nvim_win_get_buf(win)
          local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":t")
          if name == "" then return "[No Name]" end
          return name
        end,
      },
    },
  })

  -- Clean up previous timer if setup() is called again (e.g., config reload)
  if M._timer and not M._timer:is_closing() then
    M._timer:stop()
    M._timer:close()
  end

  -- Periodic redraw to pick up async b:term_title changes
  M._timer = vim.uv.new_timer()
  M._timer:start(3000, 3000, vim.schedule_wrap(function()
    cleanup_cache()
    vim.cmd("redrawtabline")
  end))

  -- Clean up timer on exit
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("TabbyOpenCodeCleanup", { clear = true }),
    callback = function()
      if M._timer and not M._timer:is_closing() then
        M._timer:stop()
        M._timer:close()
        M._timer = nil
      end
    end,
  })
end

M.setup()

return M
