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

cat > "$WORK/stub-bazel" <<STUB
#!$BASH_BIN
printf '%s\\n' "BAZEL_ARGV: \$*" >> "\$STUB_LOG"
exit "\${STUB_BAZEL_RC:-0}"
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

chmod +x "$WORK/stub-bazel" "$WORK/stub-systemd-run"

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
    "$SHIM" > "$WORK/shim"
chmod +x "$WORK/shim"

# Same shim, but its cgroup holds no bazel server.
sed -e "s|^PROC_ROOT=.*|PROC_ROOT=\"$WORK/noserver/proc\"|" \
    -e "s|^CGROUP_ROOT=.*|CGROUP_ROOT=\"$WORK/noserver/cg\"|" \
    "$WORK/shim" > "$WORK/shim-noserver"
chmod +x "$WORK/shim-noserver"

grep -q "$WORK/stub-bazel" "$WORK/shim" || { echo "FAIL: harness did not rewrite REAL_BAZEL"; exit 1; }
grep -q "$WORK/stub-systemd-run" "$WORK/shim" || { echo "FAIL: harness did not rewrite SYSTEMD_RUN"; exit 1; }

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
echo
if [[ "$fail" -ne 0 ]]; then
  echo "FAILED -- the bazel scope shim invariant is broken."
  echo "See bead workstation-mqp3 (epic workstation-rdsq)."
  exit 1
fi
echo "ALL PASS (bazel scope shim: $pass assertions)"
