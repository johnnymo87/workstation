#!/usr/bin/env bash
# Tests for systemd.user.services.opencode-phantom-busy-sweeper
# (users/dev/home.devbox.nix — the DEVBOX sweeper, a systemd USER unit).
#
# Sibling of hosts/cloudbox/test-phantom-busy-sweeper.sh, which covers the
# cloudbox SYSTEM unit. The two sweepers deliberately differ in their serve
# DISCOVERY logic (see the divergence note in home.devbox.nix); everything
# below the discovery block is meant to be the same shape, and this file is
# what holds that true.
#
# Runs the SHIPPED artifact — the nix-built ExecStart script — against scratch
# WAL databases through its OPENCODE_SWEEPER_DB seam, so this exercises the
# code that actually runs in production rather than a re-implementation.
#
# RUNNABLE FROM CLOUDBOX, which is the point: devbox is not reachable from
# there, so this is the only verification available. Both hosts are
# aarch64-linux, so the devbox artifact builds anywhere. What CANNOT be
# exercised off-devbox is the discovery block itself — devbox finds serves via
# `systemctl --user`, and on cloudbox the pool is a SYSTEM unit, so discovery
# finds nothing and the script takes its no-live-pool path (CUTOFF = now). That
# is expected; every assertion below is written to hold under either path.
#
#   ./hosts/devbox/test-phantom-busy-sweeper.sh
#
# RUNS IN `nix flake check`, as checks.devbox-phantom-busy-sweeper-tests, which
# passes the unit's own ExecStart store path in SWEEPER_OVERRIDE so this file
# never has to build its own subject. The check pins the assertion COUNT as well
# as the final banner, so a suite that stops adjudicating cannot present as
# green. T9's ~600MB fixture is built inside the sandbox and costs a few seconds.
#
# SAFETY, and this is not optional. Every invocation of the sweeper here runs
# with HOME pinned into the scratch lab, NOT just with OPENCODE_SWEEPER_DB set.
# The pre-fix devbox script has no seam at all — it reads
# "$HOME/.local/share/opencode/opencode.db" unconditionally — so running it with
# only the seam set would point the OLD UNBOUNDED UPDATE at whatever real
# opencode.db exists on the machine running this test. On cloudbox that is a
# live multi-GB production database. Pinning HOME makes that impossible by
# construction, including when this file is run against an unfixed script to
# watch it fail.
set -u

REPO=$(cd "$(dirname "$0")/../.." && pwd)
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want=[$3] got=[$2])"; fi; }

SQLITE=$(command -v sqlite3 || true)
[ -n "$SQLITE" ] || { echo "sqlite3 not on PATH"; exit 1; }

# Build the sweeper the unit will actually run: pull the derivation out of the
# ExecStart string's context and realise it. home-manager renders ExecStart as a
# list, unlike the NixOS module's plain string — hence the isList branch.
# SWEEPER_OVERRIDE escapes the HOME-pinning guarantee below — point it only at a
# script that honours OPENCODE_SWEEPER_DB. Aimed at a PRE-SEAM artifact, these
# tests would drive that script's writes into the real database on this machine.
# This once cited the cloudbox sweeper as that example; that is no longer true —
# it reads OPENCODE_SWEEPER_DB with the production path only as a default, so the
# hazard is now hypothetical rather than one store path away. checks.devbox-
# phantom-busy-sweeper-tests greps the artifact for the seam before running.
SWEEPER="${SWEEPER_OVERRIDE:-}"
if [ -z "$SWEEPER" ]; then
  echo "building devbox sweeper from $REPO ..."
  DRV=$(nix eval --raw --impure --expr "let f = builtins.getFlake \"$REPO\"; s0 = f.homeConfigurations.dev.config.systemd.user.services.opencode-phantom-busy-sweeper.Service.ExecStart; s = if builtins.isList s0 then builtins.head s0 else s0; in builtins.head (builtins.attrNames (builtins.getContext s))") || exit 1
  SWEEPER=$(nix-store -r "$DRV" 2>/dev/null) || exit 1
fi
echo "sweeper: $SWEEPER"

# Discover CUTOFF exactly the way the DEVBOX script does (user units, MainPID,
# ps etimes), so this test tracks whatever that block does rather than asserting
# a second, independent copy of it. On cloudbox this finds nothing and yields
# CUTOFF=now, which is the same branch the script takes.
NOW=$(date +%s)
MAX_ETIMES=0
for u in $(systemctl --user list-units 'opencode-serve@*.service' --no-legend --plain 2>/dev/null | awk '{print $1}'); do
  pid=$(systemctl --user show "$u" -p MainPID --value 2>/dev/null)
  [ -n "$pid" ] && [ "$pid" != 0 ] || continue
  et=$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ')
  [ -n "$et" ] && [ "$et" -gt "$MAX_ETIMES" ] && MAX_ETIMES=$et
