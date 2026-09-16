#!/usr/bin/env bash
# unwired-test(workstation-oo4q): MEASURED 2026-08-17 -- nested nix (:36) is NOT the first blocker. This suite hard-exits at :52 without a LIVE opencode-serve pool to derive CUTOFF from, which a build sandbox can never provide, and its header (:9-11) says exclusion is deliberate (live pool + a ~600MB T9 fixture). Wiring it means rewriting the CUTOFF discovery, which fixture eligibility depends on -- strictly harder than the devbox sibling, which was designed for the no-pool path. An earlier version of this marker called it "likely the cheapest of the seven"; that was first-blocker-only reasoning and was wrong.
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

# mkdb builds the schema in its PRODUCTION STEADY STATE, which since bead
# workstation-o5s1.2 includes the sweeper's own partial index. That matters most
# for T9: if fixtures lacked it, the sweeper's phase 0 would build it mid-test,
# hold the write lock across a 595MB scan, and T9 would fail for a reason that
# occurs exactly once in a real database's lifetime. T10 covers the build path
# separately, on a DB deliberately created without it.
mkdb() {
  rm -f "$1" "$1-wal" "$1-shm"
  "$SQLITE" "$1" "
    PRAGMA journal_mode=WAL;
    CREATE TABLE message (
      id text PRIMARY KEY, session_id text NOT NULL,
      time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL);
    CREATE INDEX message_session_time_created_id_idx ON message (session_id, time_created, id);
  " >/dev/null
  mkidx "$1"
}

# The partial index, spelled the way the sweeper spells it.
mkidx() {
  "$SQLITE" "$1" "
    CREATE INDEX IF NOT EXISTS message_phantom_busy_idx ON message(time_updated)
      WHERE json_extract(data, '\$.role') = 'assistant'
        AND json_extract(data, '\$.time.completed') IS NULL
        AND json_extract(data, '\$.error') IS NULL;
  " >/dev/null
}

