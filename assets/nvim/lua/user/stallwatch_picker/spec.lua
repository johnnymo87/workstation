-- stallwatch_picker/spec.lua
--
-- Pure presentation for the stall-watch picker (workstation-p8ch): entry
-- text, ordinals, previewer lines, titles, and the pure subset of picker
-- options.
--
-- PURE: MUST NOT require telescope.* or plenary.*. No vim.system, no vim.fn,
-- no vim.api, no side effects. State glyphs, idle ages and the dir-gone mark
-- are the session switcher's, reused rather than copied so the two pickers
-- cannot drift.

local ss_spec = require("user.session_switcher.spec")

local M = {}

M.SEP = "│"
M.NOT_ARMED_MARK = "[log-only]"
M.NOT_ENABLED_MARK = "[disabled]"

local function oneline(s)
  if type(s) == "string" then
    return (s:gsub("[\r\n]+", " "))
  end
  return nil
end

local function nonempty(s)
  if type(s) == "string" and s ~= "" then
    local cleaned = oneline(s)
    if cleaned:match("%S") then
      return cleaned
    end
  end
  return nil
end

local function basename(dir)
  local d = nonempty(dir)
  if not d then
    return "(no dir)"
  end
  local cleaned = d:gsub("/+$", "")
  if cleaned == "" then
    return "/"
  end
  return cleaned:match("([^/]+)$") or cleaned
end

--- "5 open (2 decision, 1 blocker, 2 info)" / "0 open".
function M.counts_text(counts)
  counts = type(counts) == "table" and counts or { total = 0, by_kind = {} }
  local total = type(counts.total) == "number" and counts.total or 0
  local s = string.format("%d open", total)
  local parts = {}
  for _, kn in ipairs(type(counts.by_kind) == "table" and counts.by_kind or {}) do
    if type(kn) == "table" then
      local n = type(kn.n) == "number" and kn.n or 0
      local kind = nonempty(kn.kind) or "unknown"
      table.insert(parts, string.format("%d %s", n, kind))
    end
  end
  if #parts > 0 then
    s = s .. " (" .. table.concat(parts, ", ") .. ")"
  end
  return s
end

--- Screen 1 row: `name · N open (k decision, m blocker) · checked 12m ago`,
--- plus a marker when the program is not armed (log-only) or not enabled.
--- A missing last_tick_activity drops the "checked" part rather than lying.
function M.program_display(prow, now_ms)
  prow = type(prow) == "table" and prow or {}
  local tag = nonempty(prow.tag) or "(unnamed)"
  local parts = { tag, M.counts_text(prow.counts) }
  if type(prow.last_tick_ms) == "number" then
    table.insert(parts, "checked " .. ss_spec.idle_age(prow.last_tick_ms, now_ms) .. " ago")
  end
  local s = table.concat(parts, " · ")
  -- `== false`, not `~= true`: a MISSING field is "tolerated; that part of
  -- the row is blank" (design), and a marker would assert something unknown.
  if prow.armed == false then
    s = s .. " " .. M.NOT_ARMED_MARK
  end
  if prow.enabled == false then
    s = s .. " " .. M.NOT_ENABLED_MARK
  end
  return s
end

function M.program_ordinal(prow)
  return (type(prow) == "table" and nonempty(prow.tag)) or ""
end

--- `[kind]` for a flagged row, "" for an unflagged (all-view) row.
function M.badge(row)
  local k = type(row) == "table" and nonempty(row.badge_kind)
  return k and ("[" .. k .. "]") or ""
end

--- Screen 2 row: `kind badge · state glyph · title │ dir │ age [dir gone]`.
--- An unjoined row (the CLI did not return it) has no state or age: those
--- cells are blank, never a guessed glyph -- `~` would claim "stale data from
--- a dead source", which is a different statement.
function M.session_display(row, now_ms)
  row = type(row) == "table" and row or {}
  local joined = row.joined == true
  local glyph = joined and ss_spec.glyph_of(row) or " "
  local age = joined and ss_spec.idle_age(row.lastActivity, now_ms) or ""
  local title = nonempty(row.title) or nonempty(row.id) or "(untitled)"
  local lead = { glyph }
  local badge = M.badge(row)
  if badge ~= "" then
    table.insert(lead, 1, badge)
  end
  local s = table.concat(lead, " · ") .. " " .. title .. " " .. M.SEP .. " " .. basename(row.directory) .. " " .. M.SEP
  if age ~= "" then
    s = s .. " " .. age
  end
  if row.dir_missing == true then
    s = s .. " " .. ss_spec.DIR_MISSING_MARK
  end
  return s
end

--- Same exclusion rule as the switcher's ordinal: title and dir only, so
--- typing digits or a kind name does not match badges.
function M.session_ordinal(row)
  row = type(row) == "table" and row or {}
  return (nonempty(row.title) or nonempty(row.id) or "") .. " " .. basename(row.directory)
end

