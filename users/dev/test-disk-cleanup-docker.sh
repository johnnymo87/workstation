#!/usr/bin/env bash
# Regression tests for disk-cleanup's docker reclamation step (section 4c).
# Run: bash users/dev/test-disk-cleanup-docker.sh
#
# WHY THIS EXISTS. On 2026-09-21 cloudbox's 393 GB root reached 100% with zero
# bytes free, and docker was the single largest reclaimable item: 328 images,
# 68.79 GB, of which 67.78 GB (98%) was referenced by nothing. Nothing in this
# repo touched docker, so a by-hand prune reclaimed 67 GB and had no successor.
# Section 4c is that successor.
#
# WHAT MAKES IT DANGEROUS ENOUGH TO PIN. It runs `rm -f` on containers and
# `image prune -a` on a daemon shared with somebody's actual development stack
# (the aigateway dev compose project: dev-postgres-1, dev-gateway-1,
# dev-redis-1) on a box with ~15 concurrent agent sessions. The asymmetry that
# shapes every assertion below: a wrong "keep" costs one night of disk, which
# the next run reclaims anyway; a wrong "remove" kills a running database or
# forces a multi-gigabyte rebuild somebody is mid-task on. So the suite is
# weighted towards proving the KEEP branches.
#
# THREE FACTS MEASURED ON CLOUDBOX (moby 28.5.2) THAT THE FIXTURES REPRODUCE:
#
#   1. `docker ps` does NOT accept `--filter until=`. It answers
#      `invalid filter 'until'` and exits 1, even though docker's filtering
#      documentation lists `until` for ps. The three prune subcommands DO
#      accept it. A first draft used it uniformly; under `set -e` inside a
#      process substitution that produced an empty id list, i.e. a sweep that
#      logged success and swept nothing. test_ps_is_not_given_an_until_filter
#      pins the split so a future tidy-up cannot re-unify them.
#
#   2. `builder prune` reports "Total: N", not "Total reclaimed space: N"
#      like the other two. Matching only the latter reported every build-cache
#      prune as "nothing reclaimed" -- a report that is wrong in the quiet
#      direction and would never have been noticed.
#
#   3. Leaked testcontainers are RUNNING, not exited: ten redis:7-alpine from
#      a single afternoon (2026-09-14) were still up seven days later. So the
#      sweep cannot be a `container prune`, which only touches stopped ones.

set -o errexit -o nounset -o pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

pass_count=0
fail_count=0
pass() { printf 'PASS  %s\n' "$1"; pass_count=$((pass_count + 1)); }
fail() {
  printf 'FAIL  %s\n' "$1"
  shift || true
  for line in "$@"; do printf '      %s\n' "$line"; done
  fail_count=$((fail_count + 1))
}

# ---------------------------------------------------------------------------
# Seam: a flake check passes home-manager's OWN deployed store path for this
# file, so the suite never invokes nix (impossible in a build sandbox). Same
# arrangement as test-disk-cleanup-worktrees.sh; the seam passes .source
# rather than .text because reading .text through the CLI needs
# dynamic-derivations.
# ---------------------------------------------------------------------------
script_src="$tmpdir/disk-cleanup"
harness="$tmpdir/docker-harness"

if [ -n "${DISK_CLEANUP_SRC:-}" ]; then
  cp "$DISK_CLEANUP_SRC" "$script_src"
else
  nix --extra-experimental-features 'nix-command flakes dynamic-derivations' \
    eval --raw "git+file:$repo_root#homeConfigurations.cloudbox.config.home.file.\".local/bin/disk-cleanup\".text" \
    > "$script_src"
fi
[ -s "$script_src" ] || { echo "FAIL: empty disk-cleanup source"; exit 1; }

python3 - "$script_src" "$harness" "$(command -v bash)" <<'PY'
import pathlib
import sys

src = pathlib.Path(sys.argv[1]).read_text()
start_marker = "# --- 4c. Docker reclamation ---\n"
end_marker = "\n# --- 5. OpenCode WAL checkpoint ---"
start = src.find(start_marker)
if start == -1:
    raise SystemExit("FAIL: no '--- 4c. Docker reclamation ---' section in disk-cleanup")
