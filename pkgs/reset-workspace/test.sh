#!/usr/bin/env bash
# Unit + source-guard tests for reset-workspace's pool-aware health poll.
#
# mn9r M7: after restarting opencode-serve-pool.target, readiness must be
# confirmed for EVERY serve in the pool, not just serve-0 (:4096). The pool
# membership is discovered at runtime from the target's `Wants=` (generated
# from serve-pool.nix, the single source of truth) so it can't drift.
#
# Mirrors the pure pool_health_urls_from_wants helper and exercises it, then
# greps default.nix so a source-level regression trips before deploy. Mirror
# of the convention in pkgs/opencode-launch/test.sh.
#
# Run: bash test.sh
set -o errexit -o nounset -o pipefail

# ---- helper under test (mirror of default.nix) ------------------------------
# pool_health_urls_from_wants <wants-string> <fallback-url>: parse a systemd
# `Wants=` value (space-separated unit names) and print one
# http://127.0.0.1:<port> per opencode-serve@<port>.service instance, in order.
# Falls back to <fallback-url> when no instances are found (e.g. the query
# failed or the pool isn't templated), preserving the pre-pool single-serve
# behavior. Pure (no systemd): the caller runs `systemctl show` and hands the
# value in.
pool_health_urls_from_wants() {
  local wants="$1" fallback="$2" unit port
  local urls=()
  for unit in $wants; do
    case "$unit" in
      opencode-serve@*.service)
        port="${unit#opencode-serve@}"
        port="${port%.service}"
        [ -n "$port" ] && urls+=("http://127.0.0.1:$port")
        ;;
    esac
  done
  if [ "${#urls[@]}" -eq 0 ]; then
    printf '%s\n' "$fallback"
  else
    printf '%s\n' "${urls[@]}"
  fi
}

fail=0
check() { # check <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok: $1"; else
    echo "FAIL: $1"; echo "  expected: [$2]"; echo "  actual:   [$3]"; fail=1; fi
}

fb="http://127.0.0.1:4096"

# K=2 (devbox/darwin): two instances -> two URLs, in port order.
check "K=2 pool -> both serve URLs" \
  "http://127.0.0.1:4096 http://127.0.0.1:4097" \
  "$(pool_health_urls_from_wants 'opencode-serve@4096.service opencode-serve@4097.service' "$fb" | tr '\n' ' ' | sed 's/ $//')"

# K=4 (cloudbox): order preserved.
check "K=4 pool -> four serve URLs" \
  "http://127.0.0.1:4096 http://127.0.0.1:4097 http://127.0.0.1:4098 http://127.0.0.1:4099" \
  "$(pool_health_urls_from_wants 'opencode-serve@4096.service opencode-serve@4097.service opencode-serve@4098.service opencode-serve@4099.service' "$fb" | tr '\n' ' ' | sed 's/ $//')"

# K=1: single instance.
check "K=1 pool -> one serve URL" \
  "http://127.0.0.1:4096" \
  "$(pool_health_urls_from_wants 'opencode-serve@4096.service' "$fb")"

pool_ports_from_wants() {
  local wants="$1" unit port
  for unit in $wants; do
    case "$unit" in
      opencode-serve@*.service)
        port="${unit#opencode-serve@}"
        port="${port%.service}"
        [ -n "$port" ] && printf '%s\n' "$port"
        ;;
    esac
  done
}

# K=2 pool -> two ports
check "K=2 pool -> both serve ports" \
  "4096 4097" \
  "$(pool_ports_from_wants 'opencode-serve@4096.service opencode-serve@4097.service' | tr '\n' ' ' | sed 's/ $//')"

# K=4 pool -> four ports
check "K=4 pool -> four serve ports" \
  "4096 4097 4098 4099" \
  "$(pool_ports_from_wants 'opencode-serve@4096.service opencode-serve@4097.service opencode-serve@4098.service opencode-serve@4099.service' | tr '\n' ' ' | sed 's/ $//')"

# Non-pool units in Wants= are ignored.
check "ignores unrelated Wants units for ports" \
  "4096" \
  "$(pool_ports_from_wants 'foo.service opencode-serve@4096.service bar.target')"

