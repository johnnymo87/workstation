#!/usr/bin/env bash
# unwired-test(workstation-oo4q): spawns real nvims and a real tmux server, and the suite itself builds the package under test (`nix build`, :53) -- the nested nix is the harder blocker; needs a ${self}-path seam. SKIPs-exit-0 without nvim (:46)
# Behavioural test for Step 3.4 -- the lgtm junk-drawer teardown (workstation-n0yh.1).
#
# WHY THIS EXISTS. `tmux kill-session` tears down every pane at once, and each
# pane's nvim writes ShaDa as it dies. Doing that BEFORE the serialized walk
# produced 3 concurrent writers on 2026-08-04, the same corruption precondition
# the walk was built to remove. The fix moved the teardown after the walk and put
# a serialized DRAIN in front of it. The 2026-08-05 production readout could not
# confirm any of that: no lgtm session existed at 03:00, so the teardown never
# ran and the clean night was a null result. This harness supplies the evidence
# production could not, by running the REAL extracted Step 3.4 against a lab.
#
# It is a DISCRIMINATION test. A test that only shows the fixed path is clean
# proves nothing unless the unfixed path, measured the same way, is dirty:
#   A (old ordering)  kill-session with live nvims      -> expect >1 concurrent
#   B (new ordering)  extracted Step 3.4 (drain first)  -> expect  1 concurrent
#
# SAFETY. Three independent layers, because this test drives tmux and signals
# processes, and an earlier version of the walk harness killed the user's real
# lgtm session by running extracted code that reached the real tmux server:
#   1. The lab runs its own tmux SERVER (`tmux -L <lab socket>`), so a
#      `kill-session -t '=lgtm'` inside it cannot see the user's sessions. The
#      session is named `lgtm` for fidelity -- the extracted code is unmodified.
#   2. `pgrep`/`pkill` are stubbed to lab-spawned pids only.
#   3. Cleanup kills by recorded pid, never by pattern, and the run aborts up
#      front if it cannot prove the stubs and the private server are in effect.
set -uo pipefail

fail=0
LAB="${TMPDIR:-/tmp}/reset-workspace-lgtm-test.$$"
TMUX_SOCK="lgtm-lab-$$"
NVIM_COUNT="${NVIM_COUNT:-3}"
LAB_PIDS=""
WATCH_PID=""

cleanup() {
  local p
  for p in ${LAB_PIDS:-}; do kill -9 "$p" 2>/dev/null || true; done
  [ -n "${WATCH_PID:-}" ] && kill "$WATCH_PID" 2>/dev/null || true
  command tmux -L "$TMUX_SOCK" kill-server 2>/dev/null || true
  rm -rf "$LAB" 2>/dev/null || true
}
trap cleanup EXIT

command -v nvim >/dev/null 2>&1        || { echo "SKIP: nvim not on PATH"; exit 0; }
command -v tmux >/dev/null 2>&1        || { echo "SKIP: tmux not on PATH"; exit 0; }
command -v inotifywait >/dev/null 2>&1 || { echo "SKIP: inotifywait not on PATH"; exit 0; }

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"

built="$(nix build --no-link --print-out-paths "$repo_root#reset-workspace" 2>/dev/null | tail -1)"
[ -n "$built" ] || { echo "FAIL: could not build reset-workspace"; exit 1; }
src="$built/bin/reset-workspace"
[ -f "$src" ] || { echo "FAIL: no reset-workspace binary at $src"; exit 1; }

