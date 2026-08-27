-- session_switcher/init.lua
--
-- Telescope picker entry point for the session switcher (S7 / Task 3).
--
-- Pure telescope glue:
-- - Captures tmux client at picker open (Contract 9).
-- - Merges spec.picker_opts() (sorting_strategy, tiebreak) into pickers.new.
-- - Provides conf.values.generic_sorter({}) to ensure fuzzy search filters.
-- - Wires attach_mappings for default accept (re-resolving via flow:accept),
--   <C-f> for cycling facets (all -> attached -> detached), and <C-r> to mark
--   the highlighted session read.
-- - Surfaces warnings in prompt_title and notifications.
--
-- ACCEPTING A ROW WRITES NOTHING. Jumping used to clear the session's unread
-- badge; it no longer does, because the purpose of a jump is often to peek.
-- Clearing follows evidence of PRESENCE and lives in the pigeon daemon
-- (#131) -- a human authoring a turn or resolving a question. <C-r> is the
-- picker's only remaining write, and it is deliberate.

local pickers = require("telescope.pickers")
local finders = require("telescope.finders")
local conf = require("telescope.config").values
local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")

local spec = require("user.session_switcher.spec")
local flow = require("user.session_switcher.flow")
local exec = require("user.session_switcher.exec")
local act = require("user.session_switcher.act")

local M = {}

local function next_facet(current)
  if current == "all" then
    return "attached"
  elseif current == "attached" then
    return "detached"
  else
    return "all"
  end
end

local function make_entry_maker(opts)
  return function(row)
    local formatted = spec.format(row, opts)
    return {
      value = row,
      display = formatted.display,
      ordinal = formatted.ordinal,
    }
  end
end

local function make_finder(rows, opts)
  return finders.new_table({
    results = rows or {},
    entry_maker = make_entry_maker(opts),
  })
end

--- Open the session switcher Telescope picker.
---
--- @param opts table|nil Options passed to telescope and flow controller
function M.open(opts)
  opts = opts or {}

  -- Contract 9: Capture invoking tmux client at open, not at accept
  local client = exec.tmux_client()

  local current_facet = opts.facet or "all"
  -- Deeper window than the CLI default of 50, because the automated filter runs
  -- AFTER the limit: at ~62% automated, 50 fetched leaves ~19 rows, and the
  -- longest consecutive run of automated roots is already 14 -- a batch filling
  -- the window would render an empty picker. Cost is flat (123ms at 50, 123ms at
  -- 200), and scoping it here rather than to the CLI default leaves ad-hoc CLI
  -- use unchanged.
  local flow_opts = vim.tbl_extend("force", opts, {
    fetch_opts = vim.tbl_extend("force", { limit = 200 }, opts.fetch_opts or {}),
  })
  local controller = opts.flow or flow.new(flow_opts)

  controller:refresh(current_facet, function(rows, result, err, hidden)
    local warning_lines = spec.warning_lines(result, err)
    exec.notify_warnings(warning_lines)
    local prompt_title = spec.prompt_title(current_facet, warning_lines, hidden)

    -- ONE clock read for the whole render, not one per row. spec.format falls
    -- back to its own os.time() when `now` is absent, which would let rows
    -- formatted either side of a second boundary report ages computed against
    -- different "now"s -- two sessions last active at the same instant could
    -- render "59s" and "1m". Cosmetic, but the fix is a single line and it also
    -- makes the whole render reproducible from one injected value.
    local fmt_opts = vim.tbl_extend("force", opts, { now = os.time() * 1000 })

    local picker_opts = vim.tbl_extend("force", spec.picker_opts(), {
      prompt_title = prompt_title,
      finder = make_finder(rows or {}, fmt_opts),
      sorter = conf.generic_sorter(opts),
      attach_mappings = function(prompt_bufnr, map)
        actions.select_default:replace(function()
          -- READ THE SELECTION BEFORE CLOSING, NOT AFTER.
          --
          -- `action_state.get_selected_entry()` reads a GLOBAL key
          -- (telescope/state.lua `get_global_key "selected_entry"`), and
          -- `actions.close` only clears the per-prompt status, so reading after
          -- close happens to work today. It works by accident: it depends on a
          -- global surviving teardown, and that global is shared by every
          -- picker in the session. Reading first makes the jump depend on our
          -- own control flow instead of on telescope's teardown order, so a
          -- future telescope that clears the key on close cannot turn Enter
          -- into a silent no-op. The stub test pins this ordering.
          local entry = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if not entry then
            return
          end
          local row = entry.value or entry
          controller:accept(row, function(desc)
            if not desc or type(desc) ~= "table" then
              return
            end
            -- JUMPING DELIBERATELY CLEARS NOTHING.
            --
            -- This used to fire a watermark write whenever a jump succeeded. It was
            -- wrong for a reason no amount of care in THIS function could fix: the
            -- stated purpose of a jump is often to PEEK -- to look at a session and
            -- decide you are not ready to read it. Clearing on that destroys the
            -- record of where you had stopped, and the watermark is a MAX() upsert,
            -- so it cannot be moved back.
            --
            -- Clearing now follows evidence of PRESENCE instead, and lives in the
            -- pigeon daemon where the evidence actually is (pigeon #131): a human
            -- authoring a turn, or resolving a question, in either the TUI or
            -- Telegram. Asking a follow-up question is close to proof you read what
            -- came before it. Arriving somewhere is not.
            --
            -- The case neither signal can see -- reading a session and never typing --
            -- is covered by the explicit <C-r> gesture below, not by guessing here.
            if desc.kind == "focus_here" then
              exec.focus_here(desc)
            elseif desc.kind == "switch_pane" then
              exec.switch_pane(desc, client)
            elseif desc.kind == "attach" then
              exec.attach(desc)
            elseif desc.kind == "refuse_dir_missing" then
              exec.refuse_dir_missing(desc)
            end
          end)
        end)

        -- ONE refresh implementation, used by every in-place update.
        --
        -- This was briefly duplicated for the mark-read gesture and the copies had
        -- ALREADY drifted in the first commit -- one called exec.notify_warnings and
        -- the other did not, with nothing recording whether that was deliberate.
        local function refresh_in_place()
          controller:refresh(current_facet, function(new_rows, new_result, new_err, new_hidden)
            local new_warnings = spec.warning_lines(new_result, new_err)
            exec.notify_warnings(new_warnings)
            local new_title = spec.prompt_title(current_facet, new_warnings, new_hidden)

            local current_picker = action_state.get_current_picker(prompt_bufnr)
            if current_picker then
              current_picker.prompt_title = new_title
              if current_picker.prompt_border and current_picker.prompt_border.change_title then
                current_picker.prompt_border:change_title(new_title)
              end
              local new_fmt_opts = vim.tbl_extend("force", opts, { now = os.time() * 1000 })
              current_picker:refresh(make_finder(new_rows or {}, new_fmt_opts), { reset_prompt = false })
            end
          end)
        end

        local function cycle_facet()
          current_facet = next_facet(current_facet)
          refresh_in_place()
          return true
        end

        -- MARK THE HIGHLIGHTED SESSION READ, without jumping to it.
        --
        -- The cover for the one case presence-detection cannot observe: reading a
        -- session and never typing in it. That leaves no trace anywhere, so it needs a
        -- deliberate keystroke rather than an inference.
        --
        -- IRREVERSIBLE BY CONSTRUCTION. The daemon's upsert is MAX(current, incoming),
        -- which is what makes stale and retried writes safe and is not worth giving up
        -- for an undo. So this is bound to an explicit key on a single highlighted row,
        -- never to arriving somewhere.
        local function mark_read()
          local entry = action_state.get_selected_entry()
          local row = entry and (entry.value or entry)
          local wm = act.mark_read_watermark(row)
          if not wm then
            -- Nil means the row has no ledger to clear (no last_event_id) or failed a
            -- guard. Say so: a keystroke that silently does nothing reads as a broken
            -- keybinding, and the '·' badge for "no ledger" is easy to miss.
            vim.notify("session-switcher: nothing to mark read for this row", vim.log.levels.INFO)
            return true
          end

          -- CHECK THE RETURN VALUE. exec.clear_unread returns false when curl is
          -- missing or vim.system raises, and that boolean is the only signal there
          -- is. The code this change deleted carried a long comment about not
          -- discarding exec success booleans; dropping it here would repeat the
          -- mistake in the one place that writes irreversibly.
          if not exec.clear_unread(wm, opts) then
            vim.notify("session-switcher: failed to mark " .. wm.sid .. " read", vim.log.levels.WARN)
            return true
          end

          -- ANNOUNCE SUCCESS, and name the session.
          --
          -- The write cannot be undone (the daemon's watermark is a MAX() upsert), so
          -- the next best thing to a confirmation prompt is making the action visible
          -- after the fact -- if this fires on the wrong row, the user finds out now
          -- rather than by noticing a missing badge days later. It also disambiguates
          -- success from the refresh below racing the write and redrawing a stale
          -- count, which would otherwise look identical to failure.
          vim.notify("session-switcher: marked " .. wm.sid .. " read", vim.log.levels.INFO)
          refresh_in_place()
          return true
        end

        map({ "i", "n" }, "<C-f>", cycle_facet)
        -- <M-r>, NOT <C-r>.
        --
        -- Telescope maps <C-r><C-w>, <C-r><C-a>, <C-r><C-f> and <C-r><C-l> in INSERT
        -- mode, and plain insert-mode <C-r>{reg} is vim's paste-a-register -- including
        -- <C-r>+ to paste a session id into the filter, which is exactly what this
        -- picker invites. Mapping <C-r> shadows that prefix, so a paste gesture would
        -- fire an IRREVERSIBLE mark-read on whatever row happened to be highlighted.
        -- Normal-mode-only is not an escape either: telescope binds <esc> to close.
        -- <M-r> is unmapped, and telescope ships <M-f>/<M-k>/<M-q> defaults, so Alt is
        -- known to work in this environment.
        map({ "i", "n" }, "<M-r>", mark_read)

        return true
      end,
    })

    local picker = pickers.new(opts, picker_opts)
    picker:find()
  end)
end

return M
