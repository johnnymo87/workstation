#!/usr/bin/env bash
# The home-manager drift canary runner (bead workstation-4ze8).
#
# Layer 2 for the stale-deploy gate: this runs from a NixOS SYSTEM unit, which a
# `home-manager switch` cannot remove. See pkgs/hm-deploy-canary-sh/hm-deploy-
# canary.sh for what was measured before any of this was written, and for the
# predicates. This file is deliberately thin glue -- the decisions live in the
# library, where they are tested.
#
# WHY THIS IS A FILE AND NOT SHELL INSIDE THE NIX UNIT. The h0mp gate's own
# behavioural suite caught the gate silently ALLOWING every deploy when its
# library failed to source; nothing in the library tests could see it, because
# the defect was in the glue. Glue that lives in a Nix string can only be tested
# by evaluating and deploying. As a file it is driven as-shipped by
# test-behaviour.sh through the HM_CANARY_* seams.
#
# EXIT STATUS IS NOT THE ALERT CHANNEL. A non-zero exit here trips the unit's
# onFailure. Detection results go to the alert sink; only a broken CANARY exits
# non-zero.
set -uo pipefail

# --- seams. Defaults are production; the suite overrides all of them. --------
STATE="${HM_CANARY_STATE:-/var/lib/hm-deploy-canary}"
BEACON="${HM_CANARY_BEACON:-/home/dev/.local/state/hm-deploy-rev}"
GENERATION="${HM_CANARY_GENERATION:-/home/dev/.local/state/home-manager/gcroots/current-home/home-files/.local/state/hm-deploy-rev}"
PROFILES="${HM_CANARY_PROFILES:-/home/dev/.local/state/nix/profiles}"
REPO="${HM_CANARY_REPO:-$STATE/repo}"
HISTORY="${HM_CANARY_HISTORY:-$STATE/history}"
PUB_REF="${HM_CANARY_PUBLISHED_REF:-origin/main}"
ALERT="${HM_CANARY_ALERT:-}"
# The library paths are REQUIRED rather than defaulted to a store path, so that
# the file in the repo and the file the unit runs are byte-identical.
GATE_LIB="${HM_CANARY_GATE_LIB:-}"
CANARY_LIB="${HM_CANARY_LIB:-}"

# Alert cadence: first repeat after 15 min, capped at 4 h -- the same 900/14400
# the front-door and auth canaries use. driftAlert is a THROTTLE, not a
# scheduler, so every alerting branch below must re-invoke it on every pass.
ALERT_MIN=900
ALERT_MAX=14400

say() { printf '%s\n' "$*"; }

# raise <state-file-suffix> <signature> <text>
# Never let the alert sink's failure abort a pass: a canary that dies because
# the pager is down reports nothing about the fleet.
raise() {
  local suffix="$1" sig="$2" text="$3"
  say "ALERT [$sig]"
  if [ -n "$ALERT" ] && [ -x "$ALERT" ]; then
    "$ALERT" "$STATE/alert-$suffix" "$sig" "$text" "$ALERT_MIN" "$ALERT_MAX" || true
  else
    # No sink configured is itself a degraded state, but it must not be fatal --
    # this is the path the suite exercises, and a misconfigured unit should
    # still leave a journal trail rather than exiting non-zero every 10 min.
    say "WARNING: no alert sink configured (HM_CANARY_ALERT); alert not delivered"
  fi
}
clear_alert() { rm -f "$STATE/alert-$1" 2>/dev/null || true; }

mkdir -p "$STATE" 2>/dev/null

# --- load the libraries -----------------------------------------------------
# A canary whose own dependency vanished must never report "fine". This is the
# h0mp defect, in the layer built to cover h0mp.
if [ -z "$GATE_LIB" ] || [ -z "$CANARY_LIB" ] || [ ! -r "$GATE_LIB" ] || [ ! -r "$CANARY_LIB" ]; then
  say "FATAL: canary libraries not readable (gate='$GATE_LIB' canary='$CANARY_LIB')"
  exit 1