# Empty / failed query -> empty
check "empty Wants -> empty ports" "" "$(pool_ports_from_wants '')"

# ---- new pure helpers under test ---------------------------------------------
should_detach_destructive() {
  local no_detach="$1"
  if [ "$no_detach" = "1" ]; then
    return 1
  fi
  return 0
}

is_timestamp_increased() {
  local old="$1" new="$2"
  [[ "$old" =~ ^[0-9]+$ ]] || old=0
  [[ "$new" =~ ^[0-9]+$ ]] || new=0
  [ "$new" -gt "$old" ]
}

evaluate_restart_outcome() {
  local has_failed=0 has_unreadable=0 has_restarted=0
  if [ "$#" -eq 0 ]; then
    printf 'unverifiable\n'
    return 0
  fi
  while [ "$#" -ge 2 ]; do
    local old="$1" new="$2"
    shift 2
    if [ -z "$old" ] || [ -z "$new" ] || ! [[ "$old" =~ ^[0-9]+$ ]] || ! [[ "$new" =~ ^[0-9]+$ ]]; then
      has_unreadable=1
    elif ! is_timestamp_increased "$old" "$new"; then
      has_failed=1
    else
      has_restarted=1
    fi
  done
  if [ "$has_failed" -eq 1 ]; then
    printf 'verified-failed\n'
  elif [ "$has_unreadable" -eq 1 ] || [ "$has_restarted" -eq 0 ]; then
    printf 'unverifiable\n'
  else
    printf 'verified-restarted\n'
  fi
}

format_sentinel() {
  local status="$1" ts="$2" pid="$3" phase="${4:-}"
  if [ "$status" = "ok" ]; then
    printf 'ok %s pid=%s\n' "$ts" "$pid"
  elif [ "$status" = "failed" ]; then
    printf 'failed %s pid=%s phase=%s\n' "$ts" "$pid" "$phase"
  else
    printf 'started %s pid=%s phase=%s\n' "$ts" "$pid" "$phase"
  fi
}

count_manifest_sids() {
  local file="${1:-}"
  if [ -f "$file" ]; then
    grep -c . "$file" 2>/dev/null || true
  else
    echo 0
  fi
}

tmp_dir="$(mktemp -d)"
cleanup_tmp() { rm -rf "$tmp_dir"; }
trap cleanup_tmp EXIT

empty_manifest="$tmp_dir/empty.txt"
: > "$empty_manifest"
check "count_manifest_sids: empty file -> 0" "0" "$(count_manifest_sids "$empty_manifest")"

lines_manifest="$tmp_dir/three_sids.txt"
printf 'ses_1\nses_2\nses_3\n' > "$lines_manifest"
check "count_manifest_sids: 3 sids -> 3" "3" "$(count_manifest_sids "$lines_manifest")"

blanks_manifest="$tmp_dir/blanks.txt"
printf 'ses_1\n\nses_2\n\n' > "$blanks_manifest"
check "count_manifest_sids: 2 sids + blanks -> 2" "2" "$(count_manifest_sids "$blanks_manifest")"

only_blanks_manifest="$tmp_dir/only_blanks.txt"
printf '\n\n\n' > "$only_blanks_manifest"
v="$(count_manifest_sids "$only_blanks_manifest")"
check "count_manifest_sids: blank-lines-only file -> 0" "0" "$v"
if [ "$v" -eq 0 ] 2>/dev/null; then
  echo "ok: count_manifest_sids blank-lines result is integer usable"
else
  echo "FAIL: count_manifest_sids blank-lines result [$v] is not integer usable"; fail=1
fi

missing_manifest="$tmp_dir/missing.txt"
check "count_manifest_sids: missing file -> 0" "0" "$(count_manifest_sids "$missing_manifest")"

check "detach decision: NO_DETACH unset -> detach" \
  "0" "$(should_detach_destructive 0 && echo 0 || echo 1)"
check "detach decision: NO_DETACH=1 -> suppress" \
  "1" "$(should_detach_destructive 1 && echo 0 || echo 1)"

