#!/usr/bin/env bash
# Behavioural acceptance test for Step 3's serialized nvim exit walk.
#
# The static suite (test.sh) greps the source; this one RUNS it. It extracts the
# real walk out of the built script and drives it against a lab of throwaway
# nvims, with an inotify watch on a scratch ShaDa dir, and asserts the two things
# the design claims:
#
#   1. SERIALIZATION -- no two writers are ever mid-write at once, i.e. no
#      writer's unlink..rename window overlaps another's. This is the corruption
#      fix, and it is the property the 2026-08-03 watch showed violated three
#      times in one second under `pkill -9`.
#   2. ACCUMULATION -- every lab nvim's history survives into the final file.
#      This is the history-loss fix. Absence of a crash is NOT the bar: the old
#      code also "worked" while silently keeping only the last writer's history.
#
# Why extraction rather than a reimplementation: a reimplemented walk tests the
# reimplementation. The regions below are pulled out of the real source by
# sentinel, so if the source drifts the extraction fails loudly instead of
# silently testing nothing.
#
# SAFETY -- this host has real nvim sessions belonging to a human. The walk calls
# `pgrep -u dev -x nvim` and `pkill -9 -u dev -x nvim`, which would take every
# one of them. Both are STUBBED to a lab-only pid set before the extracted code
# is sourced, and the stubs are asserted to be in effect. Never run this file
# without them.
set -uo pipefail

fail=0
LAB="${TMPDIR:-/tmp}/reset-workspace-walk-test.$$"
NVIM_COUNT="${NVIM_COUNT:-6}"

cleanup() {
  # Kill only pids we spawned, by pid, never by pattern.
  local p
  for p in ${LAB_PIDS:-}; do kill -9 "$p" 2>/dev/null || true; done
  [ -n "${WATCH_PID:-}" ] && kill "$WATCH_PID" 2>/dev/null || true
  rm -rf "$LAB" 2>/dev/null || true
}
trap cleanup EXIT

command -v nvim >/dev/null 2>&1 || { echo "SKIP: nvim not on PATH"; exit 0; }
command -v inotifywait >/dev/null 2>&1 || { echo "SKIP: inotifywait not on PATH"; exit 0; }

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"

# ---- Build the script and locate the generated bash ------------------------
built="$(nix build --no-link --print-out-paths "$repo_root#reset-workspace" 2>/dev/null | tail -1)"
[ -n "$built" ] || { echo "FAIL: could not build reset-workspace"; exit 1; }
src="$built/bin/reset-workspace"
[ -f "$src" ] || { echo "FAIL: no reset-workspace binary at $src"; exit 1; }

