#!/usr/bin/env bash
# unwired-test(workstation-k7t4): probes live host state (systemd/tmux/sockets); needs fixture injection to be hermetic
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

  # A corrupt main.shada makes nvim refuse the tmp->main rename forever (E136),
  # warning on every start/save and stranding a temp each exit. The reset must
  # repair the master file, not just sweep the temps: quarantine the corrupt
  # file (never delete it), promote a parseable temp, then reap. All of it must
  # run AFTER the kill, so no live nvim owns the files.
  want_grep "source assesses the shada file"             'shada_verdict() {'
  want_grep "corrupt shada is quarantined"               'main.shada.corrupt'
  want_grep "source reaps orphaned shada temps"          "-name 'main.shada.tmp.*' -o"
  refuse_grep "corrupt shada is never deleted"           'rm -f "$SHADA_MAIN"'

  # workstation-wro4: five ways this repair used to fail OPEN -- declaring a bad
  # file healthy, or installing an unvalidated one. Each line below pins one.
  #
  # 1. The probe asks nvim whether it would REFUSE the rename, rather than
  #    grepping read-error codes (E575/E576/E886 are three classes and only some
  #    cause the refusal). Bare `E136` is NOT enough: five messages share that
  #    code, and "errors during writing it" fires on a HEALTHY file when the
  #    disk is full -- which would quarantine good history.
  want_grep "probe keys on the rename refusal phrase" \
    "grep -q 'E136.*does not look like a ShaDa file'"
  refuse_grep "probe does not key on read-error codes alone"  "grep -q 'E576'"
  # 2. `wshada!` skips the check nvim is being asked about.
  refuse_grep "probe never uses the checkless wshada bang"     "wshada!"
  # 3. The probe runs on a COPY: `-i <file>` makes nvim write shada on exit, so
  #    probing the real file mutates it and strands fresh temps.
  want_grep "probe runs against a scratch copy"          '-i "$scratch/probe.shada"'
  # 4. Exit status is read BEFORE grepping. In a pipeline the status is grep's,
  #    so a hung or missing nvim yields no match and reads as healthy.
  want_grep "probe treats a timeout as unknown"          '[ "$rc" -ge 124 ]'
  want_grep "probe verdict is three-state"               'echo unknown'
  # 5. Promotion installs via a same-dir temp + rename, so a reset dying
  #    mid-write cannot leave a torn main.shada.
  want_grep "promotion is atomic"                        'mv "$promote_tmp" "$SHADA_MAIN"'
  refuse_grep "promotion never cps onto the live path"   'cp "$promoted" "$SHADA_MAIN"'
  # The temps are the only recovery material, so the reap is gated on a verdict.
  want_grep "reap is gated on the verdict"               'if [ "$shada_reap_ok" -eq 1 ]; then'
  want_grep "promote leftovers are reaped too"           "-name 'main.shada.promote.*'"

  # The gate must be CLEARED on every path that leaves recovery material behind,
  # and set once at the top. Counting keeps a new early-return from skipping one.
  gate_clears=$(grep -c 'shada_reap_ok=0' "$default_nix" || true)
  if [ "$gate_clears" -eq 5 ]; then
    echo "ok: reap gate is cleared on all 5 recovery paths"
  else
    echo "FAIL: expected 5 'shada_reap_ok=0' (not-regular-file, unknown verdict,"
    echo "      quarantine failed, promotion failed, main-absent-with-unusable-temps);"
    echo "      found $gate_clears"; fail=1
  fi
  quarantine_line=$(grep -n 'quarantining ->' "$default_nix" | head -1 | cut -d: -f1)
  reap_line=$(grep -n "main.shada.promote.\*' \\\\) -delete" "$default_nix" | head -1 | cut -d: -f1)
  if [ -n "$quarantine_line" ] && [ -n "$reap_line" ] && [ "$quarantine_line" -lt "$reap_line" ]; then
    echo "ok: shada repair runs before the temp reap"
  else
    echo "FAIL: repair must precede reap (repair at ${quarantine_line:-?}, reap at ${reap_line:-?})"; fail=1
  fi
  if [ -n "$reap_line" ] && [ -n "$pkill_line" ] && [ "$pkill_line" -lt "$reap_line" ]; then
    echo "ok: shada temp reap runs after the nvim kill"
  else
    echo "FAIL: shada reap must follow pkill (pkill at ${pkill_line:-?}, reap at ${reap_line:-?})"; fail=1
  fi

  # ---- Step 3: serialized graceful nvim exits (workstation-zv0l) ----------
  # The walk's behaviour is proven in test-nvim-walk.sh (it RUNS the extracted
  # code against a lab of throwaway nvims). These are the invariants that are
  # cheap to assert statically and expensive to discover in production.
  want_grep "writers are exited with SIGTERM"        'kill -TERM "$w_pid"'
  want_grep "stragglers escalate to SIGKILL"         'kill -9 "$w_pid"'
  want_grep "a zombie counts as gone"                '[ "$state" = Z ] && return 1'
  want_grep "pid reuse is guarded by starttime"      '[ "$start" = "$want_start" ] || return 1'
  want_grep "the walk re-checks liveness per writer" 'nvim_writer_live "$w_pid" "$w_start" || continue'
  want_grep "self-ancestors are deferred"            'is an ANCESTOR of this reset'
  want_grep "socket reap skips live listeners"       'grep -qxF "$sock" && continue'
  # The RPC path is absent BY DECISION (a successful :qa! and a stale socket both
  # exit 2; an unresponsive socket blocks forever; a /tmp glob misses
  # default-address nvims). If someone "restores" it, this fails and they must
  # read the roadmap first.
  refuse_grep "no RPC --remote-expr exit path"       '--remote-expr'
  refuse_grep "the walk never talks to a socket"     'nvim --server'
  # Every signal must tolerate a pid that vanished between snapshot and kill --
  # the process set demonstrably moves mid-walk, and a bare `kill` on a dead pid
  # returns 1, which under errexit would abort the reset and skip the pool restart.
  bare_kills=$( { grep -nE '^\s*kill (-[A-Z0-9]+ )?"\$[a-z_]+"\s*$' "$default_nix" || true; } | wc -l)
  if [ "$bare_kills" -eq 0 ]; then
    echo "ok: no unguarded kill (errexit would abort the reset on a vanished pid)"
  else
    echo "FAIL: $bare_kills kill(s) lack '|| true'; a vanished pid would abort the reset"
    { grep -nE '^\s*kill (-[A-Z0-9]+ )?"\$[a-z_]+"\s*$' "$default_nix" || true; } | head -5; fail=1
  fi
  # Sweep order is load-bearing: SIGKILLing leftover WRITERS must precede the
  # client pkill, because killing a low-pid client first is exactly what makes
  # its server start the graceful write this whole step exists to serialize.
  sweep_writer_line=$(grep -n 'sweep: SIGKILL leftover writer' "$default_nix" | head -1 | cut -d: -f1)
  if [ -n "$sweep_writer_line" ] && [ -n "$pkill_line" ] && [ "$sweep_writer_line" -lt "$pkill_line" ]; then
    echo "ok: leftover writers are SIGKILLed before the client sweep"
  else
    echo "FAIL: writer sweep must precede the client pkill (writers at ${sweep_writer_line:-?}, pkill at ${pkill_line:-?})"; fail=1
  fi
  # A corrupt main.shada entering the walk makes every serialized writer fail its
  # rename, so the quarantine has to happen BEFORE the exits, not only after.
  prewalk_line=$(grep -n 'quarantined corrupt ShaDa BEFORE the walk' "$default_nix" | head -1 | cut -d: -f1)
  first_term_line=$(grep -n 'kill -TERM "$w_pid"' "$default_nix" | head -1 | cut -d: -f1)
  if [ -n "$prewalk_line" ] && [ -n "$first_term_line" ] && [ "$prewalk_line" -lt "$first_term_line" ]; then
    echo "ok: a corrupt shada is quarantined before the walk, not just after"
  else
    echo "FAIL: pre-walk quarantine must precede the exits (quarantine at ${prewalk_line:-?}, first TERM at ${first_term_line:-?})"; fail=1
  fi
  want_grep "good shada is snapshotted pre-reset"    'cp -a "$SHADA_MAIN" "$SHADA_MAIN.pre-reset"'
  # ...and that snapshot must not itself abort the reset when there is no file.
  if grep -q 'if \[ -f "$SHADA_MAIN" \]; then\s*$' "$default_nix" && \
     grep -B 2 'cp -a "$SHADA_MAIN" "$SHADA_MAIN.pre-reset"' "$default_nix" | grep -q '\[ -f "$SHADA_MAIN" \]'; then
    echo "ok: the pre-reset snapshot is guarded by a file test"
  else
    echo "FAIL: cp -a must be guarded by [ -f ] or errexit aborts when shada is absent"; fail=1
  fi
  # main.shada absent + temps present is the state a straggler SIGKILL between
  # unlink and rename produces. Reaping there destroys the only copy.
  want_grep "absent main.shada promotes a temp"      'main.shada was absent; promoted'
  want_grep "absent main.shada is a real branch"     'elif [ ! -e "$SHADA_MAIN" ]; then'
  want_grep "straggler kill notes a missing main"    'main.shada is absent after that SIGKILL'

  # workstation-n0yh.1: the lgtm junk-drawer teardown is a shada writer trigger.
  # `tmux kill-session` tears down every pane AT ONCE, and each pane's embed
  # server graceful-writes when its client dies -- the identical mechanism to the
  # old `pkill -9` storm. Measured 2026-08-04: 3 concurrent writers at 03:00:03,
  # two seconds before the walk. So the teardown must happen where no nvim is
  # left alive, i.e. AFTER the walk's client sweep. These guards pin that
  # ordering; without them a future refactor moves it back into the head phase
  # and silently restores the burst.
  lgtm_kill_line=$(grep -n "tmux kill-session -t '=lgtm'" "$default_nix" | head -1 | cut -d: -f1)
  if [ -n "$lgtm_kill_line" ] && [ -n "$pkill_line" ] && [ "$lgtm_kill_line" -gt "$pkill_line" ]; then
    echo "ok: the lgtm teardown runs after the nvim sweep (no live writers to burst)"
  else
    echo "FAIL: lgtm teardown must follow the client sweep (teardown at ${lgtm_kill_line:-?}, pkill at ${pkill_line:-?})"; fail=1
  fi
  # It must still precede Step 3.5, so that a write from any nvim that appeared
  # mid-walk lands where the repair can still see and fix it.
  repair_line=$(grep -n '^    # ---- Step 3.5' "$default_nix" | head -1 | cut -d: -f1)
  if [ -n "$lgtm_kill_line" ] && [ -n "$repair_line" ] && [ "$lgtm_kill_line" -lt "$repair_line" ]; then
    echo "ok: the lgtm teardown precedes the shada repair"
  else
    echo "FAIL: lgtm teardown must precede Step 3.5 (teardown at ${lgtm_kill_line:-?}, repair at ${repair_line:-?})"; fail=1
  fi
  # ...and precede the socket reap, so a straggler SIGKILLed by the drain below
  # (a SIGKILL does not unlink its own socket) does not leak an orphan socket.
  reap_line=$(grep -n 'reaped %s orphaned pane socket\|orphaned pane socket(s)' "$default_nix" | head -1 | cut -d: -f1)
  if [ -n "$lgtm_kill_line" ] && [ -n "$reap_line" ] && [ "$lgtm_kill_line" -lt "$reap_line" ]; then
    echo "ok: the lgtm teardown precedes the socket reap"
  else
    echo "FAIL: lgtm teardown must precede the socket reap (teardown at ${lgtm_kill_line:-?}, reap at ${reap_line:-?})"; fail=1
  fi
  # The teardown must be in the destructive tail, not the interactive head:
  # it is a destructive act and belongs behind the [y/N] confirmation.
  confirm_line=$(grep -n 'Continue? \[y/N\]' "$default_nix" | head -1 | cut -d: -f1)
  if [ -n "$lgtm_kill_line" ] && [ -n "$confirm_line" ] && [ "$lgtm_kill_line" -gt "$confirm_line" ]; then
    echo "ok: the lgtm teardown is gated behind the confirmation prompt"
  else
    echo "FAIL: lgtm teardown must follow the confirm (teardown at ${lgtm_kill_line:-?}, confirm at ${confirm_line:-?})"; fail=1
  fi
  # The lgtm-run timer fires `*:0/10`, i.e. at 03:00:00 -- the same second the
  # nightly reset starts (verified: lgtm-run began 03:00:03.461, 113ms before
  # the teardown logged at 03:00:03.574). It dispatches FRESH nvims into the
  # lgtm session, so the window between the sweep and the teardown can acquire
  # new writers. Draining them serially first is what keeps max-concurrent == 1;
  # a log-only check would merely observe the burst it is meant to prevent.
  drain_line=$(grep -n 'draining .* writer' "$default_nix" | head -1 | cut -d: -f1 || true)
  if [ -n "$drain_line" ] && [ -n "$lgtm_kill_line" ] && [ "$drain_line" -lt "$lgtm_kill_line" ]; then
    echo "ok: late-arriving writers are drained serially before the teardown"
  else
    echo "FAIL: a serialized drain must precede the lgtm teardown (drain at ${drain_line:-?}, teardown at ${lgtm_kill_line:-?})"; fail=1
  fi
  # workstation-y3fq: the reset asserts its OWN invariant every night. The
  # external inotify watch that verified S0-S2b was a hand-started transient unit
  # that dies on reboot -- and worse, `inotifywait -m` goes DEAF when its watched
  # directory is replaced (verified: the process stays alive and healthy-looking,
  # so no Restart= and no liveness probe can catch it). A permanent daemon is
  # therefore an instrument that cannot be calibrated. Self-reporting can be
  # calibrated, because the walk already knows how many writers it exited: if it
  # exited some and the watcher saw nothing, the instrument is dead and must say
  # UNKNOWN loudly rather than report a clean max of 1.
  want_grep "the reset measures its own writer concurrency" 'max concurrent shada writers'
  want_grep "a dead instrument reports unknown, not clean"  'shada concurrency: unknown'
  want_grep "inotify is a declared dependency"              'inotify-tools'
  # The watcher has to be running BEFORE the first thing that can make an nvim
  # write, and must not stop until after the last one (the Step 3.4 teardown).
  wstart_line=$(grep -n 'shada_watch_start' "$default_nix" | head -1 | cut -d: -f1 || true)
  wstop_line=$(grep -n 'shada_watch_report' "$default_nix" | tail -1 | cut -d: -f1 || true)
  first_term_line2=$(grep -n 'kill -TERM "$w_pid"' "$default_nix" | head -1 | cut -d: -f1 || true)
  if [ -n "$wstart_line" ] && [ -n "$first_term_line2" ] && [ "$wstart_line" -lt "$first_term_line2" ]; then
    echo "ok: the watcher starts before the first nvim exit"
  else
    echo "FAIL: watcher must start before the walk (start at ${wstart_line:-?}, first TERM at ${first_term_line2:-?})"; fail=1
  fi
  if [ -n "$wstop_line" ] && [ -n "$lgtm_kill_line" ] && [ "$wstop_line" -gt "$lgtm_kill_line" ]; then
    echo "ok: the watcher is still running through the lgtm teardown"
  else
    echo "FAIL: watcher must outlast the teardown (report at ${wstop_line:-?}, teardown at ${lgtm_kill_line:-?})"; fail=1
  fi
  # It must start AFTER the re-exec dance, or a manual run started from a serve
  # cgroup loses its watcher to the pool restart mid-reset and under-reports.
  tail_line=$(grep -n '^    # ---- Destructive Tail Phase' "$default_nix" | head -1 | cut -d: -f1 || true)
  if [ -n "$wstart_line" ] && [ -n "$tail_line" ] && [ "$wstart_line" -gt "$tail_line" ]; then
    echo "ok: the watcher starts inside the destructive tail (survives the re-exec)"
  else
    echo "FAIL: watcher must start after the re-exec (start at ${wstart_line:-?}, tail at ${tail_line:-?})"; fail=1
  fi

  # Exact-match target: `lgtm-foo` is somebody else's session, not ours.
  if [ "$(grep -c "kill-session -t '=lgtm'" "$default_nix" || true)" -eq 1 ]; then
    echo "ok: exactly one exact-match lgtm kill-session"
  else
    echo "FAIL: expected exactly one \`kill-session -t '=lgtm'\`"; fail=1
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
