#!/usr/bin/env bash
# serve-distribution-probe.sh — §7a GO/NO-GO gate for placement-at-create
# (workstation-iwpj / lgtm-a3r).
#
# NOTE: This diagnostic exercises the front door via opencode-launch, but its
# per-port and /route inspection is intentional (diagnostic/monitoring probe,
# not a client to repoint).
#
# Validates that opencode-launch sessions are PLACED across the serve pool
# (HRW via pigeon POST /place) instead of all concentrating on serve-0. Run
# AFTER rebuilding cloudbox with the opencode-launch POST /place change.
#
# What it does:
#   1. Snapshots agent-loop children per serve port (the compute-concentration signal).
#   2. Launches N trivial sessions via the deployed `opencode-launch`.
#   3. Asks pigeon `GET /route?session_id=` for each launched sid and tallies the
#      owning serve.
#   4. PASS iff the launched sessions land on >= 2 distinct serves AND no single
#      serve owns ALL of them (i.e. distribution actually happened). FAIL if they
#      all concentrate on one serve (placement not wired / pigeon down).
#   5. Best-effort cleanup (DELETE each session on its owner; short timeout).
#
# Usage:  bash serve-distribution-probe.sh [N] [model]
#   N      number of probe sessions (default 8)
#   model  provider/model for the launch (default google-vertex/gemini-3.5-flash)
#
# Env:  PORTS="4096 4097 4098 4099"  PIGEON_DAEMON_URL=http://127.0.0.1:4731
#       PIGEON_DAEMON_AUTH_TOKEN (sent as bearer if set)
set -o errexit -o nounset -o pipefail

N="${1:-8}"
MODEL="${2:-google-vertex/gemini-3.5-flash}"
PORTS="${PORTS:-4096 4097 4098 4099}"
PIGEON="${PIGEON_DAEMON_URL:-http://127.0.0.1:4731}"
DIR="${PROBE_DIR:-$HOME}"
AUTH=()
[ -n "${PIGEON_DAEMON_AUTH_TOKEN:-}" ] && AUTH=(-H "Authorization: Bearer $PIGEON_DAEMON_AUTH_TOKEN")

command -v opencode-launch >/dev/null 2>&1 || { echo "FAIL: opencode-launch not on PATH"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq not on PATH"; exit 2; }

children_snapshot() {
  local label="$1" p pid kids
  echo "--- agent-loop children per serve ($label) ---"
  for p in $PORTS; do
    pid="$(ss -tlnp 2>/dev/null | grep ":$p " | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2 || true)"
    if [ -n "$pid" ]; then
      kids="$(pgrep -P "$pid" 2>/dev/null | wc -l)"
      printf '  port %s (pid %s): %s children\n' "$p" "$pid" "$kids"
    else
      printf '  port %s: no serve listening\n' "$p"
    fi
  done
}

children_snapshot before

echo "--- launching $N sessions via opencode-launch (model=$MODEL) ---"
sids=()
for i in $(seq 1 "$N"); do
  out="$(opencode-launch --model "$MODEL" --tmux-session probe -- "$DIR" \
    "Reply with the single word OK and then stop." 2>/dev/null || true)"
  sid="$(printf '%s\n' "$out" | sed -n 's/^Session launched: \(ses_[A-Za-z0-9_-]*\).*/\1/p' | head -1)"
  if [ -n "$sid" ]; then
    sids+=("$sid")
    printf '  launched %s\n' "$sid"
  else
    printf '  WARN: launch %s produced no sid\n' "$i"
  fi
done

[ "${#sids[@]}" -gt 0 ] || { echo "FAIL: no sessions launched"; exit 1; }

# Give pigeon a beat to settle the assignment rows.
sleep 3

echo "--- owning serve per launched session (GET /route) ---"
declare -A tally
unrouted=0
for sid in "${sids[@]}"; do
  body="$(curl -s --max-time 5 "${AUTH[@]}" "$PIGEON/route?session_id=$sid" 2>/dev/null || true)"
  serve="$(printf '%s' "$body" | jq -r '.serveId // empty' 2>/dev/null || true)"
  if [ -n "$serve" ]; then
    tally["$serve"]=$(( ${tally["$serve"]:-0} + 1 ))
    printf '  %s -> %s\n' "$sid" "$serve"
  else
    unrouted=$(( unrouted + 1 ))
    printf '  %s -> UNROUTED (404) — placement did not happen\n' "$sid"
  fi
done

echo "--- distribution ---"
distinct=0
maxone=0
for serve in "${!tally[@]}"; do
  c="${tally[$serve]}"
  printf '  %s: %s\n' "$serve" "$c"
  distinct=$(( distinct + 1 ))
  [ "$c" -gt "$maxone" ] && maxone="$c"
done
printf '  unrouted: %s\n' "$unrouted"

children_snapshot after

echo "--- best-effort cleanup ---"
# Diagnostic cleanup: issue DELETE directly against the resolved owner apiBase.
for sid in "${sids[@]}"; do
  body="$(curl -s --max-time 5 "${AUTH[@]}" "$PIGEON/route?session_id=$sid" 2>/dev/null || true)"
  owner="$(printf '%s' "$body" | jq -r '.apiBase // empty' 2>/dev/null || true)"
  [ -n "$owner" ] && curl -s --max-time 5 -X DELETE "$owner/session/$sid" -o /dev/null 2>/dev/null || true
done
echo "  (idle probe sessions are reaped by pigeon if delete was skipped)"

echo
total="${#sids[@]}"
if [ "$distinct" -ge 2 ] && [ "$maxone" -lt "$total" ] && [ "$unrouted" -eq 0 ]; then
  echo "PASS: $total sessions spread across $distinct serves (max $maxone on one serve, 0 unrouted)."
  exit 0
else
  echo "FAIL: distribution gate not met (distinct=$distinct, max-on-one=$maxone/$total, unrouted=$unrouted)."
  echo "      Expect >=2 distinct serves, no serve owning all, 0 unrouted."
  echo "      If all on serve-0 / all unrouted: the opencode-launch POST /place change is not live."
  exit 1
fi