end = src.index(end_marker, start)
section = src[start:end]

# Sanity: the extracted slice must contain the entry point, otherwise a
# renamed function would leave the suite driving an empty harness and
# reporting green.
if "cleanup_docker() {" not in section:
    raise SystemExit("FAIL: extracted 4c section does not define cleanup_docker")

pathlib.Path(sys.argv[2]).write_text(
    f"#!{sys.argv[3]}\n"
    "set -euo pipefail\n"
    "log() { printf '[disk-cleanup-test] %s\\n' \"$*\"; }\n"
    f"{section}\n"
    "cleanup_docker\n"
)
PY
chmod +x "$harness"

# The shipped bytes are also asserted against directly where the property is
# about what the script must NEVER contain. A behavioural test cannot prove
# the absence of a command that the fixture never triggers.
#
# COMMENTS ARE STRIPPED FIRST, and that is not tidiness. Section 4c's comments
# name every command it must never run ("NO `docker volume prune`") and quote
# the very filter it must not hand to `ps`. Grepping the raw text makes all
# three absence assertions fail against a correct script -- and, worse, a lazy
# fix (delete the comment) would make them pass against a wrong one.
shipped_4c="$(python3 - "$script_src" <<'PY'
import pathlib, re, sys
src = pathlib.Path(sys.argv[1]).read_text()
start = src.index("# --- 4c. Docker reclamation ---\n")
end = src.index("\n# --- 5. OpenCode WAL checkpoint ---", start)
code = [l for l in src[start:end].splitlines() if not re.match(r"\s*#", l)]
if not any("cleanup_docker() {" in l for l in code):
    raise SystemExit("FAIL: comment-stripped 4c section lost cleanup_docker")
sys.stdout.write("\n".join(code))
PY
)"

# ---------------------------------------------------------------------------
# Fake docker. Records every invocation, answers from a fixture file.
#
# Fixture format, one container per line:
#   <id>\t<created ISO8601 or literal junk>\t<labels JSON>
# ---------------------------------------------------------------------------
fakedir="$tmpdir/bin"
mkdir -p "$fakedir"
#
# ABSOLUTE SHEBANG, same reason the harness has one: /usr/bin/env does not
# exist in a nix build sandbox. With `#!/usr/bin/env bash` this stub exits 127
# for every call, `docker info` "fails", and the script takes its
# daemon-unreachable branch -- so the suite reports a skip as a set of
# behavioural failures and points at the script instead of at itself.
#
# The shebang is written separately so the body can stay in a QUOTED heredoc:
# an unquoted one would expand the stub's own $1/$@/${...} at generation time
# and leave a stub that inspects the SUITE's arguments instead of docker's.
printf '#!%s\n' "$(command -v bash)" > "$fakedir/docker"
cat >> "$fakedir/docker" <<'FAKE'
# Deliberately NOT `set -e`: the real docker returns non-zero for some of the
# cases under test and the harness must cope with that, not be shielded.
printf '%s\n' "$*" >> "$DOCKER_CALL_LOG"

case "${1:-}" in
  info)
    [ "${FAKE_DOCKER_DAEMON_DOWN:-0}" = 1 ] && exit 1
    exit 0
    ;;
  ps)
    # Reproduce the real daemon: `ps` rejects an `until` filter.
    for arg in "$@"; do
      case "$arg" in
        until=*) echo "Error response from daemon: invalid filter 'until'" >&2; exit 1 ;;
      esac
    done
    cut -f1 "$FAKE_DOCKER_CONTAINERS"
    exit 0
    ;;
  inspect)
    want="$2"
    while IFS=$'\t' read -r id created labels; do
      [ "$id" = "$want" ] || continue
      [ "$created" = "__INVISIBLE__" ] && exit 1
      printf '%s|%s\n' "$created" "$labels"
      exit 0
    done < "$FAKE_DOCKER_CONTAINERS"
    exit 1
    ;;
  rm)
    target="${3:-}"
    if [ "$target" = "${FAKE_DOCKER_RM_FAILS:-}" ]; then
      echo "Error response from daemon: cannot remove" >&2
      exit 1
    fi
    printf '%s\n' "$target" >> "$DOCKER_RM_LOG"
    exit 0
    ;;
  container|image)
    if [ "${FAKE_DOCKER_PRUNE_FAILS:-}" = "$1" ]; then
      echo "Cannot connect to the Docker daemon" >&2
      exit 1
    fi
    echo "Total reclaimed space: 1.5GB"
    exit 0
    ;;
  builder)
    # The real `builder prune` uses a different banner from the other two.
    printf 'Total:\t51.09MB\n'
    exit 0
    ;;
