#!/usr/bin/env bash
# opencode-plugin-canary.sh -- pure logic for the plugin-load canary (E2).
#
# WHY THIS EXISTS AS A SOURCEABLE LIBRARY:
# The canary that consumes this is a systemd oneshot. Everything hard about it --
# byte-offset windowing over a shared 668MB log, rotation detection, the
# partial-line rule, latch lifecycle, and the probe status table -- is logic that
# cannot be exercised by looking at a green timer. Bead workstation-5yox exists
# because a guard was verified in the wrong role, and its own roadmap then
# shipped a second guard wired into no CI path at all. So the logic lives here,
# in functions that take arguments and echo results, and pkgs/../test.sh runs
# them in `nix flake check`.
#
# Consumers: hosts/cloudbox/configuration.nix (systemd.services.opencode-plugin-canary).
#
# ---------------------------------------------------------------------------
# LOADER_SEMANTICS_PIN: 1.17.13
#
# The pattern in plugin_canary_load_pattern and the `path=file://...` field that
# plugin_canary_plugin_key parses are opencode's LOADER INTERNALS, not our own
# output. `opencode-patched` auto-bumps every 8 hours. If upstream rewords that
# log line or restructures the field, this canary's log leg goes BLIND -- and it
# is the only leg covering 8 of the 9 deployed plugin files, including the two
# external ones (opencode-pigeon.ts, superpowers.js) that have no build-time
# cover at all. Worse, it fails green: test.sh fixtures below carry the old
# string and keep passing.
#
# That is the exact rot the LOADER_VERSION pin was built for, so this marker is
# coupled into users/dev/test-loader-pin.sh alongside the replica, the fixtures,
# and the bundle checkPhase. When the pin moves, re-read the `logError` call in
# the refreshed fixtures (assets/opencode/plugins/test/fixtures/plugin-index.ts)
# and confirm the message string and the path= field still match before moving
# this marker. Do not move the marker to make the guard quiet.
#
# THE CALL SITE IS NOT THE WHOLE CONTRACT. Everything this script parses is
# produced by the log RENDERER, not by the loader, and re-reading only the
# logError call will miss a renderer change completely. On a pin bump check
# `assets/opencode/plugins/test/fixtures/logging.ts` (upstream
# packages/core/src/observability/logging.ts) for all four of:
#
#   * `timestamp` first and `level` second in the field list (formatter():10-16)
#     -- the anchor in plugin_canary_load_pattern depends on that ORDER.
#   * the quoting rule in format() -- `/^[^\s="\\]+$/ ? value : JSON.stringify`.
#     A `file://` path has no spaces, so it renders UNQUOTED as path=file://...
#     If that regex tightens, the field becomes path="file://..." and
#     plugin_canary_plugin_key stops matching -- per-file attribution silently
#     collapses to one shared `unknown` latch.
#   * annotations rendered FLAT (`path=`), not namespaced (`annotations.path=`).
#   * the log filename, `opencode.log` (fileLogger()) -- upstream has changed
#     log naming once already; see the note further down.
#
# `Logger.formatStructured`'s own output (level casing, timestamp format) comes
# from the effect library and is one layer below even that -- vendoring cannot
# pin it. If a bump changes those, only reading a real log line will show it.
#
# LOADER_PATCH_SHA256: a35336c7bcd4c61e7920d53720d270c92f53feac589418428b1a48bbc8e4303a
#
# The second identity pinned here, and the one that moves independently of the
# version above: OUR patch, `plugin-loader-observability.patch`. Upstream logs
# NOTHING at the four report.error stages or at report.missing -- measured, a
# real unpatched binary emitted 0 log lines while 3 plugins failed to load. That
# patch is the sole reason this script's log leg sees anything there. Editing it
# lands you here, in the greps it has to keep satisfying. See test-loader-pin.sh.
# ---------------------------------------------------------------------------
#
# Depends on: gawk (for RT), grep, sed, coreutils. Callers pin PATH; see the unit.

# plugin_canary_load_pattern
#
# The anchored ERE for a plugin load failure.
#
# THE ANCHOR IS NOT COSMETIC. A bare `grep level=ERROR` also matches INFO
# permission-audit lines, which quote the command text of whatever a session ran
# -- so any session that merely DISCUSSES this error string produces a match.
# That has already produced false positives twice in this bead, the second time
# after the author had explicitly written the warning down. Anchoring `timestamp=`
# to the start of line and requiring `level=ERROR` in field position is what makes
# the difference between reading the log and reading conversations about the log.
plugin_canary_load_pattern() {
  printf '%s\n' '^timestamp=[^ ]+ level=ERROR .*failed to load plugin'
}

