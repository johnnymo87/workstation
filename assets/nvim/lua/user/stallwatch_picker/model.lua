-- stallwatch_picker/model.lua
--
-- Pure row model for the stall-watch picker (workstation-p8ch).
--
-- Input is ONE snapshot fetched at open by source.lua:
--   { doc = <items.sh --json v1>, tagged = { [tag] = { sid, ... } },
--     rows = <oc-session-list --with-state --fold --ids rows>, warnings = {...} }
-- Everything here is a pure function of that snapshot, so moving between
-- screens never waits on I/O.
--
-- Note: JSON nulls are normalised to Lua nil at the boundary (source.lua luanil);
-- the model still tolerates vim.NIL defensively.
--
-- PURE: MUST NOT require telescope.* or plenary.*. No vim.system, no vim.fn,
-- no vim.api, no vim.notify. CI loads this under `nvim --clean -l`.

local M = {}

--- Urgency order of item kinds, mirrored from the read command's contract
--- ("decision > blocker > error > stalled > follow_up > declared_wait > info").
--- Used for the badge of a session named by several items, and for the order
--- of kinds in a program row's count breakdown.
M.KIND_ORDER = { "decision", "blocker", "error", "stalled", "follow_up", "declared_wait", "info" }

M.KIND_RANK = {}
for i, k in ipairs(M.KIND_ORDER) do
  M.KIND_RANK[k] = i
end

--- Every field of the v1 contract this picker reads, as a dotted path where
--- `[]` means "each element". The field-presence test walks the fixture with
--- this list, so a field the picker starts reading must be added here AND to
--- the fixture -- contract drift becomes a deliberate fixture edit.
M.READS = {
  "version",
  "latest_digest",
  "programs[].tag",
  "programs[].armed",
  "programs[].enabled",
  "programs[].last_tick_activity",
  "programs[].items[].kind",
  "programs[].items[].text",
  "programs[].items[].status",
  "programs[].items[].what_changed",
  "programs[].items[].stale",
  "programs[].items[].sessions[].id",
  "programs[].items[].sessions[].title",
  "programs[].items[].sessions[].directory",
  "programs[].items[].sessions[].directory_exists",
}