esac
exit 0
FAKE
chmod +x "$fakedir/docker"

# A `df` stub, so the disk-pressure gate on the image prune is exercised at a
# chosen percentage rather than at whatever the machine running the suite
# happens to be at -- which would make the gate's two branches untestable on
# one host and flaky across hosts.
printf '#!%s\n' "$(command -v bash)" > "$fakedir/df"
cat >> "$fakedir/df" <<'FAKEDF'
[ "${FAKE_DF_BROKEN:-0}" = 1 ] && exit 1
printf 'Use%%\n%s%%\n' "${FAKE_ROOT_PCT:-90}"
exit 0
FAKEDF
chmod +x "$fakedir/df"

# Prove the stub runs before any assertion depends on it. A stub that cannot
# exec makes `docker info` fail, which the script correctly answers by
# skipping -- and every behavioural assertion below then fails while blaming
# the script. This turns that into one honest error about the harness.
DOCKER_CALL_LOG="$tmpdir/selfcheck.calls" "$fakedir/docker" info >/dev/null 2>&1 || {
  echo "FAIL: the fake docker stub does not execute in this environment"
  exit 1
}

hours_ago() { date -u -d "@$(( $(date +%s) - $1 * 3600 ))" +%Y-%m-%dT%H:%M:%S.000000000Z; }

TC_LABELS='{"org.testcontainers":"true","org.testcontainers.lang":"node"}'
COMPOSE_TC_LABELS='{"org.testcontainers":"true","com.docker.compose.project":"dev"}'

# Drives the harness over a fixture. Echoes nothing; sets $out/$rm_log/$calls.
run_harness() {
  local fixture="$1"; shift
  out="$tmpdir/out.$RANDOM"
  rm_log="$tmpdir/rm.$RANDOM"
  calls="$tmpdir/calls.$RANDOM"
  : > "$rm_log"
  : > "$calls"
  env -i \
    PATH="$fakedir:$PATH" \
    HOME="$tmpdir" \
    DOCKER_BIN="$fakedir/docker" \
    DOCKER_CALL_LOG="$calls" \
    DOCKER_RM_LOG="$rm_log" \
    FAKE_DOCKER_CONTAINERS="$fixture" \
    FAKE_ROOT_PCT=90 \
    "$@" \
    "$harness" > "$out" 2>&1 || true
}

# ---------------------------------------------------------------------------
# Fixture 1: the population observed on cloudbox on 2026-09-21.
# ---------------------------------------------------------------------------
fixture="$tmpdir/containers.tsv"
{
  printf 'leaked_old\t%s\t%s\n'      "$(hours_ago 168)" "$TC_LABELS"
  printf 'leaked_boundary\t%s\t%s\n' "$(hours_ago 25)"  "$TC_LABELS"
  printf 'fresh_running\t%s\t%s\n'   "$(hours_ago 2)"   "$TC_LABELS"
  printf 'compose_owned\t%s\t%s\n'   "$(hours_ago 168)" "$COMPOSE_TC_LABELS"
  printf 'undateable\tnot-a-timestamp\t%s\n' "$TC_LABELS"
  printf 'invisible\t__INVISIBLE__\t%s\n'    "$TC_LABELS"
} > "$fixture"

run_harness "$fixture"

removed() { grep -Fqx "$1" "$rm_log"; }

if removed leaked_old; then
  pass "removes a leaked testcontainer older than the threshold"
else
  fail "removes a leaked testcontainer older than the threshold" \
       "rm log: $(tr '\n' ' ' < "$rm_log")"
fi

