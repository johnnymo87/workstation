#!/usr/bin/env bash
# Regression tests for disk-watch, the between-nightlies disk threshold alarm.
# Run: bash users/dev/test-disk-watch.sh
#
# WHY THIS EXISTS. On 2026-08-28 the cloudbox root filesystem reached 0 bytes free and killed a
# running automation episode mid-flight (`echo: write error: No space left on device`). It was the
# SECOND such event in four days -- 2026-08-25 20:18 hit 97% -- and both were resolved only because
# a human happened to look. disk-cleanup.timer runs once a day at 03:00, so nothing watched the
# other 23 hours.
#
# The measured series from the nightly logs is what set the threshold, and it is worth keeping
# because it refutes the obvious objection (that 85% would page every day):
#
#   quiet days   +47G, +48G, +55G overnight   peak 81%, 82%, 84%
#   active days  +117G, +112G                 peak 97%, 100%   <- both incidents
#
# 85% of 393G is 334G, which sits ABOVE the worst quiet-day peak (314G) and well below both
# incidents. Replayed against 2026-08-28, it would have fired around 13:30 -- five hours before the
# box filled.
#
# THIS WATCHER ONLY WARNS. It deliberately does NOT start disk-cleanup.service, and one of the tests
# below pins that. Adversarial review found the auto-cleanup version was net-negative for two
# independent reasons: disk-cleanup runs `cleanup_nix` FIRST (disk-cleanup.nix, "# --- Main ---"),
# and the cleaning-disk skill documents that above ~90% a nix GC can generate enough I/O pressure to
# stop socket-activated sshd from answering -- so triggering at 90% would launch the box-wedging
# operation exactly and only inside the danger zone. And it would not even have helped: the bazel
# purge SKIPS any output base whose server PID is alive, which during a live build spike is all of
# them. Hazard constant, benefit near zero.

#
# TWO HOSTS, ONE SUITE. disk-cleanup.nix generates disk-watch from a single
# mkDiskWatch function and instantiates it per host, because cloudbox and devbox
# cannot share thresholds -- devbox's ORDINARY baseline is 84% on a 149G root
# (measured 2026-09-13, after a GC), which is cloudbox's alarm line. So the
# threshold-specific assertions below read their percentages from the
# environment, defaulting to cloudbox's. checks.disk-watch-tests runs this
# against the cloudbox script with the defaults; checks.disk-watch-devbox-tests
# runs the SAME assertions against the devbox script with devbox's numbers.
#
# The defaults are cloudbox's on purpose: a suite whose thresholds all had to be
# supplied would silently test nothing if a caller forgot to supply them, and the
# tally would still read green.

set -o errexit -o nounset -o pipefail

# Percentages that bracket the host's WARN_PCT/CLEAR_PCT. Defaults = cloudbox
# (warn 85, clear 80); devbox passes its own (warn 90, clear 86).
QUIET_PCT="${DISK_WATCH_TEST_QUIET_PCT:-84}"       # highest value that must NOT alert
WARN_PCT="${DISK_WATCH_TEST_WARN_PCT:-85}"         # lowest value that MUST alert
DEADBAND_PCT="${DISK_WATCH_TEST_DEADBAND_PCT:-82}" # below warn, at/above clear: state survives
CLEARED_PCT="${DISK_WATCH_TEST_CLEARED_PCT:-79}"   # below clear: state is dropped
# A string the alert text must contain, naming the remedy for THIS host. Cloudbox
# points at its nightly reclaimer; devbox has none and points at a cache path.
#
# `-` and NOT `:-`, deliberately. With `:-`, an explicitly EMPTY value silently
# becomes the other host's token, which is a confusing failure at best and a
# silent pass at worst. With `-`, an explicit empty survives to the guard below
# and fails loudly, which is what a caller who wrote `TOKEN=` deserves to see.
REMEDY_TOKEN="${DISK_WATCH_TEST_REMEDY_TOKEN-disk-cleanup}"

