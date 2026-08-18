#!/usr/bin/env bash
# Behavioural tests for the drift canary RUNNER (bead workstation-4ze8).
#
# The library suite (test.sh) proves the predicates. It cannot see a canary
# whose glue never reaches the alert sink -- which is precisely how layer 1
# failed: the h0mp gate silently ALLOWED every deploy when its library did not
# source, and only a behavioural test caught it. This suite runs the SHIPPED
# pkgs/hm-deploy-canary-sh/canary.sh end to end against scratch state, a scratch
# beacon, a scratch mirror and a stub alert sink.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$HERE/canary.sh"

FAILED=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; FAILED=1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export GIT_AUTHOR_NAME=canary GIT_AUTHOR_EMAIL=c@example.invalid
export GIT_COMMITTER_NAME=canary GIT_COMMITTER_EMAIL=c@example.invalid
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

# Stub alert sink: records the SIGNATURE (arg 2) of every alert raised.
SINK="$WORK/sink"
# /bin/sh, NOT /usr/bin/env bash: the nix sandbox has no /usr/bin/env, so an
# env-shebang sink silently fails to exec. The runner tolerates a failing sink
# by design, so every "no alert" assertion then passes VACUOUSLY -- which is
# exactly what happened on the first sandbox run, while the host was green.
cat > "$SINK" <<'EOF'
#!/bin/sh
printf '%s\n' "$2" >> "$HM_CANARY_TEST_ALERTS"
EOF
chmod +x "$SINK"

# A fixture whose published ref holds the NEWER commit, so deploying the older
# one drops something PUBLISHED and is a provable regression.
FIX="$WORK/fixture"; mkdir -p "$FIX"
(
  cd "$FIX"
  git init -q .
  echo 1 > f && git add f && git commit -q -m one
  git branch -f old
  echo 2 > f && git add f && git commit -q -m two
  git branch -f pubref
) >/dev/null 2>&1
OLD="$(git -C "$FIX" rev-parse old)"
NEW="$(git -C "$FIX" rev-parse pubref)"

# prep <case-name>  -- creates scratch state and RESETS the alert record.
# go [VAR=val ...]  -- runs the SHIPPED runner with the standard seams.
#
# Split deliberately: an earlier draft ran the runner inside the setup helper,
# so every case executed once before its own fixture existed and the alert
# record accumulated across runs. The healthy case caught it.
prep() {
  CASE="$WORK/case-$1"
  rm -rf "$CASE"; mkdir -p "$CASE/state" "$CASE/store" "$CASE/gen"
  ALERTS="$CASE/alerts"; : > "$ALERTS"
  OUT="$CASE/out.txt"
}

go() {
  env \
    HM_CANARY_STATE="$CASE/state" \
    HM_CANARY_BEACON="$CASE/beacon" \
    HM_CANARY_GENERATION="$CASE/gen/beacon" \
    HM_CANARY_PROFILES="$CASE/profiles" \
    HM_CANARY_REPO="$FIX" \
    HM_CANARY_HISTORY="$CASE/state/history" \
    HM_CANARY_PUBLISHED_REF=pubref \
    HM_CANARY_ALERT="$SINK" \
    HM_CANARY_TEST_ALERTS="$ALERTS" \
    HM_CANARY_GATE_LIB="$HERE/../hm-deploy-gate-sh/hm-deploy-gate.sh" \
    HM_CANARY_LIB="$HERE/hm-deploy-canary.sh" \
    "$@" \
    bash "$RUNNER" > "$OUT" 2>&1
  RC=$?
}

# Writes a store-shaped beacon: a symlink that both the beacon path and the
# generation path resolve to, mimicking production's layout.
set_beacon() {
  printf '%s\n' "$1" > "$CASE/store/rev"
  ln -sfn "$CASE/store/rev" "$CASE/beacon"
  ln -sfn "$CASE/store/rev" "$CASE/gen/beacon"
}

has_alert()  { grep -q "$1" "$ALERTS" 2>/dev/null; }
no_alerts()  { [ ! -s "$ALERTS" ]; }

echo "== a healthy fleet is silent =="
prep healthy
set_beacon "$NEW"; printf '%s\n' "$NEW" > "$CASE/state/history"
go
if [ "$RC" = 0 ]; then pass "exits 0"; else fail "exits 0 (rc=$RC)"; fi
if no_alerts; then pass "raises no alert at all"; else fail "raises no alert (got: $(tr '\n' ' ' < "$ALERTS"))"; fi
if grep -q 'pass complete' "$OUT"; then pass "reaches the end of the pass"; else fail "reaches the end of the pass"; fi
if [ -s "$CASE/state/last-ok" ]; then pass "stamps last-ok"; else fail "stamps last-ok"; fi