# The boundary case is the one a refactor gets wrong. 25h against a 24h
# threshold must sweep; the assertion below pins the direction of the
# comparison, not merely that some container was removed.
if removed leaked_boundary; then
  pass "removes a container just past the age threshold (25h vs 24h)"
else
  fail "removes a container just past the age threshold (25h vs 24h)" \
       "rm log: $(tr '\n' ' ' < "$rm_log")"
fi

if removed fresh_running; then
  fail "KEEPS a testcontainer younger than the threshold" \
       "a 2h-old container was removed; a live test run's containers are 2h old"
else
  pass "KEEPS a testcontainer younger than the threshold"
fi

# THE GUARD THAT MATTERS MOST. A compose-owned container carrying a
# testcontainers label is somebody's development database. Removing it is the
# failure this whole guard exists to prevent.
if removed compose_owned; then
  fail "KEEPS a container that also carries a compose label" \
       "the aigateway dev stack would have been destroyed"
else
  pass "KEEPS a container that also carries a compose label"
fi

if grep -q 'carries a compose label' "$out"; then
  pass "says out loud when it skips a compose-owned container"
else
  fail "says out loud when it skips a compose-owned container" \
       "output: $(tr '\n' ' ' < "$out")"
fi

if removed undateable; then
  fail "KEEPS a container whose creation time will not parse" \
       "an unparseable date must fail safe towards keeping"
else
  pass "KEEPS a container whose creation time will not parse"
fi

if removed invisible; then
  fail "KEEPS a container docker inspect cannot see"
else
  pass "KEEPS a container docker inspect cannot see"
fi

# A `set -e` script that aborts on the first unparseable container would keep
# everything AFTER it too -- silently, and looking like success. The two
# fail-safe fixtures sit before the prune steps for exactly this reason.
if grep -q 'Docker reclamation complete' "$out"; then
  pass "completes the whole step despite unparseable and invisible containers"
else
  fail "completes the whole step despite unparseable and invisible containers" \
       "output: $(tr '\n' ' ' < "$out")"
fi

# ---------------------------------------------------------------------------
# Prune steps: which ones run, in what order, with what filters.
# ---------------------------------------------------------------------------
if grep -q '^container prune .*--filter until=' "$calls"; then
  pass "prunes stopped containers with an until filter"
else
  fail "prunes stopped containers with an until filter" \
       "calls: $(tr '\n' ' ' < "$calls")"
fi

if grep -qE '^image prune -af .*--filter until=' "$calls"; then
  pass "prunes images with -a and an until filter"
else
  fail "prunes images with -a and an until filter" \
       "calls: $(tr '\n' ' ' < "$calls")"
fi

# THE SECOND HALF OF "COMPOSE OWNERSHIP WINS". 4c-1's per-container check
# protects only containers carrying BOTH labels; the bulk prunes need their
# own exclusion or they delete a compose stack that is merely stopped. The
# aigateway dev stack's Postgres keeps its ledger in an ANONYMOUS volume, so
# deleting the container orphans the data even though no volume is pruned.
if grep -q "^container prune .*label!=com.docker.compose.project" "$calls"; then
  pass "excludes compose-owned containers from the bulk container prune"
else
  fail "excludes compose-owned containers from the bulk container prune" \
       "calls: $(tr '\n' ' ' < "$calls")"
fi

if grep -q "^image prune .*label!=com.docker.compose.project" "$calls"; then
  pass "excludes compose-owned images from the image prune"
else
  fail "excludes compose-owned images from the image prune" \
       "calls: $(tr '\n' ' ' < "$calls")"
fi

# Every testcontainers redis carries an anonymous /data volume. Without -v the
# sweep converts a running leak into a dangling volume that the standing
# no-volume-prune rule then guarantees nobody ever reclaims.
if grep -q '^rm -fv ' "$calls"; then
  pass "removes a leaked container's anonymous volumes with it (rm -fv)"
else
  fail "removes a leaked container's anonymous volumes with it (rm -fv)" \
       "calls: $(tr '\n' ' ' < "$calls")"
fi

if grep -q '^builder prune .*--filter until=' "$calls"; then
  pass "prunes build cache with an until filter"