# F1(b) test: prove log() shape writing to broken pipe exits 141 without trap and 0 with trap.
# Uses $! (PID of process-substitution reader >(exit 0)) in a bounded loop to wait deterministically
# for reader death without relying on fixed timing.
code_without_trap='log() { printf "[test] %s\n" "$*" >&2 || true; }; exec 2> >(exit 0); pid=$!; for i in $(seq 1 100); do kill -0 "$pid" 2>/dev/null || break; sleep 0.01; done; log "hello"'
code_with_trap='trap "" PIPE; log() { printf "[test] %s\n" "$*" >&2 || true; }; exec 2> >(exit 0); pid=$!; for i in $(seq 1 100); do kill -0 "$pid" 2>/dev/null || break; sleep 0.01; done; log "hello"'

rc_without=$(bash -c "$code_without_trap" 2>/dev/null; echo $?)
rc_with=$(bash -c "$code_with_trap" 2>/dev/null; echo $?)

check "broken pipe log() without trap PIPE -> exits 141" "141" "$rc_without"
check "broken pipe log() with trap PIPE -> exits 0" "0" "$rc_with"

# Behavioral test: child inherits SIGPIPE ignored unless restored via ( trap - PIPE; exec ... )
if [ -f /proc/self/status ]; then
  get_sigpipe_ign() {
    local hex
    hex="$(grep "^SigIgn:" /proc/self/status | awk '{print $2}')"
    echo "$(( (16#$hex >> 12) & 1 ))"
  }
  export -f get_sigpipe_ign

  plain_child_ign=$(bash -c 'trap "" PIPE; exec bash -c get_sigpipe_ign' 2>/dev/null || echo "?")
  restored_child_ign=$(bash -c 'trap "" PIPE; ( trap - PIPE; exec bash -c get_sigpipe_ign )' 2>/dev/null || echo "?")

  check "plain child inherits SIGPIPE ignored (1)" "1" "$plain_child_ign"
  check "restored child sees SIGPIPE default (0)" "0" "$restored_child_ign"
fi

# Behavioral test for Item 1: post-tail decision when tail exits before vs after child finishes
check_post_tail_status() { # check_post_tail_status <tail_pid> <sentinel_file> <log_file>
  local TAIL_PID="$1" SENTINEL_PATH="$2" LOG_FILE="$3"
  log() { :; }
  die() { exit 1; }
  if kill -0 "$TAIL_PID" 2>/dev/null; then
    log "destructive phase still running in background (PID $TAIL_PID)"
    return 0
  fi

  if [ -f "$SENTINEL_PATH" ]; then
    status_line="$(cat "$SENTINEL_PATH" 2>/dev/null || true)"
    case "$status_line" in
      ok*" pid=$TAIL_PID") log "reset-workspace finished successfully"; return 0 ;;
      ok*) die "destructive phase sentinel OK status belongs to stale PID (expected pid=$TAIL_PID; status: $status_line)" ;;
      *) die "destructive phase finished with status: $status_line" ;;
    esac
  else
    die "destructive phase PID $TAIL_PID exited without writing sentinel status"
  fi
}

item1_dir="$(mktemp -d)"
item1_sentinel="$item1_dir/status.txt"
item1_logfile="$item1_dir/run.log"

# Case 1: child is still alive when log-follow exits (e.g. Ctrl+C) -> success 0
sleep 10 & alive_pid=$!
check_post_tail_status "$alive_pid" "$item1_sentinel" "$item1_logfile" >/dev/null 2>&1
check "post-tail check: child still running -> success 0" "0" "$?"
kill -9 "$alive_pid" 2>/dev/null || true
wait "$alive_pid" 2>/dev/null || true

# Case 2: child dead, ok sentinel -> success 0
sleep 0.001 & dead_pid1=$!
wait "$dead_pid1" 2>/dev/null || true
echo "ok 2026-07-25T00:00:00Z pid=$dead_pid1" > "$item1_sentinel"
check_post_tail_status "$dead_pid1" "$item1_sentinel" "$item1_logfile" >/dev/null 2>&1
check "post-tail check: dead child, ok sentinel -> success 0" "0" "$?"