--- Rank of a kind; unknown kinds sort after every known one (additive contract
--- fields must not crash the picker, and an unknown kind is not more urgent
--- than a known one).
function M.kind_rank(kind)
  return M.KIND_RANK[kind] or (#M.KIND_ORDER + 1)
end

local function nonempty(s)
  if type(s) == "string" and s ~= "" then
    return s
  end
  return nil
end

local function list(t)
  if type(t) == "table" and vim.islist(t) then
    return t
  end
  return {}
end

--- Parse the contract's ISO-8601 timestamps ("2026-01-01T12:00:00.123456+00:00",
--- also "Z" or no offset) to epoch MILLISECONDS. Pure arithmetic: os.time()
--- would interpret the fields in the LOCAL zone. Returns nil on anything else.
function M.iso_ms(s)
  if type(s) ~= "string" then
    return nil
  end
  local y, mo, d, h, mi, sec, rest =
    s:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)[T ](%d%d):(%d%d):(%d%d)(.*)$")
  if not y then
    return nil
  end
  local frac, tz = "", rest
  if rest:sub(1, 1) == "." then
    frac, tz = rest:match("^(%.%d+)(.*)$")
    if not frac then
      return nil
    end
  end
  y, mo, d = tonumber(y), tonumber(mo), tonumber(d)
  local ih, imi, isec = tonumber(h), tonumber(mi), tonumber(sec)
  if mo < 1 or mo > 12 or d < 1 or d > 31 or ih > 23 or imi > 59 or isec > 60 then
    return nil
  end
  -- days_from_civil (H. Hinnant), valid for the proleptic Gregorian calendar.
  local yy = (mo <= 2) and (y - 1) or y
  local era = math.floor(yy / 400)
  local yoe = yy - era * 400
  local mp = (mo + 9) % 12
  local doy = math.floor((153 * mp + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  local days = era * 146097 + doe - 719468
  local secs = days * 86400 + ih * 3600 + imi * 60 + isec
  if tz ~= "" and tz ~= "Z" then
    local sign, oh, om = tz:match("^([+-])(%d%d):?(%d%d)$")
    if not sign then
      return nil
    end
    local ioh, iom = tonumber(oh), tonumber(om)
    if ioh > 23 or iom > 59 then
      return nil
    end
    local off = ioh * 3600 + iom * 60
    secs = (sign == "+") and (secs - off) or (secs + off)
  end
  local ms = 0
  if frac ~= "" then
    ms = math.floor(tonumber("0" .. frac) * 1000)
  end
  return secs * 1000 + ms
end

--- Open-item counts for one program: total, and per kind in KIND_ORDER
--- (unknown kinds after, alphabetically). Zero-count kinds are omitted.
--- @return { total: integer, by_kind: { kind: string, n: integer }[] }
function M.counts(program)
  local items = list(type(program) == "table" and program.items)
  local n = {}
  local total = 0
  for _, it in ipairs(items) do
    if type(it) == "table" then
      total = total + 1
      local k = nonempty(it.kind) or "unknown"
      n[k] = (n[k] or 0) + 1
    end
  end
  local by_kind = {}
  for _, k in ipairs(M.KIND_ORDER) do
    if n[k] then
      table.insert(by_kind, { kind = k, n = n[k] })
      n[k] = nil
    end
  end
  local rest = vim.tbl_keys(n)
  table.sort(rest)
  for _, k in ipairs(rest) do
    table.insert(by_kind, { kind = k, n = n[k] })
  end
  return { total = total, by_kind = by_kind }
end

--- Screen 1 rows: one per program, in the READ COMMAND'S ORDER (stable
--- between opens, so cursor restore by position is meaningful). Urgency is
--- carried in the row text, never by re-sorting.
function M.program_rows(doc)
  local out = {}
  for _, p in ipairs(list(type(doc) == "table" and doc.programs)) do
    if type(p) == "table" then
      local armed, enabled = nil, nil
      if type(p.armed) == "boolean" then
        armed = p.armed
      end
      if type(p.enabled) == "boolean" then
        enabled = p.enabled
      end
      table.insert(out, {
        tag = nonempty(p.tag) or "(unnamed)",
        armed = armed,
        enabled = enabled,
        last_tick_ms = M.iso_ms(p.last_tick_activity),
        items = list(p.items),
        counts = M.counts(p),
      })
    end
  end
  return out
end

--- id -> CLI row, for the left-join.
function M.index_rows(rows)
  local by_id = {}
  for _, r in ipairs(list(rows)) do
    if type(r) == "table" and nonempty(r.id) then
      by_id[r.id] = r
    end
  end
  return by_id
end

--- Screen 2 flagged view: ITEM-DRIVEN rows.
---
--- Built from items[].sessions and LEFT-JOINED to CLI rows by id. A session
--- the CLI did not return (archived, deleted, filtered) still gets a row from
--- item data alone -- that is the whole reason the rows are item-driven.
---
--- Order: first appearance while walking items in contract order, which is
--- already most-urgent-first. A session named by several items appears ONCE,
--- carrying every item that names it and the most urgent kind as its badge.
---
--- Joined rows are a shallow copy of the CLI row (so act.decide and the jump
--- dispatch see every field they normally do: id, dir_missing, directory,
--- anchor_msg_id, ...). Unjoined rows fall back to:
---   title       = item session title, else the id
---   directory   = item session directory
---   dir_missing = (directory_exists == false)
--- and carry no effective_state / lastActivity (rendered blank).
---
--- @param prow table a row from M.program_rows
--- @param by_id table from M.index_rows
--- @return table[]
function M.flagged_rows(prow, by_id)
  by_id = type(by_id) == "table" and by_id or {}
  local out, seen = {}, {}
  for _, item in ipairs(list(type(prow) == "table" and prow.items)) do
    if type(item) == "table" then
      for _, s in ipairs(list(item.sessions)) do
        local sid = type(s) == "table" and nonempty(s.id)
        if sid then
          local row = seen[sid]
          if not row then
            local cli = type(by_id[sid]) == "table" and by_id[sid] or nil
            if cli then
              row = vim.tbl_extend("force", {}, cli)
              row.joined = true
            else
              row = {
                id = sid,
                title = nonempty(s.title) or sid,
                directory = nonempty(s.directory),
                dir_missing = s.directory_exists == false,
                joined = false,
              }
            end
            local ikind = nonempty(item.kind)
            row.badge_kind = ikind
            row.items = {}
            seen[sid] = row
            table.insert(out, row)
          elseif M.kind_rank(nonempty(item.kind)) < M.kind_rank(row.badge_kind) then
            row.badge_kind = nonempty(item.kind)
          end
          table.insert(row.items, item)
        end
      end
    end
  end
  return out
end

--- Screen 2 all view: a STABLE PARTITION of the one CLI result.
---
--- flagged rows first, then the program's other tagged roots, each group in
--- oc-session-list order -- the CLI still owns ordering. Flagged rows the CLI
--- did not return are appended to the flagged group in item order, so
--- toggling views never makes a flagged session vanish.
---
--- @param flagged table[] from M.flagged_rows
--- @param cli_rows table[] snapshot rows, CLI order
--- @param tagged_ids string[]|nil root ids carrying this program's tag
function M.all_rows(flagged, cli_rows, tagged_ids)
  local flagged_by_id = {}
  for _, f in ipairs(list(flagged)) do
    local fid = type(f) == "table" and nonempty(f.id)
    if fid then
      flagged_by_id[fid] = f
    end
  end
  local tagged = {}
  for _, sid in ipairs(list(tagged_ids)) do
    local tsid = nonempty(sid)
    if tsid then
      tagged[tsid] = true
    end
  end
  local head, tail, placed = {}, {}, {}
  for _, r in ipairs(list(cli_rows)) do
    local sid = type(r) == "table" and nonempty(r.id)
    if sid and flagged_by_id[sid] then
      table.insert(head, flagged_by_id[sid])
      placed[sid] = true
    elseif sid and tagged[sid] then
      local copy = vim.tbl_extend("force", {}, r)
      copy.joined = true
      copy.items = {}
      table.insert(tail, copy)
    end
  end
  for _, f in ipairs(list(flagged)) do
    local fid = type(f) == "table" and nonempty(f.id)
    if fid and not placed[fid] then
      table.insert(head, f)
    end
  end
  vim.list_extend(head, tail)
  return head
end

--- Union of every session id the snapshot needs from oc-session-list: item
--- sessions of every program plus every program's tagged ids. Deduped,
--- first-seen order (deterministic argv).
function M.union_ids(doc, tagged)
  local out, seen = {}, {}
  local function add(sid)
    if nonempty(sid) and not seen[sid] then
      seen[sid] = true
      table.insert(out, sid)
    end
  end
  for _, p in ipairs(list(type(doc) == "table" and doc.programs)) do
    for _, it in ipairs(list(type(p) == "table" and p.items)) do
      for _, s in ipairs(list(type(it) == "table" and it.sessions)) do
        add(type(s) == "table" and s.id)
      end
    end
  end
  for _, p in ipairs(list(type(doc) == "table" and doc.programs)) do
    local tag = type(p) == "table" and nonempty(p.tag)
    for _, sid in ipairs(list(type(tagged) == "table" and tag and tagged[tag])) do
      add(sid)
    end
  end
  return out
end

return M