else
  fail "prunes build cache with an until filter" \
       "calls: $(tr '\n' ' ' < "$calls")"
fi

# ORDER IS LOAD-BEARING: a stopped container pins its image, so pruning
# containers second under-reclaims by exactly one image per stale container
# (21 of them on the day this was written).
container_line=$(grep -n '^container prune' "$calls" | head -1 | cut -d: -f1)
image_line=$(grep -n '^image prune' "$calls" | head -1 | cut -d: -f1)
if [ -n "$container_line" ] && [ -n "$image_line" ] && \
   [ "$container_line" -lt "$image_line" ]; then
  pass "prunes containers BEFORE images"
else
  fail "prunes containers BEFORE images" \
       "container prune at line ${container_line:-none}, image prune at ${image_line:-none}"
fi

if grep -q 'build cache pruned: Total:' "$out"; then
  pass "reports builder prune's 'Total:' banner as reclaimed, not as nothing"
else
  fail "reports builder prune's 'Total:' banner as reclaimed, not as nothing" \
       "output: $(tr '\n' ' ' < "$out")"
fi

# ---------------------------------------------------------------------------
# Absence properties, asserted against the shipped bytes.
# ---------------------------------------------------------------------------
if grep -q 'volume prune' <<<"$shipped_4c"; then
  fail "NEVER prunes volumes" \
       "15 of 30 volumes were in use and volumes hold unrecoverable data"
else
  pass "NEVER prunes volumes"
fi

if grep -q 'system prune' <<<"$shipped_4c"; then
  fail "NEVER runs system prune" \
       "system prune is a blanket that reaches volumes and networks"
else
  pass "NEVER runs system prune"
fi

# Pins fact 1 in the header: `ps` must not be handed an `until` filter, which
# this daemon rejects. The fake docker exits 1 on one, so a regression also
# shows up behaviourally -- but the byte-level assertion is what names it.
ps_invocation=$(grep -c 'ps .*until=' <<<"$shipped_4c" || true)
if [ "$ps_invocation" = "0" ]; then
  pass "does not pass an until filter to docker ps (the daemon rejects it)"
else
  fail "does not pass an until filter to docker ps (the daemon rejects it)" \
       "found $ps_invocation such invocation(s)"
fi

if grep -q 'invalid filter' "$out"; then
  fail "does not trip the daemon's invalid-filter error"
else
  pass "does not trip the daemon's invalid-filter error"
fi

# ---------------------------------------------------------------------------
# Environment gates: no docker, dead daemon, failing prune, failing rm.
# ---------------------------------------------------------------------------
out="$tmpdir/out.nodocker"
calls="$tmpdir/calls.nodocker"
: > "$calls"
env -i PATH="/nonexistent" HOME="$tmpdir" \
  DOCKER_BIN="$tmpdir/no-such-docker" \
  DOCKER_CALL_LOG="$calls" DOCKER_RM_LOG="$tmpdir/rm.nodocker" \
  FAKE_DOCKER_CONTAINERS="$fixture" \
  "$harness" > "$out" 2>&1 || true
if grep -q 'Docker not installed' "$out" && [ ! -s "$calls" ]; then
  pass "skips cleanly when docker is not installed"
else
  fail "skips cleanly when docker is not installed" \
       "output: $(tr '\n' ' ' < "$out")"
fi

run_harness "$fixture" FAKE_DOCKER_DAEMON_DOWN=1
if grep -q 'daemon unreachable' "$out" && ! grep -q 'prune' "$calls"; then
  pass "skips cleanly, and prunes nothing, when the daemon is unreachable"
else
  fail "skips cleanly, and prunes nothing, when the daemon is unreachable" \
       "output: $(tr '\n' ' ' < "$out")" "calls: $(tr '\n' ' ' < "$calls")"
fi

# A docker hiccup at 03:00 must not abort the steps after it -- including
# cleanup_opencode_wal, which runs next in the real script.
run_harness "$fixture" FAKE_DOCKER_PRUNE_FAILS=container
if grep -q 'WARN: docker stopped containers prune failed' "$out" && \
   grep -q '^image prune' "$calls"; then
  pass "a failing prune is logged and the later steps still run"
