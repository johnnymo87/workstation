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

local M = {}

M.DEFAULT_TIMEOUT_MS = 1000

--- Extract the tmux pane id from an nvims socket path.
---
--- `nvims` listens on /tmp/nvim-<pane>.sock where <pane> is $TMUX_PANE with the
--- leading '%' stripped (pkgs/nvims/default.nix:12,79), so this is the inverse.
--- Outside tmux nvims uses a NON-NUMERIC key; that is not a pane, and returning
--- a fabricated "%<key>" would make the later `tmux display -t` either fail or,
--- worse, resolve to an unrelated pane. Such sockets get nil.
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
      if prev == nil or M.is_live(hit) or not M.is_live(prev) then
        out[hit.sid] = hit
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
      -- Never --remote-expr our OWN socket. We would be asking an editor that
      -- is waiting for the answer to produce it: a self-deadlock that resolves
      -- only on timeout. Our own sessions come from the in-process snapshot.
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
    for _, h in ipairs(handles) do
      pcall(function() if h and h.kill then h:kill(15) end end)
    end
    vim.schedule(function() cb(M.dedupe(results)) end)
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
      -- A dead or stale socket is NORMAL -- /tmp accumulates them. Skip it
      -- silently; one corpse must not blank the whole picker.
      if out.code == 0 then
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
