#!/usr/bin/env bash
# unwired-test(workstation-k7t4): probes live host state (systemd/tmux/sockets); needs fixture injection to be hermetic
# Tests for systemd.services.opencode-phantom-busy-sweeper (configuration.nix).
#
# Runs the SHIPPED artifact — the nix-built ExecStart script — against scratch
# WAL databases through its OPENCODE_SWEEPER_DB seam, so this exercises the code
# that actually runs in production rather than a re-implementation of its logic.
#
# NOT part of `nix flake check`, deliberately: it needs a live serve pool (the
# sweeper's CUTOFF comes from systemd) and builds a ~600MB fixture. Run it by
# hand on cloudbox after touching the sweeper:
#
#   ./hosts/cloudbox/test-phantom-busy-sweeper.sh
#
# T9 is the regression test for bead workstation-yvxh.1: the old unbounded
# UPDATE held the SQLite WAL write lock across a full scan of a 13GB DB even
# when it matched 0 rows (173/173 runs), which on 2026-08-02 blew the serves'
# 5s busy_timeout and killed a live turn. It carries a positive control so a
# too-small fixture cannot make the test vacuously pass.
set -u

REPO=$(cd "$(dirname "$0")/../.." && pwd)
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want=[$3] got=[$2])"; fi; }

SQLITE=$(command -v sqlite3 || true)
[ -n "$SQLITE" ] || { echo "sqlite3 not on PATH"; exit 1; }

# Build the sweeper the unit will actually run: pull the derivation out of the
# ExecStart string's context and realise it.
SWEEPER="${SWEEPER_OVERRIDE:-}"
if [ -z "$SWEEPER" ]; then
  echo "building sweeper from $REPO ..."
  DRV=$(nix eval --raw --impure --expr "let f = builtins.getFlake \"$REPO\"; s = f.nixosConfigurations.cloudbox.config.systemd.services.opencode-phantom-busy-sweeper.serviceConfig.ExecStart; in builtins.head (builtins.attrNames (builtins.getContext s))") || exit 1
  SWEEPER=$(nix-store -r "$DRV" 2>/dev/null) || exit 1
fi
echo "sweeper: $SWEEPER"

# Fixtures must be older than the sweeper's CUTOFF (min ActiveEnterTimestamp
# over active pool serves) to be eligible. Discover it the same way the sweeper
# does — from systemd, by unit glob, with no hardcoded ports.
CUTOFF=$(systemctl list-units 'opencode-serve@*.service' --no-legend --plain --state=active |
  awk '{print $1}' |
  while read -r u; do
    [ -n "$u" ] || continue
    systemctl show "$u" --timestamp=unix -p ActiveEnterTimestamp |
      awk -F= '/^ActiveEnterTimestamp=/{ sub(/^@/,"",$2); if ($2 != "") print $2 }'
  done | sort -n | head -1)
[ -n "$CUTOFF" ] || { echo "no active opencode-serve@* units; start the pool first"; exit 1; }
echo "pool cutoff: $CUTOFF"

LAB="$(mktemp -d "${TMPDIR:-/tmp}/sweepertest.XXXXXX")"
trap 'rm -rf "$LAB"' EXIT

OLD=$(( (CUTOFF - 86400) * 1000 ))   # created well before cutoff
NOW_MS=$(( $(date +%s) * 1000 ))
STALE_UPD=$(( NOW_MS - 7200000 ))    # touched 2h ago -> passes the >30min gate
FRESH_UPD=$NOW_MS                    # touched now    -> fails it

mkdb() {
  rm -f "$1" "$1-wal" "$1-shm"
  "$SQLITE" "$1" "
    PRAGMA journal_mode=WAL;
    CREATE TABLE message (
      id text PRIMARY KEY, session_id text NOT NULL,
      time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL);
    CREATE INDEX message_session_time_created_id_idx ON message (session_id, time_created, id);
  " >/dev/null
}

# addrow <db> <id> <created_ms> <updated_ms> <completed|NULL> <error_json|NULL> [role]
addrow() {
  local role="${7:-assistant}" completed="$5" err="$6"
  "$SQLITE" "$1" "
    INSERT INTO message VALUES('$2','ses_test',$3,$4,
      json_object('role','$role','time', json_object('created',$3
        $( [ "$completed" = NULL ] || echo ", 'completed', $completed" ))
        $( [ "$err" = NULL ] || echo ", 'error', json('$err')" )));"
}

