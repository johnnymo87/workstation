-- Unit tests for session_switcher/{discovery,rpc}.lua (S5).
-- Driven by assets/nvim/test-session-switcher.sh via `nvim --clean -l`.

local discovery = loadfile("assets/nvim/lua/user/session_switcher/discovery.lua")()
local rpc = loadfile("assets/nvim/lua/user/session_switcher/rpc.lua")()

-- ---------------------------------------------------------------- pane_of

assert(discovery.pane_of("/tmp/nvim-17.sock") == "%17", "socket -> %pane")
assert(discovery.pane_of("/tmp/nvim-395.sock") == "%395", "multi-digit pane")
-- Non-numeric keys are NOT pane ids. nvims falls back to a non-pane key when
-- it is not running under tmux, and inventing a "%foo" pane would make the
-- later `tmux display -t %foo` fail (or, worse, match something unrelated).
assert(discovery.pane_of("/tmp/nvim-abc.sock") == nil, "non-numeric key -> nil")
assert(discovery.pane_of("/tmp/other.sock") == nil, "unrelated path -> nil")
assert(discovery.pane_of("/tmp/nvim-.sock") == nil, "empty key -> nil")
assert(discovery.pane_of(nil) == nil, "nil -> nil")
assert(discovery.pane_of("") == nil, "empty -> nil")
assert(discovery.pane_of(42) == nil, "non-string -> nil")

-- ---------------------------------------------------------------- is_live
--
-- THE HEADLINE ACCEPTANCE TEST. A failed `opencode attach` leaves the buffer
-- in place with b:oc_session_id still set and only renames it "[FAILED] <sid>"
-- (oc_auto_attach.lua:78-82). So buffer-presence alone reports a DEAD attach as
-- attached, and the picker would jump the user into a corpse.

assert(discovery.is_live({ attach_status = "running" }) == true, "running -> attached")
assert(discovery.is_live({ attach_status = "failed" }) == false, "failed -> NOT attached")
assert(discovery.is_live({ attach_status = "exited" }) == false, "exited -> NOT attached")
-- "unknown" is deliberately NOT live: see the rationale in discovery.lua.
assert(discovery.is_live({ attach_status = "unknown" }) == false, "unknown -> NOT attached")
assert(discovery.is_live({}) == false, "missing status -> NOT attached")
assert(discovery.is_live(nil) == false, "nil hit -> NOT attached")
assert(discovery.is_live({ attach_status = "RUNNING" }) == false, "status match is exact/case-sensitive")

-- ---------------------------------------------------------------- dedupe

local function hit(sid, status, pane) return { sid = sid, attach_status = status, pane = pane } end

-- Distinct sids are all preserved.
local d = discovery.dedupe({ hit("ses_a", "running", "%1"), hit("ses_b", "running", "%2") })
assert(vim.tbl_count(d) == 2, "distinct sids preserved")

-- A LIVE hit beats a DEAD one regardless of arrival order. The plan specified
-- plain "last-writer per sid", which would let a stale [FAILED] buffer in one
-- nvim mask a healthy attach in another -- reintroducing the very bug is_live
-- exists to kill.
d = discovery.dedupe({ hit("ses_a", "running", "%1"), hit("ses_a", "failed", "%2") })
assert(d["ses_a"].pane == "%1", "live hit beats a later dead one")
d = discovery.dedupe({ hit("ses_a", "failed", "%1"), hit("ses_a", "running", "%2") })
assert(d["ses_a"].pane == "%2", "live hit beats an earlier dead one")

