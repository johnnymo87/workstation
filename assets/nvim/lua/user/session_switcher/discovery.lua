-- session_switcher/discovery.lua
--
-- Answers "where is session X actually attached, and is that attachment
-- ALIVE?" by asking every running nvim (via session_switcher/rpc.lua) and
-- joining the answers.
--
-- THE BUG THIS MODULE EXISTS TO PREVENT. `oc_auto_attach` sets
-- b:oc_session_id on the terminal buffer it creates. When the attach job dies
-- it renames that buffer "[FAILED] <sid>" and sets statuses[sid]="failed" --
-- but LEAVES b:oc_session_id in place (oc_auto_attach.lua:78-82). So any
-- discovery built on buffer presence reports a dead attach as attached, and
-- the picker jumps the user into a corpse instead of opening a fresh session.
-- Every "is it live?" decision here goes through `is_live`, never presence.

-- SCOPE LIMIT (hides live sessions, by design of the socket convention):
-- only nvims running DIRECTLY in a tmux pane are discoverable. Outside tmux, or
-- nested inside another nvim's :terminal, nvims execs plain `nvim` with no
-- --listen (pkgs/nvims/default.nix:53-54), so no /tmp/nvim-*.sock exists and no
-- peer can see those sessions at all. The picker will therefore offer a fresh
-- attach for a session that is already open in such an editor. Acceptable
-- today because oc-auto-attach only ever targets tmux panes, but S6 must not
-- present "not attached" as proof that nothing is attached.

local M = {}

M.DEFAULT_TIMEOUT_MS = 1000

--- Extract the tmux pane id from an nvims socket path.
---
--- `nvims` listens on /tmp/nvim-<pane>.sock where <pane> is $TMUX_PANE with the
--- leading '%' stripped (pkgs/nvims/default.nix:12,79), so this is the inverse.
--- Anything else gets nil. NOTE: outside tmux (or nested in another nvim)
--- nvims does NOT create a non-numeric socket -- it execs plain `nvim` and
--- makes no /tmp socket at all (pkgs/nvims/default.nix:53-54,94-98). So this
--- nil branch is purely defensive against unrelated junk in /tmp; do not
--- design around a "non-pane key" mechanism, it does not exist.
--- @param sock string|nil
--- @return string|nil  e.g. "%17"
function M.pane_of(sock)
  if type(sock) ~= "string" or sock == "" then return nil end
  local key = sock:match("^.*/nvim%-(%d+)%.sock$")
  if not key then return nil end
  return "%" .. key
end

