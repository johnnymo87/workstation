#!/usr/bin/env bash
# Behavioural tests for the plugin-load canary: runs THE SHIPPED SCRIPT.
#
# WHY THIS EXISTS SEPARATELY FROM test.sh:
# test.sh exercises the sourceable library and then makes three *static grep*
# assertions that ordering markers still appear in hosts/cloudbox/configuration.nix.
# Those greps are deletion tripwires, and they are honestly not much more: a
# refactor that hoists the offset write above the latch loop while leaving the
# comment in place passes every one of them.
#
# That gap matters more here than it usually would, because the property they
# pretend to guard IS the design. driftAlert is a throttle, not a scheduler -- it
# re-alerts only when the caller invokes it again, and it swallows a failed POST
# (exit 0 always, state written only on HTTP 2xx). An earlier revision of this
# canary alerted once per detection, which would have produced ONE
# warning-severity page, no nag, no escalation, and total loss if pigeon were down
# for that minute: the 2026-07-26 frontdoor incident rebuilt (760 detections, one
# page, missed, 12h39m of silence) inside the fix for it.
#
# So this harness extracts the real ExecStart out of the evaluated NixOS config
# and runs it, using the script's four test seams (PLUGIN_CANARY_STATE / _LOG /
# _ALERT / _DOOR) to point it at a scratch state dir, a fixture log, a recording
# alert stub, and a dead door. The whole bead exists because something was
# verified as a module and never in the role it actually plays; asserting that a
# comment exists is a third version of that mistake.
#
# CANARY_SCRIPT is passed in by the flake check.

set -uo pipefail

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'PASS: %s\n' "$1"; }
no() {
  fail=$((fail + 1))
  printf 'FAIL: %s\n' "$1" >&2
  printf '  expected: %s\n' "$2" >&2
  printf '  actual:   %s\n' "$3" >&2
}
eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "$2" "$3"; fi; }

CANARY="${CANARY_SCRIPT:-}"
if [ -z "$CANARY" ] || [ ! -x "$CANARY" ]; then
  echo "FAIL: CANARY_SCRIPT is not set to an executable (got '$CANARY')." >&2
  echo "  The flake check must pass the evaluated ExecStart of" >&2
  echo "  systemd.services.opencode-plugin-canary. Without it this suite would" >&2
  echo "  silently test nothing, which is the failure mode it exists to prevent." >&2
  exit 1
fi

# Which legs the script under test actually has. Cloudbox runs the frontdoor
# probe (leg A) plus the log tail (leg B); devbox runs leg B alone, because it
# has no front door. Declared rather than sniffed: a suite that inferred "no
# probe alerts appeared, so this must be a leg-B host" would report a BROKEN leg
# A as a passing devbox, which is the failure mode this whole bead is about.
LEGS="${CANARY_LEGS:-AB}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

REAL_LINE='timestamp=2026-08-01T15:40:54.070Z level=ERROR run=2d30b122 message="failed to load plugin" path=file:///home/dev/.config/opencode/plugins/shell-env.ts error="Plugin export is not a function"'

# Recording alert stub. Absolute shebang on purpose: the canary pins a minimal
# PATH that deliberately has no bash, and a `#!/usr/bin/env bash` stub fails to
# exec under it -- which is exactly how a real driftAlert misconfiguration would
# look, and how this harness would silently record zero alerts.
cat > "$WORK/alert-stub" <<EOF
#!$(command -v bash)
printf '%s\n' "\$2" >> "\$ALERT_SINK"
exit 0
EOF
chmod +x "$WORK/alert-stub"

# A dead port: leg A must take the SKIP path rather than alerting. This also keeps
# the suite hermetic -- the nix sandbox has no network and no front door.
DEAD_DOOR="http://127.0.0.1:1"

run_pass() { # run_pass STATE LOG SINK
  PLUGIN_CANARY_STATE="$1" PLUGIN_CANARY_LOG="$2" \
  PLUGIN_CANARY_ALERT="$WORK/alert-stub" PLUGIN_CANARY_DOOR="$DEAD_DOOR" \
  ALERT_SINK="$3" "$CANARY" >>"$WORK/out.log" 2>&1
}

