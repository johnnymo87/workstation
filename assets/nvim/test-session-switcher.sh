#!/usr/bin/env bash
#
# Unit tests for assets/nvim/lua/user/session_switcher/*.lua.
#
# WHY THIS FILE EXISTS RATHER THAN AN EXTENSION OF
# pkgs/oc-auto-attach/test-project-key.sh: that file is a genuine `nvim -l`
# harness and was the right *pattern* to copy, but it is wired into NOTHING.
# pkgs/oc-auto-attach/default.nix has no `doCheck`/`checkPhase`, and CI runs
# only `nix flake check`, so every assertion in it is inert. Adding S4's tests
# there would have produced, in flake.nix's own words about the opacity guard,
# "documentation with a shebang". This file is instead registered as a flake
# check (flake.nix -> checks.nvim-lua), so it runs on every PR.
#
# Run standalone:  bash assets/nvim/test-session-switcher.sh
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

if ! command -v nvim >/dev/null 2>&1; then
  # Inside a Nix build the derivation guarantees nvim, so its absence means the
  # check is mis-wired -- fail rather than skip. A check that silently passes
  # when its runner vanishes is the "guard nothing runs" failure this file was
  # created to avoid.
  if [ -n "${NIX_BUILD_TOP:-}" ]; then
    printf 'FAIL  nvim missing inside the Nix build (check is mis-wired)\n'
    exit 1
  fi
  printf 'SKIP  session_switcher lua tests (nvim not on PATH)\n'
  exit 0
fi

# nvim writes state/shada under $HOME; in a Nix sandbox HOME may be unset or
# read-only. Give it a scratch one so the tests do not depend on the caller's.
export HOME="${TMPDIR:-/tmp}/nvim-test-home-$$"
mkdir -p "$HOME"
trap 'rm -rf "$HOME"' EXIT

