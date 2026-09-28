-- stallwatch_picker/init.lua
--
-- Thin telescope layer for the stall-watch picker (workstation-p8ch).
--
-- Screen 1 (programs) and Screen 2 (sessions of one program) are two pickers
-- over ONE snapshot fetched at open (source.lua). Moving between them never
-- does I/O, so there is no in-flight callback to race.
--
-- Keys:
--   Screen 1: <CR> drill into a program, <C-d> latest digest.
--   Screen 2: <CR> jump, <C-f> flagged/all, <C-b> back (cursor restored).
-- <C-d> (Screen 1) and <C-f> (Screen 2) shadow telescope's
-- preview_scrolling_down/_left defaults in those pickers only; the session
-- switcher already shadows <C-f> the same way.
--
-- Jumping is the session switcher's own path, not a copy of it:
-- flow:accept (fresh discovery re-resolve + act.decide) and then
-- session_switcher.dispatch (the exec.* side effects), with the tmux client
-- captured ONCE at open, as the switcher does (its Contract 9).

local pickers = require("telescope.pickers")
local finders = require("telescope.finders")
local previewers = require("telescope.previewers")
local conf = require("telescope.config").values
local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")

local switcher = require("user.session_switcher")
local exec = require("user.session_switcher.exec")
local flow = require("user.session_switcher.flow")

local model = require("user.stallwatch_picker.model")
local spec = require("user.stallwatch_picker.spec")
local source = require("user.stallwatch_picker.source")

local M = {}

--- Fill the preview buffer and soft-wrap its window. Item text is prose
--- (1-2 sentences), so an unwrapped preview cuts most of it off at the right
--- edge. linebreak wraps at word boundaries; breakindent keeps a wrapped
--- continuation under its own line's indent.
local function set_preview(state, lines)
  vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, lines)
  local win = state.winid
  if win and vim.api.nvim_win_is_valid(win) then
    vim.wo[win].wrap = true
    vim.wo[win].linebreak = true
    vim.wo[win].breakindent = true
  end
end

local function now_ms()
  return os.time() * 1000
end

--- Show `latest_digest` in a scratch buffer.
---
--- readfile into a `nofile` buffer, NEVER :edit -- :edit would put the
--- private path into the jumplist/oldfiles and hence shada. The buffer is not
--- named after the path for the same reason.
function M.show_digest(path)
  if type(path) ~= "string" or path == "" or vim.fn.filereadable(path) ~= 1 then
    vim.notify("stall-watch: no digest yet", vim.log.levels.INFO)
    return nil
  end
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    vim.notify("stall-watch: could not read the digest", vim.log.levels.WARN)
    return nil
  end
  local stat = (vim.uv or vim.loop).fs_stat(path)
  local mtime_ms = stat and (stat.mtime.sec * 1000) or nil
  vim.cmd("botright new")
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.wo.winbar = spec.digest_title(mtime_ms, now_ms())
  vim.keymap.set("n", "q", "<cmd>close<CR>", { buffer = buf, silent = true, nowait = true })
  return buf
end

local function digest_mapping(state, prompt_bufnr)
  return function()
    actions.close(prompt_bufnr)
    vim.schedule(function()
      M.show_digest(state.snap.doc.latest_digest)
    end)
    return true
  end
end

--- Screen 1.
--- @param state table { snap, prows, by_id, client, controller, opts }
--- @param select_tag string|nil program to put the cursor on (after <C-b>)
function M.programs(state, select_tag)
  local now = now_ms()
  local picker_opts = vim.tbl_extend("force", spec.programs_picker_opts(state.prows, select_tag), {
    prompt_title = spec.programs_title(state.snap.warnings),
    finder = finders.new_table({
      results = state.prows,
      entry_maker = function(p)
        return { value = p, display = spec.program_display(p, now), ordinal = spec.program_ordinal(p) }
      end,
    }),
    sorter = conf.generic_sorter(state.opts),
    previewer = previewers.new_buffer_previewer({
      title = "Open items",
      define_preview = function(self, entry)
        set_preview(self.state, spec.program_preview_lines(entry.value))
      end,
    }),
    attach_mappings = function(prompt_bufnr, map)
      actions.select_default:replace(function()
        -- Read the selection BEFORE closing (see session_switcher/init.lua).
        local entry = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if not entry then
          return
        end
        vim.schedule(function()
          M.sessions(state, entry.value, "flagged")
        end)
      end)
      map({ "i", "n" }, "<C-d>", digest_mapping(state, prompt_bufnr))
      return true
    end,
  })
  local picker = pickers.new(state.opts, picker_opts)
  picker:find()
  return picker
