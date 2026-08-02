-- session_switcher/rpc.lua
--
-- The RPC entrypoint every nvim exposes so the session switcher in ANY nvim can
-- ask it "which opencode sessions are you showing, and are they alive?".
--
-- Invoked from another editor as:
--
--   nvim --server <sock> --remote-expr \
--     'luaeval("require(\"user.session_switcher.rpc\").snapshot()")'
--
-- RETURNS A JSON STRING, NOT A TABLE. `--remote-expr` can only carry simple
-- scalars back across the wire; a table would arrive as a useless stringified
-- address. The caller decodes.
--
-- WHY THIS JOINS attach_status RATHER THAN REPORTING BUFFER PRESENCE:
-- when `opencode attach` dies, oc_auto_attach only renames the buffer to
-- "[FAILED] <sid>" and records statuses[sid]="failed" -- it does NOT clear
-- b:oc_session_id (oc_auto_attach.lua:78-82). A snapshot built from buffer
-- variables alone therefore reports a DEAD attach as an attached session, and
-- the picker cheerfully jumps the user into a corpse. The status join is the
-- whole point of this module.

local M = {}

--- Snapshot the opencode sessions visible in THIS nvim.
--- @param opts table|nil { status?, job_dead? }  -- injection seams for tests
--- @return string JSON array of { sid, buffer, tabpage, attach_status, job_dead }
function M.snapshot(opts)
  opts = opts or {}

  -- PER-BUFFER liveness, because attach_status alone is not enough.
  -- oc_auto_attach keys `statuses` by SID, not by buffer. Re-attaching a
  -- session whose previous attach died sets statuses[sid]="running" again --
  -- and the ORIGINAL corpse buffer still carries b:oc_session_id, so a
  -- sid-only join reports the corpse as running too. That is precisely the
  -- dead terminal this module must never send anyone to. A terminal buffer
  -- carries b:terminal_job_id, and jobwait(...,0) returns -1 only while the
  -- job is alive, which is buffer-level truth rather than sid-level memory.
  local job_dead = opts.job_dead or function(buf)
    local ok, jid = pcall(function() return vim.b[buf].terminal_job_id end)
    if not ok or type(jid) ~= "number" then return nil end -- not a terminal: no opinion
    local res = vim.fn.jobwait({ jid }, 0)
    return res[1] ~= -1
  end

  local status = opts.status
  if not status then
    -- Resolved lazily and defensively: a switcher in an nvim that never loaded
    -- oc_auto_attach must degrade to "unknown" rather than raising inside an
    -- RPC call, where the error would surface to the caller as an empty reply.
    local ok, mod = pcall(require, "user.oc_auto_attach")
    if ok and type(mod.status) == "function" then
      status = mod.status
    else
      status = function() return "unknown" end
    end
  end

  -- Map buffer -> tabpage for the buffers that are actually displayed. A
  -- session whose buffer is hidden has no tabpage; that is reported as nil
  -- rather than guessed, since the consumer uses it to decide where to jump.
  local tab_of = {}
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      local ok, buf = pcall(vim.api.nvim_win_get_buf, win)
      if ok then tab_of[buf] = tab end
    end
  end

  local hits = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) then
      local ok, sid = pcall(function() return vim.b[buf].oc_session_id end)
      if ok and type(sid) == "string" and sid ~= "" then
        table.insert(hits, {
          sid = sid,
          buffer = buf,
          tabpage = tab_of[buf],
          attach_status = status(sid),
          job_dead = job_dead(buf),
        })
      end
    end
  end

  -- vim.json.encode({}) yields "{}", which is not a list and would fail the
  -- consumer's islist check. Be explicit about the empty case.
  if #hits == 0 then return "[]" end
  return vim.json.encode(hits)
end

return M
