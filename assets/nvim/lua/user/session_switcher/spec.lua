-- session_switcher/spec.lua
--
-- Pure presentation module for session switcher (S7 / Task 1).
--
-- Defines glyph mappings, row display/ordinal formatting, warning lines,
-- prompt title generation, and the pure subset of telescope picker options.
--
-- PURE: MUST NOT reference telescope.* or plenary.* at any level.
-- CI runs bare nixpkgs neovim where `require("telescope")` FAILS.
-- No vim.system, no vim.fn.system, no side effects.

local model = require("user.session_switcher.model")

local M = {}

--- Glyph mapping for each effective_state in model.STATES.
---
--- Rationale:
--- - `nodata` is an outage TRIPWIRE (no live writer could report), so `⚠` is
---   deliberately LOUDER than `idle`'s `○`, and distinct from `unknown`'s `~`
---   (which means stale data from a dead source). Collapsing any of these three
---   was rejected in design review.
--- - None of these glyphs collide with the unread badge characters `·` and `?`
---   from `model.unread_badge`.
M.GLYPHS = {
  error = "✖",
  blocked = "■",
  retry = "↻",
  working = "●",
  nodata = "⚠",
  unknown = "~",
  idle = "○",
}

--- Visible marker for a row whose target directory no longer exists on disk.
M.DIR_MISSING_MARK = "[dir gone]"

--- Get the presentation glyph for a session row based on its effective_state.
--- Degrades safely to the `unknown` glyph ("~") on missing, nil, vim.NIL, or
--- unrecognised states. Never errors.
---
--- @param row table|nil
--- @return string
function M.glyph_of(row)
  if type(row) ~= "table" then
    return M.GLYPHS.unknown
  end
  local state = row.effective_state
  if state == nil or state == vim.NIL or type(state) ~= "string" then
    return M.GLYPHS.unknown
  end
  return M.GLYPHS[state] or M.GLYPHS.unknown
end

--- Format idle age into a short human string.
--- Pure function: takes `now_ms`, never calls system clock itself.
---
--- Boundaries:
---   nil / non-number / vim.NIL -> "?"
---   <= 0 elapsed               -> "now"
---   < 60s                      -> "<N>s"
---   < 60m                      -> "<N>m"
---   < 24h                      -> "<N>h"
---   >= 24h                     -> "<N>d"
---
--- @param last_activity_ms number|nil Epoch milliseconds of last activity
--- @param now_ms number|nil Current epoch milliseconds
--- @return string
function M.idle_age(last_activity_ms, now_ms)
  if last_activity_ms == nil or last_activity_ms == vim.NIL or type(last_activity_ms) ~= "number" then
    return "?"
  end
  if now_ms == nil or now_ms == vim.NIL or type(now_ms) ~= "number" then
    return "?"
  end

  local elapsed_ms = now_ms - last_activity_ms
  if elapsed_ms <= 0 then
    return "now"
  end

  local sec = math.floor(elapsed_ms / 1000)
  if sec < 60 then
    return string.format("%ds", sec)
  end

  local min = math.floor(sec / 60)
  if min < 60 then
    return string.format("%dm", min)
  end

  local hr = math.floor(min / 60)
  if hr < 24 then
    return string.format("%dh", hr)
  end

  local day = math.floor(hr / 24)
  return string.format("%dd", day)
end

--- Extract directory basename safely.
--- @param dir string|nil
--- @return string
local function get_basename(dir)
  if dir == nil or dir == vim.NIL or type(dir) ~= "string" or dir == "" then
    return "(no dir)"
  end
  local cleaned = dir:gsub("/+$", "")
  if cleaned == "" then
    return "/"
  end
  local base = cleaned:match("([^/]+)$")
  return base or cleaned
end

--- Format a session row for the picker entry.
---
--- @param row table Session row (from model.build or cli.fetch)
--- @param opts table|nil Options:
---   now?: number  Epoch ms for idle_age calculation (defaults to os.time() * 1000)
--- @return { display: string, ordinal: string }
function M.format(row, opts)
  local safe_row = type(row) == "table" and row or {}
  opts = opts or {}
  local now_ms = (type(opts.now) == "number") and opts.now or (os.time() * 1000)

  local glyph = M.glyph_of(safe_row)

  local ok_badge, badge = pcall(model.unread_badge, safe_row)
  if not ok_badge or type(badge) ~= "string" then
    badge = "?"
  end

  local title = safe_row.title
  if title == nil or title == vim.NIL or type(title) ~= "string" or title == "" then
    title = "(untitled)"
  end

  local basename = get_basename(safe_row.directory)
  local age = M.idle_age(safe_row.lastActivity, now_ms)

  -- THE SEPARATOR MUST NOT BE THE BADGE CHARACTER.
  --
  -- model.unread_badge renders "·" for `absent` (pigeon has no ledger for this
  -- session, the chronic majority case). Using "·" as the field separator too
  -- made the row read `○ · Title · dir · age`, where the badge is
  -- indistinguishable from punctuation -- so the one state that says "we have
  -- no unread data at all" rendered as invisible noise. That defeats contract
  -- 5 in practice while passing every glyph-distinctness test, because those
  -- compare glyphs against badges and never against the separator.
  local SEP = "│"

  local parts = { glyph }
  if badge ~= "" then
    table.insert(parts, badge)
  end
  table.insert(parts, title)
  table.insert(parts, SEP)
  table.insert(parts, basename)
  table.insert(parts, SEP)
  table.insert(parts, age)

  if safe_row.dir_missing == true then
    table.insert(parts, M.DIR_MISSING_MARK)
  end

  local display = table.concat(parts, " ")

  -- ORDINAL EXCLUSION:
  -- Ordinal must contain ONLY title and directory basename.
  -- Excludes glyph, unread badge, and idle age.
  -- Reason: the unread badge contains digits (e.g. "(3)"), so including it in
  -- ordinal would make typing "3" match unread counts instead of session titles.
  local ordinal = title .. " " .. basename

  return {
    display = display,
    ordinal = ordinal,
  }
