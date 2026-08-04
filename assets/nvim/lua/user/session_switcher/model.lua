-- session_switcher/model.lua
--
-- Pure transformer for session switcher rows (S6).
--
-- Takes pre-sorted root rows from `cli.fetch()` and live RPC hits from
-- `discovery.locate()`. Annotates attachment status, carries diagnostic
-- metadata (pane, sock, buffer, tabpage, own), and applies facet filtering.
--
-- ORDER IS PRESERVED EXACTLY. Order is owned by `oc-session-list` CLI.

-- LIVENESS IS NOT REIMPLEMENTED HERE, DELIBERATELY.
--
-- The first draft of this module kept a private copy of discovery.is_live as a
-- fallback for when the `require` failed. Measured 2026-08-04: because the test
-- harness loads modules with `loadfile` under `nvim --clean`, that require ALWAYS
-- failed in tests, so every liveness assertion exercised the copy -- and the whole
-- suite still printed LUA_TEST_OK with discovery.is_live sabotaged to
-- `return true`. A duplicated definition that no test covers is free to drift
-- from the one module whose stated purpose is "never send anyone to a corpse".
--
-- So: one definition, injectable. Tests pass the REAL discovery.is_live in
-- (see test-session-switcher-model.lua), which makes a mutation of discovery.lua
-- break these tests -- the property the copy destroyed.
local function default_is_live(hit)
  local ok, discovery = pcall(require, "user.session_switcher.discovery")
  if ok and type(discovery) == "table" and type(discovery.is_live) == "function" then
    return discovery.is_live(hit)
  end
  -- Cannot verify liveness at all. Report NOT attached, matching the asymmetry
  -- discovery.lua documents: a false "dead" costs the user a duplicate attach
  -- (recoverable), a false "live" teleports them into a dead terminal.
  return false
end

local M = {}

--- The `effective_state` vocabulary, mirrored from the CLI.
---
--- MIRRORED, NOT INVENTED: oc-session-list-fold.ts's SEVERITY table is the source
--- of truth, and assets/nvim/test-session-switcher.sh mechanically asserts these
--- two lists are equal. Without that guard the seam could drift silently -- a
--- state renamed CLI-side would leave the pierce below matching nothing, and both
--- test suites would stay green because each one builds its own fixtures using
--- its own copy of the literals.
M.STATES = { "blocked", "error", "idle", "nodata", "retry", "unknown", "working" }

--- States that always survive a facet filter. A blocked or errored session is
--- the most attention-worthy thing in the list; hiding it behind a scope toggle
--- is how completed-but-unreviewed work goes missing.
M.ATTENTION = { error = true, blocked = true }

--- Annotate session rows with live attachment state and filter by facet.
---
--- @param rows table[]|nil Pre-sorted root rows from cli.lua
--- @param hits table<string, table>|nil Map of sid -> hit from discovery.locate()
--- @param opts table|nil Options:
---   facet?: "all"|"attached"|"detached" (default "all")
---   blocked_pierces?: boolean (default true)
---   is_live?: fun(hit): boolean  -- injection seam; defaults to discovery.is_live
--- @return table[] Array of annotated row shallow copies
function M.build(rows, hits, opts)
  if type(rows) ~= "table" or not vim.islist(rows) then
    return {}
  end

  local safe_hits = type(hits) == "table" and hits or {}
  opts = opts or {}
  local is_live = opts.is_live or default_is_live

  local facet = opts.facet or "all"
  local blocked_pierces = opts.blocked_pierces
  if blocked_pierces == nil then
    blocked_pierces = true
  end

  local out = {}

  for _, row in ipairs(rows) do
    if type(row) == "table" and type(row.id) == "string" and row.id ~= "" then
      local hit = safe_hits[row.id]
      local hit_table = type(hit) == "table" and hit or nil

      local copy = {}
      for k, v in pairs(row) do
        copy[k] = v
      end

      copy.attached = is_live(hit_table)

      if hit_table then
        copy.pane = hit_table.pane
        copy.sock = hit_table.sock
        copy.buffer = hit_table.buffer
        copy.tabpage = hit_table.tabpage
        copy.own = hit_table.own
      end

      local is_blocked = (
        M.ATTENTION[row.effective_state] == true
        or M.ATTENTION[row.child_state] == true
      )

      local pierces = blocked_pierces and is_blocked == true

      -- Why this row survived. A pierced row is in the list DESPITE the facet,
      -- so it can be detached (and pane-less) while facet == "attached". Task 9
      -- must branch on `attached`, not on the facet it asked for, or it will try
      -- to jump to a pane that is not there. Marked explicitly rather than left
      -- for the picker to reverse-engineer.
      copy.pierced = pierces

      local keep = false
      if pierces then
        keep = true
      elseif facet == "attached" then
        keep = (copy.attached == true)
      elseif facet == "detached" then
        keep = (copy.attached == false)
      else
        keep = true
      end

      if keep then
        table.insert(out, copy)
      end
    end
  end

  return out
end

return M
