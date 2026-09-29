-- oc_auto_attach.lua
--
-- External RPC entrypoint for oc-auto-attach (see pkgs/oc-auto-attach).
-- Called from outside via:
--
--   nvim --server <sock> --remote-expr \
--     'luaeval("require(\"user.oc_auto_attach\").open(_A)",
--              {sid="ses_...", dir="/abs/path", url="http://127.0.0.1:4096"})'
--
-- The dir field MUST be the exact session.directory from
-- `GET /session/<id>` (NOT the collapsed project root). It is used both as
-- the cwd of the spawned attach process AND passed via `--dir` to the
-- `opencode attach` invocation. The latter is load-bearing: opencode-serve
-- runs with WorkingDirectory=/home/dev (cloudbox) so its default
-- `Instance.directory` is `/home/dev`. The TUI's event-filter at
-- packages/opencode/src/cli/cmd/tui/context/event.ts:28 silently drops
-- session events whose `event.directory` (= the session's actual directory)
-- doesn't match `project.instance.directory()` (= /home/dev for a
-- no-`--dir` attach). Without `--dir`, every TUI for a session OUTSIDE
-- /home/dev freezes. See docs/plans/2026-04-28-attach-tui-frozen-fix-design.md
-- for the full causal chain. (Tracked: workstation-gsi.)

local M = {}

local statuses = {}

-- Full text of the last failure per sid. The visible notify below may be
-- truncated (or suppressed) to fit the command line; this keeps the whole
-- diagnostic somewhere non-blocking: `:lua =require("user.oc_auto_attach").errors`.
M.errors = {}

--- Notify without ever raising a hit-enter prompt (workstation-u8xx).
---
--- A message wider than the command line wraps and stops nvim at "Press
--- ENTER". While it waits there nvim does not serve RPC, and oc-auto-attach
--- polls status() over RPC -- so a failure message in a narrow pane (a
--- freshly created detached tmux server is 80 columns) hung the caller
--- forever. Truncate to v:echospace (screen cells free on the command line),
--- measured in DISPLAY width, and show nothing at all when there is no room.
local function safe_notify(msg, level)
  local room = tonumber(vim.v.echospace) or 0
  if room < 12 then return end
  if vim.fn.strdisplaywidth(msg) > room then
    local cut = room - 3
    while cut > 0 and vim.fn.strdisplaywidth(vim.fn.strcharpart(msg, 0, cut)) > room - 3 do
      cut = cut - 1
    end
    msg = vim.fn.strcharpart(msg, 0, cut) .. "..."
  end
  vim.notify(msg, level)
end
M._safe_notify = safe_notify

--- Query attach status for a session ID.
--- @param sid string
--- @return string "running" | "failed" | "exited" | "unknown"
function M.status(sid)
  if type(sid) ~= "string" or sid == "" then return "unknown" end
  return statuses[sid] or "unknown"
end

--- Open a new tab with `opencode attach` running in a terminal buffer.
--- @param opts table  { sid: string, dir: string, url: string, settle_ms?: number, scroll_to_message_id?: string }
--- @return integer 1  (so --remote-expr has something to print)
function M.open(opts)
  -- Validate synchronously so --remote-expr returns a meaningful status.
  if type(opts) ~= "table" then return 0 end
  if type(opts.sid) ~= "string" or not opts.sid:match("^ses_[A-Za-z0-9]+$") then
    safe_notify("oc_auto_attach: invalid sid", vim.log.levels.ERROR)
    return 0
  end
  if type(opts.dir) ~= "string" or vim.fn.isdirectory(opts.dir) == 0 then
    safe_notify("oc_auto_attach: invalid or missing dir", vim.log.levels.ERROR)
    return 0
  end
  if type(opts.url) ~= "string" or opts.url == "" then
    safe_notify("oc_auto_attach: invalid url", vim.log.levels.ERROR)
    return 0
  end

  local settle_threshold_ms = tonumber(opts.settle_ms) or 8000

  statuses[opts.sid] = "running"

  -- Schedule UI work for the next event-loop tick (so RPC can return promptly).
  vim.schedule(function()
    vim.cmd.tabnew()
    local buf = vim.api.nvim_get_current_buf()
    vim.b[buf].oc_session_id = opts.sid
    vim.b[buf].oc_session_dir = opts.dir

    local uv = vim.uv or vim.loop
    local start_hr = uv.hrtime()

    -- workstation-swws: hand the scroll target to the TUI in its ENVIRONMENT.
    --
    -- Not on the command line: `opencode attach` would reject an unknown flag, so a
    -- newer helper against an older opencode would fail to attach at all instead of
    -- merely failing to jump. Re-qualified with the sid here (the script strips it
    -- after checking it) so the TUI can confirm the target is for the session it
    -- actually opened -- an inherited variable otherwise applies to whoever reads it.
    --
    -- Shape-checked again rather than trusted: this crosses a process boundary, and
    -- the previous validator is in a different language in a different package.
    local job_env = nil
    if type(opts.scroll_to_message_id) == "string"
      and opts.scroll_to_message_id:match("^msg_[A-Za-z0-9]+$")
    then
      job_env = { OPENCODE_SCROLL_TO = opts.sid .. ":" .. opts.scroll_to_message_id }
    end

    -- `env -u BUN_INSPECT`, not clear_env + a filtered vim.fn.environ(): the
    -- latter bypasses nvim's own terminal-job env policy (TERM, COLORTERM,
    -- COLUMNS, VIMRUNTIME, NVIM). BUN_INSPECT is opencode-serve's inspector
    -- address (ws://127.0.0.1:1<port>/debug); it leaks into tmux servers
    -- started from an opencode bash tool, and an attach that inherits it dies
    -- with EADDRINUSE on that port (workstation-u8xx).
    local job_id = vim.fn.jobstart({
      "env", "-u", "BUN_INSPECT",
      "opencode", "attach", opts.url,
      "--session", opts.sid,
      "--dir", opts.dir,
    }, {
      term = true,
      cwd = opts.dir,
      -- Merges into the inherited environment (clear_env unset): replacing it would
      -- strip PATH and the attach would not find the binary it is launching.
      env = job_env,
      on_exit = function(_, exit_code, _)
        local elapsed_ms = (uv.hrtime() - start_hr) / 1e6
        if elapsed_ms < settle_threshold_ms then
          statuses[opts.sid] = "failed"
          if vim.api.nvim_buf_is_valid(buf) then
            pcall(vim.api.nvim_buf_set_name, buf, "[FAILED] " .. opts.sid)
          end
          M.errors[opts.sid] = "attach job exited prematurely for " .. opts.sid
            .. " (code " .. tostring(exit_code) .. "); see the [FAILED] tab"
          safe_notify("oc attach failed (code " .. tostring(exit_code) .. "): " .. opts.sid, vim.log.levels.ERROR)
        else
          statuses[opts.sid] = "exited"
          safe_notify("oc attach ended: " .. opts.sid, vim.log.levels.INFO)
        end
      end,
    })

    if job_id <= 0 then
      statuses[opts.sid] = "failed"
      if vim.api.nvim_buf_is_valid(buf) then
        pcall(vim.api.nvim_buf_set_name, buf, "[FAILED] " .. opts.sid)
      end
      M.errors[opts.sid] = "failed to start attach job for " .. opts.sid .. " (jobstart=" .. tostring(job_id) .. ")"
      safe_notify("oc attach did not start: " .. opts.sid, vim.log.levels.ERROR)
    end
  end)

  return 1
end

return M