end

local function session_rows(state, prow, view)
  local flagged = model.flagged_rows(prow, state.by_id)
  if view == "all" then
    return model.all_rows(flagged, state.snap.rows, state.snap.tagged[prow.tag])
  end
  return flagged
end

local function session_finder(rows)
  local now = now_ms()
  return finders.new_table({
    results = rows,
    entry_maker = function(r)
      return { value = r, display = spec.session_display(r, now), ordinal = spec.session_ordinal(r) }
    end,
  })
end

--- Screen 2.
--- @param view "flagged"|"all"
function M.sessions(state, prow, view)
  local picker_opts = vim.tbl_extend("force", spec.sessions_picker_opts(), {
    prompt_title = spec.sessions_title(prow.tag, view, state.snap.warnings),
    finder = session_finder(session_rows(state, prow, view)),
    sorter = conf.generic_sorter(state.opts),
    previewer = previewers.new_buffer_previewer({
      title = "Items naming this session",
      define_preview = function(self, entry)
        set_preview(self.state, spec.session_preview_lines(entry.value))
      end,
    }),
    attach_mappings = function(prompt_bufnr, map)
      actions.select_default:replace(function()
        local entry = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if not entry then
          return
        end
        local row = entry.value or entry
        state.controller:accept(row, function(desc)
          switcher.dispatch(desc, row, state.client, state.opts)
        end)
      end)

      map({ "i", "n" }, "<C-f>", function()
        view = (view == "all") and "flagged" or "all"
        local picker = action_state.get_current_picker(prompt_bufnr)
        if picker then
          local title = spec.sessions_title(prow.tag, view, state.snap.warnings)
          picker.prompt_title = title
          if picker.prompt_border and picker.prompt_border.change_title then
            picker.prompt_border:change_title(title)
          end
          picker:refresh(session_finder(session_rows(state, prow, view)), { reset_prompt = false })
        end
        return true
      end)

      -- BACK: close, then reopen Screen 1 on the next tick with the cursor on
      -- this program. Reopening from inside the mapping would build a picker
      -- while telescope is still tearing this one down.
      map({ "i", "n" }, "<C-b>", function()
        actions.close(prompt_bufnr)
        vim.schedule(function()
          M.programs(state, prow.tag)
        end)
        return true
      end)
      return true
    end,
  })
  local picker = pickers.new(state.opts, picker_opts)
  picker:find()
  return picker
end

--- Open the picker: fetch the snapshot once, then Screen 1.
--- @param opts table|nil {
---   fetch?: function(source_opts, cb)  -- defaults to source.fetch
---   source_opts?: table
---   flow?: table                        -- controller with :accept(row, cb)
--- } plus telescope options.
function M.open(opts)
  opts = opts or {}
  -- Contract 9 (as in the switcher): capture the invoking tmux client at
  -- OPEN, not at accept, so a jump targets the terminal the user is in.
  local client = exec.tmux_client()
  local controller = opts.flow or flow.new({})
  local fetch = opts.fetch or source.fetch
  fetch(opts.source_opts or {}, function(snap, err)
    if err then
      vim.notify(err.message, err.kind == "timeout" and vim.log.levels.INFO or vim.log.levels.WARN)
      return
    end
    exec.notify_warnings(snap.warnings)
    local state = {
      snap = snap,
      prows = model.program_rows(snap.doc),
      by_id = model.index_rows(snap.rows),
      client = client,
      controller = controller,
      opts = opts,
    }
    M.programs(state, nil)
  end)
end

return M