done
CUTOFF=$(( NOW - MAX_ETIMES ))
[ "$MAX_ETIMES" -eq 0 ] && CUTOFF=$NOW
echo "pool cutoff: $CUTOFF (max_etimes=$MAX_ETIMES)"

LAB="$(mktemp -d "${TMPDIR:-/tmp}/devboxsweepertest.XXXXXX")"
trap 'rm -rf "$LAB"' EXIT

# The pinned HOME. A decoy DB lives at the exact path the pre-fix script
# hardcodes, so T0 can prove the seam is honoured rather than merely present.
FAKEHOME="$LAB/home"
DECOY="$FAKEHOME/.local/share/opencode/opencode.db"
mkdir -p "$FAKEHOME/.local/share/opencode"

OLD=$(( (CUTOFF - 86400) * 1000 ))   # created well before cutoff
NOW_MS=$(( NOW * 1000 ))
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

# HOME is pinned on every run — see the SAFETY note at the top.
run() { local db="$1"; shift; OUT=$(HOME="$FAKEHOME" OPENCODE_SWEEPER_DB="$db" "$SWEEPER" "$@" 2>&1); RC=$?; }

echo "== T0: the OPENCODE_SWEEPER_DB seam is honoured, not ignored =="
# Guards the failure mode that makes this whole harness dangerous: a script that
# ignores the seam and sweeps $HOME's database instead. The decoy carries a
# sweepable orphan, so "seam ignored" is loud rather than silent.
DB="$LAB/t0.db"; mkdb "$DB"; mkdb "$DECOY"
addrow "$DB"    msg_seam  "$OLD" "$STALE_UPD" NULL NULL
addrow "$DECOY" msg_decoy "$OLD" "$STALE_UPD" NULL NULL
run "$DB"
check "exit 0"                    "$RC" 0
check "seam db WAS swept"         "$("$SQLITE" "$DB"    "SELECT json_extract(data,'\$.time.completed') IS NOT NULL FROM message WHERE id='msg_seam';")" 1
check "\$HOME decoy NOT touched"  "$("$SQLITE" "$DECOY" "SELECT json_extract(data,'\$.time.completed') IS NULL FROM message WHERE id='msg_decoy';")" 1

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
# Defect (b): `PRAGMA busy_timeout=N;` RETURNS A ROW, so the pre-fix script
# emitted a bare "10000" line to the journal every five minutes. Harmless while
# only humans read it, fatal once phase 1's output is parsed as candidate ids.
check "no bare pragma row in output" "$(printf '%s\n' "$OUT" | grep -cx '[0-9]\+')" 0

echo "== T2: one stale orphan -> finalized with the canonical error shape =="
DB="$LAB/t2.db"; mkdb "$DB"
addrow "$DB" msg_orphan "$OLD" "$STALE_UPD" NULL NULL
run "$DB"
check "exit 0"              "$RC" 0
check "reports 1 finalized" "$(printf '%s' "$OUT" | grep -c 'finalized 1 orphaned message(s)')" 1
check "completed set"       "$("$SQLITE" "$DB" "SELECT json_extract(data,'\$.time.completed') IS NOT NULL FROM message WHERE id='msg_orphan';")" 1
check "error name"          "$("$SQLITE" "$DB" "SELECT json_extract(data,'\$.error.name') FROM message WHERE id='msg_orphan';")" MessageAbortedError

echo "== T3: idempotence -- a second sweep does not re-touch a finalized row =="
# HONEST SCOPE, do not read more into this than it proves. The second run
# filters msg_race out in PHASE 1, so this tests the phase-1 predicate and
# idempotence. It does NOT exercise the re-checked predicates inside the
# phase-2 UPDATE, which are what protect a row that a serve completes BETWEEN
# the two phases. Nothing in this suite exercises those in the declining
# direction: a regression deleting every re-check from the UPDATE still passes.
# Bounding the risk -- those predicates are a verbatim copy of phase 1's, so
# only an always-TRUE corruption (e.g. AND -> OR) would slip through; an
# always-FALSE one fails T2 and T6 loudly. Closing it properly needs a seam
# that completes a row between the phases; tracked in workstation-yvxh.11.
# THE MIRROR, measured while wiring this suite: deleting the gates from PHASE 1
# was ALSO invisible, because phase 2 re-checks them. The two copies covered for
# each other in both directions, so this suite verified their conjunction while
# being unable to localise either. T4/T5 now assert the no-write-lock path, which
# closes the phase-1 direction; the phase-2 direction above remains open.
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
# "finalized 0" is NOT sufficient, and this line is why. MEASURED: delete the
# >30min gate from PHASE 1 and both assertions above still pass -- phase 2's
# re-check declines the write, so the row survives and the count stays 0. What
# actually changed is that the row BECAME A CANDIDATE and a write chunk ran
# against it ("1 candidate(s), 1 chunk(s)"), i.e. the sweeper took a write lock
# on a row it should never have selected. That is the phantom-busy regression
# this unit exists to prevent, and it was invisible here. Assert the no-write-
# lock path explicitly, so phase 1's gate cannot be deleted silently.
check "never became a candidate" "$(printf '%s' "$OUT" | grep -c 'no candidates')" 1

