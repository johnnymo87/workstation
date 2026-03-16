# Tabby + OpenCode Tab Titles Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Show OpenCode session titles as nvim tab labels, with Gemini-shortened titles for ~24 char display.

**Architecture:** tabby.nvim's `override` function scans each tab for a terminal buffer whose `b:term_title` starts with `"OC | "`, extracts the session name, and calls Gemini to shorten it. A background timer ensures title changes are picked up. State is cached per-tab so Gemini is only called when titles change.

**Tech Stack:** tabby.nvim (nixpkgs), Lua, Gemini REST API (`gemini-2.5-flash-lite`), `vim.system()` for async HTTP.

**Design doc:** `docs/plans/2026-03-12-tabby-opencode-tab-titles-design.md`

---

### Task 1: Create the tabby.lua Lua module

**Files:**
- Create: `assets/nvim/lua/user/tabby.lua`

**Step 1: Write the complete Lua module**

The module has four parts: title extraction, Gemini shortening, tabby setup, and refresh timer.

```lua
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
    'Shorten this title to at most 24 characters. Keep it meaningful. Return ONLY the shortened title, nothing else.\n\nTitle: %s',
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
          local ok, response = pcall(vim.json.decode, result.stdout)
          if ok
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
```

**Step 2: Verify the file is syntactically valid**

Run: `luac -p assets/nvim/lua/user/tabby.lua`
Expected: No output (success)

**Step 3: Commit**

```bash
git add assets/nvim/lua/user/tabby.lua
git commit -m "feat(nvim): add tabby.lua for OpenCode session tab titles"
```

---

### Task 2: Add tabby-nvim plugin and require to home.base.nix

**Files:**
- Modify: `users/dev/home.base.nix` (plugins list ~line 384, extraLuaConfig ~line 388)

**Step 1: Add tabby-nvim to the plugins list**

In the `programs.neovim` block, add `tabby-nvim` to the plugins list:

```nix
plugins = with pkgs.vimPlugins; [
  vim-obsession
  tabby-nvim
];
```

**Step 2: Add require to extraLuaConfig**

Add `require("user.tabby")` to the extraLuaConfig string. Use resilient loading since tabby-nvim may not be available on Darwin where programs.neovim is disabled:

```nix
extraLuaConfig = ''
  require("user.settings")
  require("user.mappings")
  require("user.sessions")    -- Session management for tmux-resurrect
  require("user.tabby")       -- OpenCode session titles in tab labels
'' + lib.optionalString (isDarwin || isCloudbox) ''
  require("user.atlassian")   -- :FetchJiraTicket, :FetchConfluencePage
'';
```

**Step 3: Verify nix evaluation**

Run: `nix eval .#homeConfigurations.dev.config.programs.neovim.plugins --apply 'ps: map (p: p.name) ps' 2>&1 | head -5`
Expected: List includes "tabby-nvim" or "vimplugin-tabby.nvim-..."

**Step 4: Commit**

```bash
git add users/dev/home.base.nix
git commit -m "feat(nvim): add tabby-nvim plugin for tab labeling"
```

---

### Task 3: Add Darwin deployment (Pattern 1 + Pattern 2)

**Files:**
- Modify: `users/dev/home.darwin.nix` (~line 343, after existing lua file deployments)

**Step 1: Add tabby-nvim plugin to packpath via xdg.dataFile**

After the existing `xdg.configFile` lines for `sessions.lua` and `atlassian.lua` (~line 344), add:

```nix
# tabby.nvim: install plugin to packpath (Pattern 2 from gradual-migration)
# Auto-loads from site/pack without touching dotfiles plugin manager
xdg.dataFile."nvim/site/pack/nix/start/tabby-nvim" = {
  source = pkgs.vimPlugins.tabby-nvim;
  recursive = true;
};

# Deploy tabby config (Pattern 1: single file alongside dotfiles)
xdg.configFile."nvim/lua/user/tabby.lua".source = "${assetsPath}/nvim/lua/user/tabby.lua";
```

**Step 2: Verify nix evaluation**

Run: `nix eval .#homeConfigurations.\"jonathan.mohrbacher\".config.xdg.dataFile --apply 'builtins.attrNames' 2>&1 | head -10`
Expected: Includes nvim/site/pack/nix/start/tabby-nvim entries

Note: If the Darwin home configuration name differs, check with:
`nix flake show 2>&1 | grep homeConfigurations`

**Step 3: Commit**

```bash
git add users/dev/home.darwin.nix
git commit -m "feat(nvim/darwin): deploy tabby-nvim via packpath for dotfiles compat"
```

---

### Task 4: Apply and verify on devbox

**Step 1: Apply home-manager config**

Run: `nix run home-manager -- switch --flake .#dev`
Expected: Successful activation, no errors

**Step 2: Verify plugin is installed**

Run: `nvim --headless -c 'lua print(pcall(require, "tabby"))' -c 'q' 2>&1`
Expected: Output includes `true`

**Step 3: Verify tabby.lua is deployed**

Run: `ls -la ~/.config/nvim/lua/user/tabby.lua`
Expected: File exists (symlink to nix store)

**Step 4: Commit (if any fixups needed)**

If any changes were needed, commit them with a descriptive message.