run() { local db="$1"; shift; OUT=$(OPENCODE_SWEEPER_DB="$db" "$SWEEPER" "$@" 2>&1); RC=$?; }

echo "== T1: zero candidates -> short-circuit, no write phase =="
DB="$LAB/t1.db"; mkdb "$DB"
addrow "$DB" msg_done "$OLD" "$STALE_UPD" "$NOW_MS" NULL
addrow "$DB" msg_user "$OLD" "$STALE_UPD" NULL NULL user
run "$DB"
check "exit 0"                  "$RC" 0
check "reports 0 finalized"     "$(printf '%s' "$OUT" | grep -c 'finalized 0 orphaned message(s)')" 1
check "says no write lock"      "$(printf '%s' "$OUT" | grep -c 'no candidates')" 1
check "logs the db path"        "$(printf '%s' "$OUT" | grep -c "db=$DB")" 1
check "completed row untouched" "$("$SQLITE" "$DB" "SELECT json_extract(data,'\$.error') IS NULL FROM message WHERE id='msg_done';")" 1

echo "== T2: one stale orphan -> finalized with the canonical error shape =="
DB="$LAB/t2.db"; mkdb "$DB"
addrow "$DB" msg_orphan "$OLD" "$STALE_UPD" NULL NULL
run "$DB"
check "exit 0"              "$RC" 0
check "reports 1 finalized" "$(printf '%s' "$OUT" | grep -c 'finalized 1 orphaned message(s)')" 1
check "completed set"       "$("$SQLITE" "$DB" "SELECT json_extract(data,'\$.time.completed') IS NOT NULL FROM message WHERE id='msg_orphan';")" 1
check "error name"          "$("$SQLITE" "$DB" "SELECT json_extract(data,'\$.error.name') FROM message WHERE id='msg_orphan';")" MessageAbortedError

echo "== T3: write-time re-check -- an already-finalized row is never clobbered =="
DB="$LAB/t3.db"; mkdb "$DB"
addrow "$DB" msg_race "$OLD" "$STALE_UPD" NULL NULL
run "$DB"
MARK=$("$SQLITE" "$DB" "SELECT json_extract(data,'\$.time.completed') FROM message WHERE id='msg_race';")
run "$DB"
check "second pass finalizes 0"       "$(printf '%s' "$OUT" | grep -c 'finalized 0 orphaned')" 1
check "completed timestamp unchanged" "$("$SQLITE" "$DB" "SELECT json_extract(data,'\$.time.completed') FROM message WHERE id='msg_race';")" "$MARK"

echo "== T4: recently-updated row is protected by the >30min gate =="
DB="$LAB/t4.db"; mkdb "$DB"
addrow "$DB" msg_fresh "$OLD" "$FRESH_UPD" NULL NULL
run "$DB"
check "reports 0 finalized" "$(printf '%s' "$OUT" | grep -c 'finalized 0 orphaned')" 1
check "row untouched"       "$("$SQLITE" "$DB" "SELECT json_extract(data,'\$.time.completed') IS NULL FROM message WHERE id='msg_fresh';")" 1

echo "== T5: row created after CUTOFF is protected (live-owner gate) =="
DB="$LAB/t5.db"; mkdb "$DB"
addrow "$DB" msg_new "$NOW_MS" "$STALE_UPD" NULL NULL
run "$DB"
check "reports 0 finalized" "$(printf '%s' "$OUT" | grep -c 'finalized 0 orphaned')" 1
check "row untouched"       "$("$SQLITE" "$DB" "SELECT json_extract(data,'\$.time.completed') IS NULL FROM message WHERE id='msg_new';")" 1

echo "== T6: >500 candidates -> chunked, all finalized =="
DB="$LAB/t6.db"; mkdb "$DB"
"$SQLITE" "$DB" "
  WITH RECURSIVE s(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM s WHERE i<1201)
  INSERT INTO message SELECT 'msg_b'||i,'ses_test',$OLD,$STALE_UPD,
    json_object('role','assistant','time',json_object('created',$OLD)) FROM s;" >/dev/null
