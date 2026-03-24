-- OpenCode session titles as tab labels via tabby.nvim
-- Reads b:term_title set by OpenCode's TUI, shortens via Gemini for ~24 char display.

local M = {}

-- Per-tab cache: { [tabid_string] = { oc_title = "...", short_title = "..." } }
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

-- Build the curl command for the Gemini API.
-- Returns url, auth_args or nil if no credentials available.
-- Devbox/Crostini: direct Gemini API with API key
-- macOS/Cloudbox: Vertex AI with gcloud bearer token
local function gemini_curl_args(model)
  -- Option 1: Direct Gemini API via API key (devbox, crostini)
  local api_key = vim.env.GOOGLE_GENERATIVE_AI_API_KEY
  if api_key and api_key ~= "" and not api_key:match("^PLACEHOLDER") then
    local url = string.format(
      "https://generativelanguage.googleapis.com/v1beta/models/%s:generateContent",
      model
    )
    return url, { "-H", "x-goog-api-key: " .. api_key }
  end

  -- Option 2: Vertex AI via gcloud (macOS, cloudbox)
  local project = vim.env.GOOGLE_CLOUD_PROJECT
  local location = vim.env.GOOGLE_CLOUD_LOCATION or "global"
  if project and project ~= "" and vim.fn.executable("gcloud") == 1 then
    local url = string.format(
      "https://aiplatform.googleapis.com/v1/projects/%s/locations/%s/publishers/google/models/%s:generateContent",
      project, location, model
    )
    local token_result = vim.system({ "gcloud", "auth", "print-access-token" }, { text = true }):wait()
    if token_result.code == 0 and token_result.stdout then
      local token = vim.trim(token_result.stdout)
      return url, { "-H", "Authorization: Bearer " .. token }
    end
  end

  return nil, nil
end

-- Async Gemini call to shorten a title to ~24 characters.
-- Calls callback(shortened_title) on completion or fallback.
local function shorten_title_async(raw_title, callback)
  local truncated = vim.fn.strcharpart(raw_title, 0, 24)

  -- Skip Gemini for already-short titles
  if vim.fn.strchars(raw_title) <= 24 then
    callback(raw_title)
    return
  end

  if vim.fn.executable("curl") == 0 then
    callback(truncated)
    return
  end

  local model = "gemini-2.5-flash-lite"
  local url, auth_args = gemini_curl_args(model)
  if not url then
    callback(truncated)
    return
  end

  local prompt = string.format(
    "Shorten this title to at most 24 characters. Keep it meaningful. Return ONLY the shortened title, nothing else.\n\nTitle: %s",
    raw_title
  )

  local body = vim.json.encode({
    contents = { { parts = { { text = prompt } } } },
  })

  local cmd = { "curl", "-s", "--max-time", "5", "-X", "POST",
    "-H", "Content-Type: application/json" }
  for _, arg in ipairs(auth_args) do
    cmd[#cmd + 1] = arg
  end
  cmd[#cmd + 1] = "-d"
  cmd[#cmd + 1] = body
  cmd[#cmd + 1] = url

  vim.system(cmd, { text = true },
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
            if vim.fn.strchars(text) > 0 and vim.fn.strchars(text) <= 30 then
              callback(text)
              return
            end
          end
        end
        -- Fallback: truncate
        callback(truncated)
      end)
    end
  )
end

-- The override function called by tabby on every tabline render.
-- Returns a tab label string, or nil to fall through to tabby defaults.
local function opencode_tab_override(tabid)
  local raw_title, term_title = find_opencode_title(tabid)
  local key = tostring(tabid)
  local entry = cache[key]

  if raw_title then
    -- OpenCode title found; use cache or update it
    if entry and entry.oc_title == raw_title then
      return entry.short_title
    end

    -- Title changed (or first seen) -- update cache and fire async shortening
    local interim = vim.fn.strcharpart(raw_title, 0, 24)
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

  -- No OpenCode title found. Decide whether to keep cached title.
  if entry then
    if term_title == "" then
      -- Terminal still running but title is empty (OpenCode temporarily
      -- cleared it, e.g. during compaction or state transition). Keep the
      -- last known good title.
      return entry.short_title
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