end

--- Compose warning lines from fetch result and error.
---
--- Precedence:
--- 1. err ~= nil: one line naming the failure (must contain err.kind and err.message).
---    Handles "spawn", "exit", "timeout", "decode".
--- 2. result.warnings non-empty: split on newlines, drop empties, one line each.
---    (S3 outage tripwire: never discard).
--- 3. result present with 0 rows and no warnings: exactly one line indicating
---    no open sessions found, phrased so it CANNOT be confused with a failure.
--- 4. otherwise: {} (empty table).
---
--- @param result table|nil
--- @param err table|nil
--- @return string[]
function M.warning_lines(result, err)
  if err ~= nil then
    local kind = (type(err) == "table" and err.kind) and tostring(err.kind) or "error"
    local msg = (type(err) == "table" and err.message) and tostring(err.message) or tostring(err)
    return { string.format("[%s error] %s", kind, msg) }
  end

  if type(result) == "table" and type(result.warnings) == "string" and result.warnings ~= "" then
    local lines = {}
    for line in result.warnings:gmatch("[^\r\n]+") do
      local trimmed = line:match("^%s*(.-)%s*$")
      if trimmed ~= "" then
        table.insert(lines, trimmed)
      end
    end
    if #lines > 0 then
      return lines
    end
  end

  local rows = nil
  if type(result) == "table" then
    if vim.islist(result.rows) then
      rows = result.rows
    elseif vim.islist(result) then
      rows = result
    end
  end

  if rows ~= nil and #rows == 0 then
    return { "No open sessions found" }
  end

  return {}
end

--- Generate prompt title for the telescope picker.
---
--- Includes the current facet. If warning_lines is non-empty, visibly indicates
--- the warning count (e.g. " [⚠ N]"), ensuring warnings are seen even if
--- notifications under a floating picker window are missed.
---
--- @param facet string|nil
--- @param warning_lines string[]|nil
--- @param hidden integer|nil Count of automated rows dropped from the FETCHED
---        WINDOW -- not a fleet-wide total. Its job is attribution: it explains
---        why a short list is short, so an empty picker is never mistaken for a
---        broken tool. Wording it as a total would make it a lie.
--- @return string
function M.prompt_title(facet, warning_lines, hidden)
  local f = (facet and facet ~= "" and facet ~= vim.NIL) and tostring(facet) or "all"
  local base = string.format("Sessions (%s)", f)
  if type(hidden) == "number" and hidden > 0 then
    base = string.format("%s · %d hidden", base, hidden)
  end
  if type(warning_lines) == "table" and #warning_lines > 0 then
    return string.format("%s [⚠ %d]", base, #warning_lines)
  end
  return base
end

--- Telescope picker configuration options (pure subset).
---
--- THREE ORDERING CONTROLS (CRUX OF THE ORDERING DESIGN):
---
--- 1. `sorting_strategy`: Pinned EXPLICITLY to telescope's current default "descending"
---    (entry 1 renders at the BOTTOM, adjacent to the prompt, and is the initially-selected row).
---    Pinned explicitly rather than left implicit so a telescope default change cannot silently
---    reorder the list. Consistent with the user's other pickers, which all use the default.
---
--- 2. `tiebreak`: Returning false preserves arrival order. Note it is INSURANCE, not the guard:
---    real sorters return exactly 1 on an empty prompt and EntryManager consults tiebreak only
---    when score < 1, so it is not reached in the default view -- but typed prompts do produce
---    sub-1 ties.
---
--- 3. `sorter` IS NOT HERE AND THAT IS DELIBERATE:
---    The sorter needs a telescope-typed value (conf.generic_sorter) that a pure module cannot
---    construct without requiring telescope, so init.lua supplies it.
---    LIVE HAZARD: pickers.new defaults to sorters.empty(), which returns 1 for EVERY entry at
---    EVERY prompt, so omitting the sorter ships a fuzzy finder that does not filter -- silently,
---    and invisibly to every unit test. Task 3 asserts the sorter reaches pickers.new.
---
--- @return table
function M.picker_opts()
  return {
    sorting_strategy = "descending",
    tiebreak = function()
      return false
    end,
  }
end

return M