# mkdb_noidx: the pre-o5s1.2 schema, i.e. what a fresh opencode DB looks like
# before the sweeper has ever run against it.
mkdb_noidx() {
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

# --- stamped gate, ARMED (bead workstation-63wo) ------------------------------
# Since opencode-patched 1.17.13.9 a pool serve stamps its systemd InvocationID
# into every assistant row it writes, so "is the process that CREATED this row
# still alive?" is answerable directly instead of being approximated by the
# min-over-pool CUTOFF. The gate ran in shadow (count-only) from 2026-08-11 and
# was armed on 2026-08-12 after a deliberate single-member SIGKILL produced the
# predicted 0->1 transition with zero FAILED counts across ~58 runs.
#
# The gate is CONJUNCTIVE per branch, and that is the whole safety argument:
#     stale AND ( (NOT stamped AND created < CUTOFF)
#              OR (stamped     AND invocation not live) )
# A stamped row is judged ONLY by its stamp. It is never finalized merely for
# being old (T8j), because "old" is a proxy for "owner is gone" and the stamp is
# the real thing — under clock skew or a restored DB the proxy is simply wrong,
# and the cost of being wrong is aborting a live turn.
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

echo "== T8c: row stamped by a DEAD invocation IS finalized (the point of arming) =="
# NEWER than CUTOFF, so the min-over-pool gate alone cannot see it at all -- this
# is exactly the fresh single-member orphan that used to wait for the 03:00
# bounce (measured: ~18h on 2026-08-12).
#
# This case pins ONE phase-2 drift shape and no more: leaving the OLD cutoff
# predicate in the phase 2 UPDATE while phase 1 moves to the new gate makes this
# run report "1 candidate(s)" and then finalize 0. It does NOT pin phase 2's
# re-check in general -- deleting `AND $GATE` from the UPDATE outright survives
# this test and the whole suite, because phase 1 has already filtered the ids.
# The genuine between-phase race (a serve finishing a row after phase 1 read it)
# is timing-dependent and stays untested; T3 covers only the completed-row half.
DB="$LAB/t8c.db"; mkdb "$DB"
stamprow "$DB" msg_dead "$NOW_MS" "$STALE_UPD" "$DEAD_IV"
run "$DB"
check "exit 0"                 "$RC" 0
check "finalizes it"           "$(printf '%s' "$OUT" | grep -c 'finalized 1 orphaned message(s)')" 1
check "attributed to the stamp" "$(printf '%s' "$OUT" | grep -c 'stamped-gate ARMED: 1 row')" 1
check "completed set"          "$("$SQLITE" "$DB" "SELECT json_extract(data,'\$.time.completed') IS NOT NULL FROM message WHERE id='msg_dead';")" 1
check "error name"             "$("$SQLITE" "$DB" "SELECT json_extract(data,'\$.error.name') FROM message WHERE id='msg_dead';")" MessageAbortedError

echo "== T8d: row stamped by a LIVE invocation is protected =="
DB="$LAB/t8d.db"; mkdb "$DB"
stamprow "$DB" msg_live "$NOW_MS" "$STALE_UPD" "$LIVE_IV"
run "$DB"
check "exit 0"           "$RC" 0
check "finalizes 0"      "$(printf '%s' "$OUT" | grep -c 'finalized 0 orphaned message(s)')" 1
check "attribution 0"    "$(printf '%s' "$OUT" | grep -c 'stamped-gate ARMED: 0 row')" 1
check "row untouched"    "$("$SQLITE" "$DB" "SELECT json_extract(data,'\$.time.completed') IS NULL FROM message WHERE id='msg_live';")" 1

echo "== T8j: a LIVE-stamped row OLDER than CUTOFF is protected (conjunctive gate) =="
# THE test that separates the shipped gate from the disjunctive form
#     (created < CUTOFF) OR (stamped AND not live)
# which every other case in this file passes identically. Here the row predates
# CUTOFF *and* its stamp says the writer is alive; the disjunctive form finalizes
# it on the first clause alone, aborting a live turn. Reachable in production
# through clock skew or a restored/copied DB -- rare, but the failure is the
# worst one this script can produce, and it is invisible to every other test.
DB="$LAB/t8j.db"; mkdb "$DB"
stamprow "$DB" msg_live_old "$OLD" "$STALE_UPD" "$LIVE_IV"
run "$DB"
check "exit 0"        "$RC" 0
check "finalizes 0"   "$(printf '%s' "$OUT" | grep -c 'finalized 0 orphaned message(s)')" 1
check "row untouched" "$("$SQLITE" "$DB" "SELECT json_extract(data,'\$.time.completed') IS NULL FROM message WHERE id='msg_live_old';")" 1

echo "== T8e: an UNSTAMPED fresh row is still invisible (no accidental widening) =="
DB="$LAB/t8e.db"; mkdb "$DB"
addrow "$DB" msg_fresh_unstamped "$NOW_MS" "$STALE_UPD" NULL NULL
run "$DB"
check "attribution 0"   "$(printf '%s' "$OUT" | grep -c 'stamped-gate ARMED: 0 row')" 1
check "finalizes 0"     "$(printf '%s' "$OUT" | grep -c 'finalized 0 orphaned message(s)')" 1
check "row untouched"   "$("$SQLITE" "$DB" "SELECT json_extract(data,'\$.time.completed') IS NULL FROM message WHERE id='msg_fresh_unstamped';")" 1

echo "== T8f: a stamped row that is NOT yet 30min silent is not counted =="
# The staleness gate is the blast-radius cap; a stamp is not a licence to skip it.
DB="$LAB/t8f.db"; mkdb "$DB"
stamprow "$DB" msg_recent "$NOW_MS" "$FRESH_UPD" "$DEAD_IV"
run "$DB"
check "attribution 0"   "$(printf '%s' "$OUT" | grep -c 'stamped-gate ARMED: 0 row')" 1
check "finalizes 0"     "$(printf '%s' "$OUT" | grep -c 'finalized 0 orphaned message(s)')" 1
check "row untouched"   "$("$SQLITE" "$DB" "SELECT json_extract(data,'\$.time.completed') IS NULL FROM message WHERE id='msg_recent';")" 1

echo "== T8g: an OLD stamped-dead row is finalized, but is NOT attributed to the stamp =="
# Finalized via the stamped branch (a stamped row is judged only by its stamp),
# yet the OLD gate would have caught it too, so it is not part of the marginal
# gain. Attributing it would overstate what arming bought.
DB="$LAB/t8g.db"; mkdb "$DB"
stamprow "$DB" msg_old_dead "$OLD" "$STALE_UPD" "$DEAD_IV"
run "$DB"
check "finalized"          "$(printf '%s' "$OUT" | grep -c 'finalized 1 orphaned message(s)')" 1
check "not attributed"     "$(printf '%s' "$OUT" | grep -c 'stamped-gate ARMED: 0 row')" 1

echo "== T8h: the CUTOFF boundary itself -- created == CUTOFF is attributable =="
# The no-double-counting claim in T8g rests on the attribution counter splitting
# rows exactly at CUTOFF (the old gate was created < CUTOFF, attribution is
# created >= CUTOFF). Without a fixture sitting ON the boundary, flipping >= to >
# survives the whole suite while silently dropping one row from every count.
DB="$LAB/t8h.db"; mkdb "$DB"
stamprow "$DB" msg_boundary "$(( CUTOFF * 1000 ))" "$STALE_UPD" "$DEAD_IV"
run "$DB"
check "finalized"     "$(printf '%s' "$OUT" | grep -c 'finalized 1 orphaned message(s)')" 1
check "attributed"    "$(printf '%s' "$OUT" | grep -c 'stamped-gate ARMED: 1 row')" 1

echo "== T8k: a MALFORMED stamp is not evidence of death =="
# The gate compares a row's stamp against the live set and sweeps on no-match.
# The live side is validated to 32 lowercase hex or the run aborts; without the
# matching shape check on the ROW side, every unrecognisable value would
# "not match" and so read as proof the writer died.
#
# This is the format-drift blast radius, and the reason it is worth a test: the
# stamp is written by opencode-patched, a DIFFERENT repo that auto-updates every
# 8 hours. A future version rendering the id as a dashed UUID would make every
# LIVE row stop matching at once, and every turn silent for 30 minutes would be
# aborted. With the shape check those rows fall back to the old CUTOFF rule.
# All four fixtures are NEWER than CUTOFF, so a sweep here can only come from
# the stamped branch trusting a value it should not.
DB="$LAB/t8k.db"; mkdb "$DB"
stamprow "$DB" msg_garbage_empty  "$NOW_MS" "$STALE_UPD" ""
stamprow "$DB" msg_garbage_short  "$NOW_MS" "$STALE_UPD" "zz"
stamprow "$DB" msg_garbage_dashed "$NOW_MS" "$STALE_UPD" "5ebd8272-a9b5-4422-99ae-128c8f5ae5f8"
stamprow "$DB" msg_garbage_upper  "$NOW_MS" "$STALE_UPD" "5EBD8272A9B5442299AE128C8F5AE5F8"
"$SQLITE" "$DB" "INSERT INTO message VALUES('msg_jsonnull','ses_test',$NOW_MS,$STALE_UPD,
  json_object('role','assistant','time',json_object('created',$NOW_MS),
              'serve', json_object('serveId','serve-9','invocationId',json('null'))));"