-- Among equally-live hits, last writer wins (the plan's rule).
d = discovery.dedupe({ hit("ses_a", "running", "%1"), hit("ses_a", "running", "%2") })
assert(d["ses_a"].pane == "%2", "equally live -> last writer wins")
-- Among equally-dead hits, last writer wins, and the entry is still NOT live.
d = discovery.dedupe({ hit("ses_a", "failed", "%1"), hit("ses_a", "exited", "%2") })
assert(d["ses_a"].pane == "%2", "equally dead -> last writer wins")
assert(discovery.is_live(d["ses_a"]) == false, "deduped dead hit stays dead")

assert(vim.tbl_count(discovery.dedupe({})) == 0, "empty -> empty")
assert(vim.tbl_count(discovery.dedupe(nil)) == 0, "nil -> empty")
-- Junk entries must not become phantom sessions.
assert(vim.tbl_count(discovery.dedupe({ { pane = "%1" }, hit("", "running") })) == 0, "sid-less entries dropped")

-- ---------------------------------------------------------------- rpc.snapshot

-- snapshot() is called via --remote-expr, which can only carry simple values,
-- so it MUST return a JSON string rather than a table.
local buf_live = vim.api.nvim_create_buf(false, true)
vim.b[buf_live].oc_session_id = "ses_live"
local buf_dead = vim.api.nvim_create_buf(false, true)
vim.b[buf_dead].oc_session_id = "ses_dead"
vim.api.nvim_create_buf(false, true) -- no session id: must be ignored

local fake_status = { ses_live = "running", ses_dead = "failed" }
local snap = rpc.snapshot({ status = function(sid) return fake_status[sid] or "unknown" end })
assert(type(snap) == "string", "snapshot returns a STRING (remote-expr constraint)")

local decoded = vim.json.decode(snap)
assert(vim.islist(decoded), "snapshot decodes to a list")
local by_sid = {}
for _, e in ipairs(decoded) do by_sid[e.sid] = e end
assert(by_sid["ses_live"], "buffer with b:oc_session_id is reported")
assert(by_sid["ses_dead"], "FAILED buffer is still REPORTED (so the picker can show it as dead)")
assert(vim.tbl_count(by_sid) == 2, "buffers without b:oc_session_id are ignored")

-- The join that makes the whole step worth doing.
assert(by_sid["ses_live"].attach_status == "running", "status joined onto the hit")
assert(by_sid["ses_dead"].attach_status == "failed", "FAILED buffer carries failed status, not presence")
assert(discovery.is_live(by_sid["ses_live"]) == true, "live buffer -> attached")
assert(discovery.is_live(by_sid["ses_dead"]) == false, "FAILED buffer -> NOT attached (no jumping to corpses)")
assert(type(by_sid["ses_live"].buffer) == "number", "hit carries buffer handle")

-- Empty JSON array, not an empty object: `{}` would not decode as a list.
vim.api.nvim_buf_delete(buf_live, { force = true })
vim.api.nvim_buf_delete(buf_dead, { force = true })
assert(rpc.snapshot({ status = function() return "unknown" end }) == "[]", "no sessions -> '[]'")

-- ---------------------------------------------------------------- locate

local function collect(opts)
  local done, res = false, nil
  discovery.locate(opts, function(r) res, done = r, true end)
  vim.wait(2000, function() return done end)
  assert(done, "locate must ALWAYS call back")
  return res
end

local function fake_reply(payload)
  return function(_cmd, _opts, on_exit)
    vim.schedule(function() on_exit({ code = 0, signal = 0, stdout = payload, stderr = "" }) end)
    return { pid = 1, kill = function() end }
  end
end

-- Own snapshot is taken IN-PROCESS. Never via --remote-expr to our own socket:
-- that is the deadlock (we would be waiting on ourselves).
local own = vim.json.encode({ { sid = "ses_own", attach_status = "running", buffer = 1 } })
local res = collect({
  sockets = {},
  own_snapshot = function() return own end,
  system = function() error("must not spawn for the OWN socket") end,
})
assert(res["ses_own"], "own snapshot included")
assert(res["ses_own"].pane == nil or type(res["ses_own"].pane) == "string", "own hit shape sane")

-- Other sockets are queried, and their pane is derived from the socket path.
res = collect({
  sockets = { "/tmp/nvim-42.sock" },
  own_snapshot = function() return "[]" end,
  system = fake_reply(vim.json.encode({ { sid = "ses_other", attach_status = "running", buffer = 3 } })),
})
assert(res["ses_other"], "other socket's session discovered")
assert(res["ses_other"].pane == "%42", "pane derived from socket path")
assert(res["ses_other"].sock == "/tmp/nvim-42.sock", "socket recorded")

-- A dead/garbage socket must be SKIPPED, not fatal: one stale socket in /tmp
-- must not blank the whole picker.
res = collect({
  sockets = { "/tmp/nvim-1.sock", "/tmp/nvim-2.sock" },
  own_snapshot = function() return "[]" end,
  system = function(cmd, _o, on_exit)
    if cmd[3] == "/tmp/nvim-1.sock" then
      -- NOTE the payload: a FAILED call whose stdout nevertheless parses as a
      -- valid hit. Pairing exit!=0 with empty stdout would let an
      -- implementation that ignores the exit code pass this test by accident
      -- (mutation testing caught exactly that). Output from a failed call must
      -- not be trusted.
      vim.schedule(function() on_exit({
        code = 1, signal = 0, stderr = "connection refused",
        stdout = vim.json.encode({ { sid = "ses_phantom", attach_status = "running" } }),
      }) end)
    else
      vim.schedule(function()
        on_exit({ code = 0, signal = 0, stdout = vim.json.encode({ { sid = "ses_ok", attach_status = "running" } }), stderr = "" })
      end)
    end
    return { pid = 1, kill = function() end }
  end,
})
assert(res["ses_ok"], "healthy socket still yields results when a peer is dead")
assert(vim.tbl_count(res) == 1, "dead socket contributes nothing")
assert(res["ses_phantom"] == nil, "output of a NON-ZERO-exit call is not trusted")

-- The own socket is excluded from the fan-out. Asking our own editor over
-- --remote-expr would block on the very loop that must produce the answer:
-- a self-deadlock resolving only at the timeout.
local spawned_socks = {}
res = collect({
  own_sock = "/tmp/nvim-100.sock",
  all_sockets = function() return { "/tmp/nvim-100.sock", "/tmp/nvim-101.sock" } end,
  own_snapshot = function() return own end,
  system = function(cmd, _o, on_exit)
    table.insert(spawned_socks, cmd[3])
    vim.schedule(function() on_exit({ code = 0, signal = 0, stdout = "[]", stderr = "" }) end)
    return { pid = 1, kill = function() end }
  end,
})
assert(#spawned_socks == 1, "exactly one peer queried, got " .. #spawned_socks)
assert(spawned_socks[1] == "/tmp/nvim-101.sock", "peer queried")
assert(not vim.tbl_contains(spawned_socks, "/tmp/nvim-100.sock"), "OWN socket never queried (self-deadlock)")
assert(res["ses_own"], "own sessions still present via the in-process snapshot")

-- Garbage on stdout from a live-but-confused nvim must not raise.
res = collect({
  sockets = { "/tmp/nvim-3.sock" },
  own_snapshot = function() return "[]" end,
  system = fake_reply("not json at all"),
})
assert(vim.tbl_count(res) == 0, "unparseable peer reply skipped, not fatal")

-- A STRAGGLER must not stall the picker: a socket that never replies is
-- abandoned at the deadline. This is why the fan-out is async.
local t0 = vim.uv.hrtime()
res = collect({
  sockets = { "/tmp/nvim-9.sock" },
  timeout_ms = 150,
  own_snapshot = function() return own end,
  system = function() return { pid = 1, kill = function() end } end,
})
local elapsed = (vim.uv.hrtime() - t0) / 1e6
assert(res["ses_own"], "straggler does not lose the results we already have")
assert(elapsed < 1500, "straggler abandoned at the deadline, took " .. math.floor(elapsed) .. "ms")

-- The FAILED-attach end-to-end case: a peer reports a session whose attach
-- died. It must appear, and it must NOT be considered attached.
res = collect({
  sockets = { "/tmp/nvim-7.sock" },
  own_snapshot = function() return "[]" end,
  system = fake_reply(vim.json.encode({ { sid = "ses_corpse", attach_status = "failed", buffer = 9 } })),
})
assert(res["ses_corpse"], "dead attach still discovered (the picker must be able to show it)")
assert(discovery.is_live(res["ses_corpse"]) == false, "dead attach is NOT live -- no jumping to dead terminals")

print("LUA_TEST_OK")
