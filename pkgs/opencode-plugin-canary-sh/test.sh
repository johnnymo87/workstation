#!/usr/bin/env bash
# Tests for opencode-plugin-canary.sh, the plugin-load canary's pure logic.
#
# Run by `nix flake check` (flake.nix, check `plugin-canary`). That wiring is the
# point: this bead already shipped a well-designed guard that ran in no CI path
# at all, and #292 landed the same day because three plugin test harnesses were
# green and unreachable. A test nothing runs is documentation with a shebang.
#
# Every case below corresponds to a defect found in the design review, and each
# one fails silently in production if the logic regresses -- which is why they are
# here rather than left to a manual once-over.

set -uo pipefail

lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/opencode-plugin-canary.sh"
# shellcheck source=/dev/null
. "$lib"

pass=0
fail=0

ok() { pass=$((pass + 1)); printf 'PASS: %s\n' "$1"; }
no() {
  fail=$((fail + 1))
  printf 'FAIL: %s\n' "$1" >&2
  printf '  expected: %s\n' "$2" >&2
  printf '  actual:   %s\n' "$3" >&2
}

eq() { # eq LABEL EXPECTED ACTUAL
  if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "$2" "$3"; fi
}

# A real load-failure line, kept byte-faithful to production output. Taken from
# ~/.local/share/opencode/log/opencode.log on cloudbox (2026-08-01 incident).
REAL_LINE='timestamp=2026-08-01T15:40:54.070Z level=ERROR run=2d30b122 message="failed to load plugin" path=file:///home/dev/.config/opencode/plugins/shell-env.ts error="Plugin export is not a function"'

# ---------------------------------------------------------------------------
# The anchored pattern
# ---------------------------------------------------------------------------

pat="$(plugin_canary_load_pattern)"

printf '%s\n' "$REAL_LINE" | grep -qE "$pat"
eq "anchored pattern matches a real production failure line" "0" "$?"

# THE false positive that has bitten this bead twice: an INFO permission-audit
# line quoting the error string in the command text a session ran.
AUDIT_LINE='timestamp=2026-08-04T10:00:00.000Z level=INFO message="evaluated permission" command="grep -E level=ERROR .*failed to load plugin /home/dev/.local/share/opencode/log/opencode.log"'
if printf '%s\n' "$AUDIT_LINE" | grep -qE "$pat"; then
  no "anchored pattern rejects an INFO audit line quoting the error string" "no match" "matched"
else
  ok "anchored pattern rejects an INFO audit line quoting the error string"
fi

# And the naive pattern this replaces MUST match it -- otherwise the test above
# proves nothing about the anchoring, only that the fixture happens not to match.
if printf '%s\n' "$AUDIT_LINE" | grep -qE 'level=ERROR .*failed to load plugin'; then
  ok "control: the unanchored pattern DOES match the audit line (so anchoring is what saves us)"
else
  no "control: unanchored pattern should match the audit line" "match" "no match"
fi

# A WARN-level line mentioning the same text must not match either.
WARN_LINE='timestamp=2026-08-04T10:00:00.000Z level=WARN message="failed to load plugin" path=file:///x/plugins/a.ts'
if printf '%s\n' "$WARN_LINE" | grep -qE "$pat"; then
  no "anchored pattern requires level=ERROR" "no match" "matched"
else
  ok "anchored pattern requires level=ERROR"
fi

# ---------------------------------------------------------------------------
# Partial-line handling (MEDIUM-5: a match split across two reads)
# ---------------------------------------------------------------------------

chunk_a="$(printf 'timestamp=1 level=INFO message="x"\ntimestamp=2 level=ERROR run=aa message="failed to load pl')"
eq "complete_lines drops an unterminated trailing fragment" \
  'timestamp=1 level=INFO message="x"' \
  "$(printf '%s' "$chunk_a" | plugin_canary_complete_lines)"

eq "complete_bytes counts only the terminated line" \
  "35" \
  "$(printf '%s' "$chunk_a" | plugin_canary_complete_bytes)"

# The split match must be found once the line completes -- i.e. resuming from the
# offset complete_bytes reported yields the WHOLE line, not a fragment. Modelled
# on a real file rather than in shell variables, because command substitution
# strips trailing newlines and would fake the very property under test.
split_log="$(mktemp)"
printf 'timestamp=1 level=INFO message="x"\ntimestamp=2 level=ERROR run=aa message="failed to load pl' > "$split_log"

