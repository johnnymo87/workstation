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
# file. An instrument that cannot express the failure cannot detect it. So the
# limit assertions below read cgroupfs and nothing else.
#
# WHY THE CGROUP PATH IS DISCOVERED RATHER THAN HARDCODED (2026-08-12)
#
# The first version of this script hardcoded
#     SLICE_DIR=/sys/fs/cgroup/system.slice/opencode-serve.slice
# and that path CANNOT EVER EXIST, so the script would have failed on a
# perfectly correct deploy -- and the runbook says to revert on failure, so a
# good change would have been reverted for a bad reason.
#
# systemd derives a slice's PARENT from the dashes in its own name: `a-b.slice`
# nests inside `a.slice`. So `opencode-serve.slice` lives under `opencode.slice`
# (`/sys/fs/cgroup/opencode.slice/opencode-serve.slice`), NOT under system.slice,
# even though the units in it are system services. Putting it under system.slice
# would require naming the unit `system-opencode\x2dserve.slice`, with the dash
# escaped so it is not read as a hierarchy separator. Both are legal; the point
# is that the layout follows the NAME, and a hand-written path silently encodes
# a guess about it.
#
# So we discover the truth instead, from /proc/<MainPID>/cgroup -- where the
# process ACTUALLY is. That is also the strictly better instrument for this
# specific incident: the 2026-08-02 failure WAS a divergence between where the
# unit said the process was and where it really was, so a check that derives
# its path from systemd's opinion could not have seen it. /proc cannot lie about
# this.
#
# Usage:  ./hosts/cloudbox/verify-serve-slice.sh [expected_per_serve] [expected_slice] [slice_unit]
set -u

EXPECT_SERVE=${1:-15032385536}          # 14G  (workstation-8rou will make this 10G)
EXPECT_SLICE=${2:-34359738368}          # 32G
EXPECT_SLICE_UNIT=${3:-opencode-serve.slice}

PASS=0; FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

# Real cgroup dir of a PID, from /proc. cgroup2 lines look like `0::/system.slice/foo`.
pid_cgroup_dir() {
  local rel
  rel=$(sed -n 's|^0::||p' "/proc/$1/cgroup" 2>/dev/null) || return 1
  [ -n "$rel" ] || return 1
  printf '/sys/fs/cgroup%s' "$rel"
}

echo "== the pool has active serves =="
UNITS=$(systemctl list-units 'opencode-serve@*.service' --no-legend --plain --state=active | awk '{print $1}')
if [ -z "$UNITS" ]; then
  bad "no active opencode-serve@* units"; echo "==== $PASS passed, $FAIL failed ===="; exit 1
fi
ok "active units: $(echo "$UNITS" | tr '\n' ' ')"

echo "== every ACTIVE serve is really inside $EXPECT_SLICE_UNIT, with an ENFORCED limit =="
SLICE_DIR=""
for u in $UNITS; do
  port=${u#opencode-serve@}; port=${port%.service}

  mp=$(systemctl show "$u" --value -p MainPID)
  if [ -z "$mp" ] || [ "$mp" = "0" ]; then bad "$port: no MainPID"; continue; fi

  real=$(pid_cgroup_dir "$mp")
  if [ -z "$real" ]; then bad "$port: cannot read /proc/$mp/cgroup"; continue; fi

  # Where the process actually lives, and which slice dir that implies.
  parent=$(dirname "$real")
  leaf=$(basename "$parent")
  if [ "$leaf" = "$EXPECT_SLICE_UNIT" ]; then
    ok "$port: MainPID $mp is really in $leaf"
  else
    bad "$port: MainPID $mp is in '$leaf', expected '$EXPECT_SLICE_UNIT' (cgroup: $real)"
  fi

  # All members must agree on one slice, or the pool is split across two.
  if [ -z "$SLICE_DIR" ]; then SLICE_DIR=$parent
  elif [ "$SLICE_DIR" != "$parent" ]; then
    bad "$port: pool is SPLIT across slices ($SLICE_DIR vs $parent)"
  fi

  # The limit, read from the cgroup the process is genuinely in.
  f="$real/memory.max"
  if [ ! -f "$f" ]; then
    bad "$port: $f DOES NOT EXIST — this is the PR #264 failure; the serve is UNBOUNDED"
    continue
  fi
  v=$(cat "$f")
  [ "$v" = "$EXPECT_SERVE" ] && ok "$port: memory.max=$v" || bad "$port: memory.max=$v expected $EXPECT_SERVE"
done

if [ -z "$SLICE_DIR" ]; then
  bad "could not determine the slice dir from any serve"
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
if [ "$SMAX" = "$EXPECT_SLICE" ]; then
  ok "slice memory.max=$SMAX ($SLICE_DIR)"
else
  bad "slice memory.max=$SMAX expected $EXPECT_SLICE ($SLICE_DIR)"
fi

echo
echo "==== $PASS passed, $FAIL failed ===="
[ "$FAIL" -eq 0 ] || exit 1
