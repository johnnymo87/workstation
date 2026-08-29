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

set -o errexit -o nounset -o pipefail

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
    eval --raw "git+file:$repo_root#homeConfigurations.cloudbox.config.home.file.\".local/bin/disk-watch\".text" \
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

run_at 84 || true
alerted && bad "84% is quiet (the worst measured quiet-day peak)" \
  "84% was the highest normal pre-nightly peak in the measured series; alerting here is the
   daily-wallpaper failure that makes an alarm worthless" \
  || ok "84% is quiet (the worst measured quiet-day peak)"

run_at 85 || true
alerted && ok "85% warns" || bad "85% warns" "the threshold is >=85, so 85 itself must fire"

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
run_at 82 || true
[ -f "$state_file" ] && ok "82% is in the dead band: state survives, no re-arm" \
  || bad "82% is in the dead band: state survives, no re-arm" \
         "clearing state at 82 lets an 84<->86 sawtooth alert on every single crossing"

printf 'disk-warn\n3\n1756000000\n' > "$state_file"
run_at 79 || true
[ -f "$state_file" ] \
  && bad "below 79% the episode is over and state is cleared" \
         "a stale state file makes the NEXT episode's first alert claim 'STILL UNRESOLVED: alert #4,
          first reported 400h ago', which is false and trains the reader to ignore it" \
  || ok "below 79% the episode is over and state is cleared"

# --- 4. the alert contract ------------------------------------------------------------------------

run_at 91 || true
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
grep -q '91%' "$alert_log" \
  && ok "the alert text states the actual percentage" || bad "the alert text states the actual percentage" "$(cat "$alert_log")"
grep -q 'disk-cleanup' "$alert_log" \
  && ok "the alert text names the remedy" \
  || bad "the alert text names the remedy" "the reader should not have to go find the command"

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
