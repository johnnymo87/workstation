#!/usr/bin/env bash
# Behavioural half of the stale-deploy gate suite (bead workstation-h0mp).
#
# The other file tests the LIBRARY. This one runs the ACTUAL activation script
# from the evaluated cloudbox config -- the exact text home-manager will execute
# -- through its three test seams, and asserts it aborts, allows and warns as
# intended.
#
# WHY THIS EXISTS SEPARATELY. A guard whose decision logic is perfect but whose
# glue never calls `exit 1` ships inert, and this repo has done that before (the
# front-door opacity guard shipped without being wired to anything; the E2
# canary's revision 1 alerted exactly once and called it escalation). The
# library tests cannot see that class of defect: everything they exercise
# returns strings. Only running the real script can tell you it aborts.
#
# WHAT THIS CANNOT DO, stated plainly: it does not perform a real
# `home-manager switch`. Making the gate REFUSE end-to-end requires a beacon in
# the live profile, and installing one means deploying an unmerged branch to the
# box every other agent is working on. The seams below are the closest honest
# substitute -- same script, same code path, scratch inputs.
set -uo pipefail

: "${GATE_SCRIPT:?GATE_SCRIPT must point at the evaluated activation script}"

PASS=0; FAIL=0
ok() {
  if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); else
    FAIL=$((FAIL + 1)); echo "FAIL: $1" >&2
    echo "  expected: [$2]" >&2; echo "  actual:   [$3]" >&2
  fi
}
contains() { # contains <name> <needle> <haystack>
  case "$3" in
    *"$2"*) PASS=$((PASS + 1)) ;;
    *) FAIL=$((FAIL + 1)); echo "FAIL: $1" >&2
       echo "  expected to contain: [$2]" >&2; echo "  in: [$3]" >&2 ;;
  esac
}

REPO="$(mktemp -d)"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email t@t; git -C "$REPO" config user.name t
echo a > "$REPO/f"; git -C "$REPO" add -A; git -C "$REPO" commit -qm A
OLD="$(git -C "$REPO" rev-parse HEAD)"
echo b > "$REPO/f"; git -C "$REPO" commit -qam B
NEW="$(git -C "$REPO" rev-parse HEAD)"

BEACON="$(mktemp -d)/beacon"

run() { # run <incoming> <beacon-contents|__none__> [allow-stale] [pub-ref]
  local inc="$1" bec="$2" allow="${3:-}" pub="${4:-refs/remotes/origin/main}"
  if [ "$bec" = "__none__" ]; then rm -f "$BEACON"; else printf '%s\n' "$bec" > "$BEACON"; fi
  HM_GATE_INCOMING="$inc" HM_GATE_BEACON="$BEACON" HM_GATE_REPO="$REPO" \
    HM_GATE_PUBLISHED_REF="$pub" HM_ALLOW_STALE_DEPLOY="$allow" bash "$GATE_SCRIPT" 2>&1
}
rc() { # same, but echo the exit code
  local out; out="$(run "$@")"; printf '%s' "$?"
}

# --- THE INCIDENT: deploying OLD while NEW is live --------------------------
OUT="$(run "$OLD" "$NEW")"; RC="$(rc "$OLD" "$NEW")"
ok       "incident: aborts"                "1" "$RC"
contains "incident: says what it is"       "would UN-DEPLOY live configuration" "$OUT"
contains "incident: names deployed rev"    "$NEW" "$OUT"
contains "incident: names incoming rev"    "$OLD" "$OUT"
contains "incident: says nothing written"  "Nothing has been written" "$OUT"
contains "incident: gives the fix"         "git rebase origin/main" "$OUT"
contains "incident: gives the escape hatch" "HM_ALLOW_STALE_DEPLOY=1" "$OUT"
contains "incident: cites the bead"        "workstation-h0mp" "$OUT"

# A dirty stale tree is still stale.
ok "incident: dirty tree also aborts" "1" "$(rc "${OLD}-dirty" "$NEW")"

# --- the squash-merge false positive (production, 2026-08-05) ---------------
# Deployed from a PR branch; the PR was then squash-merged. Switching from main
# drops that branch sha but nothing published and no content. v1 REFUSED this,
# which would have blocked every agent on the box.
git -C "$REPO" update-ref refs/remotes/origin/main "$NEW"
git -C "$REPO" checkout -q -b pr "$OLD" 2>/dev/null
echo pr > "$REPO/p"; git -C "$REPO" add -A; git -C "$REPO" commit -qm PR
BRANCH="$(git -C "$REPO" rev-parse HEAD)"; git -C "$REPO" checkout -q main
OUT="$(run "$NEW" "$BRANCH")"
ok       "squash: does not abort"      "0" "$(rc "$NEW" "$BRANCH")"
contains "squash: explains itself accurately" "nothing published is being dropped" "$OUT"
# It must NOT claim doubt: the gate checked, and a misleading message on a
# correct verdict trains people to ignore the guard.
case "$OUT" in
  *"could not verify"*) FAIL=$((FAIL + 1)); echo "FAIL: squash: must not claim it could not verify" >&2 ;;
  *) PASS=$((PASS + 1)) ;;
esac