# Sanity-check the bracket itself, so a caller that passes a nonsensical set gets
# a hard failure instead of a green run that asserted nothing. Without this, e.g.
# QUIET_PCT >= WARN_PCT would make "quiet" and "warns" contradictory and one of
# them would be trivially satisfiable by a broken script.
[ "$QUIET_PCT" -lt "$WARN_PCT" ] \
  || { echo "FAIL: QUIET_PCT ($QUIET_PCT) must be below WARN_PCT ($WARN_PCT)"; exit 1; }
[ "$CLEARED_PCT" -lt "$DEADBAND_PCT" ] \
  || { echo "FAIL: CLEARED_PCT ($CLEARED_PCT) must be below DEADBAND_PCT ($DEADBAND_PCT)"; exit 1; }
[ "$DEADBAND_PCT" -lt "$WARN_PCT" ] \
  || { echo "FAIL: DEADBAND_PCT ($DEADBAND_PCT) must be below WARN_PCT ($WARN_PCT)"; exit 1; }
# An EMPTY remedy token would make `grep -q -- ""` match any alert text at all,
# so the remedy assertion would pass against a script that named no remedy --
# a vacuous green in the one assertion that checks alert CONTENT rather than
# thresholds. Caught in adversarial review of this parameterization. Reachable
# only because REMEDY_TOKEN uses `-` rather than `:-` above; verified to fire.
[ -n "$REMEDY_TOKEN" ] \
  || { echo "FAIL: REMEDY_TOKEN is empty; the remedy assertion would match anything"; exit 1; }

# A comfortably-alarming reading used by the alert-contract section. 91 is above
# both hosts' warn lines, so it needs no per-host value -- but it is checked, not
# assumed, because a future host with a higher line would otherwise turn every
# assertion in section 4 into a vacuous pass against an empty log.
ALERT_PCT="${DISK_WATCH_TEST_ALERT_PCT:-91}"
[ "$ALERT_PCT" -ge "$WARN_PCT" ] \
  || { echo "FAIL: ALERT_PCT ($ALERT_PCT) must be at or above WARN_PCT ($WARN_PCT)"; exit 1; }

# Which host's script to evaluate when DISK_WATCH_SRC is not supplied.
DISK_WATCH_ATTR="${DISK_WATCH_ATTR:-cloudbox}"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/disk-watch.XXXXXX")"
trap 'rm -rf "$tmpdir"' EXIT

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; shift || true; for l in "$@"; do printf '      %s\n' "$l"; done; }

script_src="$tmpdir/disk-watch"

# Same seam as test-disk-cleanup-worktrees.sh: prefer an explicitly supplied source (so the flake
# check never has to invoke nix inside a build sandbox), else evaluate the real home.file text.
# Either way the bytes under test are the bytes that ship.
if [ -n "${DISK_WATCH_SRC:-}" ]; then
  cp "$DISK_WATCH_SRC" "$script_src"
else
  nix --extra-experimental-features 'nix-command flakes dynamic-derivations' \
    eval --raw "git+file:$repo_root#homeConfigurations.$DISK_WATCH_ATTR.config.home.file.\".local/bin/disk-watch\".text" \
    > "$script_src"
fi
[ -s "$script_src" ] || { echo "FAIL: empty disk-watch source"; exit 1; }
chmod +x "$script_src"

# --- harness -------------------------------------------------------------------------------------
# A stub `df` shadowed onto PATH, so the script under test runs its REAL parsing code against
# realistic `df -P` output. Injecting a percentage directly would have tested nothing about the
# parsing, which is the part most likely to be wrong.
stub_bin="$tmpdir/bin"
mkdir -p "$stub_bin"

# Stubs get an ABSOLUTE bash shebang, resolved from the running interpreter. `#!/usr/bin/env bash`
# does not work inside a nix build sandbox -- /usr/bin/env is not there -- and a stub that fails to
# exec is invisible: `df` then resolves to the real one and the suite silently tests the host's disk
# instead of the injected percentage. Same fix as test-disk-cleanup-worktrees.sh.
bash_bin="$(command -v bash)"