run "$DB"
check "exit 0"          "$RC" 0
check "finalizes 0"     "$(printf '%s' "$OUT" | grep -c 'finalized 0 orphaned message(s)')" 1
check "attribution 0"   "$(printf '%s' "$OUT" | grep -c 'stamped-gate ARMED: 0 row')" 1
check "none touched"    "$("$SQLITE" "$DB" "SELECT count(*) FROM message WHERE json_extract(data,'\$.time.completed') IS NOT NULL;")" 0

echo "== T8l: a malformed stamp still falls through to the OLD cutoff rule =="
# The other half of T8k: rows the stamped branch declines to judge must land on
# the unstamped branch, not vanish between the two. Same fixtures, but created
# before CUTOFF, so the old rule applies and every one of them is swept. Without
# this, a shape check that made malformed stamps permanently unsweepable -- a
# slow leak of rows nothing ever finalizes -- would pass T8k happily.
DB="$LAB/t8l.db"; mkdb "$DB"
stamprow "$DB" msg_old_dashed "$OLD" "$STALE_UPD" "5ebd8272-a9b5-4422-99ae-128c8f5ae5f8"
stamprow "$DB" msg_old_empty  "$OLD" "$STALE_UPD" ""
run "$DB"
check "both swept by the old rule" "$(printf '%s' "$OUT" | grep -c 'finalized 2 orphaned message(s)')" 1
check "not attributed to the stamp" "$(printf '%s' "$OUT" | grep -c 'stamped-gate ARMED: 0 row')" 1