echo "== T5: row created after CUTOFF is protected (live-owner gate) =="
# created deliberately AHEAD of cutoff so this stays meaningful on cloudbox,
# where discovery finds no user serves and CUTOFF collapses to now.
DB="$LAB/t5.db"; mkdb "$DB"
addrow "$DB" msg_new "$(( (CUTOFF + 3600) * 1000 ))" "$STALE_UPD" NULL NULL
run "$DB"
check "reports 0 finalized" "$(printf '%s' "$OUT" | grep -c 'finalized 0 orphaned')" 1
check "row untouched"       "$("$SQLITE" "$DB" "SELECT json_extract(data,'\$.time.completed') IS NULL FROM message WHERE id='msg_new';")" 1
# Same reasoning as T4: without this, deleting the live-owner gate from phase 1
# is invisible because phase 2 re-checks it. MEASURED as a survivor before this
# line existed.
check "never became a candidate" "$(printf '%s' "$OUT" | grep -c 'no candidates')" 1

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

echo "== T10: every command the script calls resolves on the PATH it exports =="
# The single highest-risk mistake in this port. Devbox keeps `ps`-based
# discovery, so it needs procps on its PATH; cloudbox dropped procps when it
# moved discovery to systemd timestamps. Copying cloudbox's PATH line here
# breaks discovery SILENTLY: `ps` not found -> et empty -> the unit is skipped
# -> MAX_ETIMES stays 0 -> CUTOFF collapses to now -> the live-owner gate opens
# wide. That is the permissive failure the gate exists to prevent, arriving
# through the PATH. Assert against the BUILT artifact, not the nix source.
SPATH=$(awk -F'export PATH=' '/^[[:space:]]*export PATH=/{print $2; exit}' "$SWEEPER")
check "script exports a PATH" "$([ -n "$SPATH" ] && echo yes || echo no)" yes
for c in ps sqlite3 date systemctl awk tr wc; do
  if PATH="$SPATH" command -v "$c" >/dev/null 2>&1; then ok "$c resolves on the exported PATH"
  else bad "$c DOES NOT resolve on the exported PATH"; fi
done

echo "== T9: REGRESSION -- a zero-candidate sweep must not block a concurrent writer =="
# Fixture: all rows already completed, so 0 candidates -- exactly production,
# where the equivalent cloudbox sweeper matched nothing on 173/173 runs -- but
# large enough that a full scan is far longer than the writer's busy_timeout.
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

# The exit status goes through a FILE, not `wait`: hammer_while runs inside a
# command substitution, i.e. a subshell, where `wait` cannot reap a process that
# is a child of the parent shell (it returns 127 regardless of how the job
# actually ended). The rc write happens before the subshell exits, so it is
# there by the time the kill -0 loop notices the exit.
( HOME="$FAKEHOME" OPENCODE_SWEEPER_DB="$DB" "$SWEEPER" >"$LAB/t9.out" 2>&1; echo $? >"$LAB/t9.rc" ) &
read -r TRIES BLOCKED <<<"$(hammer_while $!)"
SRC=$(cat "$LAB/t9.rc" 2>/dev/null || echo "no-rc")
echo "  (sweeper: attempts=$TRIES blocked=$BLOCKED rc=$SRC)"
# blocked=0 is only meaningful if the sweeper actually RAN. A sweeper that
# crashed on startup would also block nobody, and would have passed this
# assertion silently while its output went to /dev/null. Hold both: it must
# have exited cleanly, and the hammer must have had real time to contend.
check "sweeper exited 0"     "$SRC" 0
if [ "$TRIES" -gt 5 ]; then ok "hammer got a real window ($TRIES attempts)"
else bad "hammer only managed $TRIES attempt(s) -- sweeper returned too fast for this to mean anything; see $LAB/t9.out"; fi
check "concurrent writer never blocked by sweeper" "$BLOCKED" 0

echo
echo "==== $PASS passed, $FAIL failed ===="
[ "$FAIL" -eq 0 ]