--- Is this discovery hit an attachment a user can actually be sent to?
---
--- ONLY "running" counts. "failed"/"exited" are explicitly dead. "unknown" is
--- also treated as NOT live, which is a deliberate asymmetry: a false "dead"
--- costs the user a duplicate attach (annoying, recoverable), while a false
--- "live" teleports them into a dead terminal (the exact bug this guards). When
--- the evidence is absent, prefer the recoverable error.
--- @param hit table|nil
--- @return boolean
function M.is_live(hit)
  if type(hit) ~= "table" then return false end
  -- Buffer-level truth overrides sid-level memory: a re-attached session marks
  -- statuses[sid]="running" again, which would otherwise resurrect the ORIGINAL
  -- corpse buffer as live (see rpc.lua's job_dead note).
  if hit.job_dead == true then return false end
  return hit.attach_status == "running"
end

--- Collapse hits from many nvims into one entry per session id.
---
--- The plan specified plain "last-writer per sid". That is not safe on its own:
--- the same session can appear as a stale [FAILED] buffer in one nvim and a
--- healthy attach in another, and pure last-writer would let arrival order
--- decide -- silently reintroducing the corpse-jump that is_live exists to
--- prevent. A LIVE hit therefore always beats a dead one; last-writer breaks
--- ties only among hits of equal liveness.
--- @param results table[]|nil
--- @return table<string, table>
function M.dedupe(results)
  local out = {}
  if type(results) ~= "table" then return out end
  for _, hit in ipairs(results) do
    if type(hit) == "table" and type(hit.sid) == "string" and hit.sid ~= "" then
      local prev = out[hit.sid]
      if prev == nil then
        out[hit.sid] = hit
      else
        local live_hit, live_prev = M.is_live(hit), M.is_live(prev)
        if live_hit ~= live_prev then
          -- A LIVE hit always beats a dead one, whoever reported it.
          if live_hit then out[hit.sid] = hit end
        elseif prev.own and not hit.own then
          -- Equal liveness: keep home. Sending the user to another editor's
          -- pane when this one already has the session is strictly worse.
        else
          out[hit.sid] = hit
        end
      end
    end
  end
  return out
end

--- List the nvim sockets currently on this machine.
--- @return string[]
function M.sockets()
  return vim.fn.glob("/tmp/nvim-*.sock", true, true)
end

--- Locate every opencode session attached anywhere, asynchronously.
---
--- @param opts table|nil {
---   sockets?: string[],            -- default: M.sockets() minus our own
---   all_sockets?: fun(): string[], -- injection seam for the glob
---   own_sock?: string,             -- injection seam for vim.v.servername
---   own_snapshot?: fun(): string,  -- default: rpc.snapshot() IN-PROCESS
---   system?: function,             -- injection seam (default vim.system)
---   timeout_ms?: integer,          -- default 1000
--- }
--- @param cb fun(hits: table<string, table>)
function M.locate(opts, cb)
  opts = opts or {}
  vim.validate("cb", cb, "function")

  local timeout_ms = opts.timeout_ms or M.DEFAULT_TIMEOUT_MS
  local system = opts.system or vim.system
  local own_sock = opts.own_sock or vim.v.servername

  local socks = opts.sockets
  if socks == nil then
    socks = {}
    for _, s in ipairs((opts.all_sockets or M.sockets)()) do
      -- Never --remote-expr our OWN socket. Because locate() is async this
      -- would probably not hang (we would serve ourselves once idle), so the
      -- cost is a pointless subprocess and duplicate hits rather than the
      -- deadlock a SYNCHRONOUS caller would suffer -- but there is no reason
      -- to ask over a wire for what we can read in-process. Matching is string
      -- equality, which covers the whole real population: nvims listens on the
      -- literal /tmp/nvim-<key>.sock that the glob returns.
      if s ~= own_sock then table.insert(socks, s) end
    end
  end

  local results = {}

  -- Our own sessions, taken in-process. Done first so that even a total
  -- fan-out failure still yields the sessions in THIS editor.
  local own_fn = opts.own_snapshot or function()
    local ok, mod = pcall(require, "user.session_switcher.rpc")
    if not ok then return "[]" end
    return mod.snapshot()
  end
  local ok_own, own_json = pcall(own_fn)
  if ok_own then
    local ok_decode, decoded = pcall(vim.json.decode, own_json, { luanil = { object = true } })
    if ok_decode and vim.islist(decoded) then
      for _, hit in ipairs(decoded) do
        hit.sock = own_sock ~= "" and own_sock or nil
        hit.pane = M.pane_of(own_sock)
        hit.own = true -- lets dedupe keep home when liveness ties
        table.insert(results, hit)
      end
    end
  end

  local settled = false
  local pending = #socks
  local handles = {}

  local function finish()
    if settled then return end
    settled = true
    -- Abandon stragglers rather than letting one modal-prompt-blocked editor
    -- hold the picker hostage. Kill what is still outstanding so we do not
    -- leave orphaned `nvim --server` clients behind.
    -- Freeze the answer BEFORE killing anything. Killing a handle makes its
    -- on_exit fire as a fast event, which lands before the scheduled callback
    -- runs on the main loop; computing dedupe inside that closure would let a
    -- straggler we just killed edit the result we had already decided on, and
    -- whether it managed to would depend on scheduler interleaving.
    local final = M.dedupe(results)
    for _, h in ipairs(handles) do
      pcall(function() if h and h.kill then h:kill(15) end end)
    end
    vim.schedule(function() cb(final) end)
  end

  if pending == 0 then
    finish()
    return
  end

  for _, sock in ipairs(socks) do
    local argv = {
      "nvim", "--server", sock, "--remote-expr",
      'luaeval("require(\'user.session_switcher.rpc\').snapshot()")',
    }
    local spawned, handle = pcall(system, argv, { text = true }, function(out)
      -- Once the deadline has fired we have already answered; a late reply
      -- must not mutate results the picker is about to render. Without this,
      -- whether a straggler's rows appear depends on scheduler interleaving,
      -- because finish() kills handles and only THEN schedules the callback.
      if settled then return end
      -- A dead or stale socket is NORMAL -- /tmp accumulates them. Skip it
      -- silently; one corpse must not blank the whole picker.
      -- signal ~= 0 means the process was killed -- by our own deadline, most
      -- likely -- and vim.system reports code=0 for it (measured: code=0,
      -- signal=15, with TRUNCATED stdout). Trusting that is trusting a corpse.
      if out.code == 0 and (out.signal or 0) == 0 then
        local ok, decoded = pcall(vim.json.decode, out.stdout or "", { luanil = { object = true } })
        if ok and vim.islist(decoded) then
          for _, hit in ipairs(decoded) do
            hit.sock = sock
            hit.pane = M.pane_of(sock)
            table.insert(results, hit)
          end
        end
      end
      pending = pending - 1
      if pending <= 0 then finish() end
    end)
    if spawned then
      table.insert(handles, handle)
    else
      pending = pending - 1
    end
  end

  if pending <= 0 then
    finish()
    return
  end

  -- One deadline for the whole fan-out, not one per socket, so N stale sockets
  -- cost the same wall-clock as one.
  vim.defer_fn(finish, timeout_ms)
end

return M