fi
# shellcheck source=/dev/null
source "$GATE_LIB" || { say "FATAL: could not source the gate library"; exit 1; }
# shellcheck source=/dev/null
source "$CANARY_LIB" || { say "FATAL: could not source the canary library"; exit 1; }

# --- 0. tripwire: does the decision logic still decide? ---------------------
# Runs FIRST and every pass. This canary is silent by construction, so a wedged
# detector and a healthy fleet are externally identical without this.
SELF="$(hm_canary_selftest "$STATE" 2>/dev/null || echo 'FAIL:selftest-crashed')"
if [ "$SELF" != "ok" ]; then
  raise degraded "hm-canary:detector-degraded:$SELF" "$(cat <<EOF
The home-manager drift canary CANNOT DECIDE ($SELF).

Its self-test builds a throwaway repo with a known regression and asserts the
gate library still calls it one. That assertion failed, so this canary is NOT
watching the fleet right now -- treat this as a broken detector, not as a
healthy deploy.

This is the shape bead workstation-h0mp hit in layer 1: when its library failed
to source, the gate produced an empty verdict and allowed every deploy in
silence.

Check:
  systemctl status hm-deploy-canary --no-pager | head -20
  journalctl -u hm-deploy-canary -n 50 --no-pager
EOF
)"
  # Deliberately NOT exit 1: the unit is working, the logic under it is not.
  # Exiting non-zero would double-page through onFailure.
  exit 0
fi
clear_alert degraded

# --- 1. provenance: is the beacon the one the live generation declares? -----
# A hand-written beacon is well-formed, produces no transition, and would be
# TRUSTED by layer 1 -- strictly worse than a missing one.
PROV="$(hm_canary_provenance "$BEACON" "$GENERATION")"
case "$PROV" in
  ok|generation-absent)
    # generation-absent is not evidence of drift: the gcroot path is not
    # guaranteed to exist on every host layout. Say so and move on.
    [ "$PROV" = "generation-absent" ] && say "note: no generation beacon to compare against ($GENERATION)"
    clear_alert provenance
    ;;
  beacon-absent)
    : # handled by the beacon-state leg below, which has the better message
    ;;
  *)
    raise provenance "hm-canary:beacon-provenance:$PROV" "$(cat <<EOF
The home-manager deploy beacon is NOT the one the live generation declares
($PROV).

  beacon     : $BEACON
  generation : $GENERATION

The beacon is what the stale-deploy gate reads on the NEXT switch. If it no
longer resolves to the file the live generation installed, something replaced it
outside home-manager -- and layer 1 will trust whatever it says, which can bless
a real regression.

Check:
  ls -l $BEACON
  readlink -f $BEACON
  readlink -f $GENERATION
EOF
)"
    ;;
esac

# --- 2. beacon value --------------------------------------------------------
RAW="$(cat "$BEACON" 2>/dev/null || true)"
BSTATE="$(hm_canary_beacon_state "$RAW")"
CUR="$(hm_gate_beacon_rev "$RAW")"

case "$BSTATE" in
  ok) clear_alert beacon ;;
  dirty)
    raise beacon "hm-canary:beacon-dirty" "$(cat <<EOF
The live home-manager generation was deployed from an UNCOMMITTED tree.

  beacon: ${RAW%$'\n'}

Nothing in git corresponds to what is running, so neither layer 1 nor this
canary can answer whether it dropped anything. Re-deploy from a committed
revision to restore the guarantee.
EOF
)"
    ;;
  *)
    # absent / empty / unknown / malformed. Absence is NOT authoritative -- that
    # is the entire lesson of the 2026-08-01 incident, which was silent on both
    # ends.
    raise beacon "hm-canary:beacon-$BSTATE" "$(cat <<EOF
The home-manager deploy beacon is unusable ($BSTATE).

  path : $BEACON
  value: ${RAW:-<nothing>}

