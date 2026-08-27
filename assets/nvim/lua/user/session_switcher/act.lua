-- session_switcher/act.lua
--
-- Pure decision module for session switcher actions and watermark payloads (S7 / Task 2).
--
-- Maps a displayed row and a fresh discovery hit to an action descriptor, and determines
-- whether a jump fires a watermark clear payload to pigeon daemon.
--
-- PURE: MUST NOT reference telescope.* or plenary.* at any level.
-- CI runs bare nixpkgs neovim where `require("telescope")` FAILS.
-- No vim.system, no vim.fn, no vim.notify, no vim.api, no side effects.

-- LIVENESS IS NOT REIMPLEMENTED HERE, DELIBERATELY.
--
-- Matches model.lua:11-23. The test harness loads modules with `loadfile` under
-- `nvim --clean`, where `require` fails without runtimepath unless preloaded in
-- package.preload. A private copy of discovery.is_live was the exact incident where
-- discovery.lua could be sabotaged while tests stayed green.
--
-- So: one definition, injectable via opts.is_live, defaulting to the real
-- discovery.is_live via pcall(require, ...).
local function default_is_live(hit)
  local ok, discovery = pcall(require, "user.session_switcher.discovery")
  if ok and type(discovery) == "table" and type(discovery.is_live) == "function" then
    return discovery.is_live(hit)
  end
  -- Cannot verify liveness at all. Report NOT attached / NOT live, matching
  -- the asymmetry discovery.lua documents: a false "dead" costs the user a duplicate
  -- attach (recoverable), a false "live" teleports them into a dead terminal.
  return false
end

local M = {}

--- Decide the action to take for a selected session row.
---
--- Evaluates branch precedence based on `row` and a FRESH `hit` from discovery re-resolve.
--- Branch precedence order is the crux of the decision logic:
---
--- 1. `refuse_dir_missing`: Checked FIRST, before anything about attachment.
---    A session whose directory has disappeared from disk cannot be opened safely;
---    even if currently attached and live, it refuses navigation.
--- 2. `focus_here`: Fresh hit is live and attached in THIS Neovim instance (`hit.own == true`).
--- 3. `switch_pane`: Fresh hit is live and attached in another tmux pane / editor.
---    Carries pane, sock, and buffer FROM THE FRESH HIT (never the stale displayed row,
---    preventing TOCTOU races where a session moved between render and keypress).
--- 4. `attach`: No live hit. Opens fresh attach via oc-auto-attach.
---
--- CONTRACT 2 / NIL-DEREF GUARD:
--- A pierced row (e.g. error/blocked) survives facet="attached" while being detached and pane-less.
--- Branching on the fresh hit and liveness ensures we yield `attach` rather than attempting
--- to jump to a non-existent pane.
---
--- @param row table|nil Displayed row (annotated by model.build or cli.fetch)
--- @param hit table|nil Fresh discovery hit for row.id (from discovery.locate)
--- @param opts table|nil Options:
---   is_live?: fun(hit: table|nil): boolean  -- injection seam; defaults to discovery.is_live
--- @return table Action descriptor
function M.decide(row, hit, opts)
  local safe_row = (type(row) == "table") and row or {}
  opts = (type(opts) == "table") and opts or {}
  local is_live = opts.is_live or default_is_live

  -- 1. Checked FIRST: dir_missing beats attachment
  if safe_row.dir_missing == true then
    return {
      kind = "refuse_dir_missing",
      directory = safe_row.directory,
    }
  end

  -- 2 & 3. Attachment branches based on fresh hit liveness
  local hit_table = (type(hit) == "table") and hit or nil
  -- `hit_table and` is not redundant with is_live's nil handling. It makes "no
  -- hit means no jump" STRUCTURAL rather than a contract we inherit from
  -- another module: without it, decide() depends on is_live(nil) returning
  -- false, and an is_live that ever returned true for nil would not merely
  -- misroute -- it would nil-deref on hit_table.own one line later. Found by
  -- mutation testing, where sabotaging discovery.is_live to `return true`
  -- crashed here instead of producing the wrong descriptor.
  if hit_table and is_live(hit_table) then
    if hit_table.own == true then
      return {
        kind = "focus_here",
        buffer = hit_table.buffer,
        tabpage = hit_table.tabpage,
      }
    else
      return {
        kind = "switch_pane",
        pane = hit_table.pane,
        sock = hit_table.sock,
        buffer = hit_table.buffer,
      }
    end
  end

  -- 4. No live hit -> attach fresh
  return {
    kind = "attach",
    sid = safe_row.id,
  }
