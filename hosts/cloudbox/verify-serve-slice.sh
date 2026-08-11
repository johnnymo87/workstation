#!/usr/bin/env bash
# unwired-test(workstation-le0a): run by hand after any deploy that changes the
# serve units' Slice=. Not in `nix flake check` -- it inspects the LIVE cgroup
# hierarchy of a running pool, which a build sandbox does not have.
#
# WHY THIS EXISTS AS A SCRIPT RATHER THAN A NOTE
#
# Attaching `Slice=` to the serve units without restarting them in the same
# deploy silently DELETES the per-serve memory limits: systemd re-realizes the
# units as members of the new slice while the processes stay in the old one,
# `memory` drops out of the old slice's cgroup.subtree_control, and
# memory.max/memory.swap.max cease to exist. All four serves then run with no
# limit at all. That happened on 2026-08-02 and was reverted in PR #264.
#
# The reason it went unnoticed is the important part: `systemctl show` reported
# the configured values perfectly the whole time. It reports what the unit ASKS
# for, not what the kernel is ENFORCING, and the failure mode here is a missing
# file. An instrument that cannot express the failure cannot detect it. So this
# script reads cgroupfs and nothing else.
#
# Usage:  ./hosts/cloudbox/verify-serve-slice.sh [expected_per_serve] [expected_slice]
set -u

EXPECT_SERVE=${1:-15032385536}   # 14G
EXPECT_SLICE=${2:-34359738368}   # 32G
SLICE_DIR=/sys/fs/cgroup/system.slice/opencode-serve.slice

PASS=0; FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "== the slice cgroup exists =="
if [ -d "$SLICE_DIR" ]; then ok "$SLICE_DIR"; else
  bad "$SLICE_DIR missing — the serves are not in the slice at all"
  echo "==== $PASS passed, $FAIL failed ===="; exit 1
fi

echo "== the slice delegates 'memory' to its children =="
# Without this, per-serve memory.max files cannot exist no matter what the unit
# says. This is the exact bit that got dropped in the 2026-08-02 incident.
SUB=$(cat "$SLICE_DIR/cgroup.subtree_control" 2>/dev/null || echo "")
case " $SUB " in
  *" memory "*) ok "cgroup.subtree_control has memory ($SUB)" ;;
  *) bad "cgroup.subtree_control lacks memory ($SUB) — per-serve limits CANNOT be enforced" ;;
esac

echo "== the slice's own aggregate cap =="
SMAX=$(cat "$SLICE_DIR/memory.max" 2>/dev/null || echo missing)
[ "$SMAX" = "$EXPECT_SLICE" ] && ok "slice memory.max=$SMAX" || bad "slice memory.max=$SMAX expected $EXPECT_SLICE"

echo "== every ACTIVE serve is inside the slice, with an enforced limit =="
UNITS=$(systemctl list-units 'opencode-serve@*.service' --no-legend --plain --state=active | awk '{print $1}')
[ -n "$UNITS" ] || { bad "no active opencode-serve@* units"; echo "==== $PASS passed, $FAIL failed ===="; exit 1; }

for u in $UNITS; do
  port=${u#opencode-serve@}; port=${port%.service}
  f="$SLICE_DIR/$u/memory.max"
  if [ ! -f "$f" ]; then
    bad "$port: $f DOES NOT EXIST — this is the PR #264 failure; the serve is unbounded"
    continue
  fi
  v=$(cat "$f")
  [ "$v" = "$EXPECT_SERVE" ] && ok "$port: memory.max=$v" || bad "$port: memory.max=$v expected $EXPECT_SERVE"

  # The process must actually BE in this cgroup, not merely have a unit that
  # says so -- that mismatch is the whole incident.
  mp=$(systemctl show "$u" -p MainPID | sed -n 's/^MainPID=//p')
  cg=$(cat "/proc/$mp/cgroup" 2>/dev/null || echo "")
  case "$cg" in
    *"opencode-serve.slice/$u"*) ok "$port: MainPID $mp is really in the slice" ;;
    *) bad "$port: MainPID $mp is NOT in the slice (cgroup: ${cg:-unreadable})" ;;
  esac
done

echo
echo "==== $PASS passed, $FAIL failed ===="
[ "$FAIL" -eq 0 ] || exit 1
