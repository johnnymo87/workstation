#!/usr/bin/env bash
# unwired-test(workstation-ixw7): proves verify-serve-slice.sh can express a
# MISSING pool member. Run by hand on cloudbox; needs a live systemd user
# manager, so it cannot go in `nix flake check`.
#
# WHY A SCRATCH POOL RATHER THAN A FAKE `systemctl`
#
# The fix rests on a non-obvious systemd fact: a STOPPED unit is still listed in
# its target's ConsistsOf. A hand-written fake systemctl would encode whatever
# the author BELIEVED about that, the test would pass against the belief, and
# real systemd could differ -- testing the emulation instead of the behaviour.
# That is the same failure shape the script itself exists to fix. So this builds
# a real scratch pool as user units (octest-pool.target + octest-serve@{1,2,3})
# shaped like the production units (PartOf=, a slice, MemoryMax) and drives the
# real script against it through its documented seams.
#
# It must never touch the production pool: there are live sessions on
# :4096-4099, and stopping one to test a verifier would destroy user work to
# check a check. Nothing below names an opencode-serve unit.
#
# The user manager delegates `memory` (cgroup.subtree_control under
# user@1000.service), which is what lets the scratch units carry a real
# MemoryMax -- and that in turn is what lets T1 assert a full exit 0 rather than
# merely "no FAIL line mentioned a member". Both directions matter here: a false
# PASS launders an unverified deploy, and a false FAIL tells the operator to
# revert a good one (the 847ec73 trap).
set -u

SCRIPT=${SCRIPT:-"$(dirname "$0")/verify-serve-slice.sh"}
UD=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}

SERVE_MAX=$((64 * 1024 * 1024))   # 64M per scratch serve
SLICE_MAX=$((256 * 1024 * 1024))  # 256M scratch aggregate

PASS=0; FAIL=0
ok()  { echo "  ok   — $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL — $1"; FAIL=$((FAIL+1)); }

run_verifier() {
  VERIFY_SYSTEMCTL="systemctl --user" \
  VERIFY_POOL_TARGET="octest-pool.target" \
  VERIFY_UNIT_GLOB='octest-serve@*.service' \
  VERIFY_SETTLE_DEADLINE="${1:-0}" \
  VERIFY_SETTLE_INTERVAL=1 \
    bash "$SCRIPT" "$SERVE_MAX" "$SLICE_MAX" "octest.slice" 2>&1
}

setup() {
  mkdir -p "$UD"
  cat > "$UD/octest.slice" <<EOF
[Unit]
Description=octest scratch slice
[Slice]
MemoryMax=$SLICE_MAX
EOF
  cat > "$UD/octest-serve@.service" <<EOF
[Unit]
Description=octest scratch serve %i
PartOf=octest-pool.target
[Service]
Type=simple
Slice=octest.slice
MemoryMax=$SERVE_MAX
ExecStart=/bin/sh -c 'while :; do sleep 5; done'
EOF
  cat > "$UD/octest-pool.target" <<EOF
[Unit]
Description=octest scratch pool
Wants=octest-serve@1.service octest-serve@2.service octest-serve@3.service
EOF
  systemctl --user daemon-reload
  systemctl --user start octest.slice octest-pool.target \
    octest-serve@1.service octest-serve@2.service octest-serve@3.service
  # settle
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ "$(systemctl --user list-units 'octest-serve@*.service' --no-legend --plain --state=active | wc -l)" -eq 3 ] && break
    sleep 1
  done
}

teardown() {
  systemctl --user stop octest-serve@1.service octest-serve@2.service \
    octest-serve@3.service octest-pool.target octest.slice 2>/dev/null
  rm -f "$UD/octest-serve@.service" "$UD/octest-pool.target" "$UD/octest.slice"
  systemctl --user daemon-reload
}
trap teardown EXIT

echo "### setup: scratch pool of 3"
setup
ACTIVE=$(systemctl --user list-units 'octest-serve@*.service' --no-legend --plain --state=active | wc -l)
[ "$ACTIVE" -eq 3 ] || { echo "PRECONDITION FAILED: only $ACTIVE/3 scratch serves up"; exit 1; }
echo "  3/3 scratch serves up"
echo

# --- T1: healthy pool must PASS, exit 0 -------------------------------------
# This is the 847ec73 direction: the script must not fail a correct deploy. It
# is asserted on the EXIT CODE because that is what the runbook consumes; a
# refactor that prints FAIL lines but exits 0 is the original bug shape.
echo "### T1: healthy scratch pool -> exit 0"
OUT=$(run_verifier 0); RC=$?
if [ $RC -eq 0 ]; then ok "exit 0 on a healthy pool"; else
  bad "exit $RC on a HEALTHY pool — this is the 847ec73 trap (good deploy, wrongful revert)"
  printf '%s\n' "$OUT" | sed 's/^/      | /'