# ---- Extract the walk from the real source, by sentinel --------------------
# snapshot() is followed by live() and wait_gone(); grab through wait_gone's close
funcs="$(awk '
  /^    nvim_writer_snapshot\(\) \{/ { on=1 }
  on { print }
  on && /^    nvim_writer_wait_gone\(\) \{/ { tail=1 }
  tail && /^    \}$/ { exit }
' "$src")"
# Stop BEFORE the lgtm teardown (Step 3.4) and the orphan-socket reap. Both act
# on real, outside-the-lab state: the reap globs the real /tmp/nvim-*.sock, and
# the teardown drives the real tmux server. Only `pgrep`/`pkill` are stubbed, so
# an extraction that runs past here kills the user's actual lgtm session -- which
# is exactly what happened when Step 3.4 was first inserted between the sweep and
# the reap and silently landed inside this extraction. Both blocks are asserted
# statically in test.sh instead.
walk="$(awk '
  /^    SELF_ANCESTORS=" "$/ { on=1 }
  on && /^    # ---- Step 3\.4/ { exit }
  on && /^    # Reap orphan pane sockets/ { exit }
  on { print }
' "$src")"

for name in funcs walk; do
  eval "body=\$$name"
  [ -n "$body" ] || { echo "FAIL: extraction '$name' came back empty -- source drifted"; exit 1; }
done
printf '%s\n' "$funcs" | grep -q 'state" = Z' || { echo "FAIL: extracted funcs lack the zombie guard"; exit 1; }
printf '%s\n' "$walk"  | grep -q 'kill -TERM' || { echo "FAIL: extracted walk lacks kill -TERM"; exit 1; }
printf '%s\n' "$walk"  | grep -q 'pkill -9 -u dev -x nvim' || { echo "FAIL: extracted walk lacks the sweep"; exit 1; }
printf '%s\n' "$walk"  | grep -q 'sock_reaped' && { echo "FAIL: extraction includes the real-/tmp socket reap"; exit 1; }
# tmux is NOT stubbed here, so any tmux call in the extracted body would hit the
# user's real server. This guard is the one that was missing when Step 3.4 was
# added; it cost a live lgtm session to learn.
printf '%s\n' "$walk"  | grep -q 'tmux ' && { echo "FAIL: extraction includes a real tmux command"; exit 1; }
echo "ok: extracted the real walk from $src"

# ---- Lab -------------------------------------------------------------------
mkdir -p "$LAB/state/nvim/shada"
export XDG_STATE_HOME="$LAB/state"
SHADA_DIR="$LAB/state/nvim/shada"
SHADA_MAIN="$SHADA_DIR/main.shada"

LAB_PIDS=""
declare -a MARKERS=()
for i in $(seq 1 "$NVIM_COUNT"); do
  sock="$LAB/nvim-$i.sock"
  setsid nvim --headless --listen "$sock" </dev/null >/dev/null 2>&1 &
  for _ in $(seq 1 80); do [ -S "$sock" ] && break; sleep 0.25; done
  [ -S "$sock" ] || { echo "FAIL: lab nvim $i never listened"; exit 1; }
  pid="$(ss -xlp 2>/dev/null | grep -F "$sock" | sed -E 's/.*pid=([0-9]+).*/\1/' | head -1)"
  [ -n "$pid" ] || { echo "FAIL: could not find pid for lab nvim $i"; exit 1; }
  LAB_PIDS="$LAB_PIDS$pid "
  m="WALKMARKER_$i"
  MARKERS+=("$m")
  nvim --server "$sock" --remote-expr "execute('call histadd(\":\", \"$m\")')" >/dev/null 2>&1 || true
done
echo "ok: lab has $NVIM_COUNT nvims [$LAB_PIDS]"

# ---- Stubs: the walk must only ever see the lab --------------------------
# shellcheck disable=SC2317
pgrep() {
  # Only answer the walk's own query shape; anything else is a bug in the test.
  case "$*" in
    *"-x nvim"*) printf '%s\n' $LAB_PIDS ;;
    *) command pgrep "$@" ;;
  esac
}
PKILL_CALLED=0
# shellcheck disable=SC2317
pkill() {
  case "$*" in
    *"-x nvim"*) PKILL_CALLED=1; return 1 ;;   # rc=1: "nothing left", the happy path
    *) echo "FAIL: unexpected pkill '$*'"; return 1 ;;
  esac
}
export -f pgrep pkill 2>/dev/null || true
[ "$(pgrep -u dev -x nvim | wc -l)" -eq "$NVIM_COUNT" ] || { echo "FAIL: pgrep stub not in effect"; exit 1; }
echo "ok: pgrep/pkill stubbed to the lab only ($(pgrep -u dev -x nvim | wc -l) pids)"

log() { printf '    | %s\n' "$*"; }
update_sentinel() { :; }

# ---- Watch the shada dir so we can prove serialization --------------------
WATCH_LOG="$LAB/watch.log"
setsid inotifywait -m --format '%T %e %f' --timefmt '%s' \
  -e create,delete,modify,moved_to,moved_from "$SHADA_DIR" \
  > "$WATCH_LOG" 2>/dev/null &
WATCH_PID=$!
sleep 1

# ---- Run the extracted walk ----------------------------------------------
t0=$(date +%s%3N)
# shellcheck disable=SC1090
eval "$funcs"
eval "$walk"
t1=$(date +%s%3N)
echo "ok: walk completed in $((t1-t0))ms"
sleep 1
kill "$WATCH_PID" 2>/dev/null || true

# ---- Assertion 1: every lab nvim is gone ---------------------------------
alive=0
for p in $LAB_PIDS; do
  st="$(sed 's/.*) //' "/proc/$p/stat" 2>/dev/null | awk '{print $1}')"
  [ -n "$st" ] && [ "$st" != Z ] && alive=$((alive+1))
