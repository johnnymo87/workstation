#!/usr/bin/env bash
# bazel scope shim: behavioural guard (bead workstation-mqp3, epic workstation-rdsq).
#
# WHAT THE SHIM IS FOR. The agent's bash tool spawns `bazel` as a CHILD of
# `opencode serve`, so every bazel process -- the server JVM and its whole fleet
# of sandboxed actions -- is charged to opencode-serve@<port>.service's cgroup
# and counts against its MemoryMax=14G. Because that unit is OOMPolicy=stop, ANY
# OOM kill in the cgroup restarts the WHOLE serve and destroys every session on
# it. opencode-serve@4098 died that way four times in ~6h on 2026-08-03/04,
# producing 960 HTTP 502s at the front door.
#
# The shim re-execs bazel inside `systemd-run --user --scope`, which lands it in
# /user.slice/.../user@1000.service/bazel.slice/run-pNNN.scope -- a different
# cgroup subtree entirely from /system.slice/system-opencode\x2dserve.slice/...
# A memcg OOM there can no longer reach the serve.
#
# WHY THESE ASSERTIONS. Each one below corresponds to a way the shim can look
# installed and working while silently doing nothing:
#
#   * XDG_RUNTIME_DIR is UNSET in the serve's bash environment (verified). Without
#     the shim exporting it, `systemd-run --user` fails with "Failed to connect to
#     user scope bus", EVERY invocation takes the degrade path, and the bug is
#     fully back -- invisibly. This is the highest-value assertion in the file.
#   * The degrade path must shut the server down afterwards. A raw bazel run forks
#     a server JVM INTO THE SERVE CGROUP where it then lives for max_idle_secs
#     (900s), so every LATER build -- even ones whose clients scoped correctly --
#     charges its memory to the serve, because build actions are spawned by the
#     server, not the client. One degraded invocation would otherwise poison the
#     workspace until the server idles out.
#   * The scope needs an EXPLICIT MemoryMax. The JVM is container-aware, so an
#     uncapped scope sizes its heap against the host's 62G rather than the cgroup
#     -- strictly worse than the status quo.
#   * OOMPolicy must be set EXPLICITLY. systemd 258 defaults a scope to
#     OOMPolicy=stop (measured -- do not trust the "scopes default to continue"
#     folklore), which tears down the whole scope, server JVM included, when a
#     single action is OOM-killed.
#   * Both helper binaries must be absolute /nix/store paths: `bazel` calling
#     `bazel` off PATH would recurse into the shim forever.
#
# `nix flake check` runs this (checks.<system>.bazel-scope-shim in flake.nix).
# It is BEHAVIOURAL, not a grep over the source: it runs the real built shim with
# stubbed systemd-run/bazelisk and asserts on the argv the shim actually produces.

set -euo pipefail

SHIM="${BAZEL_SCOPE_SHIM_BIN:?BAZEL_SCOPE_SHIM_BIN must point at the built shim}"

fail=0
pass=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=1; }

check() { # check <desc> <expected-substring> <haystack>
  if [[ "$3" == *"$2"* ]]; then ok "$1"; else
    bad "$1"
    printf '       expected to find: %s\n' "$2"
    printf '       in: %s\n' "$3"
  fi
}

refute() { # refute <desc> <forbidden-substring> <haystack>
  if [[ "$3" != *"$2"* ]]; then ok "$1"; else
    bad "$1"
    printf '       expected NOT to find: %s\n' "$2"
    printf '       in: %s\n' "$3"
  fi
}

# ---------------------------------------------------------------------------
# Static: the shipped script must reach its helpers by absolute store path.
# ---------------------------------------------------------------------------
echo "== static: no-recursion invariant =="

real_line=$(grep -m1 '^REAL_BAZEL=' "$SHIM" || true)
sdrun_line=$(grep -m1 '^SYSTEMD_RUN=' "$SHIM" || true)