# ---------------------------------------------------------------------------
# 1. Clean log: silent, and the offset initialises at EOF rather than scanning
#    history. (The production log holds ~2500 historical matches; a first pass
#    that scans them pages on install and gets the unit masked on install.)
# ---------------------------------------------------------------------------
S1="$WORK/s1"; mkdir -p "$S1"
printf 'timestamp=1 level=INFO message="nothing to see"\n' > "$WORK/clean.log"
: > "$WORK/sink1"
run_pass "$S1" "$WORK/clean.log" "$WORK/sink1"

eq "clean log: no alerts" "0" "$(wc -l < "$WORK/sink1")"
eq "clean log: no latches" "0" "$(ls -1 "$S1/latch" 2>/dev/null | wc -l)"
eq "first pass initialises the offset at EOF, not 0" \
  "$(stat -c %s "$WORK/clean.log")" "$(awk '{print $2}' "$S1/logtail.state")"

# A pre-existing failure line BELOW the initialised offset must stay unread --
# this is the documented, accepted blind window, and it must not silently become
# a 2500-page storm.
printf '%s\n' "$REAL_LINE" > "$WORK/hist.log"
S1b="$WORK/s1b"; mkdir -p "$S1b"; : > "$WORK/sink1b"
run_pass "$S1b" "$WORK/hist.log" "$WORK/sink1b"
eq "history present at first pass is NOT scanned (accepted blind window)" \
  "0" "$(wc -l < "$WORK/sink1b")"

# ---------------------------------------------------------------------------
# 2. A failure appended after initialisation: latched, alerted, offset advanced.
# ---------------------------------------------------------------------------
printf '%s\n' "$REAL_LINE" >> "$WORK/clean.log"
: > "$WORK/sink2"
run_pass "$S1" "$WORK/clean.log" "$WORK/sink2"

eq "a new failure line is latched" "1" "$(ls -1 "$S1/latch" | wc -l)"
eq "the latch is keyed by plugin, not by line" "shell-env.ts" "$(ls -1 "$S1/latch")"
eq "a new failure line alerts once" "1" "$(wc -l < "$WORK/sink2")"
eq "with the load-failed signature" "plugin-canary:load-failed:shell-env.ts" "$(cat "$WORK/sink2")"
eq "the offset advanced to the new EOF" \
  "$(stat -c %s "$WORK/clean.log")" "$(awk '{print $2}' "$S1/logtail.state")"

# ---------------------------------------------------------------------------
# 3. THE PROPERTY. No new log content at all, yet the alert helper must be
#    re-invoked every pass -- that is what turns edge detection into level
#    alerting and lets driftAlert's backoff, escalation, and delivery retry work.
#    The pre-fix implementation scores 0 here and passes every static grep.
# ---------------------------------------------------------------------------
: > "$WORK/sink3"
run_pass "$S1" "$WORK/clean.log" "$WORK/sink3"
run_pass "$S1" "$WORK/clean.log" "$WORK/sink3"
run_pass "$S1" "$WORK/clean.log" "$WORK/sink3"

eq "live latch re-invokes the alert helper on EVERY pass (3 passes, no new lines)" \
  "3" "$(wc -l < "$WORK/sink3")"
eq "and always with the same signature, so driftAlert can throttle the episode" \
  "1" "$(sort -u "$WORK/sink3" | wc -l)"
eq "the failure is not re-latched (no duplicate evidence)" "1" "$(ls -1 "$S1/latch" | wc -l)"

# Clearing the latch (the documented manual remedy) must stop the alerts.
rm -f "$S1/latch/shell-env.ts"
: > "$WORK/sink4"
run_pass "$S1" "$WORK/clean.log" "$WORK/sink4"
eq "clearing the latch ends the episode" "0" "$(wc -l < "$WORK/sink4")"

