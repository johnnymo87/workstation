#!/usr/bin/env bash
# Tests for hosts/devbox/nix-gc-floor.sh. df and nix-store are stubbed on PATH.
# shellcheck disable=SC2016,SC2034  # check() evals its single-quoted assertions
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
pass=0; fail=0
check() { if eval "$2"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; fi; }

# Absolute shebangs: the flake-check sandbox has no /usr/bin/env.
bash_bin=$(command -v bash)
bin=$(mktemp)
trap 'rm -f "$bin"' EXIT
{ echo "#!$bash_bin"; echo 'set -euo pipefail'; cat "$here/nix-gc-floor.sh"; } >"$bin"; chmod +x "$bin"

GiB=$((1024 * 1024))   # in KiB, the unit df -k reports
setup() {
  S=$(mktemp -d); mkdir -p "$S/bin" "$S/state"
  export STATE_DIRECTORY=$S/state GC_FLOOR_TRIGGER_GIB=25 GC_FLOOR_TARGET_GIB=35 \
         GC_FLOOR_BACKOFF_MIN=120 GC_FLOOR_MIN_USEFUL_GIB=1 GC_FLOOR_NOW=1000000
  # df: prints a header and the KiB in $S/avail.
  printf '#!%s\necho Avail; cat %s/avail\n' "$bash_bin" "$S" >"$S/bin/df"
  # nix-store: logs NIX_REMOTE + args; moves avail to $S/after if present; fails if $S/fail.
  cat >"$S/bin/nix-store" <<EOF
#!$bash_bin
echo "\${NIX_REMOTE:-unset} \$*" >>"$S/calls"
[ -e "$S/fail" ] && exit 1
[ -e "$S/after" ] && cp "$S/after" "$S/avail"
exit 0
EOF
  chmod +x "$S/bin/df" "$S/bin/nix-store"
  PATH_SAVED=$PATH
}
avail() { echo $(($1 * GiB)) >"$S/avail"; }
after() { echo $(($1 * GiB)) >"$S/after"; }
tick() { PATH="$S/bin:$PATH_SAVED" "$bin" >"$S/out" 2>&1; }
calls() { [ -e "$S/calls" ] && wc -l <"$S/calls" || echo 0; }

# 1. Plenty of space: no GC.
setup; avail 30
if tick; then rc=0; else rc=$?; fi
check "above trigger: exit 0" '[ "$rc" -eq 0 ]'
check "above trigger: nix-store not called" '[ "$(calls)" -eq 0 ]'

# 2. Below trigger: GC through the daemon, bounded to reach the target.
setup; avail 19; after 31; tick
check "below trigger: one GC" '[ "$(calls)" -eq 1 ]'
check "GC runs via the daemon" 'grep -q "^daemon " "$S/calls"'
check "GC is bounded to target-avail (16 GiB)" 'grep -q -- "--quiet --gc --max-freed $((16 * 1024 * 1024 * 1024))\$" "$S/calls"'
check "useful GC: no backoff file" '[ ! -e "$S/state/backoff-until" ]'
check "logs the freed amount" 'grep -q "freed 12 GiB" "$S/out"'

# 3. GC that frees almost nothing arms the backoff, and the backoff holds.
setup; avail 20; after 20; tick
check "useless GC: backoff armed" '[ "$(cat "$S/state/backoff-until")" -eq $((1000000 + 120 * 60)) ]'
GC_FLOOR_NOW=$((1000000 + 60 * 60)) tick
check "within backoff: no second GC" '[ "$(calls)" -eq 1 ]'
check "within backoff: says so" 'grep -q "backing off" "$S/out"'
GC_FLOOR_NOW=$((1000000 + 121 * 60)) tick
check "after backoff: GC again" '[ "$(calls)" -eq 2 ]'

# 4. A useful GC clears an armed backoff.
setup; avail 20; echo 1 >"$S/state/backoff-until"; after 30; tick
check "expired backoff + useful GC: cleared" '[ ! -e "$S/state/backoff-until" ]'

# 5. Recovering above the trigger clears the backoff too (space came back by other means).
setup; avail 28; echo $((1000000 + 999)) >"$S/state/backoff-until"; tick
check "above trigger: backoff cleared" '[ ! -e "$S/state/backoff-until" ]'

# 6. nix-store failure surfaces as a failed unit.
setup; avail 10; touch "$S/fail"
if tick; then rc=0; else rc=$?; fi
check "nix-store failure: non-zero exit" '[ "$rc" -ne 0 ]'

# 7. Unparseable df output fails loudly instead of silently skipping.
setup; echo garbage >"$S/avail"
if tick; then rc=0; else rc=$?; fi
check "bad df: non-zero exit" '[ "$rc" -ne 0 ]'
check "bad df: no GC" '[ "$(calls)" -eq 0 ]'

total=$((pass + fail))
if [ "$fail" -eq 0 ]; then echo "ALL PASS ($total assertions)"; else echo "$fail of $total FAILED"; exit 1; fi
