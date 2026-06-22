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

# ---- source guards (default.nix) --------------------------------------------
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
default_nix="$script_dir/default.nix"
want_grep() { # want_grep <desc> <fixed-string>
  if grep -qF -- "$2" "$default_nix"; then echo "ok: $1"; else
    echo "FAIL: $1"; echo "  not found in default.nix: $2"; fail=1; fi
}
if [ -f "$default_nix" ]; then
  want_grep "source defines pool_health_urls_from_wants" 'pool_health_urls_from_wants() {'
  want_grep "source reads the pool target Wants="         'show -p Wants --value opencode-serve-pool.target'
  want_grep "source polls each discovered serve URL"      'serve_health_urls'
else
  echo "SKIP: source guards (default.nix not next to test)"
fi

[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "SOME TESTS FAILED"; exit 1; }