if [[ "$real_line" =~ ^REAL_BAZEL=\"?/nix/store/ ]]; then
  ok "REAL_BAZEL is an absolute /nix/store path (cannot recurse into the shim)"
else
  bad "REAL_BAZEL must be an absolute /nix/store path, got: ${real_line:-<missing>}"
fi

for v in PROC_ROOT CGROUP_ROOT; do
  line=$(grep -m1 "^$v=" "$SHIM" || true)
  if [[ "$line" =~ ^"$v"=\"?/ ]]; then
    ok "$v is an absolute path in the shipped script"
  else
    bad "$v must be an absolute path, got: ${line:-<missing>}"
  fi
done

for v in FLOCK SLEEP MKDIR SYSTEMD_CAT; do
  line=$(grep -m1 "^$v=" "$SHIM" || true)
  if [[ "$line" =~ ^"$v"=\"?/nix/store/ ]]; then
    ok "$v is an absolute /nix/store path (the shim's PATH is the caller's)"
  else
    bad "$v must be an absolute /nix/store path, got: ${line:-<missing>}"
  fi
done

if [[ "$sdrun_line" =~ ^SYSTEMD_RUN=\"?/nix/store/ ]]; then
  ok "SYSTEMD_RUN is an absolute /nix/store path"
else
  bad "SYSTEMD_RUN must be an absolute /nix/store path, got: ${sdrun_line:-<missing>}"
fi

# ---------------------------------------------------------------------------
# Harness: a copy of the real shim with its two helper paths swapped for stubs.
# We rewrite rather than add a test-only env backdoor, so the SHIPPED script has
# no branch that a caller could use to escape the scope.
# ---------------------------------------------------------------------------
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

BASH_BIN=$(command -v bash)

# Stub bazel. Besides its argv it records:
#   * any open fd pointing at a gate slot file -- the slot must NOT leak into the
#     client, or the server JVM it forks could hold the slot for max_idle_secs;
#   * a line on STDERR, so a shim that silently swallows bazel's stderr fails;
#   * START/END epoch-ns stamps around an optional sleep, so concurrency tests
#     can check whether two builds overlapped.
cat > "$WORK/stub-bazel" <<STUB
#!$BASH_BIN
printf '%s\\n' "BAZEL_ARGV: \$*" >> "\$STUB_LOG"
for f in /proc/\$\$/fd/*; do
  t=\$(readlink "\$f" 2>/dev/null || true)
  case "\$t" in *bazel-gate*slot*) printf '%s\\n' "INHERITED_SLOT_FD: \$t" >> "\$STUB_LOG" ;; esac
done
echo "STUB_BAZEL_STDERR" >&2
if [[ -n "\${STUB_BAZEL_SLEEP:-}" ]]; then
  printf 'START %s\\n' "\$(date +%s%N)" >> "\$STUB_LOG"
  sleep "\$STUB_BAZEL_SLEEP"
  printf 'END %s\\n' "\$(date +%s%N)" >> "\$STUB_LOG"
fi
exit "\${STUB_BAZEL_RC:-0}"
STUB

# Stub systemd-cat: the gate's journal events land in STUB_LOG instead.
cat > "$WORK/stub-systemd-cat" <<STUB
#!$BASH_BIN
while IFS= read -r l; do printf 'JOURNAL: %s\\n' "\$l" >> "\$STUB_LOG"; done
STUB

# Stub systemd-run: records argv, then actually runs the command after `--` so
# that exit-code propagation through the scope is genuinely exercised. Fails the
# canary (`-- true`) on demand to drive the degrade path.
cat > "$WORK/stub-systemd-run" <<STUB
#!$BASH_BIN
cmd=(); seen=0
for a in "\$@"; do
  if [[ "\$seen" == 1 ]]; then cmd+=("\$a"); elif [[ "\$a" == "--" ]]; then seen=1; fi
done
if [[ "\${cmd[0]:-}" == "true" ]]; then
  printf '%s\\n' "CANARY: \$*" >> "\$STUB_LOG"
  exit "\${STUB_CANARY_RC:-0}"
fi
printf '%s\\n' "SDRUN_ARGV: \$*" >> "\$STUB_LOG"
printf '%s\\n' "SDRUN_XDG: \${XDG_RUNTIME_DIR:-<unset>}" >> "\$STUB_LOG"
exec "\${cmd[@]}"
STUB

chmod +x "$WORK/stub-bazel" "$WORK/stub-systemd-run" "$WORK/stub-systemd-cat"

# Fixture tree for the degrade path's "is a bazel server resident in my own
# cgroup?" probe. Two variants: one where the cgroup holds a bazel SERVER
# (argv[0] is rewritten to `bazel(<name>)`) and one where it holds something else.
mkfake() { # mkfake <dir> <argv0>
  mkdir -p "$1/proc/self" "$1/proc/999" "$1/cg/fake"
  printf '0::/fake\n' > "$1/proc/self/cgroup"
  printf '999\n'      > "$1/cg/fake/cgroup.procs"
  printf '%s\0--flag\0' "$2" > "$1/proc/999/cmdline"
}
mkfake "$WORK/withserver" 'bazel(demo)'
mkfake "$WORK/noserver"   'node'

sed -e "s|^REAL_BAZEL=.*|REAL_BAZEL=\"$WORK/stub-bazel\"|" \
    -e "s|^SYSTEMD_RUN=.*|SYSTEMD_RUN=\"$WORK/stub-systemd-run\"|" \
    -e "s|^PROC_ROOT=.*|PROC_ROOT=\"$WORK/withserver/proc\"|" \
    -e "s|^CGROUP_ROOT=.*|CGROUP_ROOT=\"$WORK/withserver/cg\"|" \
    -e "s|^SYSTEMD_CAT=.*|SYSTEMD_CAT=\"$WORK/stub-systemd-cat\"|" \
    -e "s|^GATE_DIR=.*|GATE_DIR=\"$WORK/bazel-gate\"|" \
    -e "s|^GATE_MAX_WAIT_SECS=.*|GATE_MAX_WAIT_SECS=\"\${TEST_GATE_MAX_WAIT:-30}\"|" \
    -e "s|^GATE_POLL_SECS=.*|GATE_POLL_SECS=\"1\"|" \
    -e "s|^GATE_SLOTS=.*|GATE_SLOTS=\"\${TEST_GATE_SLOTS:-1}\"|" \
    "$SHIM" > "$WORK/shim"
chmod +x "$WORK/shim"

# Same shim, but running INSIDE a bazel.slice scope -- i.e. spawned by a build.
mkdir -p "$WORK/inslice/proc/self"
printf '0::/user.slice/user-1000.slice/user@1000.service/bazel.slice/run-p1.scope\n' > "$WORK/inslice/proc/self/cgroup"
sed -e "s|^PROC_ROOT=.*|PROC_ROOT=\"$WORK/inslice/proc\"|" "$WORK/shim" > "$WORK/shim-inslice"
chmod +x "$WORK/shim-inslice"

# Same shim, but its cgroup holds no bazel server.
sed -e "s|^PROC_ROOT=.*|PROC_ROOT=\"$WORK/noserver/proc\"|" \
    -e "s|^CGROUP_ROOT=.*|CGROUP_ROOT=\"$WORK/noserver/cg\"|" \
    "$WORK/shim" > "$WORK/shim-noserver"
chmod +x "$WORK/shim-noserver"

grep -q "$WORK/stub-bazel" "$WORK/shim" || { echo "FAIL: harness did not rewrite REAL_BAZEL"; exit 1; }
grep -q "$WORK/stub-systemd-run" "$WORK/shim" || { echo "FAIL: harness did not rewrite SYSTEMD_RUN"; exit 1; }
for v in SYSTEMD_CAT GATE_DIR GATE_MAX_WAIT_SECS GATE_POLL_SECS GATE_SLOTS; do
  [[ "$(grep -m1 "^$v=" "$SHIM")" != "$(grep -m1 "^$v=" "$WORK/shim")" ]] \
    || { echo "FAIL: harness did not rewrite $v"; exit 1; }
done

run_shim() { # run_shim <logfile> [env assignments via caller] -- args...
  STUB_LOG="$1"; shift
  : > "$STUB_LOG"
  export STUB_LOG
  set +e
  env -u XDG_RUNTIME_DIR \
      STUB_LOG="$STUB_LOG" \
      STUB_CANARY_RC="${CANARY_RC:-0}" \
      STUB_BAZEL_RC="${BAZEL_RC:-0}" \
      "$WORK/shim" "$@" > "$STUB_LOG.out" 2> "$STUB_LOG.err"
  RC=$?
  set -e
}

# ---------------------------------------------------------------------------
echo "== happy path: build is re-exec'd into a capped scope =="
# ---------------------------------------------------------------------------
run_shim "$WORK/log1" build //foo:bar --config=remote
argv=$(grep '^SDRUN_ARGV:' "$WORK/log1" || true)

check "runs under a user scope"                 "--user"            "$argv"
check "creates a scope (not a service)"         "--scope"           "$argv"
check "scope is GC'd when it empties"           "--collect"         "$argv"
check "lands in the aggregate-capped slice"     "--slice=bazel"     "$argv"
check "scope carries an EXPLICIT MemoryMax"     "-p MemoryMax="     "$argv"
check "scope sets OOMPolicy explicitly"         "-p OOMPolicy="     "$argv"
# Without this, systemd EXPANDS the argv it is handed and silently corrupts any
# bazel argument containing `$$` or `${...}`. Measured before the fix:
#   systemd-run --user --scope -q -- printf '%s\n' 'both=$$'   ->   both=$
check "systemd env expansion is disabled"       "--expand-environment=no" "$argv"
check "invokes the real bazel by abs path"      "$WORK/stub-bazel"  "$argv"
check "user args pass through verbatim"         "build //foo:bar --config=remote" "$argv"

bargv=$(grep '^BAZEL_ARGV:' "$WORK/log1" || true)
check "real bazel receives the user's args"     "build //foo:bar --config=remote" "$bargv"
refute "no bare 'bazel' on the systemd-run cmdline" " bazel build" "$argv"

# XDG_RUNTIME_DIR: the shim ran with it explicitly UNSET (env -u in run_shim),
# reproducing the serve's real environment. The stub records what systemd-run
# actually saw. If the shim failed to export it, the REAL systemd-run would fail
# with "Failed to connect to user scope bus" and every build would silently take
# the degrade path -- the single highest-value assertion in this file.
xdg=$(grep '^SDRUN_XDG:' "$WORK/log1" || true)
# Positive form on purpose: `refute ... "<unset>"` would pass vacuously if the
# log line were missing entirely, which is exactly how this assertion
# false-passed the first time it ran.
check "shim exports XDG_RUNTIME_DIR before calling systemd-run" "SDRUN_XDG: /run/user/" "$xdg"

# A build is GATED, so it went through the slot machinery, a watcher fork and
# a dozen fd redirections before reaching bazel. Any of them
# could swallow bazel's output without failing a single argv assertion above.
check  "bazel's stderr reaches the caller"       "STUB_BAZEL_STDERR" "$(cat "$WORK/log1.err")"
check  "a build takes a gate slot"               "JOURNAL: acquired slot=0 waited=0 cmd=build" "$(cat "$WORK/log1")"
refute "the slot fd is NOT inherited by bazel"   "INHERITED_SLOT_FD" "$(cat "$WORK/log1")"

# ---------------------------------------------------------------------------
echo "== exit codes propagate through the scope =="
# ---------------------------------------------------------------------------
BAZEL_RC=37 run_shim "$WORK/log2" build //x
[[ "$RC" == 37 ]] && ok "bazel's exit code survives the scope wrapper" \
                  || bad "expected exit 37 through the scope, got $RC"

# ---------------------------------------------------------------------------
echo "== loop guard: a nested bazel does not re-wrap =="
# ---------------------------------------------------------------------------
: > "$WORK/log3"
STUB_LOG="$WORK/log3" BAZEL_SCOPE_SHIM_ACTIVE=1 STUB_CANARY_RC=0 STUB_BAZEL_RC=0 \
  "$WORK/shim" build //y > /dev/null 2>&1 || true
refute "nested invocation does not call systemd-run" "SDRUN_ARGV" "$(cat "$WORK/log3")"
check  "nested invocation still runs bazel"          "build //y"  "$(cat "$WORK/log3")"

# ---------------------------------------------------------------------------
echo "== degrade path: systemd-run unusable =="
# ---------------------------------------------------------------------------
# Canary fails (e.g. a full /run/user/1000 tmpfs, which surfaces as a misleading
# "not found"). The build must still RUN -- a degraded build beats no build --
# but it must warn, and it must shut the server down afterwards so the JVM it
# just forked into the serve cgroup does not linger there for 900s.
CANARY_RC=1 run_shim "$WORK/log4" build //z
log4=$(cat "$WORK/log4")

refute "degrade does not run under systemd-run" "SDRUN_ARGV" "$log4"
check  "degrade still runs the build"           "build //z"  "$log4"
check  "degrade shuts down the server it left in this cgroup" "shutdown" "$log4"
check  "degrade warns on stderr"                "WARNING"    "$(cat "$WORK/log4.err")"

# Ordering: the build must run BEFORE the shutdown, or we kill the server the
# build is using.
if [[ "$(grep -c 'BAZEL_ARGV' <<< "$log4")" == 2 ]] \
   && [[ "$(grep -n 'BAZEL_ARGV' <<< "$log4" | head -1)" == *"build //z"* ]]; then
  ok "degrade order is build-then-shutdown"
else
  bad "degrade must run the build first, then shutdown; got: $log4"
fi

CANARY_RC=1 BAZEL_RC=12 run_shim "$WORK/log5" build //w
[[ "$RC" == 12 ]] && ok "degrade propagates the BUILD's exit code, not shutdown's" \
                  || bad "expected exit 12 on the degrade path, got $RC"

# ...and the other half of that bargain: do NOT shut down a server that is not
# ours to kill. The degrade trigger (a transiently full /run/user) says nothing
# about where this workspace's server lives; if it is healthy in its own scope,
# an unconditional shutdown would throw away its analysis cache for no benefit.
# `bazel version` on the degrade path must likewise not fork a JVM just to kill it.
: > "$WORK/log6"
STUB_LOG="$WORK/log6" STUB_CANARY_RC=1 STUB_BAZEL_RC=0 \
  "$WORK/shim-noserver" build //v > /dev/null 2>&1 || true
log6=$(cat "$WORK/log6")
check  "degrade still runs the build when no server is resident" "build //v" "$log6"
refute "degrade does NOT shut down a server living outside this cgroup" "shutdown" "$log6"

# The gate must key on a real bazel SERVER (argv[0] = `bazel(<name>)`), not on
# any old process, or it would fire on almost every cgroup.
if [[ "$(grep -c 'BAZEL_ARGV' <<< "$log6")" == 1 ]]; then
  ok "no-server degrade path invokes bazel exactly once"
else
  bad "expected exactly one bazel invocation with no resident server; got: $log6"
fi

# ---------------------------------------------------------------------------
echo "== concurrency gate (workstation-o5s1.19) =="
# ---------------------------------------------------------------------------
# The harness shim has ONE slot unless TEST_GATE_SLOTS says otherwise, and polls
# every second.
GATE="$WORK/bazel-gate"

slot_free() { # slot_free <n>: true iff nobody holds slot n
  flock -n "$GATE/slot.$1" true
}

# The slot is held by a watcher that polls every second for the client to be
# gone, so release lags the shim's exit by up to ~1s. Allow 3.
slot_frees() { # slot_frees <n>
  for _ in $(seq 1 30); do slot_free "$1" && return 0; sleep 0.1; done
  return 1
}

# Hold slot 0 from outside for <secs>, the way a running build would. Waits
# until the lock is actually held before returning, so the test cannot race it.
hold_slot() { # hold_slot <secs>
  mkdir -p "$GATE"
  rm -f "$WORK/held"
  ( exec 9<>"$GATE/slot.0"; flock 9; printf 'pid=%s since=x cmd=build cwd=/elsewhere\n' "$BASHPID" > "$GATE/slot.0.info"; : > "$WORK/held"; sleep "$1" ) &
  HOLDER=$!
  for _ in $(seq 1 50); do [[ -e "$WORK/held" ]] && return 0; sleep 0.1; done
  echo "FAIL: test harness could not take slot 0"; exit 1
}

# A slot is released when the build ends -- including when it FAILS.
BAZEL_RC=3 run_shim "$WORK/g0" build //r
if slot_frees 0; then ok "slot is released after the build exits (rc=$RC)"; else bad "slot 0 still held 3s after the shim exited"; fi

# The exit code survives the gated path too.
[[ "$RC" == 3 ]] && ok "gated path propagates bazel's exit code" || bad "expected exit 3 on the gated path, got $RC"

# Startup options before the command do not hide it from the gate.
run_shim "$WORK/g1" --output_user_root=/tmp/x test //t
check "startup options before the command are skipped" "cmd=test" "$(cat "$WORK/g1")"

# Ungated commands never wait, even when every slot is taken.
hold_slot 20
run_shim "$WORK/g2" query //...
refute "query is not gated"               "JOURNAL:" "$(cat "$WORK/g2")"
check  "query still runs"                 "BAZEL_ARGV: query //..." "$(cat "$WORK/g2")"
refute "query prints no wait message"     "for a build slot" "$(cat "$WORK/g2.err")"
run_shim "$WORK/g2r" run //srv
refute "run is not gated (its client execs the target)" "JOURNAL:" "$(cat "$WORK/g2r")"

# Overflow: every slot held past the max wait -> the build still runs, loudly.
TEST_GATE_MAX_WAIT=2 run_shim "$WORK/g3" build //o
check "a waiter says what it is waiting for"           "for a build slot" "$(cat "$WORK/g3.err")"
check "the wait message names the current holder"      "cwd=/elsewhere"           "$(cat "$WORK/g3.err")"
check "after the max wait the build runs anyway"       "BAZEL_ARGV: build //o"    "$(cat "$WORK/g3")"
check "and says so on stderr"                          "running UNGATED"          "$(cat "$WORK/g3.err")"
check "and logs overflow to the journal"               "JOURNAL: overflow"        "$(cat "$WORK/g3")"
kill "$HOLDER" 2>/dev/null || true; wait "$HOLDER" 2>/dev/null || true

# A waiter takes the slot as soon as it frees up.
hold_slot 2
run_shim "$WORK/g4" build //w
check  "a waiter acquires the slot once it is released" "JOURNAL: acquired slot=0 waited=" "$(cat "$WORK/g4")"
refute "and does not overflow"                          "overflow" "$(cat "$WORK/g4")"
if grep -q 'waited=0 ' "$WORK/g4"; then bad "waiter reported waited=0 while the slot was held"; else ok "waiter recorded a non-zero wait"; fi
wait "$HOLDER" 2>/dev/null || true

# EXCLUSION, with a control that can fail. Two builds that each sleep 2s are
# started together. With one slot they must NOT overlap; with two they MUST --
# which proves the overlap detector can see an overlap at all.
overlap() { # overlap <slots> -> prints yes|no
  local a="$WORK/ov-$1-a" b="$WORK/ov-$1-b"
  : > "$a"; : > "$b"
  env -u XDG_RUNTIME_DIR STUB_LOG="$a" STUB_BAZEL_SLEEP=2 TEST_GATE_SLOTS="$1" "$WORK/shim" build //a >/dev/null 2>&1 &
  local p1=$!
  env -u XDG_RUNTIME_DIR STUB_LOG="$b" STUB_BAZEL_SLEEP=2 TEST_GATE_SLOTS="$1" "$WORK/shim" build //b >/dev/null 2>&1 &
  local p2=$!
  wait "$p1" "$p2" || true
  local sa ea sb eb
  sa=$(awk '/^START/{print $2}' "$a"); ea=$(awk '/^END/{print $2}' "$a")
  sb=$(awk '/^START/{print $2}' "$b"); eb=$(awk '/^END/{print $2}' "$b")
  if [[ -z "$sa" || -z "$ea" || -z "$sb" || -z "$eb" ]]; then echo "missing"; return; fi
  if (( sa < eb && sb < ea )); then echo yes; else echo no; fi
}
rm -f "$GATE"/slot.*
r1=$(overlap 1)
[[ "$r1" == no ]] && ok "one slot: two concurrent builds are serialized" || bad "one slot: builds overlapped (got: $r1)"
rm -f "$GATE"/slot.*
r2=$(overlap 2)
[[ "$r2" == yes ]] && ok "control: two slots let them overlap, so the detector works" || bad "control: two slots did not overlap (got: $r2)"

# FAIRNESS. A is already waiting when B arrives; when the slot frees, A must
# get it. Without the turnstile both poll independently and B wins about half
# the time. (Held 5s so B's silent 2s turnstile grace expires while A is
# still at the head of the line, and B has to say it is waiting.)
hold_slot 5
fa="$WORK/fair-a"; fb="$WORK/fair-b"; : > "$fa"; : > "$fb"
env -u XDG_RUNTIME_DIR STUB_LOG="$fa" STUB_BAZEL_SLEEP=1 "$WORK/shim" build //A >/dev/null 2>&1 &
pa=$!
sleep 1.5
env -u XDG_RUNTIME_DIR STUB_LOG="$fb" STUB_BAZEL_SLEEP=1 "$WORK/shim" build //B >/dev/null 2>"$fb.err" &
pb=$!
wait "$pa" "$pb" "$HOLDER" || true
sa=$(awk '/^START/{print $2}' "$fa"); sb=$(awk '/^START/{print $2}' "$fb")
if [[ -n "$sa" && -n "$sb" ]] && (( sa < sb )); then ok "the earlier waiter gets the slot first"; else bad "fairness: A start=$sa, B start=$sb"; fi
check "a waiter behind another says it is in line" "waiting in line" "$(cat "$fb.err")"

# A bazel spawned BY a build (a test shelling out to bazel) must not queue for a
# slot its own outer build is holding.
hold_slot 20
run_shim_as() { # run_shim_as <shim> <log> args...
  local sh="$1" log="$2"; shift 2
  : > "$log"
  set +e
  env -u XDG_RUNTIME_DIR STUB_LOG="$log" TEST_GATE_MAX_WAIT=2 "$sh" "$@" > "$log.out" 2> "$log.err"
  RC=$?
  set -e
}
run_shim_as "$WORK/shim-inslice" "$WORK/g6" build //nested
check  "a build inside bazel.slice skips the gate"   "JOURNAL: nested cmd=build" "$(cat "$WORK/g6")"
refute "and does not wait"                           "for a build slot" "$(cat "$WORK/g6.err")"
check  "and still runs"                              "BAZEL_ARGV: build //nested" "$(cat "$WORK/g6")"
kill "$HOLDER" 2>/dev/null || true; wait "$HOLDER" 2>/dev/null || true

# Gate dir unusable (here: a regular file sits where the directory should be).
rm -rf "$GATE"; : > "$GATE"
run_shim "$WORK/g5" build //u
check "an unusable gate dir does not block the build" "BAZEL_ARGV: build //u" "$(cat "$WORK/g5")"
check "but it says the gate is off"                   "WITHOUT the concurrency gate" "$(cat "$WORK/g5.err")"
rm -f "$GATE"

# ---------------------------------------------------------------------------
echo
if [[ "$fail" -ne 0 ]]; then
  echo "FAILED -- the bazel scope shim invariant is broken."
  echo "See bead workstation-mqp3 (epic workstation-rdsq)."
  exit 1
fi
echo "ALL PASS (bazel scope shim: $pass assertions)"