# ---------------------------------------------------------------------------
# 4. Delivery failure at the moment of detection must not lose the alert.
#    driftAlert exits 0 and writes no state on a failed POST, so the ONLY thing
#    that saves the alert is the caller re-invoking. Stub a failing sink for the
#    detection pass, then a working one.
# ---------------------------------------------------------------------------
S5="$WORK/s5"; mkdir -p "$S5"
printf 'timestamp=1 level=INFO message="x"\n' > "$WORK/l5.log"
: > "$WORK/sink5"
run_pass "$S5" "$WORK/l5.log" "$WORK/sink5"          # initialise at EOF
printf '%s\n' "$REAL_LINE" >> "$WORK/l5.log"

cat > "$WORK/alert-failing" <<EOF
#!$(command -v bash)
exit 0
EOF
chmod +x "$WORK/alert-failing"

# Detection pass with a sink that records nothing (pigeon down).
PLUGIN_CANARY_STATE="$S5" PLUGIN_CANARY_LOG="$WORK/l5.log" \
  PLUGIN_CANARY_ALERT="$WORK/alert-failing" PLUGIN_CANARY_DOOR="$DEAD_DOOR" \
  ALERT_SINK="$WORK/sink5" "$CANARY" >>"$WORK/out.log" 2>&1

eq "delivery failed at detection: nothing recorded yet" "0" "$(wc -l < "$WORK/sink5")"
eq "but the evidence was latched before the offset advanced" "1" "$(ls -1 "$S5/latch" | wc -l)"

# Pigeon recovers. No new log line will ever be written for this failure.
: > "$WORK/sink6"
run_pass "$S5" "$WORK/l5.log" "$WORK/sink6"
eq "a later pass still delivers it (the revision-1 killer)" "1" "$(wc -l < "$WORK/sink6")"

# ---------------------------------------------------------------------------
# 5. Lock held: no state mutation whatsoever, and the pending failure survives
#    to be reported after the reset finishes.
# ---------------------------------------------------------------------------
S7="$WORK/s7"; mkdir -p "$S7"
printf 'timestamp=1 level=INFO message="x"\n' > "$WORK/l7.log"
: > "$WORK/sink7"
run_pass "$S7" "$WORK/l7.log" "$WORK/sink7"
BEFORE="$(cat "$S7/logtail.state")"
printf '%s\n' "$REAL_LINE" >> "$WORK/l7.log"

if command -v flock >/dev/null 2>&1; then
  : > /tmp/reset-workspace.lock 2>/dev/null || true
  if [ -w /tmp/reset-workspace.lock ]; then
    exec 8> /tmp/reset-workspace.lock
    if flock -n -x 8; then
      : > "$WORK/sink8"
      run_pass "$S7" "$WORK/l7.log" "$WORK/sink8"
      eq "lock held: no alert" "0" "$(wc -l < "$WORK/sink8")"
      eq "lock held: offset NOT advanced" "$BEFORE" "$(cat "$S7/logtail.state")"
      eq "lock held: nothing latched" "0" "$(ls -1 "$S7/latch" 2>/dev/null | wc -l)"
      flock -u 8; exec 8>&-
      : > "$WORK/sink9"
      run_pass "$S7" "$WORK/l7.log" "$WORK/sink9"
      eq "after the lock clears, the failure written during it IS reported" \
        "1" "$(wc -l < "$WORK/sink9")"
    else
      echo "SKIP: could not take /tmp/reset-workspace.lock exclusively"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 6. Leg A against a dead door: SKIP, never an alert. Serve-down belongs to
#    opencode-serve-canary, which already pages for it; a duplicate pager for an
#    unrelated fault is how a channel gets ignored.
# ---------------------------------------------------------------------------
case "$LEGS" in
  *A*)
    S10="$WORK/s10"; mkdir -p "$S10"
    : > "$WORK/l10.log"; : > "$WORK/sink10"
    for _ in 1 2 3 4 5 6 7 8 9 10; do run_pass "$S10" "$WORK/l10.log" "$WORK/sink10"; done
    eq "10 passes against an unreachable door raise no probe alert" "0" "$(wc -l < "$WORK/sink10")"
    eq "and the failure counter is not left claiming healthy" "0" \
      "$(cat "$S10/probe.fails" 2>/dev/null || echo 0)"
    ;;
  *)
    echo "SKIP: leg A assertions (this host runs LEGS=$LEGS)"
    ;;
