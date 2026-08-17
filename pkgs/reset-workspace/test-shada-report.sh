#!/usr/bin/env bash
#
# Tests the reset's self-verifying ShaDa concurrency report (workstation-y3fq).
#
# WHY THIS EXISTS. The report is the only thing that will notice if a future edit
# re-introduces overlapping ShaDa writers, now that the hand-started inotify watch
# is retired. A measurement nobody has calibrated is decoration: S0 got its event
# filter wrong twice, in two different ways, and each time the wrong filter
# produced a plausible-looking number. So this drives the REAL extracted function
# with event streams whose correct answer is known by construction.
#
# It deliberately does NOT try to manufacture real concurrency by racing nvims.
# That was measured and rejected: three lab nvims serialize by luck more often
# than not (production saw only 3 of 8 writers overlap), so a race-based test
# would be flaky in the direction that matters -- passing when it should fail.
set -uo pipefail

fail=0
LAB="${TMPDIR:-/tmp}/reset-shada-report-test.$$"
mkdir -p "$LAB"
cleanup() { [ -n "${DUMMY_PID:-}" ] && kill "$DUMMY_PID" 2>/dev/null; rm -rf "$LAB" 2>/dev/null || true; }
trap cleanup EXIT

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
# Seam: a check passes the ALREADY-BUILT artifact so this suite never invokes
# nix itself (impossible in a build sandbox). Falls back to building, so a
# local run with no seam set behaves exactly as before.
if [ -n "${RESET_WORKSPACE_BIN:-}" ]; then
  src="$RESET_WORKSPACE_BIN"
else
  built="$(nix build --no-link --print-out-paths "$repo_root#reset-workspace" 2>/dev/null | tail -1)"
  [ -n "$built" ] || { echo "FAIL: could not build reset-workspace"; exit 1; }
  src="$built/bin/reset-workspace"
fi
[ -r "$src" ] || { echo "FAIL: reset-workspace not readable: $src"; exit 1; }