# Case 3: child dead, started sentinel -> failure non-zero
sleep 0.001 & dead_pid2=$!
wait "$dead_pid2" 2>/dev/null || true
echo "started 2026-07-25T00:00:00Z pid=$dead_pid2 phase=kill-nvim" > "$item1_sentinel"
rc_started=0
( check_post_tail_status "$dead_pid2" "$item1_sentinel" "$item1_logfile" ) >/dev/null 2>&1 || rc_started=$?
check "post-tail check: dead child, started sentinel -> non-zero failure" "1" "$([ "$rc_started" -ne 0 ] && echo 1 || echo 0)"

rm -rf "$item1_dir"

check "timestamp increased: 100 -> 200 -> true" \
  "0" "$(is_timestamp_increased 100 200 && echo 0 || echo 1)"
check "timestamp increased: 200 -> 100 -> false" \
  "1" "$(is_timestamp_increased 200 100 && echo 0 || echo 1)"
check "timestamp increased: 100 -> 100 -> false" \
  "1" "$(is_timestamp_increased 100 100 && echo 0 || echo 1)"
check "timestamp increased: 0 -> 50 -> true" \
  "0" "$(is_timestamp_increased 0 50 && echo 0 || echo 1)"

check "restart eval: all ports restarted -> verified-restarted" \
  "verified-restarted" "$(evaluate_restart_outcome 100 200 105 205)"
check "restart eval: one port failed -> verified-failed" \
  "verified-failed" "$(evaluate_restart_outcome 100 200 100 100)"
check "restart eval: one port unreadable before -> unverifiable" \
  "unverifiable" "$(evaluate_restart_outcome 100 200 "" 200)"
check "restart eval: one port unreadable after -> unverifiable" \
  "unverifiable" "$(evaluate_restart_outcome 100 200 100 "")"
check "restart eval: mixed failed + unreadable -> verified-failed" \
  "verified-failed" "$(evaluate_restart_outcome 100 100 "" 200)"
check "restart eval: no ports -> unverifiable" \
  "unverifiable" "$(evaluate_restart_outcome)"

# Health-poll pause idiom test: prove read -t 0.5 < <(:) does not pause (< 50ms) while sleep 0.1 genuinely pauses (>= 80ms)
t0=$(date +%s%N)
read -t 0.5 -r _ < <(:) 2>/dev/null || true
t1=$(date +%s%N)
dt_read_ms=$(( (t1 - t0) / 1000000 ))

t2=$(date +%s%N)
sleep 0.1
t3=$(date +%s%N)
dt_sleep_ms=$(( (t3 - t2) / 1000000 ))

check "non-pausing read idiom returns immediately (< 50ms)" "1" "$([ "$dt_read_ms" -lt 50 ] && echo 1 || echo 0)"
check "sleep 0.1 genuinely pauses (>= 80ms)" "1" "$([ "$dt_sleep_ms" -ge 80 ] && echo 1 || echo 0)"

check "sentinel format: started" \
  "started 2026-07-24T12:00:00Z pid=1234 phase=kill-nvim" \
  "$(format_sentinel started 2026-07-24T12:00:00Z 1234 kill-nvim)"
check "sentinel format: ok" \
  "ok 2026-07-24T12:00:00Z pid=1234" \
  "$(format_sentinel ok 2026-07-24T12:00:00Z 1234)"
check "sentinel format: failed" \
  "failed 2026-07-24T12:00:00Z pid=1234 phase=restart-pool" \
  "$(format_sentinel failed 2026-07-24T12:00:00Z 1234 restart-pool)"

# ---- scope + discovery mirrors (stubbed systemctl) ---------------------------
# pool_scope / discover_pool_urls mirrors (lockstep with default.nix). A shell
# function named `systemctl` shadows the real binary for the rest of this
# script, so these run hermetically on any host. NOTE: the system branch's
# empty-wants -> sudo-fallback path is NOT exercised here (the absolute
# /run/wrappers/bin/sudo path is not stub-able, and calling it for real would
# make the test host-dependent — on cloudbox it would return the REAL pool).
# Empty-wants -> $OPENCODE_URL fallback is covered by the pure
# pool_health_urls_from_wants checks above.
systemctl() { # test stub; cases match the exact "$*" of each source call site
  case "$*" in
    "--user is-active --quiet opencode-serve-pool.target") return "${STUB_USER_ACTIVE_RC:-1}" ;;
    "--user show -p Wants --value opencode-serve-pool.target") printf '%s\n' "${STUB_USER_WANTS:-}" ;;
    "show -p Wants --value opencode-serve-pool.target") printf '%s\n' "${STUB_SYS_WANTS:-}" ;;
    *) echo "unexpected systemctl call in test: $*" >&2; return 1 ;;
  esac
}

