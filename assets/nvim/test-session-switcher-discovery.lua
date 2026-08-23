-- Unit tests for session_switcher/{discovery,rpc}.lua (S5).
-- Driven by assets/nvim/test-session-switcher.sh via `nvim --clean -l`.

local N = 0
local function check(cond, msg) N = N + 1; assert(cond, msg) end

local discovery = loadfile("assets/nvim/lua/user/session_switcher/discovery.lua")()
local rpc = loadfile("assets/nvim/lua/user/session_switcher/rpc.lua")()

-- ---------------------------------------------------------------- pane_of

check(discovery.pane_of("/tmp/nvim-17.sock") == "%17", "socket -> %pane")
check(discovery.pane_of("/tmp/nvim-395.sock") == "%395", "multi-digit pane")
-- Non-numeric keys are NOT pane ids. nvims falls back to a non-pane key when
-- it is not running under tmux, and inventing a "%foo" pane would make the
-- later `tmux display -t %foo` fail (or, worse, match something unrelated).
check(discovery.pane_of("/tmp/nvim-abc.sock") == nil, "non-numeric key -> nil")
check(discovery.pane_of("/tmp/other.sock") == nil, "unrelated path -> nil")
check(discovery.pane_of("/tmp/nvim-.sock") == nil, "empty key -> nil")
check(discovery.pane_of(nil) == nil, "nil -> nil")
check(discovery.pane_of("") == nil, "empty -> nil")
check(discovery.pane_of(42) == nil, "non-string -> nil")

-- ---------------------------------------------------------------- is_live
--
-- THE HEADLINE ACCEPTANCE TEST. A failed `opencode attach` leaves the buffer
-- in place with b:oc_session_id still set and only renames it "[FAILED] <sid>"
-- (oc_auto_attach.lua:78-82). So buffer-presence alone reports a DEAD attach as
-- attached, and the picker would jump the user into a corpse.

check(discovery.is_live({ attach_status = "running" }) == true, "running -> attached")
check(discovery.is_live({ attach_status = "failed" }) == false, "failed -> NOT attached")
check(discovery.is_live({ attach_status = "exited" }) == false, "exited -> NOT attached")
-- "unknown" is deliberately NOT live: see the rationale in discovery.lua.
check(discovery.is_live({ attach_status = "unknown" }) == false, "unknown -> NOT attached")
check(discovery.is_live({}) == false, "missing status -> NOT attached")
check(discovery.is_live(nil) == false, "nil hit -> NOT attached")
check(discovery.is_live({ attach_status = "RUNNING" }) == false, "status match is exact/case-sensitive")

-- ---------------------------------------------------------------- dedupe

local function hit(sid, status, pane) return { sid = sid, attach_status = status, pane = pane } end

-- Distinct sids are all preserved.
local d = discovery.dedupe({ hit("ses_a", "running", "%1"), hit("ses_b", "running", "%2") })
check(vim.tbl_count(d) == 2, "distinct sids preserved")

-- A LIVE hit beats a DEAD one regardless of arrival order. The plan specified
-- plain "last-writer per sid", which would let a stale [FAILED] buffer in one
-- nvim mask a healthy attach in another -- reintroducing the very bug is_live
-- exists to kill.
d = discovery.dedupe({ hit("ses_a", "running", "%1"), hit("ses_a", "failed", "%2") })
check(d["ses_a"].pane == "%1", "live hit beats a later dead one")
d = discovery.dedupe({ hit("ses_a", "failed", "%1"), hit("ses_a", "running", "%2") })
check(d["ses_a"].pane == "%2", "live hit beats an earlier dead one")