# Extract shada_watch_report verbatim.
report_fn="$(awk '
  /^    shada_watch_report\(\) \{/ { on=1 }
  on { print }
  on && /^    \}$/ && !/\(\) \{/ { exit }
' "$src")"
[ -n "$report_fn" ] || { echo "FAIL: could not extract shada_watch_report -- source drifted"; exit 1; }
printf '%s\n' "$report_fn" | grep -q 'main\\.shada\\.tmp' || { echo "FAIL: extracted report does not filter on shada temps"; exit 1; }
echo "ok: extracted shada_watch_report from $src"

# Harness scaffolding the extracted function expects.
OUT=""
log() { OUT="$OUT$*"$'\n'; }
SHADA_WATCH_LOG=""
SHADA_WATCH_PID=""
eval "$report_fn"

# A live process so the function's kill/wait path is exercised rather than skipped.
new_dummy() { sleep 30 & DUMMY_PID=$!; SHADA_WATCH_PID=$DUMMY_PID; }

run_case() {
  # run_case <name> <expected_writers> <events...>  -> sets OUT
  local name="$1" expected="$2"; shift 2
  OUT=""
  SHADA_WATCH_LOG="$LAB/events.$RANDOM"
  : > "$SHADA_WATCH_LOG"
  local e
  for e in "$@"; do printf '%s\n' "$e" >> "$SHADA_WATCH_LOG"; done
  new_dummy
  shada_watch_report "$expected"
  printf '%s' "$name" >/dev/null
}
want() {
  local what="$1" pat="$2"
  if printf '%s' "$OUT" | grep -q "$pat"; then
    echo "ok: $what"
  else
    echo "FAIL: $what"
    printf '%s' "$OUT" | sed 's/^/       got: /'
    fail=1
  fi
}

# ---- 1. THE BURST. Three temps created before any is renamed away. This is the
#         corruption precondition, and the number the whole epic turns on.
run_case burst 3 \
  '03:00:03 CREATE main.shada.tmp.a' \
  '03:00:03 CREATE main.shada.tmp.b' \
  '03:00:03 CREATE main.shada.tmp.c' \
  '03:00:03 MOVED_FROM main.shada.tmp.a' \
  '03:00:03 MOVED_FROM main.shada.tmp.b' \
  '03:00:03 MOVED_FROM main.shada.tmp.c'
want "a 3-writer burst is reported as 3, not 1" 'max concurrent shada writers: 3'
want "a burst is flagged as a BROKEN invariant"  'BROKEN'
want "a burst dumps the raw events for forensics" 'CREATE main.shada.tmp.b'

# ---- 2. THE SERIALIZED CASE. Same six events, interleaved as the walk produces
#         them. Identical event COUNT to case 1 -- only the order differs, which
#         is exactly what a naive "count the temps" implementation would miss.
run_case serial 3 \
  '03:00:05 CREATE main.shada.tmp.a' \
  '03:00:05 MOVED_FROM main.shada.tmp.a' \
  '03:00:05 CREATE main.shada.tmp.a' \
  '03:00:05 MOVED_FROM main.shada.tmp.a' \
  '03:00:05 CREATE main.shada.tmp.a' \
  '03:00:05 MOVED_FROM main.shada.tmp.a'
want "serialized writes report max 1"          'max concurrent shada writers: 1'
want "serialized writes are not flagged broken" 'invariant holds'
if printf '%s' "$OUT" | grep -q 'BROKEN'; then echo "FAIL: serialized run was flagged BROKEN"; fail=1; fi

# ---- 3. THE DEAD INSTRUMENT. Writers exited, watch saw nothing. This is the
#         false-quiet trap that a standalone daemon cannot detect at all.
run_case dead 7
want "writers with no events reports UNKNOWN"   'unknown'
want "the dead instrument is named as dead"     'instrument is dead'
if printf '%s' "$OUT" | grep -q 'max concurrent shada writers: 0'; then
  echo "FAIL: a dead watch reported a reassuring max of 0"; fail=1
fi

# ---- 4. THE LEGITIMATELY QUIET RUN. No writers exited, so no events is correct
#         and must NOT raise the dead-instrument alarm.
run_case quiet 0
if printf '%s' "$OUT" | grep -q 'instrument is dead'; then
  echo "FAIL: a legitimately quiet run was called a dead instrument"; fail=1
else
  echo "ok: a quiet run with zero writers is not an alarm"
fi

# ---- 5. NO WATCHER AT ALL (inotifywait missing). Must be unknown, never clean.
OUT=""; SHADA_WATCH_PID=""; SHADA_WATCH_LOG=""
shada_watch_report 5
want "a missing watcher reports unknown" 'unknown'

# ---- 6. DELETE closes a window too. nvim unlinks main.shada between temps, and
#         an implementation that only handled MOVED_FROM would leak the count
#         upward and cry wolf on a clean night.
# The second window MUST use a different temp name. With the same name twice,
# an implementation that ignores DELETE still reports 1 -- the second CREATE
# finds the name already live and does not re-count -- so this case passed
# even with the DELETE branch deleted from production. Measured, not supposed:
# mutating `$2 ~ /MOVED_FROM|DELETE/` to `$2 ~ /MOVED_FROM/` left all 12
# assertions green. Distinct names make the leak observable as max=2.
run_case delete_close 2 \
  '03:00:05 CREATE main.shada.tmp.a' \
  '03:00:05 DELETE main.shada.tmp.a' \
  '03:00:05 CREATE main.shada.tmp.b' \
  '03:00:05 DELETE main.shada.tmp.b'
want "DELETE closes a writer window as well as MOVED_FROM" 'max concurrent shada writers: 1'

# ---- 7. NOISE IMMUNITY. Events for the real file and for unrelated names must
#         not be counted as writers.
run_case noise 1 \
  '03:00:05 CREATE main.shada' \
  '03:00:05 DELETE main.shada' \
  '03:00:05 CREATE some-other-file' \
  '03:00:05 CREATE main.shada.tmp.a' \
  '03:00:05 MOVED_FROM main.shada.tmp.a'
want "only shada temps count as writers" 'max concurrent shada writers: 1'

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit "$fail"