# ---- Extract the real code ------------------------------------------------
funcs="$(awk '
  /^    nvim_writer_snapshot\(\) \{/ { on=1 }
  on { print }
  on && /^    nvim_writer_wait_gone\(\) \{/ { tail=1 }
  tail && /^    \}$/ { exit }
' "$src")"
# Step 3.4 runs from its banner to the socket reap (which globs the real /tmp
# and is deliberately left out of every lab).
teardown="$(awk '
  /^    # ---- Step 3\.4/ { on=1 }
  on && /^    # Reap orphan pane sockets/ { exit }
  on { print }
' "$src")"

[ -n "$funcs" ]    || { echo "FAIL: extraction 'funcs' empty -- source drifted"; exit 1; }
[ -n "$teardown" ] || { echo "FAIL: extraction 'teardown' empty -- source drifted"; exit 1; }
printf '%s\n' "$teardown" | grep -q "kill-session -t '=lgtm'" || { echo "FAIL: extracted teardown lacks the kill-session"; exit 1; }
printf '%s\n' "$teardown" | grep -q 'kill -TERM'              || { echo "FAIL: extracted teardown lacks the serialized drain"; exit 1; }
printf '%s\n' "$teardown" | grep -q 'sock_reaped'             && { echo "FAIL: extraction reached the real-/tmp socket reap"; exit 1; }
# The concurrency report lives past the reap and consumes the walk's own counter,
# which does not exist in this lab. If it drifts back inside the extraction the
# harness dies on an unbound variable -- fail with the reason instead.
printf '%s\n' "$teardown" | grep -q 'nvim_exited'             && { echo "FAIL: extraction reached shada_watch_report (needs the walk's counter)"; exit 1; }
echo "ok: extracted Step 3.4 (drain + teardown) from $src"

# ---- Lab -------------------------------------------------------------------
mkdir -p "$LAB/state/nvim/shada"
export XDG_STATE_HOME="$LAB/state"
SHADA_DIR="$LAB/state/nvim/shada"
SHADA_MAIN="$SHADA_DIR/main.shada"
SELF_ANCESTORS=" "
# Production always has a main.shada, and its presence is what makes nvim take
# the temp+rename path. Without it the first writer creates the file directly,
# no temp is ever observed, and every assertion below would pass vacuously.
seed_shada() {
  rm -f "$SHADA_DIR"/main.shada.tmp.* 2>/dev/null || true
  XDG_STATE_HOME="$LAB/state" nvim --headless -u NONE \
    -c 'call histadd(":", "SEEDMARKER")' -c 'wshada' -c 'qa!' >/dev/null 2>&1
  [ -f "$SHADA_MAIN" ]
}
DRAIN_SEEN=""
log() {
  case "$*" in *draining*) DRAIN_SEEN=1 ;; esac
  printf '    | %s\n' "$*"
}

# tmux stub: every call the extracted code makes goes to the LAB server. It also
# marks the watch log at the instant kill-session is invoked, which is what makes
# the key assertion deterministic instead of timing-dependent: any ShaDa write
# appearing AFTER that mark was caused by the teardown itself.
# shellcheck disable=SC2317
tmux() {
  case "$*" in
    *kill-session*) wc -l < "$LAB/watch.log" 2>/dev/null | tr -d ' ' > "$LAB/mark" ;;
  esac
  command tmux -L "$TMUX_SOCK" "$@"
}
export -f tmux 2>/dev/null || true

# CREATEs of a shada temp recorded after the kill-session mark.
writes_during_teardown() {
  local mark; mark="$(cat "$LAB/mark" 2>/dev/null || echo 0)"
  awk -v m="$mark" 'NR>m && /main\.shada\.tmp/ && $2 ~ /CREATE/ {n++} END {print n+0}' "$LAB/watch.log"
}

# Prove the private server is really private BEFORE anything destructive: the
# lab server must not know about any session the user's server has.
command tmux -L "$TMUX_SOCK" new-session -d -s lgtm -x 80 -y 24 "sleep 600" 2>/dev/null \
  || { echo "FAIL: could not start the lab tmux server"; exit 1; }
if command tmux -L "$TMUX_SOCK" has-session -t '=main' 2>/dev/null; then
  echo "FAIL: lab tmux server can see a 'main' session -- it is NOT isolated"; exit 1
fi
echo "ok: lab tmux server is isolated (own socket '$TMUX_SOCK')"