run "$DB"
check "exit 0"                 "$RC" 0
check "reports 1201 finalized" "$(printf '%s' "$OUT" | grep -c 'finalized 1201 orphaned')" 1
check "3 chunks"               "$(printf '%s' "$OUT" | grep -c '3 chunk(s)')" 1
check "no row left in-flight"  "$("$SQLITE" "$DB" "SELECT count(*) FROM message WHERE json_extract(data,'\$.time.completed') IS NULL;")" 0

echo "== T7: --dry-run never writes =="
DB="$LAB/t7.db"; mkdb "$DB"
addrow "$DB" msg_dry "$OLD" "$STALE_UPD" NULL NULL
run "$DB" --dry-run
check "exit 0"          "$RC" 0
check "says would"      "$(printf '%s' "$OUT" | grep -c 'would finalize 1')" 1
check "row NOT written" "$("$SQLITE" "$DB" "SELECT json_extract(data,'\$.time.completed') IS NULL FROM message WHERE id='msg_dry';")" 1

echo "== T8: missing DB fails closed =="
run "$LAB/nope.db"
check "exit 1"       "$RC" 1
check "explains why" "$(printf '%s' "$OUT" | grep -c 'refusing to run')" 1

echo "== T8b: unknown argument fails closed instead of sweeping wet =="
DB="$LAB/t8b.db"; mkdb "$DB"
addrow "$DB" msg_typo "$OLD" "$STALE_UPD" NULL NULL
run "$DB" --dryrun
check "exit 1"          "$RC" 1
check "names the arg"   "$(printf '%s' "$OUT" | grep -c 'unknown argument')" 1
check "row NOT written" "$("$SQLITE" "$DB" "SELECT json_extract(data,'\$.time.completed') IS NULL FROM message WHERE id='msg_typo';")" 1

# --- stamped-gate shadow count (bead workstation-63wo) ------------------------
# Since opencode-patched 1.17.13.9 a pool serve stamps its systemd InvocationID
# into every assistant row it writes. The sweeper reports how many rows the
# stamped gate WOULD additionally finalize, and — for now — does nothing with
# that number. These cases pin both halves of it: the count must be right, and
# the sweeper must still not touch the rows.
#
# The live id is scraped from systemd at test time rather than invented. There
# is no seam for unit state (the sweeper reads systemd directly), so a made-up
# id can only ever exercise the "not live -> sweepable" branch; proving the
# "live -> protected" branch requires an id that really is live right now.
LIVE_IV=$(systemctl list-units 'opencode-serve@*.service' --no-legend --plain --state=active |
  awk '{print $1}' |
  while read -r u; do
    [ -n "$u" ] || continue
    systemctl show "$u" -p InvocationID | awk -F= '/^InvocationID=/{ if ($2 != "") print $2 }'
  done | head -1)
[ -n "$LIVE_IV" ] || { echo "could not read a live InvocationID; is the pool up?"; exit 1; }
DEAD_IV="ffffffffffffffffffffffffffffffff"   # 32 hex, cannot be a live invocation

# stamprow <db> <id> <created_ms> <updated_ms> <invocation_id>
# addrow() is positional and cannot carry extra JSON keys, so stamped fixtures
# are inserted directly, in the shape the projector actually writes.
stamprow() {
  "$SQLITE" "$1" "
    INSERT INTO message VALUES('$2','ses_test',$3,$4,
      json_object('role','assistant',
                  'time', json_object('created',$3),
                  'serve', json_object('serveId','serve-9','invocationId','$5',
                                       'port','4099','pid',1234)));"
}