pool_scope() {
  if systemctl --user is-active --quiet opencode-serve-pool.target 2>/dev/null; then
    printf 'user\n'
  else
    printf 'system\n'
  fi
}

discover_pool_urls() {
  local scope="$1" wants
  if [ "$scope" = "user" ]; then
    wants="$(systemctl --user show -p Wants --value opencode-serve-pool.target 2>/dev/null || true)"
  else
    wants="$(systemctl show -p Wants --value opencode-serve-pool.target 2>/dev/null || true)"
    if [ -z "$wants" ]; then
      wants="$(/run/wrappers/bin/sudo -n systemctl show -p Wants --value opencode-serve-pool.target 2>/dev/null || true)"
    fi
  fi
  pool_health_urls_from_wants "$wants" "$OPENCODE_URL"
}

OPENCODE_URL="$fb"  # discover_pool_urls reads this global, same as the source

check "pool_scope: active user target -> user"   "user"   "$(STUB_USER_ACTIVE_RC=0 pool_scope)"
check "pool_scope: no user target -> system"     "system" "$(STUB_USER_ACTIVE_RC=1 pool_scope)"
check "discover: user scope K=2 (devbox)" \
  "http://127.0.0.1:4096 http://127.0.0.1:4097" \
  "$(STUB_USER_WANTS='opencode-serve@4096.service opencode-serve@4097.service' discover_pool_urls user | tr '\n' ' ' | sed 's/ $//')"
check "discover: system scope K=4 (cloudbox, unprivileged read)" \
  "http://127.0.0.1:4096 http://127.0.0.1:4097 http://127.0.0.1:4098 http://127.0.0.1:4099" \
  "$(STUB_SYS_WANTS='opencode-serve@4096.service opencode-serve@4097.service opencode-serve@4098.service opencode-serve@4099.service' discover_pool_urls system | tr '\n' ' ' | sed 's/ $//')"