# Populate the lab `lgtm` session with real nvims, one per pane.
spawn_lab_session() {
  local i sock pid tries=0
  # Tear down the whole lab SERVER, not just the session. `lgtm` is its only
  # session, so killing the session kills the server, and the new-session that
  # immediately follows then races that shutdown -- "server exited unexpectedly",
  # which surfaced as the misleading "lab nvim 1 never listened". Kill
  # deliberately, wait for it to be gone, then retry the create. This harness
  # passed twice before hitting it; a flaky test is worse than no test.
  command tmux -L "$TMUX_SOCK" kill-server 2>/dev/null || true
  for _ in $(seq 1 30); do
    command tmux -L "$TMUX_SOCK" has-session -t '=lgtm' 2>/dev/null || break
    sleep 0.1
  done
  LAB_PIDS=""
  MARKERS=()
  until command tmux -L "$TMUX_SOCK" new-session -d -s lgtm -x 80 -y 24 "sleep 600" 2>/dev/null; do
    tries=$((tries+1))
    [ "$tries" -ge 15 ] && { echo "FAIL: lab tmux server would not start after $tries tries"; return 1; }
    sleep 0.3
  done
  # Re-assert isolation on every (re)start: a fresh server must still be blind to
  # the user's sessions before this test is allowed to kill anything.
  if command tmux -L "$TMUX_SOCK" has-session -t '=main' 2>/dev/null; then
    echo "FAIL: lab tmux server can see the user's 'main' session"; return 1
  fi
  for i in $(seq 1 "$NVIM_COUNT"); do
    sock="$LAB/nvim-$i-$RANDOM.sock"
    # Each pane hosts a real nvim. Killing the pane SIGHUPs it, and it writes
    # ShaDa on the way out -- the same "pane teardown causes a write" mechanism
    # as production, where the trigger is an embed server seeing client EOF.
    command tmux -L "$TMUX_SOCK" new-window -t '=lgtm' -d \
      "XDG_STATE_HOME='$XDG_STATE_HOME' nvim --headless --listen '$sock'" 2>/dev/null
    for _ in $(seq 1 80); do [ -S "$sock" ] && break; sleep 0.25; done
    [ -S "$sock" ] || { echo "FAIL: lab nvim $i never listened"; return 1; }
    pid="$(ss -xlp 2>/dev/null | grep -F "$sock" | sed -E 's/.*pid=([0-9]+).*/\1/' | head -1)"
    [ -n "$pid" ] || { echo "FAIL: could not find pid for lab nvim $i"; return 1; }
    LAB_PIDS="$LAB_PIDS$pid "
    MARKERS+=("LGTMMARKER_$i")
    nvim --server "$sock" --remote-expr "execute('call histadd(\":\", \"LGTMMARKER_$i\")')" >/dev/null 2>&1 || true
  done
  return 0
}

# Stubs: the drain must only ever see lab pids.
# shellcheck disable=SC2317
pgrep() {
  case "$*" in
    *"-x nvim"*) printf '%s\n' $LAB_PIDS ;;
    *) command pgrep "$@" ;;
  esac
}
# shellcheck disable=SC2317
pkill() {
  case "$*" in
    *"-x nvim"*) return 1 ;;
    *) echo "FAIL: unexpected pkill '$*'"; return 1 ;;
  esac
}
export -f pgrep pkill 2>/dev/null || true

# Max concurrent writers from an inotify log: CREATE of a temp opens a writer,
# MOVED_FROM/DELETE closes it. This is the same computation used on the
# production watch log, so lab and production numbers mean the same thing.
max_concurrent() {
  awk '
    /main\.shada\.tmp/ {
      if ($2 ~ /CREATE/)                        { live[$3]=1; n++; if (n>mx) mx=n }
      else if ($2 ~ /MOVED_FROM|DELETE/)        { if ($3 in live) { delete live[$3]; n-- } }
    }
    END { print mx+0 }
  ' "$1"
}
start_watch() {
  rm -f "$LAB/watch.log"
  setsid inotifywait -m --format '%T %e %f' --timefmt '%s' \
    -e create,delete,moved_from "$SHADA_DIR" > "$LAB/watch.log" 2>/dev/null &
  WATCH_PID=$!
  sleep 1
}
stop_watch() { sleep 1; kill "$WATCH_PID" 2>/dev/null || true; WATCH_PID=""; }

# ---- A: the OLD ordering -- kill-session with live nvims -------------------
# This is what Step 1.5 did. If this does NOT burst, the test proves nothing.
spawn_lab_session || exit 1
[ "$(pgrep -u dev -x nvim | wc -l)" -eq "$NVIM_COUNT" ] || { echo "FAIL: pgrep stub not in effect"; exit 1; }
echo "ok: lab 'lgtm' session has $NVIM_COUNT nvims [$LAB_PIDS]"
seed_shada || { echo "FAIL: could not seed main.shada"; exit 1; }
start_watch
tmux kill-session -t '=lgtm' 2>/dev/null || true
for _ in $(seq 1 40); do
  still=0
  for p in $LAB_PIDS; do kill -0 "$p" 2>/dev/null && still=1; done
  [ "$still" -eq 0 ] && break
  sleep 0.25