Without a readable beacon the stale-deploy gate cannot judge the NEXT switch --
it degrades to a warning nobody outside that terminal will see. A generation
deployed by a config that predates the gate looks exactly like this.

Check:
  ls -l $BEACON
  systemctl status hm-deploy-canary --no-pager | head -20
EOF
)"
    ;;
esac

# --- 3. history: seed by RECONSTRUCTION, never by blessing ------------------
# Seeding with the current beacon would record whatever is deployed at first run
# as normal -- so a canary first started (or restored) during a bad switch is
# silent forever. Generations carry their own beacons, so the seed replays them.
if [ ! -s "$HISTORY" ]; then
  say "history absent; backfilling from retained generations"
  hm_canary_generation_revs "$PROFILES" | cut -f2 > "$HISTORY" 2>/dev/null
  if [ ! -s "$HISTORY" ]; then
    [ -n "$CUR" ] && printf '%s\n' "$CUR" > "$HISTORY"
  fi
  # Depth is bounded (NIX_KEEP_GENERATIONS=3), so this is a reconstruction of
  # what can still be seen, not a complete record. Said out loud rather than
  # implied, because a lost history is a real loss of coverage.
  raise history "hm-canary:history-reseeded" "$(cat <<EOF
The drift canary's transition history was missing and has been rebuilt from the
retained home-manager generations ($(wc -l < "$HISTORY" | tr -d ' ') entries).

Transitions older than the retained generations are unrecoverable, so any bad
switch that happened while the history was gone will NOT be reported by the
transition detector. The snapshot check below still applies.

This is expected exactly once, on first deployment of this unit.
EOF
)"
else
  clear_alert history
fi

PREV="$(tail -1 "$HISTORY" 2>/dev/null || true)"

# --- 4. fetch, decoupled from the pass --------------------------------------
# Every predicate above runs with zero network. The fetch only refreshes the
# published ref, so a blip must not silence the canary and must not page.
FETCH_STAMP="$STATE/last-fetch"
FETCH_INTERVAL="${HM_CANARY_FETCH_INTERVAL:-3600}"
FETCH_STALE="${HM_CANARY_FETCH_STALE:-21600}"
NOW="$(date +%s)"
LAST_FETCH="$(cat "$FETCH_STAMP" 2>/dev/null || echo 0)"
case "$LAST_FETCH" in ''|*[!0-9]*) LAST_FETCH=0 ;; esac

if [ -d "$REPO" ] && [ "$((NOW - LAST_FETCH))" -ge "$FETCH_INTERVAL" ]; then
  if git -C "$REPO" fetch --quiet --prune origin '+refs/heads/*:refs/remotes/origin/*' 2>/dev/null; then
    printf '%s\n' "$NOW" > "$FETCH_STAMP"
    LAST_FETCH="$NOW"
  else
    say "fetch failed; continuing with the last successfully fetched refs"
  fi
fi

# Instrument-staleness, the pattern PLUGIN_CANARY_UNMEASURABLE_THRESHOLD uses:
# one failed fetch is a blip, six hours of them is a blind detector.
if [ "$LAST_FETCH" -gt 0 ] && [ "$((NOW - LAST_FETCH))" -ge "$FETCH_STALE" ]; then
  raise fetch "hm-canary:published-ref-stale" "$(cat <<EOF
The drift canary has not refreshed its published ref for $(( (NOW - LAST_FETCH) / 3600 ))h.

It is still judging deploys, but against a stale idea of $PUB_REF, which biases
it toward calling a real regression "unpublished" -- i.e. toward UNDER-alerting.

Check:
  git -C $REPO fetch --prune origin
  journalctl -u hm-deploy-canary -n 50 --no-pager
EOF
)"
else
  clear_alert fetch
fi