lua_file="$HOME/session_switcher_test.lua"
cat >"$lua_file" <<'LUA'
  local cli = loadfile("assets/nvim/lua/user/session_switcher/cli.lua")()

  local function collect(opts)
    local done, res, err = false, nil, nil
    cli.fetch(opts, function(r, e) res, err, done = r, e, true end)
    vim.wait(2000, function() return done end)
    assert(done, "callback was never invoked (fetch must ALWAYS call back)")
    return res, err
  end

  -- A fake `vim.system` so tests need no real binary. Mirrors the real
  -- contract: returns a handle, invokes on_exit with {code,stdout,stderr}.
  local function fake(code, stdout, stderr)
    return function(_cmd, _opts, on_exit)
      vim.schedule(function()
        on_exit({ code = code, signal = 0, stdout = stdout or "", stderr = stderr or "" })
      end)
      return { pid = 123, kill = function() end }
    end
  end

  -- Calls on_exit SYNCHRONOUSLY. The scheduled fake above cannot prove the
  -- module is async, because the fake's own vim.schedule supplies the
  -- asynchrony; mutation testing caught exactly that hole. Only a synchronous
  -- reply proves fetch() defers on its own.
  local function fake_sync(code, stdout, stderr)
    return function(_cmd, _opts, on_exit)
      on_exit({ code = code, signal = 0, stdout = stdout or "", stderr = stderr or "" })
      return { pid = 123, kill = function() end }
    end
  end

  -- Calls on_exit from a real libuv timer callback -- a genuine FAST EVENT
  -- CONTEXT, which is what vim.system actually does. Most of the vim API is
  -- illegal there (E5560), so this is the only fake that can prove the module
  -- re-enters the main loop before handing control to the picker.
  local function fake_fast(code, stdout, stderr)
    return function(_cmd, _opts, on_exit)
      local timer = vim.uv.new_timer()
      timer:start(10, 0, function()
        timer:close()
        on_exit({ code = code, signal = 0, stdout = stdout or "", stderr = stderr or "" })
      end)
      return { pid = 123, kill = function() end }
    end
  end

  local ROWS = '[{"id":"ses_a","activity":"nodata"},{"id":"ses_b","activity":"working"}]'

  -- 1. Happy path: rows parsed and returned.
  local res, err = collect({ system = fake(0, ROWS) })
  assert(err == nil, "happy path -> no error")
  assert(#res.rows == 2, "happy path -> 2 rows, got " .. tostring(res and #res.rows))

  -- 2. S3 CONTRACT: `activity = "nodata"` survives the caller untouched.
  --    A thin caller that normalised/dropped the 4th union member would
  --    silently undo S3's outage tripwire.
  assert(res.rows[1].activity == "nodata", "nodata activity passes through verbatim")

  -- 3. S3 CONTRACT: exit 0 + NON-EMPTY stderr is SUCCESS WITH WARNINGS,
  --    not a failure. The degraded-path warnings ARE the tripwire; treating
  --    them as an error would blank the picker on a partial outage, and
  --    discarding them would hide the outage entirely.
  res, err = collect({ system = fake(0, ROWS, "oc-session-list: no live writer is reporting\n") })
  assert(err == nil, "stderr with exit 0 is NOT an error")
  assert(#res.rows == 2, "stderr with exit 0 still yields rows")
  assert(res.warnings and res.warnings:find("no live writer"), "warnings surfaced to caller")

  -- 4. Non-zero exit -> error, NOT an empty row list.
  res, err = collect({ system = fake(1, "", "Error querying database\n") })
  assert(err ~= nil, "non-zero exit -> error surfaces")
  assert(err.kind == "exit", "non-zero exit -> kind=exit, got " .. tostring(err.kind))
  assert(err.code == 1, "non-zero exit -> code preserved")
  assert(err.stderr:find("Error querying"), "non-zero exit -> stderr preserved for the user")
  assert(res == nil, "error -> no result (must not masquerade as an empty picker)")

  -- 5. Unparseable stdout -> decode error, not a silent empty picker.
  res, err = collect({ system = fake(0, "this is not json") })
  assert(err ~= nil and err.kind == "decode", "bad json -> kind=decode, got " .. tostring(err and err.kind))
  assert(res == nil, "decode failure -> no result")

  -- 6. CLI MISSING: vim.system raises (ENOENT) rather than calling back.
  --    Must become an error through the callback, not an uncaught exception
  --    that kills the picker.
  res, err = collect({ system = function() error("ENOENT: no such file or directory") end })
  assert(err ~= nil and err.kind == "spawn", "missing binary -> kind=spawn, got " .. tostring(err and err.kind))
  assert(res == nil, "spawn failure -> no result")

  -- 7. TIMEOUT: a CLI that never calls back must still resolve, exactly once.
  local calls = 0
  local done = false
  cli.fetch({
    timeout_ms = 50,
    system = function() return { pid = 1, kill = function() end } end,
  }, function(_, e) calls = calls + 1; done = (e ~= nil) end)
  vim.wait(2000, function() return done end)
  assert(done, "hung CLI -> callback still fires (timeout)")
  vim.wait(300)
  assert(calls == 1, "timeout fires callback EXACTLY once, got " .. calls)

  -- 8. A late reply after a timeout must not double-invoke the callback.
  local late_on_exit
  calls = 0
  cli.fetch({
    timeout_ms = 50,
    system = function(_c, _o, on_exit) late_on_exit = on_exit; return { pid = 1, kill = function() end } end,
  }, function() calls = calls + 1 end)
  vim.wait(400, function() return calls > 0 end)
  late_on_exit({ code = 0, signal = 0, stdout = ROWS, stderr = "" })
  vim.wait(200)
  assert(calls == 1, "late reply after timeout does NOT re-invoke callback, got " .. calls)

  -- 9. ASYNC: fetch must return before the callback runs. A synchronous
  --    implementation is the documented deadlock hazard.
  local ran = false
  cli.fetch({ system = fake_sync(0, ROWS) }, function() ran = true end)
  assert(ran == false, "fetch is ASYNC (callback must not run before fetch returns)")
  vim.wait(500, function() return ran end)
  assert(ran, "sync-fake callback DOES eventually fire (not merely deferred into the void)")

  -- 10. The command actually invoked is oc-session-list --with-state.
  local got_cmd
  collect({ system = function(cmd, _o, on_exit)
    got_cmd = cmd
    vim.schedule(function() on_exit({ code = 0, signal = 0, stdout = ROWS, stderr = "" }) end)
    return { pid = 1, kill = function() end }
  end })
  assert(got_cmd[1] == "oc-session-list", "argv[1] is oc-session-list, got " .. tostring(got_cmd[1]))
  assert(vim.tbl_contains(got_cmd, "--with-state"), "argv contains --with-state")

  -- 11. Callback runs on the main loop, where vim API calls are legal.
  --     vim.system's on_exit fires in a fast event context; forgetting
  --     vim.schedule makes any API call in the picker raise E5560.
  local api_ok = false
  local done2 = false
  cli.fetch({ system = fake_fast(0, ROWS) }, function()
    api_ok = pcall(vim.api.nvim_get_current_buf)
    done2 = true
  end)
  vim.wait(2000, function() return done2 end)
  assert(api_ok, "callback runs on main loop (vim.schedule), API calls must be legal")

  -- 12. The other half of the founding distinction: a legitimately EMPTY
  --     fleet is a SUCCESS with zero rows, not an error. Without this, an
  --     over-eager array check could blank every healthy-but-empty fleet and
  --     nothing would notice.
  res, err = collect({ system = fake(0, "[]") })
  assert(err == nil, "empty array -> success, not error")
  assert(#res.rows == 0, "empty array -> zero rows")

  -- 13. A top-level JSON OBJECT is NOT a row list. It is also a Lua table, so
  --     a type() check would accept it and render as an empty picker.
  res, err = collect({ system = fake(0, '{"error":"database locked"}') })
  assert(err ~= nil and err.kind == "decode", "json object -> decode error, got " .. tostring(err and err.kind))
  assert(res == nil, "json object -> no result (never a silent empty picker)")

  -- 14. JSON null maps to Lua nil, not the TRUTHY vim.NIL userdata.
  res, err = collect({ system = fake(0, '[{"id":"a","activity":null}]') })
  assert(err == nil, "null field -> still success")
  assert(res.rows[1].activity == nil, "json null -> Lua nil (vim.NIL is truthy and would misroute consumers)")

  print("LUA_TEST_OK")
LUA

lua_out="$(nvim --clean -l "$lua_file" 2>&1 || true)"

case "$lua_out" in
  *LUA_TEST_OK*) printf 'PASS  session_switcher.cli unit tests (14 assertions via nvim -l)\n' ;;
  *) printf 'FAIL  session_switcher.cli unit tests\n        out: %s\n' "$lua_out"; exit 1 ;;
esac

printf 'all session_switcher lua tests passed\n'