# ---- source guards (default.nix) --------------------------------------------
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
default_nix="$script_dir/default.nix"
want_grep() { # want_grep <desc> <fixed-string>
  if grep -qF -- "$2" "$default_nix"; then echo "ok: $1"; else
    echo "FAIL: $1"; echo "  not found in default.nix: $2"; fail=1; fi
}
refuse_grep() { # refuse_grep <desc> <fixed-string> — string must NOT appear
  if grep -qF -- "$2" "$default_nix"; then
    echo "FAIL: $1"; echo "  found in default.nix (must be absent): $2"; fail=1
  else echo "ok: $1"; fi
}
if [ -f "$default_nix" ]; then
  want_grep_func_content() { # want_grep_func_content <desc> <func_name> <string>
    local desc="$1" func="$2" pattern="$3"
    local body
    body=$(sed -n "/^    ${func}() {/,/^    }/p" "$default_nix")
    if printf '%s' "$body" | grep -qF -- "$pattern"; then
      echo "ok: $desc"
    else
      echo "FAIL: $desc"; echo "  pattern '$pattern' not found in $func body"; fail=1
    fi
  }

  want_grep "log helper is EIO proof"                     'printf '\''[reset-workspace] %s\n'\'' "$*" >&2 || true'
  want_grep "clears sentinel before setsid re-exec"       'rm -f "$SENTINEL_PATH"'
  want_grep "atomic sentinel write via mktemp and mv"     'mktemp "/tmp/reset-workspace-status.XXXXXX"'
  want_grep "source defines pool_ports_from_wants"       'pool_ports_from_wants() {'
  want_grep "source defines get_pool_wants"               'get_pool_wants() {'
  want_grep "source defines FRONTDOOR_URL"                 'FRONTDOOR_URL="'
  want_grep "source defines pool_health_urls_from_wants" 'pool_health_urls_from_wants() {'
  want_grep "source reads the pool target Wants="         'show -p Wants --value opencode-serve-pool.target'
  want_grep "source polls each discovered serve URL"      'serve_health_urls'
  # workstation-7sbo: the manifest-capture path must never hang against a
  # wedged-but-TCP-accepting serve (it runs before the Step-5 restart that
  # clears the wedge). Two layers: a hard timeout on the bare-TUI resolution
  # curl (minimal belt) + a /global/health probe that skips capture entirely
  # and falls straight through to the restart when the serve is unhealthy
  # (defense-in-depth suspenders). See investigation 2026-06-17 Q3.
  want_grep "bare-resolution curl has a hard max-time"     '--max-time 5'
  want_grep "bare-resolution curl has a connect-timeout"   '--connect-timeout 3'
  want_grep "capture discovers the whole pool"             'mapfile -t capture_pool_urls < <(discover_pool_urls "$POOL_SCOPE")'
  want_grep "capture uses FRONTDOOR_URL as CAPTURE_URL"    'CAPTURE_URL="$FRONTDOOR_URL"'
  # fable M2 #3: door-first, but keep a direct healthy-member fallback so a
  # partial-pool wedge can't silently drop a sid from the morning manifest.
  want_grep "capture records a direct healthy-member fallback"   'CAPTURE_FALLBACK="$u"'
  want_grep "capture retries the read against the direct member" '"$CAPTURE_FALLBACK/session"'
  want_grep "no-healthy-pool still runs strict-attach"      'strict-attach capture will still run'
  want_grep "source sets an unhealthy-serve flag"          'SERVE_HEALTHY=0'
  # workstation-3smg: the 2026-07-03 empty-manifest bug WAS this gate. The
  # strict-attach loop reads /proc only and must never be re-gated on serve
  # health.
  refuse_grep "strict-attach capture is ungated" 'OC_ATTACH_PIDS=""'
  want_grep "source defines pool_scope"                    'pool_scope() {'
  want_grep "source defines discover_pool_urls"            'discover_pool_urls() {'
  want_grep "pool discovery reads Wants unprivileged first" 'wants="$(systemctl show -p Wants --value opencode-serve-pool.target 2>/dev/null || true)"'
  want_grep "pool discovery sudo fallback never prompts"    'sudo -n systemctl show'
  want_grep "pool_scope checks the user pool target"       'systemctl --user is-active --quiet opencode-serve-pool.target'
  want_grep "pool discovery user-scope read"               'wants="$(systemctl --user show -p Wants --value opencode-serve-pool.target 2>/dev/null || true)"'
  want_grep "pool discovery parses via the pure helper"    'pool_health_urls_from_wants "$wants" "$OPENCODE_URL"'
  want_grep "capture computes the pool scope once" 'POOL_SCOPE="$(pool_scope)"'
  want_grep "bare-resolution uses the healthy capture url" '"$CAPTURE_URL/session"'
  want_grep "bare-resolve loop still serve-gated"          'OC_ALL_PIDS=""'
  want_grep "restart reuses the precomputed scope"        'restart_pool_target "$POOL_SCOPE"'
  want_grep "post-restart poll reuses discover_pool_urls" 'serve_health_urls < <(discover_pool_urls "$POOL_SCOPE")'
  refuse_grep "no non-pausing read in health poll"        '< <(:)'
  want_grep "health poll pauses via sleep"               'sleep 0.5'
  # workstation-px2p & workstation-3smg: process detachment & sentinel status
  want_grep "source ignores SIGPIPE via trap"            'trap "" PIPE'
  want_grep "destructive phase detaches via setsid"      'setsid'
  want_grep "destructive phase uses guard var"            'RESET_WORKSPACE_DESTRUCTIVE_DETACHED'
  want_grep "destructive detach checks RESET_WORKSPACE_NO_DETACH" 'RESET_WORKSPACE_NO_DETACH'
  want_grep "post-tail checks if detached child is still running" 'kill -0 "$TAIL_PID"'
  refuse_grep "get_tty_nr is removed"                     'get_tty_nr() {'
  refuse_grep "false session leader comment is gone"     'Has its own session leader'
  refuse_grep "false no controlling TTY comment is gone" 'no controlling TTY → no PTY-collapse SIGHUP'
  want_grep "sentinel ok match is pid anchored"          'ok*" pid=$TAIL_PID")'
  want_grep "log notes Ctrl+C behavior on detach"        'stops following this log view'
  want_grep "references bead workstation-px2p"            'workstation-px2p'
  want_grep "sentinel status path is defined"            '/tmp/reset-workspace-last-status.txt'
  want_grep "uses ExecMainStartTimestampMonotonic"       'ExecMainStartTimestampMonotonic'
  refuse_grep "PID-based restart comparison not used"     'MainPID'
  want_grep "source defines count_manifest_sids"        'count_manifest_sids() {'
  want_grep "source counts sids via count_manifest_sids" 'OPENCODE_COUNT="$(count_manifest_sids "$MANIFEST_PATH")"'
  want_grep_func_content "cleanup_trap checks OWNS_SENTINEL" "cleanup_trap" "OWNS_SENTINEL"
  want_grep_func_content "update_sentinel checks OWNS_SENTINEL" "update_sentinel" "OWNS_SENTINEL"
  want_grep "source defines evaluate_restart_outcome"     'evaluate_restart_outcome() {'
  refuse_grep "does not retry on unverifiable"            'pool restart assertion failed or unverified'
  want_grep "retry is only on verified-failed"            'outcome" = "verified-failed"'
  want_grep "unverifiable logs warning and continues"     'outcome" = "unverifiable"'
  want_grep "discovery failure warning is logged"         'WARNING: could not discover pool instances; restart postcondition NOT verified'

  # The sentinel must be written before pkill
  sentinel_line=$(grep -n 'update_sentinel "started" "kill-nvim"' "$default_nix" | head -1 | cut -d: -f1)
  pkill_line=$(grep -n 'pkill -9 -u dev -x nvim' "$default_nix" | grep -v '#' | head -1 | cut -d: -f1)
  if [ -n "$sentinel_line" ] && [ -n "$pkill_line" ] && [ "$sentinel_line" -lt "$pkill_line" ]; then
    echo "ok: sentinel is written before pkill"
  else
    echo "FAIL: sentinel write must precede pkill (sentinel at ${sentinel_line:-?}, pkill at ${pkill_line:-?})"; fail=1
  fi

  # E138 guard: orphaned main.shada.tmp.<a-z> left by the SIGKILL accumulate
  # until all 26 suffixes are taken, after which nvim can no longer persist
  # shada. The reap must run AFTER the kill (no live nvim owns the temps) and
  # must never touch main.shada itself.
  want_grep "source reaps orphaned shada temps"          "-name '*.shada.tmp.*' -delete"
  refuse_grep "shada reap does not delete main.shada"    'rm -f "$SHADA_DIR"/main.shada$'
  reap_line=$(grep -n "shada.tmp.\*' -delete" "$default_nix" | head -1 | cut -d: -f1)
  if [ -n "$reap_line" ] && [ -n "$pkill_line" ] && [ "$pkill_line" -lt "$reap_line" ]; then
    echo "ok: shada temp reap runs after the nvim kill"
  else
    echo "FAIL: shada reap must follow pkill (pkill at ${pkill_line:-?}, reap at ${reap_line:-?})"; fail=1
  fi

  # workstation-3smg: the manifest write must precede the pool restart, so a
  # restart/health-poll die can't discard a successful capture.
  manifest_line=$(grep -n 'MANIFEST_PATH="/tmp/reset-workspace-last-manifest.txt"' "$default_nix" | head -1 | cut -d: -f1)
  restart_line=$(grep -n 'restart_pool_target "$POOL_SCOPE"' "$default_nix" | head -1 | cut -d: -f1)
  if [ -n "$manifest_line" ] && [ -n "$restart_line" ] && [ "$manifest_line" -lt "$restart_line" ]; then
    echo "ok: manifest is written before the pool restart"
  else
    echo "FAIL: manifest write must precede the pool restart (manifest at ${manifest_line:-?}, restart at ${restart_line:-?})"; fail=1
  fi
  # Phase 3.5 (workstation-v03j.5): reset-workspace is the pruning owner (M1c)
  # for opencode-launch --worktree leftovers. It must sweep merged worktrees in
  # the mono root via `work --prune-merged`, guarded by command -v work, and it
  # must NOT abort the reset on failure (best-effort).
  want_grep "source prunes merged launch worktrees"     'work --prune-merged'
  want_grep "prune resets SIGPIPE disposition"          '( trap - PIPE; cd "$MONO_ROOT"'
  want_grep "prune targets the mono primary root"        '/projects/mono'
  want_grep "prune is guarded by command -v work"        'command -v work >/dev/null 2>&1 && [ -e "$MONO_ROOT/.git" ]'
  want_grep "prune failure is non-fatal to the reset"    'work --prune-merged failed (non-fatal)'
  # F3: The prune must run before the pool restart and recommendation launch (so a pool failure
  # cannot skip worktree pruning).
  prune_line=$(grep -n 'work --prune-merged' "$default_nix" | head -1 | cut -d: -f1)
  restart_line=$(grep -n 'restart_pool_target "$POOL_SCOPE"' "$default_nix" | head -1 | cut -d: -f1)
  rec_line=$(grep -n '# ---- Step 6: Launch recommendation session ----' "$default_nix" | head -1 | cut -d: -f1)
  if [ -n "$prune_line" ] && [ -n "$restart_line" ] && [ "$prune_line" -lt "$restart_line" ]; then
    echo "ok: worktree prune runs before the pool restart"
  else
    echo "FAIL: prune must precede pool restart (prune at ${prune_line:-?}, restart at ${restart_line:-?})"; fail=1
  fi
  if [ -n "$prune_line" ] && [ -n "$rec_line" ] && [ "$prune_line" -lt "$rec_line" ]; then
    echo "ok: worktree prune runs before the recommendation launch"
  else
    echo "FAIL: prune must precede recommendation launch (prune at ${prune_line:-?}, rec at ${rec_line:-?})"; fail=1
  fi
  # 2026-07-16: morning agent lands in a dedicated $HOME/morning window
  # (not headless/cwd=~). See docs/plans/2026-07-16-morning-agent-dedicated-window-design.md
  want_grep "morning agent dir is defined"          'MORNING_DIR="$HOME/morning"'
  want_grep "morning agent dir is created"          'mkdir -p "$MORNING_DIR"'
  want_grep "launch targets the morning dir"        'opencode-launch "$MORNING_DIR" "$RECOMMENDATION_PROMPT"'
  want_grep "opencode-launch resets SIGPIPE disposition" '( trap - PIPE; exec opencode-launch'
  # The old cwd=~ launch must be gone. This substring matches current source
  # (opencode-launch '~' "''${RECOMMENDATION_PROMPT}") and disappears after the change.
  refuse_grep "no legacy tilde launch"              "opencode-launch '~'"
  # 2026-07-16 Task 2: prompt rationale corrected, self-skip added.
  # The reopen instruction (with --tmux-session main) must remain.
  want_grep "reopen still forces --tmux-session main" 'oc-auto-attach --tmux-session main <sid>'
  # The stale "headless" self-description must be gone.
  refuse_grep "prompt no longer calls itself headless" 'you are a headless session not attached to tmux'
  # The self-skip directive must be present. NOTE: do NOT grep for '$HOME/morning'
  # here -- that string already exists at default.nix's MORNING_DIR assignment
  # (Task 1), so it would match vacuously. Grep for a phrase unique to the directive.
  want_grep "prompt self-skips predecessor morning sessions" 'skip any manifest sid whose session directory is'
  # The scratch-dir guidance must be independently guarded.
  want_grep "prompt keeps scratch out of morning dir" 'write them under /tmp, never in'
  # 2026-07-22 Phase 7.7: Front door routing
  want_grep "recommendation prompt reads via the front door" 'http://127.0.0.1:4700/session/'
  refuse_grep "recommendation prompt no longer hardcodes anchor for reads" 'http://127.0.0.1:4096/session/'
else
  echo "SKIP: source guards (default.nix not next to test)"
fi

[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "SOME TESTS FAILED"; exit 1; }