fi
printf '%s\n' "$OUT" | grep -q "expected members (3)" \
  && ok "declared membership read from the target (3)" \
  || bad "did not report 3 expected members"
printf '%s\n' "$OUT" | grep -q "no stray active serve units" \
  && ok "stray check ran and was clean" || bad "stray check did not run"
echo

# --- T2: a STOPPED member must FAIL, by name, nonzero ------------------------
# This is the assertion that fails against the OLD script, which is the whole
# point of the change: the old one scoped every assertion to --state=active, so
# a stopped member was absent from the set and could not fail.
echo "### T2: member 2 stopped -> named FAIL, exit != 0"
systemctl --user stop octest-serve@2.service
sleep 1
OUT=$(run_verifier 0); RC=$?
if [ $RC -ne 0 ]; then ok "exit $RC (nonzero) with a member down"; else
  bad "exit 0 with a member DOWN — the verifier still cannot express a missing member"
fi
printf '%s\n' "$OUT" | grep -q "octest-serve@2.service" \
  && ok "names the missing member" \
  || { bad "does not name octest-serve@2.service"; printf '%s\n' "$OUT" | sed 's/^/      | /'; }
printf '%s\n' "$OUT" | grep -q "expected members (3)" \
  && ok "still expects 3 members while only 2 are active" \
  || bad "expected set shrank to what happens to be running — the original bug"
echo

# --- T3: still-coming-up member is a WAIT, not an immediate FAIL --------------
# The wmrt 'database is locked' race is concentrated at the pool bounce, i.e.
# exactly when this script runs, so a not-yet-up member must be waited for, not
# reverted over. With a deadline the run should take >= the interval and still
# report the member.
echo "### T3: settle-wait actually waits (deadline 3s, member still down)"
T0=$(date +%s)
OUT=$(run_verifier 3); RC=$?
ELAPSED=$(( $(date +%s) - T0 ))
[ "$ELAPSED" -ge 1 ] && ok "waited ${ELAPSED}s before giving up (did not fail instantly)" \
  || bad "returned in ${ELAPSED}s — settle-wait did not engage"
printf '%s\n' "$OUT" | grep -q "WAIT:" \
  && ok "classifies a down member as WAIT (soft), not a hard failure" \
  || bad "no WAIT line — soft/hard classification is not working"
printf '%s\n' "$OUT" | grep -q "still not up at the deadline" \
  && ok "emits the wmrt crash-loop hint at the deadline" || bad "no deadline hint"
[ $RC -ne 0 ] && ok "still exits nonzero once the deadline expires" \
  || bad "exit 0 after the deadline with a member down"
echo

# --- T4: bring it back -> clean again ----------------------------------------
echo "### T4: member 2 restarted -> exit 0 again"
systemctl --user start octest-serve@2.service
sleep 1
OUT=$(run_verifier 10); RC=$?
[ $RC -eq 0 ] && ok "recovers to exit 0 once the member returns" \
  || { bad "exit $RC after the member came back"; printf '%s\n' "$OUT" | sed 's/^/      | /'; }
echo

# --- T5: fail closed when the target is absent -------------------------------
# An empty or unreadable expected set must FAIL, never silently verify nothing.
echo "### T5: nonexistent pool target -> fail closed"
OUT=$(VERIFY_SYSTEMCTL="systemctl --user" VERIFY_POOL_TARGET="octest-nope.target" \
  VERIFY_UNIT_GLOB='octest-serve@*.service' VERIFY_SETTLE_DEADLINE=0 \
  bash "$SCRIPT" "$SERVE_MAX" "$SLICE_MAX" "octest.slice" 2>&1); RC=$?
[ $RC -ne 0 ] && ok "exit $RC on a missing target" || bad "exit 0 on a MISSING target — verified nothing, silently"
printf '%s\n' "$OUT" | grep -qi "LoadState" \
  && ok "reports the target's LoadState (systemctl show exits 0 for missing units)" \
  || bad "did not report LoadState — the exit code alone proves nothing here"
echo

# --- T6: seam disclosure ------------------------------------------------------
# A narrowed run must not be able to look like a full one in a pasted transcript.
echo "### T6: non-default seams are disclosed in the summary"
OUT=$(run_verifier 0)
printf '%s\n' "$OUT" | grep -q "NON-DEFAULT SEAMS" \
  && ok "summary discloses the non-default seams" \
  || bad "a seam-narrowed run is indistinguishable from a full one"
echo

echo "==== $PASS passed, $FAIL failed ===="
[ "$FAIL" -eq 0 ] || exit 1
