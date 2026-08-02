-- session_switcher/cli.lua
--
-- Thin ASYNCHRONOUS caller for the `oc-session-list` CLI.
--
-- This module deliberately contains no merge, liveness or GC logic. All of
-- that moved into `oc-session-list` itself (Task 6 / PR #234) so that nvim is
-- not the correctness boundary and there is exactly ONE implementation. What
-- is left here is: spawn the CLI off the UI thread, decode its JSON, and
-- define what happens when it is missing, slow, or angry.
--
-- WHY ASYNC IS MANDATORY (two reasons, one real today and one prospective):
--
--   1. Real today: the call is not free. Measured on cloudbox against the live
--      13 GB opencode.db, `--with-state --limit 50` takes 120-250 ms and emits
--      ~300 KB of JSON (the limit is per ROOT TREE, so 50 roots expanded to
--      621 rows). Blocking the editor for a quarter second on every picker
--      open is bad; the DB is unbounded and contended, so that figure is a
--      floor, not a ceiling.
--   2. Prospective: if the CLI ever performs socket discovery via
--      `nvim --server <sock> --remote-expr`, a SYNCHRONOUS call from inside
--      nvim would have the CLI RPC back into an editor that is blocked
--      waiting for it -- a deadlock that resolves only on timeout. Verified
--      2026-08-02 that the CLI does NO nvim RPC today (S5 keeps discovery in
--      Lua precisely so it never needs to), so this hazard is currently
--      unreachable. It is cheap to stay immune to it.
--
-- ERROR SURFACE. The acceptance criterion is that failures SURFACE rather than
-- silently producing an empty picker -- "no sessions" and "the tool broke"
-- must never look alike. Measured CLI behaviour (2026-08-02):
--   exit 0, JSON on stdout, stderr empty        -> ok, no warnings
--   exit 0, JSON on stdout, stderr NON-empty    -> ok WITH warnings  <-- note
--   exit 1, stderr explains                     -> error
--
-- The middle row is load-bearing and is why `warnings` exists. S3 (PR #243)
-- made those stderr lines the fleet's outage tripwire ("no live writer is
-- reporting for any of the N session(s)"). Treating a non-empty stderr as a
-- failure would blank the picker during a partial outage; discarding it would
-- hide the outage completely. It is neither: it is data the caller must show.
--
-- CONTRACT NOTES FOR THE CONSUMER (S5/S8):
--   * JSON null decodes to Lua nil, not vim.NIL (see luanil below).
--   * There is NO cancellation. Each fetch is independent and its callback
--     WILL fire, even if the picker that asked for it has since closed. A
--     caller that can re-open within the timeout window owns the generation
--     token needed to ignore a stale reply.
--
-- Rows are passed through VERBATIM. In particular `activity` may be "nodata",
-- a 4th union member meaning no live writer was in a position to report. It is
-- a tripwire, not a status. This module must not normalise, default or drop it.

local M = {}

M.CMD = "oc-session-list"
M.DEFAULT_TIMEOUT_MS = 5000

--- Build the argv for the CLI invocation.
--- @param opts table
--- @return string[]
function M.build_argv(opts)
  local argv = { opts.cmd or M.CMD, "--with-state" }
  if opts.limit then
    table.insert(argv, "--limit")
    table.insert(argv, tostring(opts.limit))
  end
  return argv
end

--- Fetch session rows asynchronously.
---
--- @param opts table|nil {
---   limit?: integer,        -- passed through as --limit (per ROOT TREE)
---   timeout_ms?: integer,   -- default 5000
---   cmd?: string,           -- override the binary name
---   system?: function,      -- injection seam for tests (defaults to vim.system)
--- }
--- @param cb function(result, err)
---   result = { rows = <decoded array>, warnings = <string|nil> }  on success
---   err    = { kind, message, code?, stderr? }                    on failure
---   kind is one of "spawn" | "exit" | "timeout" | "decode".
---   EXACTLY ONE of result/err is non-nil, and cb is invoked EXACTLY ONCE,
---   always on the main loop.
function M.fetch(opts, cb)
  opts = opts or {}
  vim.validate("cb", cb, "function")

  local settled = false
  local handle

  -- Every exit path funnels through here, which guarantees the two properties
  -- the picker depends on: the callback fires exactly once (a timeout followed
  -- by a late reply must not deliver two answers), and it fires via
  -- vim.schedule. The latter is not cosmetic -- vim.system's on_exit runs in a
  -- fast event context where most of the API is forbidden, so a callback that
  -- touched the picker would raise E5560 without it. Scheduling also makes
  -- fetch() unconditionally async even if a caller injects a `system` that
  -- replies synchronously.
  local function settle(result, err)
    if settled then return end
    settled = true
    vim.schedule(function() cb(result, err) end)
  end

  local system = opts.system or vim.system
  local argv = M.build_argv(opts)

  -- A missing binary makes vim.system RAISE (ENOENT) rather than call back, so
  -- without this pcall the picker would die of an uncaught exception instead of
  -- reporting "the CLI is not installed".
  local spawned, err_or_handle = pcall(system, argv, { text = true }, function(out)
    if out.code ~= 0 then
      settle(nil, {
        kind = "exit",
        code = out.code,
        stderr = out.stderr or "",
        message = string.format("%s exited %d", argv[1], out.code),
      })
      return
    end

    -- luanil: JSON null becomes Lua nil rather than vim.NIL. vim.NIL is
    -- userdata and therefore TRUTHY, so `if row.activity then` would silently
    -- take the wrong branch for a null field. Mapping to nil kills that
    -- footgun at the source instead of documenting a landmine for S5/S8.
    local ok, decoded = pcall(vim.json.decode, out.stdout or "", { luanil = { object = true } })
    -- vim.islist, NOT type()=="table": a top-level JSON OBJECT is also a table,
    -- and `{"error":"database locked"}` would otherwise pass the type check and
    -- present as ZERO ROWS -- the silent empty picker this module exists to
    -- prevent. `[]` is islist=true, so a legitimately empty fleet still
    -- succeeds with 0 rows (verified on 0.11.7).
    if not ok or not vim.islist(decoded) then
      settle(nil, {
        kind = "decode",
        stderr = out.stderr or "",
        message = string.format("%s returned unparseable output", argv[1]),
      })
      return
    end

    local warnings = out.stderr
    if warnings == nil or warnings == "" then warnings = nil end
    settle({ rows = decoded, warnings = warnings }, nil)
  end)

  if not spawned then
    settle(nil, {
      kind = "spawn",
      message = string.format("could not run %s: %s", argv[1], tostring(err_or_handle)),
    })
    return
  end
  handle = err_or_handle

  -- Bound the wait ourselves rather than leaning on vim.system's own `timeout`
  -- option, so the deadline still applies to an injected `system` in tests and
  -- so the error we report is ours rather than a signal number.
  local timeout_ms = opts.timeout_ms or M.DEFAULT_TIMEOUT_MS
  vim.defer_fn(function()
    if settled then return end
    -- Best-effort: don't leave the child running after we've stopped caring.
    pcall(function()
      if handle and handle.kill then handle:kill(15) end
    end)
    settle(nil, {
      kind = "timeout",
      message = string.format("%s did not respond within %dms", argv[1], timeout_ms),
    })
  end, timeout_ms)
end

return M