-- Among equally-live hits, last writer wins (the plan's rule).
d = discovery.dedupe({ hit("ses_a", "running", "%1"), hit("ses_a", "running", "%2") })
check(d["ses_a"].pane == "%2", "equally live -> last writer wins")
-- Among equally-dead hits, last writer wins, and the entry is still NOT live.
d = discovery.dedupe({ hit("ses_a", "failed", "%1"), hit("ses_a", "exited", "%2") })
check(d["ses_a"].pane == "%2", "equally dead -> last writer wins")
check(discovery.is_live(d["ses_a"]) == false, "deduped dead hit stays dead")

check(vim.tbl_count(discovery.dedupe({})) == 0, "empty -> empty")
check(vim.tbl_count(discovery.dedupe(nil)) == 0, "nil -> empty")
-- Junk entries must not become phantom sessions.
check(vim.tbl_count(discovery.dedupe({ { pane = "%1" }, hit("", "running") })) == 0, "sid-less entries dropped")

-- job_dead (buffer-level truth) overrides attach_status (sid-level memory).
check(discovery.is_live({ attach_status = "running", job_dead = true }) == false,
  "dead terminal job -> NOT live even when the sid says running")
check(discovery.is_live({ attach_status = "running", job_dead = false }) == true, "live job + running -> live")
check(discovery.is_live({ attach_status = "running" }) == true, "no job opinion -> fall back to status")

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
check(type(snap) == "string", "snapshot returns a STRING (remote-expr constraint)")

local decoded = vim.json.decode(snap)
check(vim.islist(decoded), "snapshot decodes to a list")
local by_sid = {}
for _, e in ipairs(decoded) do by_sid[e.sid] = e end
check(by_sid["ses_live"], "buffer with b:oc_session_id is reported")
check(by_sid["ses_dead"], "FAILED buffer is still REPORTED (so the picker can show it as dead)")
check(vim.tbl_count(by_sid) == 2, "buffers without b:oc_session_id are ignored")

-- The join that makes the whole step worth doing.
check(by_sid["ses_live"].attach_status == "running", "status joined onto the hit")
check(by_sid["ses_dead"].attach_status == "failed", "FAILED buffer carries failed status, not presence")
check(discovery.is_live(by_sid["ses_live"]) == true, "live buffer -> attached")
check(discovery.is_live(by_sid["ses_dead"]) == false, "FAILED buffer -> NOT attached (no jumping to corpses)")
check(type(by_sid["ses_live"].buffer) == "number", "hit carries buffer handle")

-- Empty JSON array, not an empty object: `{}` would not decode as a list.
vim.api.nvim_buf_delete(buf_live, { force = true })
vim.api.nvim_buf_delete(buf_dead, { force = true })
check(rpc.snapshot({ status = function() return "unknown" end }) == "[]", "no sessions -> '[]'")

-- RE-ATTACH RESURRECTION. statuses is keyed by SID, not buffer. Re-attaching a
-- session whose first attach died sets statuses[sid]="running" again while the
-- ORIGINAL corpse buffer still carries b:oc_session_id -- so a sid-only join
-- reports the corpse as running. Only per-buffer job liveness separates them.
local corpse = vim.api.nvim_create_buf(false, true)
vim.b[corpse].oc_session_id = "ses_re"
local fresh = vim.api.nvim_create_buf(false, true)
vim.b[fresh].oc_session_id = "ses_re"
local snap2 = vim.json.decode(rpc.snapshot({
  status = function() return "running" end,               -- sid-level: both "running"
  job_dead = function(b) return b == corpse end,          -- buffer-level: one is a corpse
}))
check(#snap2 == 2, "both buffers reported")
local live_count, dead_count = 0, 0
for _, h in ipairs(snap2) do
  if discovery.is_live(h) then live_count = live_count + 1 else dead_count = dead_count + 1 end
end
check(live_count == 1 and dead_count == 1, "re-attach: exactly one of the two is live")
local deduped = discovery.dedupe(snap2)
check(deduped["ses_re"].buffer == fresh, "dedupe keeps the LIVE buffer, not the corpse")
check(discovery.is_live(deduped["ses_re"]), "survivor is the live one")
vim.api.nvim_buf_delete(corpse, { force = true })
vim.api.nvim_buf_delete(fresh, { force = true })

-- ---------------------------------------------------------------- locate

local function collect(opts)
  local done, res = false, nil
  discovery.locate(opts, function(r) res, done = r, true end)
  vim.wait(2000, function() return done end)
  assert(done, "locate must ALWAYS call back")
  return res
end

local function fake_kill(payload)
  return function(_cmd, _opts, on_exit)
    vim.schedule(function() on_exit({ code = 0, signal = 15, stdout = payload, stderr = "" }) end)
    return { pid = 1, kill = function() end }
  end
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
check(res["ses_own"], "own snapshot included")
check(res["ses_own"].pane == nil or type(res["ses_own"].pane) == "string", "own hit shape sane")

-- Other sockets are queried, and their pane is derived from the socket path.
res = collect({
  sockets = { "/tmp/nvim-42.sock" },
  own_snapshot = function() return "[]" end,
  system = fake_reply(vim.json.encode({ { sid = "ses_other", attach_status = "running", buffer = 3 } })),
})
check(res["ses_other"], "other socket's session discovered")
check(res["ses_other"].pane == "%42", "pane derived from socket path")
check(res["ses_other"].sock == "/tmp/nvim-42.sock", "socket recorded")

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
check(res["ses_ok"], "healthy socket still yields results when a peer is dead")
check(vim.tbl_count(res) == 1, "dead socket contributes nothing")
check(res["ses_phantom"] == nil, "output of a NON-ZERO-exit call is not trusted")

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
check(#spawned_socks == 1, "exactly one peer queried, got " .. #spawned_socks)
check(spawned_socks[1] == "/tmp/nvim-101.sock", "peer queried")
check(not vim.tbl_contains(spawned_socks, "/tmp/nvim-100.sock"), "OWN socket never queried (self-deadlock)")
check(res["ses_own"], "own sessions still present via the in-process snapshot")

-- Garbage on stdout from a live-but-confused nvim must not raise.
res = collect({
  sockets = { "/tmp/nvim-3.sock" },
  own_snapshot = function() return "[]" end,
  system = fake_reply("not json at all"),
})
check(vim.tbl_count(res) == 0, "unparseable peer reply skipped, not fatal")

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
check(res["ses_own"], "straggler does not lose the results we already have")
check(elapsed < 1500, "straggler abandoned at the deadline, took " .. math.floor(elapsed) .. "ms")

-- The FAILED-attach end-to-end case: a peer reports a session whose attach
-- died. It must appear, and it must NOT be considered attached.
res = collect({
  sockets = { "/tmp/nvim-7.sock" },
  own_snapshot = function() return "[]" end,
  system = fake_reply(vim.json.encode({ { sid = "ses_corpse", attach_status = "failed", buffer = 9 } })),
})
check(res["ses_corpse"], "dead attach still discovered (the picker must be able to show it)")
check(discovery.is_live(res["ses_corpse"]) == false, "dead attach is NOT live -- no jumping to dead terminals")

-- A straggler KILLED by our own deadline reports code=0 with signal=15 and
-- possibly truncated stdout (measured). Trusting code alone would let a corpse
-- of our own making into the picker.
res = collect({
  sockets = { "/tmp/nvim-5.sock" },
  own_snapshot = function() return "[]" end,
  system = fake_kill(vim.json.encode({ { sid = "ses_killed", attach_status = "running" } })),
})
check(res["ses_killed"] == nil, "output of a SIGNALLED (killed) call is not trusted")

-- A peer replying AFTER the deadline must not mutate the answer already given.
local late_cb, calls, late_res = nil, 0, nil
discovery.locate({
  sockets = { "/tmp/nvim-6.sock" },
  timeout_ms = 80,
  own_snapshot = function() return own end,
  system = function(_c, _o, on_exit) late_cb = on_exit; return { pid = 1, kill = function() end } end,
}, function(r) calls = calls + 1; late_res = r end)
vim.wait(1500, function() return calls > 0 end)
check(calls == 1, "deadline answered once")
check(late_res["ses_own"] and late_res["ses_late"] == nil, "answer contains only what arrived in time")
late_cb({ code = 0, signal = 0, stdout = vim.json.encode({ { sid = "ses_late", attach_status = "running" } }), stderr = "" })
vim.wait(200)
check(calls == 1, "late reply does not re-invoke the callback, got " .. calls)
check(late_res["ses_late"] == nil, "late reply does not mutate the delivered result")

-- A kill-triggered reply must not edit an answer already decided. A real
-- handle:kill() makes on_exit fire as a FAST EVENT, i.e. before the scheduled
-- callback reaches the main loop -- so an implementation that deduped inside
-- the scheduled closure would let a straggler it just killed inject rows.
local killed_res, kcalls = nil, 0
discovery.locate({
  sockets = { "/tmp/nvim-11.sock" },
  timeout_ms = 80,
  own_snapshot = function() return own end,
  system = function(_c, _o, on_exit)
    return {
      pid = 1,
      kill = function()
        on_exit({ code = 0, signal = 0, stderr = "",
                  stdout = vim.json.encode({ { sid = "ses_ghost", attach_status = "running" } }) })
      end,
    }
  end,
}, function(r) kcalls = kcalls + 1; killed_res = r end)
vim.wait(1500, function() return kcalls > 0 end)
check(kcalls == 1, "kill-triggered reply does not double-answer")
check(killed_res["ses_own"], "own rows survive")
check(killed_res["ses_ghost"] == nil, "a straggler killed at the deadline cannot inject rows")

-- Equal liveness: our OWN editor wins over a peer. Jumping the user to another
-- nvim's pane when this one already holds the session is strictly worse.
res = collect({
  sockets = { "/tmp/nvim-8.sock" },
  own_snapshot = function() return vim.json.encode({ { sid = "ses_dup", attach_status = "running", buffer = 1 } }) end,
  system = fake_reply(vim.json.encode({ { sid = "ses_dup", attach_status = "running", buffer = 2 } })),
})
check(res["ses_dup"].own == true, "equally-live duplicate resolves to the OWN hit")
-- ...but a LIVE peer still beats our own DEAD hit.
res = collect({
  sockets = { "/tmp/nvim-8.sock" },
  own_snapshot = function() return vim.json.encode({ { sid = "ses_dup", attach_status = "failed", buffer = 1 } }) end,
  system = fake_reply(vim.json.encode({ { sid = "ses_dup", attach_status = "running", buffer = 2 } })),
})
check(res["ses_dup"].own ~= true and discovery.is_live(res["ses_dup"]), "live peer beats our own corpse")

print("LUA_TEST_OK " .. N)