echo "== T8i: an already-finished stamped row is never touched or counted =="
# Pins the completed/error predicates on BOTH the finalization gate and the
# attribution counter -- dropping either survived the mutation pass. The error
# fixture also guards the re-abort case: a row someone else already aborted must
# not have its error overwritten with ours.
DB="$LAB/t8i.db"; mkdb "$DB"
stamprow "$DB" msg_stamped_done "$NOW_MS" "$STALE_UPD" "$DEAD_IV"
"$SQLITE" "$DB" "UPDATE message SET data=json_set(data,'\$.time.completed',$NOW_MS) WHERE id='msg_stamped_done';"
stamprow "$DB" msg_stamped_err "$NOW_MS" "$STALE_UPD" "$DEAD_IV"
"$SQLITE" "$DB" "UPDATE message SET data=json_set(data,'\$.error',json('{\"name\":\"X\"}')) WHERE id='msg_stamped_err';"
run "$DB"
check "attribution 0"   "$(printf '%s' "$OUT" | grep -c 'stamped-gate ARMED: 0 row')" 1
check "finalizes 0"     "$(printf '%s' "$OUT" | grep -c 'finalized 0 orphaned message(s)')" 1
check "foreign error kept" "$("$SQLITE" "$DB" "SELECT json_extract(data,'\$.error.name') FROM message WHERE id='msg_stamped_err';")" X

# --- the partial index (bead workstation-o5s1.2) ------------------------------
# MEASURED 2026-09-15: every sweeper run read 3.4-4.2 GB and burned 11.5-17.0s
# CPU to find 0 candidates, because the three json_extract() terms in phase 1
# cannot be served by (session_id, time_created, id) -- this query has no session
# filter, and the table has never been ANALYZEd so a skip-scan has no stats to be
# costed against. Runs of 5m16 and 7m05 overran the 5-minute timer and chained.
#
# The fix is a partial index over exactly those three terms. It is applicable
# only because SQLite can prove the query's WHERE implies the index's, which
# rests on the two being written the same way -- so the thing that must be
# tested is THE PLAN, not the result. Every functional test in this file passes
# identically whether the index is used or ignored; a reshaped predicate would
# revert to a 4GB full scan with no output changing anywhere.
echo "== T10b: a DB without the index gets one, and only then =="
# The build branch. It is gated: the sweeper refuses to build unattended when a
# serve is live AND the DB is over 256 MiB, because CREATE INDEX holds the write
# lock across a full scan and that is the 2026-08-02 incident phase 1's
# read-only connection exists to prevent. These fixtures are kilobytes, so they
# take the small-DB carve-out and self-heal. T10c pins the refusal.
DB="$LAB/t10b.db"; mkdb_noidx "$DB"
addrow "$DB" msg_noidx "$OLD" "$STALE_UPD" NULL NULL
check "index absent to begin with" \
  "$("$SQLITE" "$DB" "SELECT count(*) FROM sqlite_master WHERE name='message_phantom_busy_idx';")" 0
run "$DB"
check "exit 0"                "$RC" 0
check "says it was missing"   "$(printf '%s' "$OUT" | grep -c 'is MISSING and building is safe here')" 1
check "says it was built"     "$(printf '%s' "$OUT" | grep -c 'message_phantom_busy_idx built')" 1
check "index now present"     "$("$SQLITE" "$DB" "SELECT count(*) FROM sqlite_master WHERE name='message_phantom_busy_idx';")" 1
check "still did its job"     "$(printf '%s' "$OUT" | grep -c 'finalized 1 orphaned message(s)')" 1
# Second run must be silent about the index: nothing to build, no drift.
run "$DB"
check "second run says nothing about building" "$(printf '%s' "$OUT" | grep -c 'MISSING\|built\|DRIFTED')" 0

echo "== T10c: --dry-run never builds the index =="
# A build is the largest write this script can make, and an operator reaching for
# the "safe" flag against an unfamiliar DB is exactly who must not trigger it.
DB="$LAB/t10c.db"; mkdb_noidx "$DB"
addrow "$DB" msg_dryidx "$OLD" "$STALE_UPD" NULL NULL
run "$DB" --dry-run
check "exit 0"              "$RC" 0
check "says dry run"        "$(printf '%s' "$OUT" | grep -c 'dry run, NOT building it')" 1
check "index NOT created"   "$("$SQLITE" "$DB" "SELECT count(*) FROM sqlite_master WHERE name='message_phantom_busy_idx';")" 0
check "row NOT written"     "$("$SQLITE" "$DB" "SELECT json_extract(data,'\$.time.completed') IS NULL FROM message WHERE id='msg_dryidx';")" 1

