#!/usr/bin/env bash
# Tests for pkgs/goose-link (bead workstation-6w7i.27.2, L6).
# Usage: GOOSE_LINK_BIN=<pkg>/bin/goose-link bash test.sh
set -uo pipefail

: "${GOOSE_LINK_BIN:?set GOOSE_LINK_BIN to <pkg>/bin/goose-link}"

pass=0
fail=0
ok() { echo "ok   - $1"; pass=$((pass + 1)); }
bad() { echo "FAIL - $1"; fail=$((fail + 1)); }
check() { # name expected actual
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Fake store paths: <p>/bin/goose is a real ELF executable (a copy of bash;
# coreutils may be one multi-call binary that keys on its name), because
# goose-link refuses anything that is not ELF.
echo_elf="$(readlink -f "$(type -P bash)")"
mkgoose() {
  mkdir -p "$tmp/store/$1/bin"
  cp "$echo_elf" "$tmp/store/$1/bin/goose"
  chmod +x "$tmp/store/$1/bin/goose"
}
mkgoose g18
mkgoose g60
mkgoose g61
mkdir -p "$tmp/store/notgoose"
# What the profile's `goose` is after L6: a script exec'ing the link.
mkdir -p "$tmp/store/wrapper/bin"
printf '#!/bin/sh\nexec /var/lib/goose/current/bin/goose "$@"\n' > "$tmp/store/wrapper/bin/goose"
chmod +x "$tmp/store/wrapper/bin/goose"
mkgoose_outside() { mkdir -p "$tmp/elsewhere/bin"; cp "$echo_elf" "$tmp/elsewhere/bin/goose"; }
mkgoose_outside

export GOOSE_LINK_DIR="$tmp/var"
export GOOSE_PINNED="$tmp/etc-pinned"
export GOOSE_LINK_STORE="$tmp/store"
mkdir -p "$GOOSE_LINK_DIR"
L() { "$GOOSE_LINK_BIN" "$@"; }
tgt() { readlink "$GOOSE_LINK_DIR/$1" 2>/dev/null || echo "<none>"; }

# --- status with nothing set: says so, fails (nothing to run) ---
out="$(L status 2>&1)"; rc=$?
check "status with no current link exits 1" "1" "$rc"
grep -q 'current=<none>' <<<"$out" && ok "status names a missing current" || bad "status names a missing current ($out)"

# --- set: refuses a path without an executable bin/goose ---
out="$(L set "$tmp/store/notgoose" 2>&1)"; rc=$?
check "set refuses a path with no bin/goose" "2" "$rc"
check "refused set leaves current unset" "<none>" "$(tgt current)"

out="$(L set "relative/path" 2>&1)"; rc=$?
check "set refuses a relative path" "2" "$rc"

out="$(L set "$tmp/store/wrapper" 2>&1)"; rc=$?
check "set refuses a wrapper script (would loop through the link)" "2" "$rc"
grep -q 'not an ELF' <<<"$out" && ok "wrapper refusal says not an ELF" || bad "wrapper refusal says not an ELF ($out)"

out="$(L set "$tmp/elsewhere" 2>&1)"; rc=$?
check "set refuses a path outside the store" "2" "$rc"
check "refusals leave current unset" "<none>" "$(tgt current)"

# --- first set: current only, no previous ---
L set "$tmp/store/g18" >/dev/null; rc=$?
check "first set exits 0" "0" "$rc"
check "first set points current" "$tmp/store/g18" "$(tgt current)"
check "first set leaves no previous" "<none>" "$(tgt previous)"
check "current/bin/goose execs through the link" "hello g18" "$("$GOOSE_LINK_DIR/current/bin/goose" -c 'echo hello g18')"

# --- set to the same path: no-op, previous untouched ---
out="$(L set "$tmp/store/g18" 2>&1)"; rc=$?
check "set to current is a no-op (exit 0)" "0" "$rc"
check "no-op set leaves previous unset" "<none>" "$(tgt previous)"
grep -q 'already' <<<"$out" && ok "no-op set says already current" || bad "no-op set says already current ($out)"

# --- trailing slash and a symlinked path resolve to the same store path ---
ln -s "$tmp/store/g60" "$tmp/alias60"
L set "$tmp/alias60/" >/dev/null
check "set resolves symlinks and trailing slash" "$tmp/store/g60" "$(tgt current)"
check "set moves the old current to previous" "$tmp/store/g18" "$(tgt previous)"

# --- links are symlinks, never directories (mv -T, not into) ---
[ -L "$GOOSE_LINK_DIR/current" ] && ok "current is a symlink" || bad "current is a symlink"
[ -L "$GOOSE_LINK_DIR/previous" ] && ok "previous is a symlink" || bad "previous is a symlink"
check "no stray temp links left behind" "" "$(find "$GOOSE_LINK_DIR" -name '.goose-link.*' | tr '\n' ' ')"

# --- rollback swaps current and previous ---
L rollback >/dev/null; rc=$?
check "rollback exits 0" "0" "$rc"
check "rollback restores previous as current" "$tmp/store/g18" "$(tgt current)"
check "rollback keeps the rolled-back target as previous" "$tmp/store/g60" "$(tgt previous)"
L rollback >/dev/null
check "a second rollback rolls forward again" "$tmp/store/g60" "$(tgt current)"

# --- rollback refuses when previous is missing or dangling ---
rm "$GOOSE_LINK_DIR/previous"
out="$(L rollback 2>&1)"; rc=$?
check "rollback with no previous exits 1" "1" "$rc"
check "failed rollback leaves current alone" "$tmp/store/g60" "$(tgt current)"
ln -s "$tmp/store/gone" "$GOOSE_LINK_DIR/previous"
out="$(L rollback 2>&1)"; rc=$?
check "rollback to a dangling previous exits 1" "1" "$rc"
check "dangling rollback leaves current alone" "$tmp/store/g60" "$(tgt current)"
rm "$GOOSE_LINK_DIR/previous"

# --- pinned: sets current to what /etc/goose/pinned resolves to ---
ln -s "$tmp/store/g61" "$GOOSE_PINNED"
L pinned >/dev/null; rc=$?
check "pinned exits 0" "0" "$rc"
check "pinned sets current to the pinned target" "$tmp/store/g61" "$(tgt current)"
check "pinned moves old current to previous" "$tmp/store/g60" "$(tgt previous)"
rm "$GOOSE_PINNED"
out="$(L pinned 2>&1)"; rc=$?
check "pinned with no pinned link exits 2" "2" "$rc"

# --- status: all three, exit 0, and flags current != pinned ---
ln -s "$tmp/store/g18" "$GOOSE_PINNED"
out="$(L status)"; rc=$?
check "status exits 0 with a runnable current" "0" "$rc"
grep -q "^current=$tmp/store/g61\$" <<<"$out" && ok "status prints current" || bad "status prints current ($out)"
grep -q "^previous=$tmp/store/g60\$" <<<"$out" && ok "status prints previous" || bad "status prints previous ($out)"
grep -q "^pinned=$tmp/store/g18\$" <<<"$out" && ok "status prints pinned" || bad "status prints pinned ($out)"
grep -q '^pinned_is_current=no$' <<<"$out" && ok "status flags pin != current" || bad "status flags pin != current ($out)"
L set "$tmp/store/g18" >/dev/null
grep -q '^pinned_is_current=yes$' < <(L status) && ok "status flags pin == current" || bad "status flags pin == current"

# --- usage ---
out="$(L bogus 2>&1)"; rc=$?
check "unknown subcommand exits 2" "2" "$rc"
out="$(L 2>&1)"; rc=$?
check "no subcommand exits 2" "2" "$rc"

echo "goose-link: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