esac

# ---------------------------------------------------------------------------
# 7. A partially written final line must not be consumed.
# ---------------------------------------------------------------------------
S11="$WORK/s11"; mkdir -p "$S11"
printf 'timestamp=1 level=INFO message="x"\n' > "$WORK/l11.log"
: > "$WORK/sink11"
run_pass "$S11" "$WORK/l11.log" "$WORK/sink11"
printf 'timestamp=2 level=ERROR run=z message="failed to load pl' >> "$WORK/l11.log"
: > "$WORK/sink12"
run_pass "$S11" "$WORK/l11.log" "$WORK/sink12"
eq "a half-written line is not consumed" "0" "$(wc -l < "$WORK/sink12")"
printf 'ugin" path=file:///x/plugins/late.ts error="e"\n' >> "$WORK/l11.log"
: > "$WORK/sink13"
run_pass "$S11" "$WORK/l11.log" "$WORK/sink13"
eq "and IS detected once it completes" "plugin-canary:load-failed:late.ts" "$(cat "$WORK/sink13")"

# ---------------------------------------------------------------------------
# 8. INIT_OVERSIZE: a rotation is indicated but the file is too large to be a
#    fresh rotation, so reading from 0 is refused and the gap is LATCHED.
#
# This branch had no test until workstation-fg2w, and it is precisely where the
# extraction could have detonated: the oversize alert text used to interpolate
# $DOOR -- leg A's variable -- so on a leg-B-only host (devbox) the FIRST time
# this branch was reached, `set -u` would abort the relatch loop with an unbound
# variable. Silent branches are where cross-leg coupling hides, and this suite is
# now run against BOTH hosts' real ExecStart.
#
# Sparse file: 9 MiB by `truncate`, which exceeds the 8 MiB max_reset without
# writing 9 MiB or needing a production seam to lower the threshold.
# ---------------------------------------------------------------------------
S20="$WORK/s20"; mkdir -p "$S20"
printf 'timestamp=1 level=INFO message="small"\n' > "$WORK/l20.log"
: > "$WORK/sink20"
run_pass "$S20" "$WORK/l20.log" "$WORK/sink20"   # INIT at EOF

# mv-over, NOT rm-then-recreate: `rm` frees the inode and the very next create
# in the same directory reuses the SAME inode number, so the file id is
# unchanged and no rotation is detected at all -- the test would then quietly
# exercise the ordinary READ path while appearing to cover INIT_OVERSIZE.
# Verified by measurement, not assumed. mv is also what logrotate actually does.
truncate -s 9M "$WORK/l20.new"                    # far too big to be a fresh rotation
mv "$WORK/l20.new" "$WORK/l20.log"                # new inode => rotation indicated
: > "$WORK/sink21"
run_pass "$S20" "$WORK/l20.log" "$WORK/sink21"

eq "oversize rotation is latched, not silently rescanned" "1" \
  "$(ls -1 "$S20/latch" | grep -c 'logtail-oversize')"
eq "and it alerts as a DEGRADED DETECTOR, not as a broken plugin" \
  "plugin-canary:logtail-oversize-reset" "$(head -1 "$WORK/sink21")"

# The relatch loop must survive the branch on a leg-B-only script: re-run and
# require a SECOND invocation. An unbound-variable abort would show up here as a
# missing repeat even though the latch above already exists.
: > "$WORK/sink22"
run_pass "$S20" "$WORK/l20.log" "$WORK/sink22"
eq "oversize latch re-alerts every pass (survives the relatch loop)" \
  "plugin-canary:logtail-oversize-reset" "$(head -1 "$WORK/sink22")"