# Pass 1: the second line is still being written, so nothing is consumed past it.
consumed="$(plugin_canary_complete_bytes < "$split_log")"
eq "pass 1 consumes only the complete line, leaving the partial one" "35" "$consumed"
eq "pass 1 finds no match (the failure line is incomplete)" "0" \
  "$(tail -c "+1" "$split_log" | head -c "$consumed" | plugin_canary_complete_lines | grep -cE "$pat")"

# The writer finishes that line (and it is a real failure line).
printf '\n%s\n' "$REAL_LINE" >> "$split_log"

# Pass 2: resume at the stored offset. The completed line must be seen whole.
eq "pass 2 detects the line that was split across the read boundary" "1" \
  "$(tail -c "+$((consumed + 1))" "$split_log" | plugin_canary_complete_lines | grep -cE "$pat")"
rm -f "$split_log"

eq "complete_bytes is 0 when nothing is terminated" \
  "0" \
  "$(printf 'no newline here' | plugin_canary_complete_bytes)"

eq "complete_bytes on empty input is 0" "0" "$(printf '' | plugin_canary_complete_bytes)"

# ---------------------------------------------------------------------------
# Plugin identity extraction (driftAlert signatures + latch filenames)
# ---------------------------------------------------------------------------

eq "plugin key from a real line" "shell-env.ts" "$(plugin_canary_plugin_key "$REAL_LINE")"

# caveman deploys as a DIRECTORY, so a basename-only key would be `plugin.js` --
# ambiguous, and wrong the moment a second directory-shaped plugin exists.
eq "plugin key keeps the subdirectory for a directory-shaped plugin" \
  "caveman_plugin.js" \
  "$(plugin_canary_plugin_key 'timestamp=1 level=ERROR run=x message="failed to load plugin" path=file:///home/dev/.config/opencode/plugins/caveman/plugin.js error="x"')"

# A plugin outside the plugins dir (npm-installed) still needs a distinct key
# rather than being dropped.
eq "plugin key falls back to the final component outside the plugins dir" \
  "anthropic-auth.js" \
  "$(plugin_canary_plugin_key 'timestamp=1 level=ERROR run=x message="failed to load plugin" path=file:///home/dev/.config/opencode/node_modules/@ex/anthropic-auth.js error="x"')"

eq "plugin key is empty when there is no path field" "" \
  "$(plugin_canary_plugin_key 'timestamp=1 level=ERROR message="failed to load plugin"')"

