#!/usr/bin/env bash
# Tests for hosts/devbox/credo-diff-sweep.sh, against a scratch directory.
# shellcheck disable=SC2016,SC2034  # check() evals its single-quoted assertions
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
pass=0; fail=0
check() { if eval "$2"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; fi; }

bash_bin=$(command -v bash)
bin=$(mktemp)
trap 'rm -f "$bin"' EXIT
{ echo "#!$bash_bin"; echo 'set -euo pipefail'; cat "$here/credo-diff-sweep.sh"; } >"$bin"; chmod +x "$bin"

# NOW = 2026-10-16 12:00:00 UTC
NOW=$(date -u -d '2026-10-16 12:00:00' +%s)
S=$(mktemp -d)
export CREDO_SWEEP_DIR=$S CREDO_SWEEP_MAX_AGE_MIN=360 CREDO_SWEEP_NOW=$NOW
mk() { mkdir -p "$S/$1/lib"; echo x >"$S/$1/lib/a.ex"; }

mk credo-diff-20261016050000123456   # 7h old by name  -> removed
mk credo-diff-20261016070000123456   # 5h old by name  -> kept
mk credo-diff-20261014000000000000   # 2.5d old        -> removed
# Name says old, but atime/mtime are fresh: the name wins.
touch "$S/credo-diff-20261014000000000000/lib/a.ex"
mk credo-diff-weird; touch -d '2026-10-16 02:00:00 UTC' "$S/credo-diff-weird"   # no ts, 10h-old mtime -> removed
mk credo-diff-weird2                                                           # no ts, fresh mtime  -> kept
mk unrelated-20261001000000                                                    # not ours            -> kept
mkdir -p "$S/target"; echo keep >"$S/target/f"
ln -s "$S/target" "$S/credo-diff-20261001000000000000"                         # symlink             -> kept, target intact

out=$("$bin")
check "7h-old removed" '[ ! -e "$S/credo-diff-20261016050000123456" ]'
check "5h-old kept" '[ -d "$S/credo-diff-20261016070000123456" ]'
check "old by name removed despite fresh file times" '[ ! -e "$S/credo-diff-20261014000000000000" ]'
check "unparseable name: old mtime removed" '[ ! -e "$S/credo-diff-weird" ]'
check "unparseable name: fresh mtime kept" '[ -d "$S/credo-diff-weird2" ]'
check "non-matching dir kept" '[ -d "$S/unrelated-20261001000000" ]'
check "symlink not followed or removed" '[ -L "$S/credo-diff-20261001000000000000" ] && [ -f "$S/target/f" ]'
check "summary counts 3" 'grep -q "removed 3 checkout" <<<"$out"'

# An undeletable old checkout is reported and does not stop the rest.
F=$(mktemp -d)
mkdir -p "$F/credo-diff-20261001000000000000/locked" "$F/credo-diff-20261002000000000000"
echo x >"$F/credo-diff-20261001000000000000/locked/f"; chmod 555 "$F/credo-diff-20261001000000000000/locked"
if CREDO_SWEEP_DIR=$F "$bin" >/dev/null; then rc=0; else rc=$?; fi
chmod 755 "$F/credo-diff-20261001000000000000/locked"
check "undeletable checkout: non-zero exit" '[ "$rc" -ne 0 ]'
check "undeletable checkout: later checkout still removed" '[ ! -e "$F/credo-diff-20261002000000000000" ]'
rm -rf "$F"

# Empty directory: no error.
E=$(mktemp -d)
if CREDO_SWEEP_DIR=$E "$bin" >/dev/null; then rc=0; else rc=$?; fi
check "nothing to sweep: exit 0" '[ "$rc" -eq 0 ]'
rm -rf "$S" "$E"

total=$((pass + fail))
if [ "$fail" -eq 0 ]; then echo "ALL PASS ($total assertions)"; else echo "$fail of $total FAILED"; exit 1; fi
