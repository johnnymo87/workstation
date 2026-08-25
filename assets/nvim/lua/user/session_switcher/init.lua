-- session_switcher/init.lua
--
-- Telescope picker entry point for the session switcher (S7 / Task 3).
--
-- Pure telescope glue:
-- - Captures tmux client at picker open (Contract 9).
-- - Merges spec.picker_opts() (sorting_strategy, tiebreak) into pickers.new.
-- - Provides conf.values.generic_sorter({}) to ensure fuzzy search filters.
-- - Wires attach_mappings for default accept (re-resolving via flow:accept)
--   and <C-f> for cycling facets (all -> attached -> detached).
-- - Surfaces warnings in prompt_title and notifications.

local pickers = require("telescope.pickers")
local finders = require("telescope.finders")
local conf = require("telescope.config").values
local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")

local spec = require("user.session_switcher.spec")
local flow = require("user.session_switcher.flow")
local exec = require("user.session_switcher.exec")

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
  local controller = opts.flow or flow.new(opts)

  controller:refresh(current_facet, function(rows, result, err)
    local warning_lines = spec.warning_lines(result, err)
    exec.notify_warnings(warning_lines)
    local prompt_title = spec.prompt_title(current_facet, warning_lines)

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

        local function cycle_facet()
          current_facet = next_facet(current_facet)
          controller:refresh(current_facet, function(new_rows, new_result, new_err)
            local new_warnings = spec.warning_lines(new_result, new_err)
            exec.notify_warnings(new_warnings)
            local new_title = spec.prompt_title(current_facet, new_warnings)

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
          return true
        end

        map({ "i", "n" }, "<C-f>", cycle_facet)

        return true
      end,
    })

    local picker = pickers.new(opts, picker_opts)
    picker:find()
  end)
end

return M
