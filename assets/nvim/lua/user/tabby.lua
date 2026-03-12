-- OpenCode session titles as tab labels via tabby.nvim
-- Reads b:term_title set by OpenCode's TUI, shortens via Gemini for ~24 char display.

local M = {}

-- Per-tab cache: { [tabid_string] = { oc_title = "...", short_title = "..." } }
local cache = {}

-- Scan a tab's windows for a terminal buffer with an OpenCode title.
-- Returns the raw session title (prefix stripped) or nil.
local function find_opencode_title(tabid)
  local ok, wins = pcall(vim.api.nvim_tabpage_list_wins, tabid)
  if not ok then return nil end
  for _, win in ipairs(wins) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.bo[buf].buftype == "terminal" then
      local title = vim.b[buf].term_title or ""
      local session_name = title:match("^OC | (.+)$")
      if session_name then
        return session_name
      end
      if title == "OpenCode" then
        return "OpenCode"
      end
    end
  end
  return nil
end

-- Async Gemini call to shorten a title to ~24 characters.
-- Calls callback(shortened_title) on completion or fallback.
local function shorten_title_async(raw_title, callback)
  -- Skip Gemini for already-short titles
  if #raw_title <= 24 then
    callback(raw_title)
    return
  end

  local api_key = vim.env.GOOGLE_GENERATIVE_AI_API_KEY
  if not api_key or api_key == "" or api_key:match("^PLACEHOLDER") then
    callback(raw_title:sub(1, 24))
    return
  end

  local model = "gemini-2.5-flash-lite"
  local url = string.format(
    "https://generativelanguage.googleapis.com/v1beta/models/%s:generateContent?key=%s",
    model, api_key
  )

  local prompt = string.format(
    "Shorten this title to at most 24 characters. Keep it meaningful. Return ONLY the shortened title, nothing else.\n\nTitle: %s",
    raw_title
  )

  local body = vim.json.encode({
    contents = { { parts = { { text = prompt } } } },
  })

  vim.system(
    { "curl", "-s", "--max-time", "5", "-X", "POST",
      "-H", "Content-Type: application/json", "-d", body, url },
    { text = true },
    function(result)
      vim.schedule(function()
        if result.code == 0 and result.stdout then
          local decode_ok, response = pcall(vim.json.decode, result.stdout)
          if decode_ok
            and response.candidates
            and response.candidates[1]
            and response.candidates[1].content
            and response.candidates[1].content.parts
            and response.candidates[1].content.parts[1]
          then
            local text = response.candidates[1].content.parts[1].text
            text = vim.trim(text):gsub("\n.*", "")
            if #text > 0 and #text <= 30 then
              callback(text)
              return
            end
          end
        end
        -- Fallback: truncate
        callback(raw_title:sub(1, 24))
      end)
    end
  )
end

-- The override function called by tabby on every tabline render.
-- Returns a tab label string, or nil to fall through to tabby defaults.
local function opencode_tab_override(tabid)
  local raw_title = find_opencode_title(tabid)
  if not raw_title then return nil end

  local key = tostring(tabid)
  local entry = cache[key]

  if entry and entry.oc_title == raw_title then
    return entry.short_title
  end

  -- Title changed (or first seen) -- update cache and fire async shortening
  local interim = raw_title:sub(1, 24)
  cache[key] = { oc_title = raw_title, short_title = interim }

  shorten_title_async(raw_title, function(shortened)
    -- Verify tab still exists and title hasn't changed again
    local current = cache[key]
    if current and current.oc_title == raw_title then
      current.short_title = shortened
      vim.cmd("redrawtabline")
    end
  end)

  return interim
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
  require("tabby").setup({
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

  -- Periodic redraw to pick up async b:term_title changes
  local timer = vim.uv.new_timer()
  timer:start(3000, 3000, vim.schedule_wrap(function()
    cleanup_cache()
    vim.cmd("redrawtabline")
  end))

  -- Clean up timer on exit
  vim.api.nvim_create_autocmd("VimLeavePre", {
    callback = function()
      if timer then
        timer:stop()
        timer:close()
      end
    end,
  })
end

M.setup()

return M
