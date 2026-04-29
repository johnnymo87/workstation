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

--- Open a new tab with `opencode attach` running in a terminal buffer.
--- @param opts table  { sid: string, dir: string, url: string }
--- @return integer 1  (so --remote-expr has something to print)
function M.open(opts)
  -- Validate synchronously so --remote-expr returns a meaningful status.
  if type(opts) ~= "table" then return 0 end
  if type(opts.sid) ~= "string" or not opts.sid:match("^ses_[A-Za-z0-9]+$") then
    vim.notify("oc_auto_attach: invalid sid", vim.log.levels.ERROR)
    return 0
  end
  if type(opts.dir) ~= "string" or vim.fn.isdirectory(opts.dir) == 0 then
    vim.notify("oc_auto_attach: invalid or missing dir", vim.log.levels.ERROR)
    return 0
  end
  if type(opts.url) ~= "string" or opts.url == "" then
    vim.notify("oc_auto_attach: invalid url", vim.log.levels.ERROR)
    return 0
  end

  -- Schedule UI work for the next event-loop tick (so RPC can return promptly).
  vim.schedule(function()
    vim.cmd.tabnew()
    vim.b.oc_session_id = opts.sid
    vim.b.oc_session_dir = opts.dir
    vim.fn.jobstart({
      "opencode", "attach", opts.url,
      "--session", opts.sid,
      "--dir", opts.dir,
    }, {
      term = true,
      cwd = opts.dir,
    })
  end)

  return 1
end

return M