echo "== T10d: a DRIFTED index definition is reported, not silently tolerated =="
# The probe keys on the NAME. An index whose predicate no longer matches phase 1
# sits there looking present while the query full-scans -- the exact silent
# reversion this whole bead is about, wearing the disguise of a healthy DB.
DB="$LAB/t10d.db"; mkdb_noidx "$DB"
"$SQLITE" "$DB" "CREATE INDEX message_phantom_busy_idx ON message(time_updated)
  WHERE json_extract(data, '\$.role') = 'user';" >/dev/null
addrow "$DB" msg_drift "$OLD" "$STALE_UPD" NULL NULL
run "$DB"
check "exit 0"            "$RC" 0
check "reports drift"     "$(printf '%s' "$OUT" | grep -c 'DEFINITION HAS DRIFTED')" 1
check "does not rebuild"  "$(printf '%s' "$OUT" | grep -c 'built')" 0
check "still did its job" "$(printf '%s' "$OUT" | grep -c 'finalized 1 orphaned message(s)')" 1

# mkidx (used by every other fixture) restates the script's index definition. If
# the two drift, every fixture in this file would provoke the DRIFTED branch and
# the suite would be testing a configuration production never sees. Compare the
# stored SQL of a mkidx index against one the SHIPPED script built in T10b.
# Compared whitespace-normalised, the same way the sweeper compares them: layout
# is not the contract, the predicate is. The first version of this check was
# exact and failed on leading spaces alone -- which is precisely the false drift
# report the sweeper would have produced on every host after any reindent.
normsql_t() { "$SQLITE" "$1" "SELECT sql FROM sqlite_master WHERE name='message_phantom_busy_idx';" |
  awk '{ $1=$1; printf "%s%s", sep, $0; sep=" " }'; }
DB="$LAB/t10e.db"; mkdb "$DB"
check "test's mkidx matches the shipped index definition" \
  "$(normsql_t "$DB")" "$(normsql_t "$LAB/t10b.db")"

echo "== T10: phase 1 is driven by the partial index, not a full scan =="
# The query is EXTRACTED FROM THE SHIPPED SCRIPT rather than restated here. A
# copy would drift: someone reshapes a term in configuration.nix, production
# silently reverts to SCAN, and a test asserting its own private copy of the
# query still passes. Extracting means the reshape lands in what we plan.
awk '/SELECT id FROM message/{f=1} f{print} /AND \$GATE;/{if(f) exit}' "$SWEEPER" > "$LAB/q.raw"
if [ ! -s "$LAB/q.raw" ] || ! grep -q 'AND \$GATE;' "$LAB/q.raw"; then
  bad "could not extract the phase 1 query from $SWEEPER -- T10 cannot check anything"
else
  ok "extracted the phase 1 query from the shipped script"
  # Unescape the shell-level \$ the nix string carries, then substitute a
  # representative gate. BOTH gate forms are exercised: the stamped/unstamped
  # disjunction used when a pool serve is live, and the CUTOFF-only fallback used
  # when none is. They take different paths through the optimiser and a fix that
  # only preserved one would be a half fix.
  IV_E="json_extract(data,'\$.serve.invocationId')"
  STAMPED_E="($IV_E IS NOT NULL AND length($IV_E) = 32 AND $IV_E NOT GLOB '*[^0-9a-f]*')"
  GATE_LIVE="( (NOT $STAMPED_E AND json_extract(data,'\$.time.created') < 1 * 1000) OR ($STAMPED_E AND $IV_E NOT IN ('$DEAD_IV')) )"
  GATE_ONLY="(json_extract(data,'\$.time.created') < 1 * 1000)"

  # PLAN AGAINST THE INDEX THE SHIPPED SCRIPT BUILT (t10b.db, from the test
  # above), NOT one this file created. mkidx is a restatement of the script's
  # IDX_SQL, so planning against a mkdb fixture would pass even if the script's
  # index definition and its phase 1 predicate had drifted apart from each other
  # -- the same "asserting a private copy" failure this test exists to prevent,
  # one layer down. Using the script's own output closes that loop: the index and
  # the query being checked for agreement both come from the artifact.
  DB="$LAB/t10b.db"
  plan_for() {
    # SINGLE quotes: in double quotes bash collapses \$ before sed ever sees it,
    # leaving sed the expression s/\\$/$/g -- an escaped backslash followed by an
    # END-OF-LINE ANCHOR, which matches nothing here. The extraction then plans a
    # query still containing '\$.role', which is not the production predicate and
    # so does not imply the index WHERE. It failed loudly, which is the point of
    # asserting the plan rather than the result.
    sed 's/\\\$/$/g' "$LAB/q.raw" > "$LAB/q.sql"
    awk -v g="$1" '{ gsub(/\$GATE/, g); print }' "$LAB/q.sql" > "$LAB/q.final"
    "$SQLITE" "file:$DB?mode=ro" "EXPLAIN QUERY PLAN $(cat "$LAB/q.final")" 2>&1
  }

  for variant in live cutoff; do
    case "$variant" in
      live)   PLAN=$(plan_for "$GATE_LIVE") ;;
      cutoff) PLAN=$(plan_for "$GATE_ONLY") ;;
    esac
    # Here-strings, not `printf ... | grep -q`: under pipefail an early-exiting
    # grep -q closes the pipe, the writer takes EPIPE, and a MATCH reads as a
    # miss. See the Pipefail Inversion Guard in AGENTS.md.
    if grep -q 'message_phantom_busy_idx' <<<"$PLAN"; then
      ok "gate=$variant: plan uses message_phantom_busy_idx"
    else
      bad "gate=$variant: plan does NOT use the partial index -- phase 1 is back to a full scan [$PLAN]"
    fi
    # Belt and braces: USING INDEX can appear alongside a SCAN of the table in a
    # compound plan, and a SCAN of message is the exact regression.
    if grep -qE '^[^|]*SCAN message([^_]|$)' <<<"$PLAN"; then
      bad "gate=$variant: plan still contains SCAN message [$PLAN]"
    else
      ok "gate=$variant: no SCAN of message"
    fi
  done