# ---------------------------------------------------------------------------
# 9. RESET: a genuine small rotation IS rescanned from 0, and a failure line
#    that was written into the new file is found.
# ---------------------------------------------------------------------------
S30="$WORK/s30"; mkdir -p "$S30"
printf 'timestamp=1 level=INFO message="before rotation"\n' > "$WORK/l30.log"
: > "$WORK/sink30"
run_pass "$S30" "$WORK/l30.log" "$WORK/sink30"

printf '%s\n' "$REAL_LINE" > "$WORK/l30.new"      # small + new inode => RESET
mv "$WORK/l30.new" "$WORK/l30.log"                # (mv-over, per the note above)
: > "$WORK/sink31"
run_pass "$S30" "$WORK/l30.log" "$WORK/sink31"
eq "a small rotation is rescanned from 0 and the failure is caught" \
  "plugin-canary:load-failed:shell-env.ts" "$(head -1 "$WORK/sink31")"

# ---------------------------------------------------------------------------
# 10. A log that cannot be measured must not stay quietly inert forever.
#
# On devbox this leg is the WHOLE detector, so an unreadable log means its
# silence carries no information at all -- indistinguishable from health, which
# is the founding failure of this roadmap wearing the detector's own clothes.
# One inert pass is a transient stat failure and must stay quiet; a sustained
# streak must latch and alert.
# ---------------------------------------------------------------------------
S40="$WORK/s40"; mkdir -p "$S40"
: > "$WORK/sink40"
PLUGIN_CANARY_STATE="$S40" PLUGIN_CANARY_LOG="$WORK/does-not-exist.log" \
  PLUGIN_CANARY_ALERT="$WORK/alert-stub" PLUGIN_CANARY_DOOR="$DEAD_DOOR" \
  PLUGIN_CANARY_UNMEASURABLE_THRESHOLD=3 \
  ALERT_SINK="$WORK/sink40" "$CANARY" >>"$WORK/out.log" 2>&1
eq "one unmeasurable pass stays quiet (transient stat failure)" "0" \
  "$(wc -l < "$WORK/sink40")"

: > "$WORK/sink41"
for _ in 1 2; do
  PLUGIN_CANARY_STATE="$S40" PLUGIN_CANARY_LOG="$WORK/does-not-exist.log" \
    PLUGIN_CANARY_ALERT="$WORK/alert-stub" PLUGIN_CANARY_DOOR="$DEAD_DOOR" \
    PLUGIN_CANARY_UNMEASURABLE_THRESHOLD=3 \
    ALERT_SINK="$WORK/sink41" "$CANARY" >>"$WORK/out.log" 2>&1
done
eq "a sustained blind streak latches and alerts" \
  "plugin-canary:logtail-unmeasurable" "$(head -1 "$WORK/sink41")"

# ...and recovers by itself once the log is readable again, so a transient
# outage does not leave a latch requiring hand-clearing.
printf 'timestamp=1 level=INFO message="back"\n' > "$WORK/l40.log"
: > "$WORK/sink42"
PLUGIN_CANARY_STATE="$S40" PLUGIN_CANARY_LOG="$WORK/l40.log" \
  PLUGIN_CANARY_ALERT="$WORK/alert-stub" PLUGIN_CANARY_DOOR="$DEAD_DOOR" \
  PLUGIN_CANARY_UNMEASURABLE_THRESHOLD=3 \
  ALERT_SINK="$WORK/sink42" "$CANARY" >>"$WORK/out.log" 2>&1
eq "a readable log clears the blind latch without hand-clearing" "0" \
  "$(ls -1 "$S40/latch" 2>/dev/null | grep -c 'logtail-unmeasurable')"

printf '\n%s\n' "-- plugin-canary behaviour (LEGS=$LEGS): $pass passed, $fail failed"
if [ "$fail" -ne 0 ]; then
  echo "--- canary output ---" >&2
  cat "$WORK/out.log" >&2
  exit 1
fi