# The PATH the script under test is given. disk-watch.service sets
# /run/wrappers/bin:/run/current-system/sw/bin, which does not exist inside a build sandbox, so the
# coreutils it calls (tail, mkdir, rm) are picked up from the caller's PATH there. Appending rather
# than replacing keeps the real unit's directories first when this is run on cloudbox. What is
# load-bearing below is `env -i` -- that NOTHING other than HOME and PATH reaches the script -- not
# which directories PATH happens to name.
base_path="/run/current-system/sw/bin:/usr/bin:/bin:$PATH"

printf '#!%s\n' "$bash_bin" > "$stub_bin/df"
cat >> "$stub_bin/df" <<'DFEOF'
# Mimics `df -P <path>`: a header line, then one data line. Percentage comes from DF_PCT.
echo "Filesystem     1024-blocks      Used Available Capacity Mounted on"
echo "/dev/nvme0n1p2   412114176 ${DF_USED:-300000000} ${DF_AVAIL:-80000000}     ${DF_PCT:-50}% /"
DFEOF
chmod +x "$stub_bin/df"

# A stub alert helper recording exactly how it was called. The real one posts to pigeon; here we
# only care that the contract is honoured.
alert_log="$tmpdir/alert.log"
printf '#!%s\n' "$bash_bin" > "$stub_bin/fake-alert"
cat >> "$stub_bin/fake-alert" <<ALEOF
{
  echo "CALL"
  echo "  state=\$1"
  echo "  sig=\$2"
  echo "  text=\$3"
  echo "  ttl=\${4:-}"
  echo "  max=\${5:-}"
} >> "$alert_log"
# Mimic the real helper's contract: it owns its own state file and writes it after a successful post.
printf '%s\n1\n%s\n' "\$2" "\$(date +%s)" > "\$1"
exit 0
ALEOF
chmod +x "$stub_bin/fake-alert"

state_dir="$tmpdir/state"
mkdir -p "$state_dir" "$tmpdir/home"
state_file="$state_dir/disk-watch.alert"

# `env -i` ON PURPOSE, and this is the most load-bearing line in the harness.
#
# disk-watch.service sets ONLY HOME and PATH (see disk-cleanup.nix). An earlier revision of this
# suite inherited the developer's interactive environment and reported 17/17 green on a script that
# referenced $USER -- which is unbound under the unit's environment, and which `set -u` turns into
# an abort BEFORE the alert is sent. The unit would have gone into `failed` at exactly the moment
# the disk filled: the precise failure the "does not fail the watcher" tests below exist to catch,
# passing them while shipping it.
#
# So the script under test gets the unit's environment and nothing else. If a future edit reaches
# for an ambient variable, it fails here instead of in production at 100% full.
run_at() { # run_at <pct> [extra env assignments...]
  local pct="$1"; shift || true
  : > "$alert_log"
  env -i \
      PATH="$stub_bin:$base_path" \
      HOME="$tmpdir/home" \
      DF_PCT="$pct" \
      DISK_WATCH_ALERT="$stub_bin/fake-alert" \
      DISK_WATCH_STATE="$state_file" \
      "$@" \
      "$script_src" 2>"$tmpdir/stderr.txt"
}

alerted() { [ -s "$alert_log" ]; }

# --- 1. the threshold itself ----------------------------------------------------------------------

run_at 70 || true
alerted && bad "70% is quiet" "alerted at 70%, far below any threshold" || ok "70% is quiet"