# plugin_canary_complete_lines
#
# stdin -> stdout, emitting ONLY lines that were terminated by a newline.
#
# The log is appended concurrently by every serve, TUI, and headless session on
# the host, so a read that ends at EOF routinely lands mid-line. Without this
# filter the trailing fragment is treated as a whole line: it cannot match the
# anchored pattern, and once the offset advances past it the remainder is never
# re-read as part of a complete line. The miss lands precisely on lines being
# written during a serve start -- which is exactly when plugin load errors are
# written. gawk's RT holds the record terminator; it is empty only for a final
# unterminated record.
plugin_canary_complete_lines() {
  LC_ALL=C gawk 'BEGIN { RS = "\n" } RT != "" { print }'
}

# plugin_canary_complete_bytes
#
# stdin -> stdout, echoing the number of bytes occupied by complete (newline
# terminated) lines. This is how far the caller may advance its stored offset:
# advancing to raw EOF is the bug described above.
plugin_canary_complete_bytes() {
  LC_ALL=C gawk 'BEGIN { RS = "\n"; n = 0 } RT != "" { n += length($0) + 1 } END { print n + 0 }'
}

# plugin_canary_plugin_key LINE
#
# Echoes a stable identity for the plugin named in a load-failure line, derived
# from its `path=file:///...` field. Echoes nothing if there is no such field.
#
# Prefers the path RELATIVE to the plugins directory, because the basename alone
# is ambiguous: caveman deploys as `plugins/caveman/plugin.js` (it must ship as a
# directory so plugin.js can resolve caveman-config.cjs as a real sibling), and a
# bare `plugin.js` would neither identify it nor survive a second directory-shaped
# plugin. Falls back to the final component for anything outside that directory.
#
# KNOWN GAP -- npm-spec plugins get NO key (workstation-njer). Both extractions
# require a literal `file://`, and opencode logs a package-spec plugin as a bare
# name: `path=opencode-beads`, `path=@ex-machina/opencode-anthropic-auth`,
# `path=opencode-gemini-auth@1.3.11`. Three of the twelve deployed plugin sources
# are that shape. config/plugin.ts normalises only PATH-LIKE specs (Glob.scan ->
# pathToFileURL for the plugins dir, pathToFileURL for absolute/relative); package
# specs fall through unchanged, by design. So this is not drift -- it is a shape
# this function was never written for.
#
# An earlier version of this comment claimed the fallback covered "an
# npm-installed plugin ... rather than being silently dropped". Measured on real
# production lines (INFO success lines rewritten to the failure shape, run through
# the extraction below): all three npm specs returned EMPTY, while a file:// plugin
# returned `caveman/plugin.js`. The claim was written from the file case and
# generalised.
#
# The alert itself is NOT lost -- the anchored pattern still matches, so the canary
# still goes red. What degrades is attribution: those three share one `unknown`
# latch, so a single stuck one masks the others.
#
# The result is used as a driftAlert signature and as a latch filename, so it is
# reduced to [A-Za-z0-9._-]: a `/` would create a spurious directory level, and
# unsanitised input from a log line has no business becoming a path.
plugin_canary_plugin_key() {
  local line="$1" raw=""

  raw="$(printf '%s\n' "$line" | LC_ALL=C sed -nE 's|.*path=file://[^[:space:]"]*/plugins/([^[:space:]"]+).*|\1|p' | head -1)"

  if [ -z "$raw" ]; then
    raw="$(printf '%s\n' "$line" | LC_ALL=C sed -nE 's|.*path=file://[^[:space:]"]*/([^/[:space:]"]+).*|\1|p' | head -1)"
  fi

  [ -n "$raw" ] || return 0

  # `printf '%s'` without a trailing newline: tr's complement set would otherwise
  # rewrite the newline itself to `_`, appending a spurious character to every key
  # -- and thus to every driftAlert signature and latch filename.
  printf '%s' "$raw" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_'
  printf '\n'
}

# plugin_canary_run_id LINE
#
# Echoes the `run=` field, opencode's per-process id, or nothing.
#
# NOT used for windowing -- that would be circular, since the id can only be
# learned from the log it is meant to scope. It is carried into the alert text so
# a human reading a page at 3am can correlate against the serve that emitted it.
plugin_canary_run_id() {
  printf '%s\n' "$1" | LC_ALL=C sed -nE 's/.*[[:space:]]run=([A-Za-z0-9]+).*/\1/p' | head -1
}

# plugin_canary_file_id PATH
#
# Echoes "<device>:<inode>" for PATH, the identity used to notice rotation.
# Echoes nothing if PATH does not exist.
plugin_canary_file_id() {
  [ -e "$1" ] || return 0
  stat -c '%d:%i' "$1" 2>/dev/null || true
}

# plugin_canary_window_action STORED_ID STORED_OFFSET CURRENT_ID CURRENT_SIZE [MAX_RESET_BYTES]
#
# Decides what to read this pass. Echoes one of:
#
#   INIT          -- no usable state. The caller must record CURRENT_SIZE as the
#                    offset and read NOTHING.
#   INIT_OVERSIZE -- a reset was indicated, but the file is too large to be a
#                    freshly rotated one. Behave as INIT, and say so loudly: an
#                    unknown quantity of log went unexamined, which is precisely
#                    the kind of silence this canary exists to not produce.
#   RESET         -- the file is not the one we were reading, or it shrank. Read
#                    from 0.
#   READ          -- read from STORED_OFFSET.
#   NOOP          -- nothing new.
#
# MAX_RESET_BYTES (default 8MiB) bounds the reset path. A rotation leaves a small
# file, so a "reset" onto a large one is not a rotation -- it is the log path
# having been repointed at something with history (opencode changed its log naming
# scheme once already; the same directory still holds the old dated files). Reading
# from 0 there would pull hundreds of MB through a minutely unit and re-latch every
# historical failure in it.
#
# INIT rather than RESET on first run is load-bearing: the log holds ~2500
# historical `failed to load plugin` matches from the very incident this bead is
# about, so a first pass that reads from 0 alerts on all of them, and a canary
# that pages 2500 times on install is a canary that gets masked on install. The
# cost is a stated blind window -- a failure logged before the first pass is
# invisible until the next serve start re-logs it (<=24h via the nightly reset),
# with leg A covering the LOUD shape meanwhile.
#
# RESET covers both rotation shapes: a move-and-recreate changes the inode, while
# a copy-truncate keeps the inode and drops the size below our offset. No rotation
# is configured for this file today; it is handled because a stale offset pointing
# past EOF would otherwise silently read nothing forever, which is indistinguishable
# from health.
plugin_canary_window_action() {
  local stored_id="$1" stored_off="$2" cur_id="$3" cur_size="$4"
  local max_reset="${5:-8388608}"

  if [ -z "$stored_id" ] || [ -z "$stored_off" ] || [ -z "$cur_id" ]; then
    printf 'INIT\n'
    return 0
  fi

  case "$stored_off" in
    ''|*[!0-9]*) printf 'INIT\n'; return 0 ;;
  esac

  if [ "$stored_id" != "$cur_id" ] || [ "$cur_size" -lt "$stored_off" ]; then
    if [ "$cur_size" -gt "$max_reset" ]; then
      printf 'INIT_OVERSIZE\n'
    else
      printf 'RESET\n'
    fi
    return 0
  fi

  if [ "$cur_size" -eq "$stored_off" ]; then
    printf 'NOOP\n'
    return 0
  fi

  printf 'READ\n'
}

# plugin_canary_probe_action TOOL_STATUS TOOL_PRESENT PROVIDERS_STATUS
#
# The leg A status table. TOOL_PRESENT is "yes"/"no". Echoes one of:
#
#   HEALTHY
#   ALERT:tool-missing
#   ALERT:providers-unhealthy
#   SKIP
#   CANNOT_EVALUATE:<status>
#
# WHY THIS IS A TABLE AND NOT AN `if [ "$status" = 200 ]`:
# Both of the tempting one-liners are wrong in opposite, silent ways.
#
#   "anything but 200 is a failure" false-pages on every routine restart. The
#   post-boot catalog/credential burn runs 5-6 minutes and /config/providers IS
#   the provider catalog, so it is unhealthy for minutes as a matter of normal
#   operation. An operator who gets paged by routine restarts stops reading the
#   channel, which hosts/cloudbox/configuration.nix documents as a worse outcome
#   than a missed alert.
#
#   "anything but 200 is a skip" goes permanently silent the day upstream moves
#   the route. /experimental/ is an unstable namespace and opencode-patched bumps
#   every 8 hours; a 404 read as "skip" makes this leg dead and quiet, which is
#   this bead's signature failure.
#
# So: 502/503/no-response mean the door or anchor is down, which is
# opencode-serve-canary's job and it already pages -- skip, and do NOT reset the
# consecutive counter, because a fault that alternates between unreachable and
# broken is still a fault. 401/404/anything unrecognised cannot self-heal and get
# their own distinct alert saying the canary cannot evaluate, which is a true
# statement and a different remedy from "a plugin is broken".
plugin_canary_probe_action() {
  local tool_status="$1" tool_present="$2" providers_status="$3"

  case "$tool_status" in
    ''|000|502|503) printf 'SKIP\n'; return 0 ;;
  esac
  case "$providers_status" in
    ''|000|502|503) printf 'SKIP\n'; return 0 ;;
  esac

  case "$tool_status" in
    200) ;;
    *) printf 'CANNOT_EVALUATE:%s\n' "$tool_status"; return 0 ;;
  esac

  if [ "$tool_present" != "yes" ]; then
    printf 'ALERT:tool-missing\n'
    return 0
  fi

  case "$providers_status" in
    200) printf 'HEALTHY\n' ;;
    500) printf 'ALERT:providers-unhealthy\n' ;;
    *) printf 'CANNOT_EVALUATE:%s\n' "$providers_status" ;;
  esac
}