local function push_text(lines, prefix, text)
  local raw = type(text) == "string" and text or ""
  local first = true
  for line in raw:gmatch("[^\r\n]+") do
    table.insert(lines, (first and prefix or string.rep(" ", #prefix)) .. line)
    first = false
  end
  if first then
    table.insert(lines, prefix)
  end
end

--- `(new)`, `(changed: <what_changed>)`, `(stale)` markers for one item.
function M.item_marks(item)
  item = type(item) == "table" and item or {}
  local marks = {}
  if item.status == "new" then
    table.insert(marks, "(new)")
  elseif item.status == "changed" then
    local wc = nonempty(item.what_changed)
    table.insert(marks, wc and ("(changed: " .. wc .. ")") or "(changed)")
  end
  if item.stale == true then
    table.insert(marks, "(stale)")
  end
  return table.concat(marks, " ")
end

local function item_lines(lines, item, with_sessions)
  item = type(item) == "table" and item or {}
  local marks = M.item_marks(item)
  push_text(lines, "[" .. (nonempty(item.kind) or "?") .. "] ", item.text)
  if marks ~= "" then
    lines[#lines] = lines[#lines] .. " " .. marks
  end
  if with_sessions then
    for _, s in ipairs(type(item.sessions) == "table" and item.sessions or {}) do
      if type(s) == "table" then
        table.insert(lines, "    - " .. (nonempty(s.title) or nonempty(s.id) or "?"))
      end
    end
  end
end

--- Screen 1 previewer: the program's open items in contract order, each
--- `[kind] text` with new/changed/stale marks and the titles of the sessions
--- it names. Item text is split on newlines (nvim_buf_set_lines rejects them).
function M.program_preview_lines(prow)
  local raw_items = type(prow) == "table" and prow.items
  local items = {}
  for _, it in ipairs(type(raw_items) == "table" and raw_items or {}) do
    if type(it) == "table" then
      table.insert(items, it)
    end
  end
  if #items == 0 then
    return { "(no open items)" }
  end
  local lines = {}
  for i, item in ipairs(items) do
    if i > 1 then
      table.insert(lines, "")
    end
    item_lines(lines, item, true)
  end
  return lines
end

--- Screen 2 previewer: the text of every item naming this session.
function M.session_preview_lines(row)
  local raw_items = type(row) == "table" and row.items
  local items = {}
  for _, it in ipairs(type(raw_items) == "table" and raw_items or {}) do
    if type(it) == "table" then
      table.insert(items, it)
    end
  end
  if #items == 0 then
    return { "(no open items name this session)" }
  end
  local lines = {}
  for i, item in ipairs(items) do
    if i > 1 then
      table.insert(lines, "")
    end
    item_lines(lines, item, false)
  end
  return lines
end

local function warn_suffix(warnings)
  if type(warnings) == "table" and #warnings > 0 then
    return string.format(" [⚠ %d]", #warnings)
  end
  return ""
end

function M.programs_title(warnings)
  return "Stall-watch programs" .. warn_suffix(warnings)
end

--- @param view "flagged"|"all"
function M.sessions_title(tag, view, warnings)
  local name = nonempty(tag) or "(unnamed)"
  local view_text = view == "all" and "all tagged" or "flagged"
  return string.format("%s · %s", name, view_text) .. warn_suffix(warnings)
end

function M.digest_title(mtime_ms, now_ms)
  if type(mtime_ms) ~= "number" then
    return "stall-watch digest"
  end
  return "stall-watch digest · " .. ss_spec.idle_age(mtime_ms, now_ms) .. " old"
end

--- 1-based position of `tag` in the Screen 1 results, or nil.
function M.selection_index(prows, tag)
  if not nonempty(tag) then
    return nil
  end
  for i, p in ipairs(type(prows) == "table" and prows or {}) do
    if type(p) == "table" and p.tag == tag then
      return i
    end
  end
  return nil
end

--- Pure picker options for Screen 1.
---
--- Ordering controls are the switcher's (sorting_strategy = "descending",
--- order-preserving tiebreak), so both pickers render the same way.
---
--- CURSOR RESTORE on <C-b>: telescope's `default_selection_index` is an index
--- into the RESULTS list, and Picker:get_row maps it through
--- sorting_strategy (descending: row = max_results - index). So passing the
--- program's position in the results is correct under "descending" and must
--- NOT be inverted by hand -- the test pins that.
---
--- selection_strategy = "closest" applies that index only while the prompt
--- is empty. Under the default "reset" telescope re-applies the index on
--- every keystroke, pinning the cursor to a row position a filter has
--- already emptied.
function M.programs_picker_opts(prows, select_tag)
  local opts = ss_spec.picker_opts()
  local idx = M.selection_index(prows, select_tag)
  if idx then
    opts.default_selection_index = idx
    opts.selection_strategy = "closest"
  end
  return opts
end

function M.sessions_picker_opts()
  return ss_spec.picker_opts()
end

return M
