-- session_switcher/flow.lua
--
-- Concurrency and orchestration layer for the session switcher (S7 / Task 3).
--
-- Manages generation tokens for async refresh operations, preventing race
-- conditions when facet toggles or background fetches interleave.
--
-- Orchestrates the accept-time re-resolution to prevent TOCTOU races.
--
-- PURE-ISH: injected seams (fetch, locate, build, decide).
-- Must NOT require telescope.* or plenary.* at any level.

local function default_fetch(opts, cb)
  local ok, cli = pcall(require, "user.session_switcher.cli")
  if ok and type(cli) == "table" and type(cli.fetch) == "function" then
    return cli.fetch(opts, cb)
  end
  cb(nil, { kind = "spawn", message = "cli module not available" })
end

local function default_locate(opts, cb)
  local ok, discovery = pcall(require, "user.session_switcher.discovery")
  if ok and type(discovery) == "table" and type(discovery.locate) == "function" then
    return discovery.locate(opts, cb)
  end
  cb({})
end

local function default_build(rows, hits, opts)
  local ok, model = pcall(require, "user.session_switcher.model")
  if ok and type(model) == "table" and type(model.build) == "function" then
    return model.build(rows, hits, opts)
  end
  return {}, 0
end

local function default_decide(row, hit)
  local ok, act = pcall(require, "user.session_switcher.act")
  if ok and type(act) == "table" and type(act.decide) == "function" then
    return act.decide(row, hit)
  end
  return { kind = "attach", sid = (type(row) == "table" and row.id) or nil }
end

local Controller = {}
Controller.__index = Controller

--- Refresh session rows and attachment status.
---
--- Pipeline: `fetch -> locate -> build -> cb(rows, result, err)`.
---
--- GENERATION CHECKING (THE TWO RACES PREVENTED):
--- 1. Post-fetch: A generation token is bumped at the START of refresh.
---    When `fetch` returns, we re-check `self.generation == gen`. If a user
---    toggled facets while fetch was in-flight, the stale reply is silently
---    dropped without invoking cb.
---
---    SCOPE, stated precisely because the obvious reading is wrong: this token
---    is per-CONTROLLER, and init.lua builds a fresh controller on every open.
---    It therefore does NOT cover reopening the picker -- two opens are two
---    controllers with independent counters, and the one that renders is the
---    LAST TO COMPLETE, not the last to open. That is benign today (same facet,
---    same data, and each open builds its own picker), but do not cite this
---    token as the reason reopening is safe.
--- 2. Post-locate: `discovery.locate` is ALSO async (1s deadline) with no
---    staleness guard of its own. When locate returns, we re-check
---    `self.generation == gen` AGAIN. A facet toggle landing mid-locate must
---    NOT clobber the finder with stale-facet rows (the race revision 1 missed).
---
--- On fetch error: If the generation is still current, cb is still invoked with
--- `(nil, nil, err)` so warnings and error banners surface (Contract 4).
---
--- @param facet string "all" | "attached" | "detached"
--- @param cb fun(rows: table[]|nil, result: table|nil, err: table|nil, hidden: integer|nil)
function Controller:refresh(facet, cb)
  if type(cb) ~= "function" then
    return
  end

  self.generation = self.generation + 1
  local gen = self.generation

  local fetch_opts = vim.tbl_extend("force", { fold = true }, self.opts.fetch_opts or {})

  self.fetch(fetch_opts, function(result, err)
    -- Re-check generation after fetch returns (Hop 1)
    if gen ~= self.generation then
      return
    end

    if err ~= nil then
      cb(nil, nil, err)
      return
    end

    local rows = (result and result.rows) or {}

    self.locate(self.opts.locate_opts or {}, function(hits)
      -- Re-check generation after locate returns (Hop 2)
      if gen ~= self.generation then
        return
      end

      local built_rows, hidden = self.build(rows, hits, { facet = facet })
      cb(built_rows, result, nil, hidden)
    end)
  end)
end

--- Accept a selected session row, re-resolving discovery before deciding action.
---
--- CONTRACT 8 (TOCTOU GUARD):
--- Never act on attachment state embedded in the displayed row. We re-resolve
--- via `locate` to discover where the session is attached RIGHT NOW.
---
--- FULL RE-SCAN NOTE:
--- `discovery.locate` fans out to every socket and cannot be scoped to one sid.
--- Scoping `opts.sockets` to a stale hit's socket would miss a session that
--- moved to another pane. Worst case ~1s, fully async, UI not blocked.
---
--- GENERATION TOKEN IS NOT SHARED:
--- The accept-time re-resolve intentionally does NOT share the render generation
--- token. Sharing it means reopening the picker mid-accept silently swallows
--- the jump, which is strictly worse than acting slightly late.
---
--- TWO PICKERS OPEN:
--- If two pickers are open simultaneously, last-opener-wins (acceptable).
---
--- @param row table Displayed session row
--- @param cb fun(descriptor: table)
function Controller:accept(row, cb)
  if type(cb) ~= "function" then
    return
  end
  local safe_row = (type(row) == "table") and row or {}

  self.locate(self.opts.locate_opts or {}, function(hits)
    local hit = (type(hits) == "table" and safe_row.id) and hits[safe_row.id] or nil
    local descriptor = self.decide(safe_row, hit)
    cb(descriptor)
  end)
end

local M = {}

--- Create a new flow controller.
---
--- @param opts table|nil Injected seams:
---   fetch?: fun(opts, cb)
---   locate?: fun(opts, cb)
---   build?: fun(rows, hits, opts): table[]
---   decide?: fun(row, hit): table
---   fetch_opts?: table
---   locate_opts?: table
--- @return table Controller instance
function M.new(opts)
  opts = opts or {}
  local self = setmetatable({}, Controller)
  self.opts = opts
  self.generation = 0
  self.fetch = opts.fetch or default_fetch
  self.locate = opts.locate or default_locate
  self.build = opts.build or default_build
  self.decide = opts.decide or default_decide
  return self
end

return M