end

--- Determine the watermark clear payload for a session row.
---
--- THE VALUE MUST COME FROM THE DISPLAYED ROW, NEVER RECOMPUTED AND NEVER A CLOCK.
---
--- Context: The pigeon daemon upserts `MAX(current, incoming)`.
--- A stale mark is merely older and self-heals on subsequent jumps. But a too-large
--- value (such as a timestamp) PERMANENTLY HIDES every future event for that session,
--- because event IDs are sequential integers (1, 2, 3...) whereas timestamps are
--- epoch milliseconds (~1.7e12).
---
--- Sending a millisecond timestamp (~1.7e12) instead of an event id is the specific
--- catastrophic mix-up — a row may carry both `last_event_id` and a `lastActivity`
--- timestamp, and they are easy to confuse.
---
--- Therefore:
--- - Returns `{ sid = row.id, last_event_id = row.last_event_id }`
--- - Returns `nil` when:
---   - `row.last_event_id` is nil, vim.NIL, or not a number (true for BOTH `unread_state == "absent"`
---     and `unread_state == "unavailable"`)
---   - `row.id` is missing, nil, vim.NIL, or not a string
---   - Defensive guard: `row.last_event_id >= 1e12` (implausibly large value; timestamp rejected)
---     or `row.last_event_id < 0`
---
--- SINGLE DEFINITION ON PURPOSE. The >= 1e12 guard is what stops a lastActivity
--- timestamp being written as an event id, which would permanently hide every future
--- event in that session. It existed once, for the jump path that no longer writes;
--- the explicit mark-read gesture needs exactly the same protection, and a second copy
--- is a second thing to forget to update.
---
--- @param row table|nil Displayed session row
--- @return { sid: string, last_event_id: number }|nil Payload for POST /sessions/:sid/read, or nil
local function watermark_for_row(row)
  if type(row) ~= "table" then
    return nil
  end

  local sid = row.id
  if sid == nil or sid == vim.NIL or type(sid) ~= "string" or sid == "" then
    return nil
  end

  local last_event_id = row.last_event_id
  if last_event_id == nil or last_event_id == vim.NIL or type(last_event_id) ~= "number" then
    return nil
  end

  -- DEFENSIVE GUARD: REJECT TIMESTAMPS
  -- Event IDs are small integers (1, 2, ...). Values >= 1e12 are epoch ms timestamps
  -- (e.g. row.lastActivity ~1.7e12). Sending a timestamp would permanently corrupt
  -- the session watermark in pigeon daemon.
  if last_event_id >= 1e12 or last_event_id < 0 then
    return nil
  end

  return {
    sid = sid,
    last_event_id = last_event_id,
  }
end

--- Watermark payload for the EXPLICIT "mark read" gesture.
---
--- Built from a row alone: there is no jump descriptor, because jumping no longer
--- writes a watermark at all. Clearing now follows evidence of PRESENCE, which the
--- pigeon daemon derives from a human authoring a turn or resolving a question
--- (pigeon #131); this keystroke is the cover for the case that cannot observe --
--- reading a session and never typing.
---
--- Deliberately does NOT inherit the refuse_dir_missing refusal. That guard exists
--- because JUMPING into a vanished directory is the unsafe act; marking read is a
--- watermark write that touches no directory, and a session whose cwd was deleted is
--- exactly one you may want to silence.
---
--- @param row table
--- @return table|nil payload { sid = string, last_event_id = number }, or nil
function M.mark_read_watermark(row)
  return watermark_for_row(row)
end

return M