# --- 5. detector A: the TRANSITION ------------------------------------------
# The gate only ever worked because it knew the previous beacon. A snapshot
# cannot distinguish an ancestor-stale deploy from the permanently-behind-main
# steady state (M1 in the library header), so the transition is the signal.
if [ -n "$CUR" ] && [ -n "$PREV" ] && [ "$CUR" != "$PREV" ]; then
  VERDICT="$(hm_canary_judge "$REPO" "$CUR" "$PREV" "$PUB_REF")"
  say "transition $PREV -> $CUR : $VERDICT"
  if [ "$(hm_canary_alertable "$VERDICT")" = "yes" ]; then
    raise "transition" "hm-canary:regress:$PREV:$CUR" "$(cat <<EOF
A home-manager switch DROPPED published configuration, fleet-wide.

  was live : $PREV
  now live : $CUR
  verdict  : $VERDICT

Layer 1 either was not present, could not judge, or was overridden with
HM_ALLOW_STALE_DEPLOY=1 -- this canary judges overrides as regressions on
purpose, because a deliberate rollback is exactly what the rest of the fleet
needs to hear about out of band.

This is bead workstation-h0mp: on 2026-08-01 exactly this took out the
session-state plugin and a shell-env fix for ~32 hours, silently.

What was dropped:
  git -C $REPO log --oneline $CUR..$PREV -- users/ assets/ pkgs/ flake.nix

To restore:
  cd ~/projects/workstation && git fetch origin && git rebase origin/main
  nix run home-manager -- switch --flake .#cloudbox
EOF
)"
  else
    clear_alert transition
  fi
  printf '%s\n' "$CUR" >> "$HISTORY"
fi

# --- 6. detector A': the SNAPSHOT -------------------------------------------
# Nearly free, and it is the only leg that still works after a lost history, a
# missed transition, or a period when this unit was masked. It cannot see
# ancestor-staleness (that is what A is for) but it does see a deployed rev that
# dropped published commits, at any time.
if [ -n "$CUR" ] && git -C "$REPO" rev-parse --verify --quiet "$PUB_REF" >/dev/null 2>&1; then
  TIP="$(git -C "$REPO" rev-parse "$PUB_REF" 2>/dev/null)"
  SNAP="$(hm_canary_judge "$REPO" "$TIP" "$CUR" "$PUB_REF")"
  say "snapshot $CUR vs $PUB_REF : $SNAP"
  if [ "$(hm_canary_alertable "$SNAP")" = "yes" ]; then
    raise snapshot "hm-canary:snapshot-regress:$CUR" "$(cat <<EOF
The LIVE home-manager deploy is not reachable from $PUB_REF and dropping it
would lose published commits ($SNAP).

  live : $CUR
  $PUB_REF : $TIP

The fleet is running configuration that is not on the published branch. Unlike
the transition check, this fires no matter when the bad switch happened -- so it
may be reporting something older than this unit.

Check:
  git -C $REPO log --oneline $CUR..$TIP -- users/ assets/ pkgs/ flake.nix
EOF
)"
  else
    clear_alert snapshot
  fi
fi

# --- 6b. detector-degraded: no repo to reason in ----------------------------
# warn:no-repo in layer 1 means "the clone I was pointed at is unusable". The
# canary owns its clone, so the same condition here means the DETECTOR is
# broken, not that the deploy is fine.
if [ ! -d "$REPO/.git" ] && [ ! -d "$REPO/objects" ] && [ ! -f "$REPO/HEAD" ]; then
  raise repo "hm-canary:mirror-missing" "$(cat <<EOF
The drift canary has no usable git mirror at $REPO, so it cannot compute
ancestry at all. Its beacon and provenance checks still run; every ancestry
verdict above is meaningless until this is fixed.

Check:
  ls -la $REPO
  systemctl status hm-deploy-canary --no-pager | head -20
EOF
)"
else
  clear_alert repo
fi

printf '%s\n' "$NOW" > "$STATE/last-ok"
say "hm-deploy-canary pass complete (beacon=$BSTATE prov=$PROV live=${CUR:-<none>})"