run_at "$QUIET_PCT" || true
alerted && bad "$QUIET_PCT% is quiet (this host's worst normal reading)" \
  "on cloudbox 84% was the highest normal pre-nightly peak in the measured series; on devbox 84% is
   the post-GC BASELINE. Either way, alerting at the host's ordinary level is the daily-wallpaper
   failure that makes an alarm worthless -- and worse than absent, since it also burns the shared
   Telegram channel the other canaries use" \
  || ok "$QUIET_PCT% is quiet (this host's worst normal reading)"

run_at "$WARN_PCT" || true
alerted && ok "$WARN_PCT% warns" \
  || bad "$WARN_PCT% warns" "the threshold is >=$WARN_PCT, so $WARN_PCT itself must fire"

run_at 97 || true
alerted && ok "97% warns (the 2026-08-25 incident level)" \
  || bad "97% warns" "this is a real incident level from the measured series"

run_at 100 || true
alerted && ok "100% warns (the 2026-08-28 incident level)" \
  || bad "100% warns" "the box was at 0 bytes free and nothing noticed"

# --- 2. warn-only: it must NEVER start the cleanup ------------------------------------------------
# Pinned because the first draft of this design DID auto-start disk-cleanup.service at 90%, and
# review established that is net-negative. If someone re-adds it, this fails.
#
# ASSERTED BEHAVIOURALLY, by stubbing systemctl and checking it is never invoked -- NOT by grepping
# the source for "disk-cleanup" or "systemctl". A text assertion is wrong here and the first draft
# of this file got it wrong in a way that could not pass: the alert text is REQUIRED (below) to name
# `systemctl --user start disk-cleanup.service` as the remedy, so the source legitimately contains
# both strings. Grepping a file for a string that the file is supposed to discuss proves nothing --
# it is the same defect that let two mutations survive in a sibling repo's suite.
printf '#!%s\n' "$bash_bin" > "$stub_bin/systemctl"
cat >> "$stub_bin/systemctl" <<SCEOF
echo "systemctl \$*" >> "$tmpdir/systemctl.log"
exit 0
SCEOF
chmod +x "$stub_bin/systemctl"

: > "$tmpdir/systemctl.log"
run_at 95 || true
[ -s "$tmpdir/systemctl.log" ] \
  && bad "the watcher starts no units, even at 95%" \
         "auto-starting the cleanup runs nix GC FIRST, inside the >90% zone the cleaning-disk skill
          says can wedge sshd into needing a console reset -- and it reclaims almost nothing during a
          live build spike anyway, because the bazel purge skips every output base whose server is
          alive. Constant hazard, near-zero benefit." \
         "$(cat "$tmpdir/systemctl.log")" \
  || ok "the watcher starts no units, even at 95%"

# --- 3. hysteresis: recovery clears state, the dead band does not ---------------------------------
# The helper treats a state file as "this episode already alerted". If we cleared it the moment we
# dropped below 85, a sawtooth across the boundary would re-alert on every crossing -- the exact
# alert storm the helper exists to prevent. So recovery is a LOWER floor, with a dead band between.

printf 'disk-warn\n3\n1756000000\n' > "$state_file"
run_at "$DEADBAND_PCT" || true
[ -f "$state_file" ] && ok "$DEADBAND_PCT% is in the dead band: state survives, no re-arm" \
  || bad "$DEADBAND_PCT% is in the dead band: state survives, no re-arm" \
         "clearing state inside the dead band lets a sawtooth across the warn line alert on every
          single crossing"

printf 'disk-warn\n3\n1756000000\n' > "$state_file"
run_at "$CLEARED_PCT" || true
[ -f "$state_file" ] \
  && bad "below the clear line ($CLEARED_PCT%) the episode is over and state is cleared" \
         "a stale state file makes the NEXT episode's first alert claim 'STILL UNRESOLVED: alert #4,
          first reported 400h ago', which is false and trains the reader to ignore it" \
  || ok "below the clear line ($CLEARED_PCT%) the episode is over and state is cleared"

# --- 4. the alert contract ------------------------------------------------------------------------

run_at "$ALERT_PCT" || true
grep -q 'ttl=900' "$alert_log" \
  && ok "uses the house backoff base (900s)" \
  || bad "uses the house backoff base (900s)" "$(cat "$alert_log")"
grep -q 'max=14400' "$alert_log" \
  && ok "uses the house backoff cap (14400s)" \
  || bad "uses the house backoff cap (14400s)" "$(cat "$alert_log")"
grep -q 'sig=disk-warn' "$alert_log" \
  && ok "signature is a stable band, not the raw percentage" \
  || bad "signature is a stable band, not the raw percentage" \
         "a percentage signature makes 86->87 read as a new episode and defeats the backoff entirely"

# The text has to carry both the number and what to DO about it. An alert that says only "disk is
# full" costs the reader a terminal session before they can act.
grep -q "$ALERT_PCT%" "$alert_log" \
  && ok "the alert text states the actual percentage" || bad "the alert text states the actual percentage" "$(cat "$alert_log")"
grep -q -- "$REMEDY_TOKEN" "$alert_log" \
  && ok "the alert text names the remedy ($REMEDY_TOKEN)" \
  || bad "the alert text names the remedy ($REMEDY_TOKEN)" \
         "the reader should not have to go find the command. NOTE this string is per-host: cloudbox
          points at its nightly reclaimer, devbox has none and must point at a nix GC instead --
          shipping cloudbox's text to devbox would name a unit that does not exist there" \
         "$(cat "$alert_log")"

# --- 5. it must not break its own timer -----------------------------------------------------------
# A watcher that exits non-zero puts its unit in `failed`, and a failed unit is one nobody looks at.
# The alert helper is explicitly documented as never aborting its caller; the watcher must be at
# least as safe, including when the helper itself is broken or missing.

printf '#!%s\n' "$bash_bin" > "$stub_bin/broken-alert"
cat >> "$stub_bin/broken-alert" <<'BAEOF'
echo "boom" >&2
exit 3
BAEOF
chmod +x "$stub_bin/broken-alert"

minimal_run() { # minimal_run <pct> <alert-cmd>  -- the unit's environment, nothing more
  env -i PATH="$stub_bin:$base_path" HOME="$tmpdir/home" \
      DF_PCT="$1" DISK_WATCH_ALERT="$2" DISK_WATCH_STATE="$state_file" \
      "$script_src"
}

rm -f "$state_file"
if minimal_run 95 "$stub_bin/broken-alert" >/dev/null 2>&1; then
  ok "a failing alert helper does not fail the watcher"
else
  bad "a failing alert helper does not fail the watcher" \
      "exit non-zero puts disk-watch.service in 'failed', which is a unit nobody reads"
fi

rm -f "$state_file"
if minimal_run 95 "$tmpdir/does-not-exist" >/dev/null 2>&1; then
  ok "a MISSING alert helper does not fail the watcher"
else
  bad "a MISSING alert helper does not fail the watcher" \
      "a store path that moved must degrade to silence-with-a-log, not to a failed unit"
fi

# THE UNIT'S ENVIRONMENT IS THE WHOLE ENVIRONMENT. Pinned separately from the runs above because
# those could all be made to pass by a script that happens not to touch an ambient variable on the
# paths they exercise. This asserts the property directly: with only HOME and PATH set -- exactly
# what disk-cleanup.nix gives the service -- the script still completes and still alerts.
rm -f "$state_file"
if env -i PATH="$stub_bin:$base_path" HOME="$tmpdir/home" \
       DF_PCT=95 DISK_WATCH_ALERT="$stub_bin/fake-alert" DISK_WATCH_STATE="$state_file" \
       "$script_src" >/dev/null 2>"$tmpdir/bare.txt"; then
  ok "runs under the unit's environment (HOME and PATH only)"
else
  bad "runs under the unit's environment (HOME and PATH only)" \
      "the service sets no USER, no XDG_*, no LOGNAME -- an unbound variable under 'set -u' aborts
       the script before it can alert, failing the unit at exactly 100% full" \
      "$(cat "$tmpdir/bare.txt")"
fi

# --- 6. parsing ------------------------------------------------------------------------------------
# `df` prints a header. Reading the wrong line yields the literal string "Capacity", and a numeric
# comparison against that is either a syntax error or, worse, a silent 0 that never alerts.

run_at 100 || true
alerted && ok "parses the data line, not the header" || bad "parses the data line, not the header" "$(cat "$tmpdir/stderr.txt")"

if grep -qE 'df[^|]*\|[^|]*head' "$script_src"; then
  bad "reads the last line of df, not the first" "head would read the header row"
else
  ok "reads the last line of df, not the first"
fi

# --- tally (MUST BE LAST) ---------------------------------------------------------------------------
# Anything appended below this point RUNS, PRINTS, and CANNOT change the exit status. Two suites in
# a sibling repo were silently in that state for weeks. Append above, never below.
printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