else
  fail "a failing prune is logged and the later steps still run" \
       "output: $(tr '\n' ' ' < "$out")"
fi

run_harness "$fixture" FAKE_DOCKER_RM_FAILS=leaked_old
if grep -q 'WARN: failed to remove leaked testcontainer leaked_old' "$out" && \
   grep -Fqx leaked_boundary "$rm_log"; then
  pass "a failing rm is logged and the sweep continues to the next container"
else
  fail "a failing rm is logged and the sweep continues to the next container" \
       "output: $(tr '\n' ' ' < "$out")"
fi

# ---------------------------------------------------------------------------
# The knobs are env-overridable, which is how an operator retunes without a
# rebuild -- and how the assertions above stay honest about being thresholds
# rather than hardcoded behaviour.
# ---------------------------------------------------------------------------
run_harness "$fixture" DOCKER_TESTCONTAINER_AGE_HOURS=1
if removed fresh_running; then
  pass "DOCKER_TESTCONTAINER_AGE_HOURS is honoured from the environment"
else
  fail "DOCKER_TESTCONTAINER_AGE_HOURS is honoured from the environment" \
       "a 2h container survived a 1h threshold; the knob is not wired"
fi

run_harness "$fixture" DOCKER_IMAGE_AGE_HOURS=9999
if grep -q 'image prune -af .*until=9999h' "$calls"; then
  pass "DOCKER_IMAGE_AGE_HOURS reaches the image prune filter"
else
  fail "DOCKER_IMAGE_AGE_HOURS reaches the image prune filter" \
       "calls: $(tr '\n' ' ' < "$calls")"
fi

# ---------------------------------------------------------------------------
# The disk-pressure gate on the image prune.
#
# WHY THIS IS GATED AT ALL. Once ryuk reaps properly, no testcontainer exists
# at 03:00, so every test base image is unreferenced -- and their upstream
# creation dates are years old, so no `until` value protects them. An
# ungated `-a` re-pulls the whole test image set every morning for ~15
# sessions behind one NAT address. Above the threshold that is worth it;
# below it there is nothing to buy.
# ---------------------------------------------------------------------------
run_harness "$fixture" FAKE_ROOT_PCT=45
if grep -qE '^image prune -f ' "$calls" && ! grep -qE '^image prune -af' "$calls"; then
  pass "below the threshold, prunes dangling images only (no -a)"
else
  fail "below the threshold, prunes dangling images only (no -a)" \
       "calls: $(tr '\n' ' ' < "$calls")"
fi

run_harness "$fixture" FAKE_ROOT_PCT=70
if grep -qE '^image prune -af' "$calls"; then
  pass "at exactly the threshold, escalates to -a (the boundary is >=)"
else
  fail "at exactly the threshold, escalates to -a (the boundary is >=)" \
       "calls: $(tr '\n' ' ' < "$calls")"
fi

# Fail-safe direction: the failure this section exists for is a disk at zero
# bytes free, and the cost of escalating wrongly is a re-pull. So an
# unmeasurable disk escalates, loudly.
run_harness "$fixture" FAKE_DF_BROKEN=1
if grep -qE '^image prune -af' "$calls" && \
   grep -q 'could not read root filesystem usage' "$out"; then
  pass "an unreadable df escalates to -a, and says so"
else
  fail "an unreadable df escalates to -a, and says so" \
       "output: $(tr '\n' ' ' < "$out")" "calls: $(tr '\n' ' ' < "$calls")"
fi

run_harness "$fixture" DOCKER_IMAGE_PRUNE_ALL_PCT=99 FAKE_ROOT_PCT=90
if grep -qE '^image prune -f ' "$calls"; then
  pass "DOCKER_IMAGE_PRUNE_ALL_PCT is honoured from the environment"
else
  fail "DOCKER_IMAGE_PRUNE_ALL_PCT is honoured from the environment" \
       "calls: $(tr '\n' ' ' < "$calls")"
fi

printf '=== %d passed, %d failed ===\n' "$pass_count" "$fail_count"
[ "$fail_count" -eq 0 ]