# The key becomes a filename. A traversal sequence from a log line must not
# survive into a path.
key="$(plugin_canary_plugin_key 'timestamp=1 level=ERROR message="failed to load plugin" path=file:///x/plugins/../../etc/passwd error="x"')"
case "$key" in
  */*) no "plugin key never contains a slash" "no slash" "$key" ;;
  *) ok "plugin key never contains a slash" ;;
esac

eq "run id is extracted for the alert text" "2d30b122" "$(plugin_canary_run_id "$REAL_LINE")"
eq "run id is empty when absent" "" "$(plugin_canary_run_id 'timestamp=1 level=ERROR message="failed to load plugin"')"

# ---------------------------------------------------------------------------
# Window action (first-run EOF, rotation, truncation)
# ---------------------------------------------------------------------------

eq "no state -> INIT (do not scan ~2500 historical matches)" \
  "INIT" "$(plugin_canary_window_action "" "" "1:2" "500")"
eq "missing offset -> INIT" "INIT" "$(plugin_canary_window_action "1:2" "" "1:2" "500")"
eq "corrupt non-numeric offset -> INIT" "INIT" "$(plugin_canary_window_action "1:2" "abc" "1:2" "500")"
eq "same file, grown -> READ" "READ" "$(plugin_canary_window_action "1:2" "100" "1:2" "500")"
eq "same file, unchanged -> NOOP" "NOOP" "$(plugin_canary_window_action "1:2" "500" "1:2" "500")"
eq "inode changed (move-and-recreate rotation) -> RESET" \
  "RESET" "$(plugin_canary_window_action "1:2" "500" "1:9" "20")"

# A "rotation" onto a file that is already huge is not a rotation. Reading it from
# 0 would drag hundreds of MB through a minutely unit and re-latch every historical
# failure in it -- so behave as INIT, but say so rather than skipping quietly.
eq "reset onto an oversize file -> INIT_OVERSIZE, not RESET" \
  "INIT_OVERSIZE" "$(plugin_canary_window_action "1:2" "500" "1:9" "999999999")"
eq "reset onto an oversize file (truncation shape) -> INIT_OVERSIZE" \
  "INIT_OVERSIZE" "$(plugin_canary_window_action "1:2" "999999999" "1:2" "99999999")"
eq "the oversize bound is configurable (20 bytes exceeds a 10-byte bound)" \
  "INIT_OVERSIZE" "$(plugin_canary_window_action "1:2" "500" "1:9" "20" "10")"
eq "the oversize bound is configurable (20 bytes is under a 100-byte bound)" \
  "RESET" "$(plugin_canary_window_action "1:2" "500" "1:9" "20" "100")"
eq "a normal grow is unaffected by the oversize bound" \
  "READ" "$(plugin_canary_window_action "1:2" "100" "1:2" "999999999")"
eq "size below offset (copy-truncate rotation) -> RESET" \
  "RESET" "$(plugin_canary_window_action "1:2" "500" "1:2" "20")"
# A stale offset past EOF must NOT read as NOOP forever: that is silence
# indistinguishable from health.
eq "offset past EOF -> RESET, not NOOP" "RESET" "$(plugin_canary_window_action "1:2" "999" "1:2" "10")"

tmp="$(mktemp)"; printf 'x\n' > "$tmp"
fid="$(plugin_canary_file_id "$tmp")"
case "$fid" in
  *:*) ok "file_id returns device:inode" ;;
  *) no "file_id returns device:inode" "d:i" "$fid" ;;
esac
eq "file_id on a missing file is empty" "" "$(plugin_canary_file_id "$tmp.nope")"
rm -f "$tmp"

# ---------------------------------------------------------------------------
# Leg A status table (MEDIUM-4)
# ---------------------------------------------------------------------------

eq "healthy: tool present and providers 200" \
  "HEALTHY" "$(plugin_canary_probe_action 200 yes 200)"
eq "the QUIET shape: reachable, but the tool is gone" \
  "ALERT:tool-missing" "$(plugin_canary_probe_action 200 no 200)"
eq "the LOUD shape: providers 500 (the literal devbox outage symptom)" \
  "ALERT:providers-unhealthy" "$(plugin_canary_probe_action 200 yes 500)"

# Door/anchor down is opencode-serve-canary's jurisdiction; it already pages.
# Alerting here too would make this a duplicate pager for an unrelated fault.
for s in "" 000 502 503; do
  eq "unreachable ($s on tool route) -> SKIP" "SKIP" "$(plugin_canary_probe_action "$s" no 500)"
  eq "unreachable ($s on providers route) -> SKIP" "SKIP" "$(plugin_canary_probe_action 200 yes "$s")"
done

# These never self-heal, so silence is the wrong default: a vanished
# experimental/ route must not read as health.
eq "404 (upstream moved the route) -> distinct cannot-evaluate alert" \
  "CANNOT_EVALUATE:404" "$(plugin_canary_probe_action 404 no 200)"
eq "401 (auth drift) -> distinct cannot-evaluate alert" \
  "CANNOT_EVALUATE:401" "$(plugin_canary_probe_action 401 no 200)"
eq "unexpected providers status -> cannot-evaluate, not health" \
  "CANNOT_EVALUATE:418" "$(plugin_canary_probe_action 200 yes 418)"

# SKIP must win over CANNOT_EVALUATE: if the door is unreachable we cannot learn
# anything about the other route, and the unreachable case is not ours to page.
eq "unreachable wins over cannot-evaluate" \
  "SKIP" "$(plugin_canary_probe_action 404 no 503)"

# ---------------------------------------------------------------------------
# The canary script's own invariants, asserted statically.
#
# These are grep assertions against the deployed script rather than behavioural
# tests, because the properties are about ORDERING inside a systemd oneshot that
# talks to pigeon and a 668MB log. The behavioural versions live in the
# post-deploy controls recorded in the roadmap. A static assertion that fails
# loudly on an edit beats a comment that hopes.
# ---------------------------------------------------------------------------

canary_src="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/hosts/cloudbox/configuration.nix"

if [ -f "$canary_src" ]; then
  # HIGH-1: the whole point of the latch. Detection is edge (a rejected file logs
  # once per serve start) but driftAlert is a THROTTLE, not a scheduler -- it
  # re-alerts only when the caller re-invokes with the same signature, and it
  # swallows a failed POST (exit 0 always, state written only on 2xx). A canary
  # that calls it once per detection sends exactly one warning-severity page and
  # then goes quiet forever, which is the 2026-07-26 frontdoor incident rebuilt
  # (760 detections, one page, missed, 12h39m silence) while appearing to use the
  # escalation logic written to prevent it.
  if grep -q 'PLUGIN_CANARY_LATCH_BEFORE_OFFSET' "$canary_src"; then
    ok "canary marks the latch-before-offset ordering (HIGH-1)"
  else
    no "canary marks the latch-before-offset ordering (HIGH-1)" "marker present" "missing"
  fi

  if grep -q 'PLUGIN_CANARY_RELATCH_EVERY_PASS' "$canary_src"; then
    ok "canary marks the re-alert-every-pass loop (HIGH-1)"
  else
    no "canary marks the re-alert-every-pass loop (HIGH-1)" "marker present" "missing"
  fi

  # The lock skip must precede any state mutation, or error lines written during
  # the nightly reset are consumed by an offset advance and never examined.
  if grep -q 'PLUGIN_CANARY_LOCK_SKIP_BEFORE_STATE' "$canary_src"; then
    ok "canary marks the lock-skip-before-state ordering"
  else
    no "canary marks the lock-skip-before-state ordering" "marker present" "missing"
  fi

  # Never restart anything: that is opencode-serve-canary's contract, and a
  # restart cannot fix a bad plugin file anyway.
  canary_block="$(LC_ALL=C sed -n '/opencode-plugin-canary = /,/^  };$/p' "$canary_src")"
  if printf '%s' "$canary_block" | grep -qE 'systemctl[[:space:]]+(restart|stop|kill)'; then
    no "canary never restarts a serve" "no systemctl restart/stop/kill" "found one"
  else
    ok "canary never restarts a serve"
  fi
else
  no "cloudbox configuration.nix is where the canary lives" "found" "missing: $canary_src"
fi

# ---------------------------------------------------------------------------
# The probe routes must stay ANCHOR-forwarded.
#
# MEDIUM-3: sixteen route rows already carry `poolSafe: true`, promoted "by
# cross-member diff", and /experimental/tool/ids PASSES a cross-member diff on
# any healthy day -- all serves read the same plugin dir. So it is a natural
# promotion candidate and the promotion method cannot see why it must not be.
# Promotion would silently convert leg A to round-robin: `forward-pool` fails
# over only on UNREACHABLE, so a member that is alive but plugin-broken answers
# wrong content ~1 probe in 4 and can never cross a 7-consecutive threshold. A
# detectable failure would become a permanently suppressed one.
#
# Asserted here so the PROMOTING pr goes red, which is where the knowledge is
# needed.
# ---------------------------------------------------------------------------

routes="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/pkgs/opencode-frontdoor/src/routes.classification.ts"

if [ -f "$routes" ]; then
  for r in "/experimental/tool/ids" "/config/providers"; do
    row="$(LC_ALL=C grep -F "path: \"$r\"" "$routes" | head -1)"
    if [ -z "$row" ]; then
      no "probe route $r is present in the classification table" "a row" "none"
    elif printf '%s' "$row" | grep -q 'poolSafe'; then
      no "probe route $r must NOT be poolSafe (see comment above)" "no poolSafe" "$row"
    elif printf '%s' "$row" | grep -q 'global-ro'; then
      ok "probe route $r is anchor-forwarded global-ro"
    else
      no "probe route $r must be global-ro" "global-ro" "$row"
    fi
  done

  # The reasoning must be discoverable from the table itself, not only from this
  # test's failure message.
  if grep -q 'plugin-canary' "$routes"; then
    ok "classification table names the canary dependency"
  else
    no "classification table names the canary dependency" "a note mentioning plugin-canary" "none"
  fi
else
  no "frontdoor route classification table exists" "found" "missing: $routes"
fi

printf '\n%s\n' "-- opencode-plugin-canary: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