done
stop_watch
old_max="$(max_concurrent "$LAB/watch.log")"
old_writes="$(writes_during_teardown)"
# The deterministic property, and the one the fix is actually about: under the
# old ordering the teardown ITSELF makes every pane write. (Whether those writes
# happen to overlap is timing -- production saw 3 of 8 overlap; a small fast lab
# often serializes by luck. Overlap is therefore reported, not asserted.)
if [ "$old_writes" -gt 0 ]; then
  echo "ok: COUNTERFACTUAL -- the old ordering writes ShaDa $old_writes time(s) during the teardown (max concurrent $old_max)"
else
  echo "FAIL: the old ordering produced no writes at all; the lab does not"
  echo "      reproduce the mechanism, so a clean result below would be meaningless"
  fail=1
fi

# ---- B: the NEW ordering -- extracted Step 3.4 (drain, then teardown) ------
spawn_lab_session || exit 1
seed_shada || { echo "FAIL: could not seed main.shada"; exit 1; }
start_watch
t0=$(date +%s%3N)
# shellcheck disable=SC1090
eval "$funcs"
eval "$teardown"
t1=$(date +%s%3N)
stop_watch
new_max="$(max_concurrent "$LAB/watch.log")"
echo "ok: Step 3.4 completed in $((t1-t0))ms"

new_writes="$(writes_during_teardown)"
if [ "$new_max" -le 1 ]; then
  echo "ok: SERIALIZED -- Step 3.4 held max-concurrent at $new_max"
else
  echo "FAIL: Step 3.4 produced $new_max concurrent writers (invariant is 1)"; fail=1
fi
# THE claim: after the drain there is nothing left alive for kill-session to make
# write. Zero, not merely fewer.
if [ "$new_writes" -eq 0 ]; then
  echo "ok: SILENT TEARDOWN -- 0 ShaDa writes during kill-session (was $old_writes)"
else
  echo "FAIL: the teardown still caused $new_writes ShaDa write(s)"; fail=1
fi
if [ "$old_writes" -gt "$new_writes" ]; then
  echo "ok: DISCRIMINATION -- teardown writes $old_writes (old) vs $new_writes (new)"
else
  echo "FAIL: no discrimination (old=$old_writes, new=$new_writes)"; fail=1
fi

# The drain is the part production has never exercised: it must actually report
# work, not silently find nothing and pass for the wrong reason.
if [ -n "${DRAIN_SEEN:-}" ]; then
  echo "ok: the drain ran and reported late writers"
else
  echo "FAIL: no drain output -- Step 3.4 passed without exercising the drain"; fail=1
fi

# Every lab nvim must be gone, and the session with it.
alive=0
for p in $LAB_PIDS; do
  st="$(sed 's/.*) //' "/proc/$p/stat" 2>/dev/null | awk '{print $1}')"
  [ -n "$st" ] && [ "$st" != Z ] && alive=$((alive+1))
done
if [ "$alive" -eq 0 ]; then echo "ok: all $NVIM_COUNT lab nvims exited"
else echo "FAIL: $alive lab nvim(s) survived Step 3.4"; fail=1; fi
if command tmux -L "$TMUX_SOCK" has-session -t '=lgtm' 2>/dev/null; then
  echo "FAIL: the lab lgtm session survived the teardown"; fail=1
else
  echo "ok: the lgtm session was torn down"
fi

# Serialized exits must MERGE history, not clobber it (the S2 property, which
# the drain has to preserve).
if [ -f "$SHADA_MAIN" ]; then
  missing=""
  for m in "${MARKERS[@]}"; do
    strings "$SHADA_MAIN" 2>/dev/null | grep -q "$m" || missing="$missing $m"
  done
  if [ -z "$missing" ]; then
    echo "ok: ACCUMULATION -- all $NVIM_COUNT histories survived the drain"
  else
    echo "FAIL: history lost for:$missing"; fail=1
  fi
else
  echo "FAIL: no main.shada after the drain"; fail=1
fi

# ---- Safety postcondition --------------------------------------------------
if command tmux -L "$TMUX_SOCK" has-session -t '=main' 2>/dev/null; then
  echo "FAIL: lab server saw the user's 'main' session"; fail=1
fi
echo "ok: the user's tmux server was never addressed"

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit "$fail"