fi

echo "== T9: REGRESSION -- a zero-candidate sweep must not block a concurrent writer =="
# Fixture: all rows already completed, so 0 candidates -- exactly production,
# where 173/173 runs matched nothing -- but large enough that a full scan is far
# longer than the writer's busy_timeout.
# NOTE THE SCHEMA: the fixture starts WITHOUT the partial index, and gains it
# below. That ordering is load-bearing since bead workstation-o5s1.2. The
# positive control is the OLD unbounded UPDATE, whose predicate is exactly the
# three terms the partial index covers -- so with the index already present it
# would no longer scan, would no longer block, and would report "fixture too
# small", quietly disarming the one check that stops T9 passing vacuously. The
# control belongs on the pre-fix schema because that is what it is a control for.
DB="$LAB/t9.db"; mkdb_noidx "$DB"
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

# Bring the fixture up to the production schema before running the sweeper, so
# phase 0 finds its index already there (T10b covers the build path). The two
# scan numbers are reported, not asserted: this fixture is written immediately
# before it is read, so it is page-cache warm and a wall-clock ratio here would
# understate the win and flake besides. The non-flaky form of that assertion is
# T10's plan check.
mkidx "$DB"
ISCAN=$( { TIMEFORMAT=%R; time "$SQLITE" "file:$DB?mode=ro" \
  "SELECT id FROM message WHERE json_extract(data,'\$.role')='assistant'
     AND json_extract(data,'\$.time.completed') IS NULL
     AND json_extract(data,'\$.error') IS NULL
     AND time_updated < (strftime('%s','now') - 1800) * 1000;" >/dev/null; } 2>&1 )
echo "  (zero-candidate probe: ${SCAN}s unindexed (warm) vs ${ISCAN}s indexed)"

OPENCODE_SWEEPER_DB="$DB" "$SWEEPER" >"$LAB/t9.out" 2>&1 &
read -r TRIES BLOCKED <<<"$(hammer_while $!)"
echo "  (sweeper: attempts=$TRIES blocked=$BLOCKED)"
check "concurrent writer never blocked by sweeper" "$BLOCKED" 0
# blocked=0 is only meaningful if the sweeper actually ran and the hammer
# actually got swings in. Since the index cut this run from ~4s to ~0.1s the
# window is 40x shorter, and a sweeper that exited instantly on an error would
# hand back blocked=0 for free. Both floors are cheap; neither existed before.
check "sweeper reported a real sweep" "$(grep -c 'finalized 0 orphaned message(s)' "$LAB/t9.out")" 1
if [ "$TRIES" -ge 5 ]; then ok "hammer got $TRIES swings in (>=5, so blocked=0 means something)"
else bad "hammer only got $TRIES swings -- blocked=0 is not evidence of anything"; fi

echo
echo "==== $PASS passed, $FAIL failed ===="
[ "$FAIL" -eq 0 ]