echo "== T8c: row stamped by a DEAD invocation is COUNTED but NOT finalized =="
# NEWER than CUTOFF, so today's min-over-pool gate cannot see it at all -- this is
# exactly the fresh single-member orphan that currently waits for the 03:00 bounce.
DB="$LAB/t8c.db"; mkdb "$DB"
stamprow "$DB" msg_dead "$NOW_MS" "$STALE_UPD" "$DEAD_IV"
run "$DB"
check "exit 0"                    "$RC" 0
check "shadow counts it"          "$(printf '%s' "$OUT" | grep -c 'stamped-gate shadow: 1 additional')" 1
check "still finalizes 0"         "$(printf '%s' "$OUT" | grep -c 'finalized 0 orphaned message(s)')" 1
check "row NOT touched (log-only)" "$("$SQLITE" "$DB" "SELECT json_extract(data,'\$.time.completed') IS NULL FROM message WHERE id='msg_dead';")" 1

echo "== T8d: row stamped by a LIVE invocation is NOT counted =="
DB="$LAB/t8d.db"; mkdb "$DB"
stamprow "$DB" msg_live "$NOW_MS" "$STALE_UPD" "$LIVE_IV"
run "$DB"
check "exit 0"           "$RC" 0
check "shadow counts 0"  "$(printf '%s' "$OUT" | grep -c 'stamped-gate shadow: 0 additional')" 1
check "row untouched"    "$("$SQLITE" "$DB" "SELECT json_extract(data,'\$.time.completed') IS NULL FROM message WHERE id='msg_live';")" 1

echo "== T8e: an UNSTAMPED fresh row is still invisible (no accidental widening) =="
DB="$LAB/t8e.db"; mkdb "$DB"
addrow "$DB" msg_fresh_unstamped "$NOW_MS" "$STALE_UPD" NULL NULL
run "$DB"
check "shadow counts 0" "$(printf '%s' "$OUT" | grep -c 'stamped-gate shadow: 0 additional')" 1
check "finalizes 0"     "$(printf '%s' "$OUT" | grep -c 'finalized 0 orphaned message(s)')" 1
check "row untouched"   "$("$SQLITE" "$DB" "SELECT json_extract(data,'\$.time.completed') IS NULL FROM message WHERE id='msg_fresh_unstamped';")" 1

echo "== T8f: a stamped row that is NOT yet 30min silent is not counted =="
# The staleness gate is the blast-radius cap; a stamp is not a licence to skip it.
DB="$LAB/t8f.db"; mkdb "$DB"
stamprow "$DB" msg_recent "$NOW_MS" "$FRESH_UPD" "$DEAD_IV"
run "$DB"
check "shadow counts 0" "$(printf '%s' "$OUT" | grep -c 'stamped-gate shadow: 0 additional')" 1
check "row untouched"   "$("$SQLITE" "$DB" "SELECT json_extract(data,'\$.time.completed') IS NULL FROM message WHERE id='msg_recent';")" 1

echo "== T8g: an OLD stamped-dead row is finalized by the EXISTING gate, counted once =="
# Created before CUTOFF, so the old path already catches it. It must NOT also
# appear in the shadow count, or the number double-counts and overstates the gain.
DB="$LAB/t8g.db"; mkdb "$DB"
stamprow "$DB" msg_old_dead "$OLD" "$STALE_UPD" "$DEAD_IV"
run "$DB"
check "finalized by old gate" "$(printf '%s' "$OUT" | grep -c 'finalized 1 orphaned message(s)')" 1
check "not double-counted"    "$(printf '%s' "$OUT" | grep -c 'stamped-gate shadow: 0 additional')" 1

echo "== T8h: the CUTOFF boundary itself -- created == CUTOFF is shadow, not old-gate =="
# The no-double-counting claim in T8g rests on the two gates partitioning rows
# exactly at CUTOFF (old gate is created < CUTOFF, shadow is created >= CUTOFF).
# Without a fixture sitting ON the boundary, flipping >= to > survives the whole
# suite while silently dropping one row from every count.
DB="$LAB/t8h.db"; mkdb "$DB"
stamprow "$DB" msg_boundary "$(( CUTOFF * 1000 ))" "$STALE_UPD" "$DEAD_IV"
run "$DB"
check "counted by shadow"     "$(printf '%s' "$OUT" | grep -c 'stamped-gate shadow: 1 additional')" 1
check "not by the old gate"   "$(printf '%s' "$OUT" | grep -c 'finalized 0 orphaned message(s)')" 1

