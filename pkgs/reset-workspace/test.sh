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

# K=1 (crostini): single instance.
check "K=1 pool -> one serve URL" \
  "http://127.0.0.1:4096" \
  "$(pool_health_urls_from_wants 'opencode-serve@4096.service' "$fb")"

# Non-pool units in Wants= are ignored.
check "ignores unrelated Wants units" \
  "http://127.0.0.1:4096" \
  "$(pool_health_urls_from_wants 'foo.service opencode-serve@4096.service bar.target' "$fb")"

# Empty / failed query -> fallback (pre-pool behavior).
check "empty Wants -> fallback"   "$fb" "$(pool_health_urls_from_wants '' "$fb")"
check "no pool units -> fallback" "$fb" "$(pool_health_urls_from_wants 'foo.service bar.service' "$fb")"

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
  want_grep "capture picks a healthy member as CAPTURE_URL" 'CAPTURE_URL="$u"'
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
  want_grep "restart reuses the precomputed scope"        '[ "$POOL_SCOPE" = "user" ]'
  want_grep "post-restart poll reuses discover_pool_urls" 'serve_health_urls < <(discover_pool_urls "$POOL_SCOPE")'
  # workstation-3smg: the manifest write must precede the pool restart, so a
  # restart/health-poll die can't discard a successful capture.
  manifest_line=$(grep -n 'MANIFEST_PATH="/tmp/reset-workspace-last-manifest.txt"' "$default_nix" | head -1 | cut -d: -f1)
  restart_line=$(grep -n 'restarting opencode-serve-pool.target' "$default_nix" | head -1 | cut -d: -f1)
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
  want_grep "prune targets the mono primary root"        '/projects/mono'
  want_grep "prune is guarded by command -v work"        'command -v work >/dev/null 2>&1 && [ -e "$MONO_ROOT/.git" ]'
  want_grep "prune failure is non-fatal to the reset"    'work --prune-merged failed (non-fatal)'
  # The prune must run before the recommendation session is launched (so a slow
  # prune can't be skipped by an early recommendation-launch exit) and after the
  # pool is confirmed healthy.
  prune_line=$(grep -n 'work --prune-merged' "$default_nix" | head -1 | cut -d: -f1)
  rec_line=$(grep -n '# ---- Step 6: Launch recommendation session ----' "$default_nix" | head -1 | cut -d: -f1)
  if [ -n "$prune_line" ] && [ -n "$rec_line" ] && [ "$prune_line" -lt "$rec_line" ]; then
    echo "ok: worktree prune runs before the recommendation launch"
  else
    echo "FAIL: prune must precede recommendation launch (prune at ${prune_line:-?}, rec at ${rec_line:-?})"; fail=1
  fi
else
  echo "SKIP: source guards (default.nix not next to test)"
fi

[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "SOME TESTS FAILED"; exit 1; }