echo "== a regressing TRANSITION pages =="
prep regress
set_beacon "$OLD"; printf '%s\n' "$NEW" > "$CASE/state/history"
go
if has_alert "hm-canary:regress:$NEW:$OLD"; then pass "alerts with both revs in the signature"; else fail "alerts on the transition (got: $(tr '\n' ' ' < "$ALERTS"))"; fi
# The alert TEXT goes to the sink (arg 3), not to stdout, so assert on the line
# the runner actually journals -- an operator reading `journalctl -u` sees this.
if grep -q "transition $NEW -> $OLD" "$OUT"; then pass "the journal names the transition"; else fail "the journal names the transition"; fi
if [ "$(grep -c . "$CASE/state/history")" = 2 ]; then pass "appends the new rev to history"; else fail "appends the new rev to history"; fi

echo "== the override leg, end to end =="
# Layer 1 downgrades this to a warning in one agent's terminal. The canary must
# still page -- and must not be reachable by the environment variable.
prep override
set_beacon "$OLD"; printf '%s\n' "$NEW" > "$CASE/state/history"
go HM_ALLOW_STALE_DEPLOY=1
if has_alert 'hm-canary:regress'; then pass "HM_ALLOW_STALE_DEPLOY=1 does not silence the canary"; else fail "HM_ALLOW_STALE_DEPLOY=1 silences the canary"; fi

echo "== an unusable beacon pages rather than being skipped =="
prep nobeacon
go
if has_alert 'hm-canary:beacon-absent'; then pass "absent beacon alerts"; else fail "absent beacon alerts (got: $(tr '\n' ' ' < "$ALERTS"))"; fi

prep malformed
set_beacon "not-a-rev"; printf '%s\n' "$NEW" > "$CASE/state/history"
go
if has_alert 'hm-canary:beacon-malformed'; then pass "malformed beacon alerts"; else fail "malformed beacon alerts (got: $(tr '\n' ' ' < "$ALERTS"))"; fi

echo "== a beacon that is not from the live generation pages =="
# The hole nothing else can see: well-formed, no transition, and layer 1 would
# TRUST it on the next switch.
prep provenance
set_beacon "$NEW"
rm -f "$CASE/beacon"; printf '%s\n' "$NEW" > "$CASE/beacon"   # a regular file
printf '%s\n' "$NEW" > "$CASE/state/history"
go
if has_alert 'hm-canary:beacon-provenance:not-symlink'; then pass "a hand-written beacon alerts"; else fail "a hand-written beacon alerts (got: $(tr '\n' ' ' < "$ALERTS"))"; fi

echo "== a broken detector says so instead of reporting a healthy fleet =="
# Readable but useless library: sourcing succeeds, the functions are absent.
: > "$WORK/empty-lib.sh"
prep degraded
set_beacon "$NEW"; printf '%s\n' "$NEW" > "$CASE/state/history"
go HM_CANARY_GATE_LIB="$WORK/empty-lib.sh"
if has_alert 'hm-canary:detector-degraded'; then pass "a gutted gate library alerts as DEGRADED"; else fail "a gutted gate library alerts as DEGRADED (got: $(tr '\n' ' ' < "$ALERTS"))"; fi
if ! grep -q 'pass complete' "$OUT"; then pass "and does not go on to report a healthy pass"; else fail "reported a healthy pass with a broken library"; fi
if [ "$RC" = 0 ]; then pass "exits 0 so onFailure does not double-page"; else fail "exits 0 (rc=$RC)"; fi

echo "== a missing library is fatal, not silent =="
prep nolib
set_beacon "$NEW"
go HM_CANARY_GATE_LIB="$WORK/does-not-exist.sh"
if [ "$RC" != 0 ]; then pass "exits non-zero so onFailure fires"; else fail "exits non-zero"; fi
if grep -q 'FATAL' "$OUT"; then pass "says FATAL in the journal"; else fail "says FATAL in the journal"; fi

echo "== a lost history is rebuilt from generations, not blessed =="
prep reseed
set_beacon "$OLD"
mkdir -p "$CASE/profiles/home-manager-1-link/home-files/.local/state"
printf '%s\n' "$NEW" > "$CASE/profiles/home-manager-1-link/home-files/.local/state/hm-deploy-rev"
go
if has_alert 'hm-canary:history-reseeded'; then pass "says the history was lost"; else fail "says the history was lost"; fi
if grep -q "^$NEW$" "$CASE/state/history"; then
  pass "seeds from the generation, not from the live beacon"
else
  fail "seeds from the generation (history: $(tr '\n' ' ' < "$CASE/state/history"))"
fi
# Because the seed RECONSTRUCTED the previous value, the very first pass still
# catches the regression that was live when the history vanished. Seeding with
# the current beacon would have blessed it forever -- the h0mp failure mode
# reproduced inside the h0mp guard.
if has_alert 'hm-canary:regress'; then pass "still catches a regression that predates the reseed"; else fail "still catches a regression that predates the reseed"; fi

echo ""
if [ "$FAILED" = 0 ]; then
  echo "hm-deploy-canary-behaviour: ALL PASS"
else
  echo "hm-deploy-canary-behaviour: FAILURES"
  exit 1
fi