# --- the allow paths must NOT abort -----------------------------------------
ok "forward: allows"        "0" "$(rc "$NEW" "$OLD")"
ok "same rev: allows"       "0" "$(rc "$NEW" "$NEW")"
ok "dirty at same rev: allows" "0" "$(rc "${NEW}-dirty" "$NEW")"
# "Quiet" here means no abort and no doubt-warning. It is NOT empty output: the
# HM_GATE_INCOMING seam announces itself on every run of this suite, by design.
OUT="$(run "$NEW" "$OLD")"
case "$OUT" in
  *FATAL*|*"could not verify"*) FAIL=$((FAIL + 1)); echo "FAIL: forward: should not warn or abort" >&2
                                echo "  actual: [$OUT]" >&2 ;;
  *) PASS=$((PASS + 1)) ;;
esac

# --- the guard's own dependency going missing --------------------------------
# The defect this suite caught: with the library absent, every hm_gate_* call
# became "command not found", VERDICT was EMPTY, the case matched nothing and
# the deploy sailed through in SILENCE. Fail-open is the deliberate choice here
# (a false refusal would block every agent on the box) but silence never is.
BROKEN="$(mktemp)"
# NOTE the @ delimiter: the replacement contains `||`, and with sed's usual `|`
# delimiter that silently truncates the s command and emits an EMPTY file, which
# then "passes" as a script that does nothing.
sed "s@^source .*@source /nonexistent/hm-deploy-gate.sh 2>/dev/null || GATE_LIB_OK=0@" "$GATE_SCRIPT" > "$BROKEN"
[ -s "$BROKEN" ] || { echo "FAIL: broken-library fixture is empty (sed failed)" >&2; FAIL=$((FAIL + 1)); }
OUT="$(HM_GATE_INCOMING="$OLD" HM_GATE_BEACON="$BEACON" HM_GATE_REPO="$REPO" bash "$BROKEN" 2>&1)"
RC=$?
ok       "broken library: does not abort the deploy" "0" "$RC"
contains "broken library: says the deploy is UNCHECKED" "UNCHECKED" "$OUT"
rm -f "$BROKEN"

# --- doubt warns but never blocks -------------------------------------------
# Every one of these is a hole the drift canary (workstation-4ze8) must cover.
OUT="$(run "$NEW" "__none__")"
ok       "no beacon: does not abort" "0" "$(rc "$NEW" "__none__")"
contains "no beacon: warns"          "could not verify" "$OUT"
contains "no beacon: names the case" "no-beacon" "$OUT"

OUT="$(run "unknown" "$NEW")"
ok       "unknown incoming rev: does not abort" "0" "$(rc "unknown" "$NEW")"
contains "unknown incoming rev: warns"          "unknown-rev" "$OUT"

OUT="$(run "0000000000000000000000000000000000000000" "$NEW")"
ok       "absent object: does not abort" "0" "$(rc "0000000000000000000000000000000000000000" "$NEW")"
contains "absent object: warns"          "unknown-object" "$OUT"

# --- escape hatch downgrades, loudly ----------------------------------------
OUT="$(run "$OLD" "$NEW" 1)"
ok       "override: does not abort"   "0" "$(rc "$OLD" "$NEW" 1)"
contains "override: still shouts"     "HM_ALLOW_STALE_DEPLOY=1" "$OUT"
contains "override: names the risk"   "DROPS commits" "$OUT"
# A stray falsy value must not disarm the gate.
ok "override: 0 does not disarm"     "1" "$(rc "$OLD" "$NEW" 0)"
ok "override: false does not disarm" "1" "$(rc "$OLD" "$NEW" false)"

# --- the incoming-rev seam must announce itself -----------------------------
# It is the one override that could weaken the gate without saying so.
contains "seam: announces itself" "HM_GATE_INCOMING override in effect" "$(run "$NEW" "$NEW")"

# --- the refusal must not touch anything ------------------------------------
# entryBefore writeBoundary is the whole safety argument for aborting.
SNAP="$(git -C "$REPO" rev-parse HEAD)$(git -C "$REPO" status --porcelain)$(git -C "$REPO" for-each-ref)"
printf '%s\n' "$NEW" > "$BEACON"; BEFORE_BEACON="$(cat "$BEACON")"
run "$OLD" "$NEW" >/dev/null
ok "refusal leaves the repo untouched"  "$SNAP" "$(git -C "$REPO" rev-parse HEAD)$(git -C "$REPO" status --porcelain)$(git -C "$REPO" for-each-ref)"
ok "refusal leaves the beacon untouched" "$BEFORE_BEACON" "$(cat "$BEACON")"

rm -rf "$REPO" "$(dirname "$BEACON")"

echo
echo "hm-deploy-gate-behaviour: $PASS passed, $FAIL failed"
if [ "$FAIL" -ne 0 ]; then
  echo "hm-deploy-gate-behaviour: FAILURES PRESENT" >&2; exit 1
fi
if [ "$PASS" -lt 30 ]; then
  echo "hm-deploy-gate-behaviour: TOO FEW ASSERTIONS RAN ($PASS)" >&2; exit 1
fi
echo "hm-deploy-gate-behaviour: ALL PASS"