done
if [ "$alive" -eq 0 ]; then echo "ok: all $NVIM_COUNT lab nvims exited"
else echo "FAIL: $alive lab nvim(s) still alive after the walk"; fail=1; fi

# ---- Assertion 2: ACCUMULATION -- every marker survived ------------------
if [ -f "$SHADA_MAIN" ]; then
  missing=""
  for m in "${MARKERS[@]}"; do
    strings "$SHADA_MAIN" 2>/dev/null | grep -q "$m" || missing="$missing $m"
  done
  if [ -z "$missing" ]; then
    echo "ok: ACCUMULATION -- all $NVIM_COUNT histories present in the final main.shada"
  else
    echo "FAIL: history lost for:$missing"
    echo "      (this is the nightly-loss bug the walk is supposed to fix)"; fail=1
  fi
else
  echo "FAIL: no main.shada after the walk"; fail=1
fi

# ---- Assertion 3: SERIALIZATION -- no overlapping unlink windows ---------
# A window opens at DELETE main.shada and closes at MOVED_TO main.shada. Two
# writers overlap if a second writer's tmp CREATE lands inside another's window,
# or if two DELETEs occur with no intervening MOVED_TO.
overlaps=$(awk '
  $2 ~ /DELETE/ && $3 == "main.shada" { if (open) { bad++ } ; open=1 ; next }
  $2 ~ /MOVED_TO/ && $3 == "main.shada" { open=0 ; next }
  END { print bad+0 }
' "$WATCH_LOG")
windows=$(grep -c 'DELETE main.shada' "$WATCH_LOG" 2>/dev/null || echo 0)
if [ "$overlaps" -eq 0 ]; then
  echo "ok: SERIALIZATION -- $windows unlink window(s), 0 overlapping"
else
  echo "FAIL: $overlaps overlapping unlink window(s) -- writers were concurrent"; fail=1
fi

# ---- Assertion 4: the walk did reach the sweep ---------------------------
if [ "$PKILL_CALLED" -eq 1 ]; then echo "ok: sweep ran (clients would have been reaped)"
else echo "FAIL: the client sweep never ran"; fail=1; fi

# ---- Assertion 5: this test can actually FAIL (discrimination) -----------
# Re-run the lab under the OLD behaviour (one concurrent pkill -9) and require
# that at least one of the two invariants breaks. A test that passes either way
# proves nothing -- three fixes shipped here on exactly that mistake.
mkdir -p "$LAB/state-old/nvim/shada"
OLD_STATE="$LAB/state-old"
OLD_PIDS=""
declare -a OLD_MARKERS=()
for i in $(seq 1 "$NVIM_COUNT"); do
  sock="$LAB/old-$i.sock"
  XDG_STATE_HOME="$OLD_STATE" setsid nvim --headless --listen "$sock" </dev/null >/dev/null 2>&1 &
  for _ in $(seq 1 80); do [ -S "$sock" ] && break; sleep 0.25; done
  pid="$(ss -xlp 2>/dev/null | grep -F "$sock" | sed -E 's/.*pid=([0-9]+).*/\1/' | head -1)"
  OLD_PIDS="$OLD_PIDS$pid "
  m="OLDMARKER_$i"; OLD_MARKERS+=("$m")
  nvim --server "$sock" --remote-expr "execute('call histadd(\":\", \"$m\")')" >/dev/null 2>&1 || true
done
# The old behaviour: SIGTERM them all at once (a faithful stand-in for the burst
# `pkill -9` produced via client-EOF, without needing TUI clients in the lab).
for p in $OLD_PIDS; do kill -TERM "$p" 2>/dev/null || true; done
for _ in $(seq 1 100); do
  still=0
  for p in $OLD_PIDS; do kill -0 "$p" 2>/dev/null && still=1; done
  [ "$still" -eq 0 ] && break
  sleep 0.1
done
old_missing=0
for m in "${OLD_MARKERS[@]}"; do
  strings "$OLD_STATE/nvim/shada/main.shada" 2>/dev/null | grep -q "$m" || old_missing=$((old_missing+1))
done
for p in $OLD_PIDS; do kill -9 "$p" 2>/dev/null || true; done
if [ "$old_missing" -gt 0 ]; then
  echo "ok: DISCRIMINATION -- concurrent exits lose $old_missing/$NVIM_COUNT histories, serialized lose 0"
else
  echo "FAIL: concurrent exits lost nothing, so this test cannot tell the fix from the bug"
  echo "      (accumulation assertion above is not discriminating on this host)"; fail=1
fi

# ---- Assertion 6: straggler escalation (a PROVABLE wedge) ----------------
# A SIGSTOPped process cannot act on SIGTERM, so it is a deterministic straggler.
# Asserts: the walk gives up after its budget, SIGKILLs, does NOT hang, and the
# other writers in the same round still exit gracefully.
mkdir -p "$LAB/state-wedge/nvim/shada"
WEDGE_STATE="$LAB/state-wedge"
LAB_PIDS=""   # reuse the stub, new lab
declare -a W_MARKERS=()
WEDGED=""
for i in 1 2 3; do
  sock="$LAB/wedge-$i.sock"
  XDG_STATE_HOME="$WEDGE_STATE" setsid nvim --headless --listen "$sock" </dev/null >/dev/null 2>&1 &
  for _ in $(seq 1 80); do [ -S "$sock" ] && break; sleep 0.25; done
  pid="$(ss -xlp 2>/dev/null | grep -F "$sock" | sed -E 's/.*pid=([0-9]+).*/\1/' | head -1)"
  [ -n "$pid" ] || { echo "FAIL: wedge lab nvim $i never listened"; fail=1; break; }
  LAB_PIDS="$LAB_PIDS$pid "
  m="WEDGEMARKER_$i"; W_MARKERS+=("$m")
  nvim --server "$sock" --remote-expr "execute('call histadd(\":\", \"$m\")')" >/dev/null 2>&1 || true
  [ "$i" -eq 2 ] && WEDGED="$pid"
done
if [ -n "$WEDGED" ]; then
  kill -STOP "$WEDGED" 2>/dev/null || true
  st="$(sed 's/.*) //' "/proc/$WEDGED/stat" 2>/dev/null | awk '{print $1}')"
  if [ "$st" = T ]; then
    echo "ok: writer $WEDGED is genuinely wedged (state T, cannot act on SIGTERM)"
    SHADA_DIR="$WEDGE_STATE/nvim/shada"; SHADA_MAIN="$SHADA_DIR/main.shada"
    export XDG_STATE_HOME="$WEDGE_STATE"
    wt0=$(date +%s%3N); eval "$walk"; wt1=$(date +%s%3N)
    elapsed=$((wt1-wt0))
    # 3s TERM budget + 1s KILL budget for the one wedged writer, and the walk
    # re-snapshots for up to 3 rounds; generous ceiling, but must not be unbounded.
    if [ "$elapsed" -lt 30000 ]; then
      echo "ok: walk bounded the wedged writer (${elapsed}ms, did not hang)"
    else
      echo "FAIL: walk took ${elapsed}ms on one wedged writer -- effectively unbounded"; fail=1
    fi
    wedge_alive=0
    for p in $LAB_PIDS; do
      pst="$(sed 's/.*) //' "/proc/$p/stat" 2>/dev/null | awk '{print $1}')"
      [ -n "$pst" ] && [ "$pst" != Z ] && wedge_alive=$((wedge_alive+1))
    done
    if [ "$wedge_alive" -eq 0 ]; then
      echo "ok: wedged writer was SIGKILLed and the round completed"
    else
      echo "FAIL: $wedge_alive writer(s) survived the wedge round"; fail=1
    fi
    # The two healthy writers must still have persisted; only the wedged one's
    # history is forfeit (that is the documented trade).
    kept=0
    for m in "${W_MARKERS[@]}"; do
      strings "$WEDGE_STATE/nvim/shada/main.shada" 2>/dev/null | grep -q "$m" && kept=$((kept+1))
    done
    if [ "$kept" -ge 2 ]; then
      echo "ok: $kept/3 histories kept despite the wedge (only the wedged writer's is forfeit)"
    else
      echo "FAIL: only $kept/3 histories survived the wedge round"; fail=1
    fi
  else
    echo "SKIP: could not wedge a writer (state '$st')"
  fi
fi

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "SOME TESTS FAILED"
exit "$fail"