echo "== T8i: an already-finished stamped row is never counted =="
# Pins the completed/error predicates in the shadow query, which otherwise no
# stamped fixture exercises -- dropping either survived the mutation pass.
DB="$LAB/t8i.db"; mkdb "$DB"
stamprow "$DB" msg_stamped_done "$NOW_MS" "$STALE_UPD" "$DEAD_IV"
"$SQLITE" "$DB" "UPDATE message SET data=json_set(data,'\$.time.completed',$NOW_MS) WHERE id='msg_stamped_done';"
stamprow "$DB" msg_stamped_err "$NOW_MS" "$STALE_UPD" "$DEAD_IV"
"$SQLITE" "$DB" "UPDATE message SET data=json_set(data,'\$.error',json('{\"name\":\"X\"}')) WHERE id='msg_stamped_err';"
run "$DB"
check "shadow counts 0" "$(printf '%s' "$OUT" | grep -c 'stamped-gate shadow: 0 additional')" 1

echo "== T9: REGRESSION -- a zero-candidate sweep must not block a concurrent writer =="
# Fixture: all rows already completed, so 0 candidates -- exactly production,
# where 173/173 runs matched nothing -- but large enough that a full scan is far
# longer than the writer's busy_timeout.
DB="$LAB/t9.db"; mkdb "$DB"
"$SQLITE" "$DB" "
  WITH RECURSIVE s(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM s WHERE i<150000)
  INSERT INTO message SELECT 'msg_p'||i,'ses_test',$OLD,$STALE_UPD,
    json_object('role','assistant','time',json_object('created',$OLD,'completed',$NOW_MS),
                'pad',hex(randomblob(1500))) FROM s;" >/dev/null
"$SQLITE" "$DB" "CREATE TABLE canary(a);" >/dev/null
SCAN=$( { TIMEFORMAT=%R; time "$SQLITE" "file:$DB?mode=ro" \
  "SELECT count(*) FROM message WHERE json_extract(data,'\$.time.completed') IS NULL;" >/dev/null; } 2>&1 )
echo "  (fixture: $("$SQLITE" "$DB" 'select count(*) from message;') rows, $(( $(stat -c%s "$DB") / 1048576 ))MB, full scan ${SCAN}s)"

# Writer uses a 50ms busy_timeout, far below the scan cost, so any write-lock
# hold shows up immediately.
hammer_while() {
  local pid="$1" tries=0 blocked=0
  while kill -0 "$pid" 2>/dev/null; do
    tries=$((tries+1))
    "$SQLITE" "$DB" "PRAGMA busy_timeout=50; INSERT INTO canary VALUES(1);" >/dev/null 2>&1 || blocked=$((blocked+1))
  done
  wait "$pid" 2>/dev/null
  echo "$tries $blocked"
}

# POSITIVE CONTROL: the OLD unbounded statement on the same fixture. If this
# does not block the writer, the fixture is too small and T9 proves nothing.
"$SQLITE" "$DB" "
  PRAGMA busy_timeout=10000;
  UPDATE message SET data = json_set(data,'\$.time.completed',1)
  WHERE json_extract(data,'\$.role')='assistant'
    AND json_extract(data,'\$.time.completed') IS NULL
    AND json_extract(data,'\$.error') IS NULL
    AND time_updated < (strftime('%s','now') - 1800) * 1000
    AND json_extract(data,'\$.time.created') < $CUTOFF * 1000;" >/dev/null 2>&1 &
read -r CTRIES CBLOCKED <<<"$(hammer_while $!)"
echo "  (control/old-shape: attempts=$CTRIES blocked=$CBLOCKED)"
if [ "$CBLOCKED" -gt 0 ]; then ok "positive control: old unbounded UPDATE does block a writer at 0 matches"
else bad "positive control did not block -- fixture too small, the result below is meaningless"; fi

OPENCODE_SWEEPER_DB="$DB" "$SWEEPER" >/dev/null 2>&1 &
read -r TRIES BLOCKED <<<"$(hammer_while $!)"
echo "  (sweeper: attempts=$TRIES blocked=$BLOCKED)"
check "concurrent writer never blocked by sweeper" "$BLOCKED" 0

echo
echo "==== $PASS passed, $FAIL failed ===="
[ "$FAIL" -eq 0 ]
