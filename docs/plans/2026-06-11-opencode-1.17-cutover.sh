#!/usr/bin/env bash
#
# OpenCode 1.15.13-patched.3 -> 1.17.2-patched.2 cutover, with in-place DB migrate.
#
# RUN THIS ON cloudbox, DRIVEN FROM A NON-cloudbox SESSION (a macOS opencode agent
# over SSH). It STOPS ALL opencode processes on cloudbox (killing every active TUI
# session AND the systemd serve), migrates the shared opencode.db, switches
# home-manager to the 1.17.2-patched.2 pin, and restarts the serve.
#
# Do NOT run it from inside a cloudbox opencode session — stopping the serve kills it.
#
# Safe: aborts if the DB is still held after the kill, verifies the migrate preserved
# history, leaves a timestamped pre-cutover backup. Verified 2026-06-11 on a 4.2 GB
# copy (migrate preserves all history; seq writes work).
# Runbook: docs/plans/2026-06-11-opencode-1.17-cutover-runbook.md  (bead: workstation-vnu)

set -euo pipefail

REPO="$HOME/projects/workstation"
DB="$HOME/.local/share/opencode/opencode.db"
TS="$(date +%Y%m%d-%H%M%S)"
HEALTH="http://127.0.0.1:4096/global/health"
PRE_PIN_COMMIT="f0821c9"   # last commit before the 1.17.2 pin (for rollback)

log(){ printf '\n=== %s ===\n' "$*"; }

log "0. Preconditions"
test -f "$DB" || { echo "ABORT: no DB at $DB"; exit 1; }
echo "profile opencode: $(readlink -f "$HOME/.nix-profile/bin/opencode")"
echo "serve unit: $(systemctl is-active opencode-serve.service 2>/dev/null || true)"

log "1. Prevent a mid-cutover auto-switch (pull-workstation)"
systemctl --user stop pull-workstation.timer 2>/dev/null || true

log "2. Stop the systemd serve"
sudo systemctl stop opencode-serve.service || true

log "3. Kill ALL opencode processes (every TUI + strays)"
kill_oc() {
  local sig="$1" n=0 pid exe
  for pid in $(pgrep -f opencode 2>/dev/null || true); do
    exe=$(readlink "/proc/$pid/exe" 2>/dev/null || true)
    case "$exe" in
      *opencode-patched*) echo "  kill $sig $pid"; kill "$sig" "$pid" 2>/dev/null || true; n=$((n+1));;
    esac
  done
  echo "  ($n signalled)"
}
kill_oc -TERM; sleep 3; kill_oc -KILL; sleep 2

log "4. Verify NOBODY holds the DB"
holders=""
for pid in $(pgrep -f opencode 2>/dev/null || true); do
  ls -l "/proc/$pid/fd" 2>/dev/null | grep -q "opencode/opencode.db" && holders="$holders $pid"
done
if [ -n "$holders" ]; then
  echo "ABORT: opencode.db still held by:$holders  (ps -fp <pid>; resolve, re-run)"; exit 1
fi
echo "  DB is quiescent."

log "5. Backup + migrate fix-up + verify (Python backup API recovers WAL)"
python3 - "$DB" "$TS" <<'PY'
import sqlite3, sys, os
db, ts = sys.argv[1], sys.argv[2]
bak = f"{db}.bak-{ts}-precutover"
s = sqlite3.connect(db); s.execute("PRAGMA busy_timeout=60000")
d = sqlite3.connect(bak)
with d: s.backup(d)
d.close()
before_msg  = s.execute("SELECT count(*) FROM message").fetchone()[0]
before_part = s.execute("SELECT count(*) FROM part").fetchone()[0]
before_sess = s.execute("SELECT count(*) FROM session").fetchone()[0]
print(f"  backup -> {bak} ({os.path.getsize(bak)} bytes)")
print(f"  before: message={before_msg} part={before_part} session={before_sess}")
# Verified fix-up: session_message is a re-derivable projection (history lives in
# message/part). Our repaired DB reverted it to a pre-`seq` schema; recreate it to
# the exact v1.17.2 schema (migration 20260604172448_event_sourced_session_input).
s.executescript('''
PRAGMA foreign_keys=OFF;
DROP TABLE IF EXISTS session_message;
CREATE TABLE session_message (
    id text PRIMARY KEY NOT NULL,
    session_id text NOT NULL REFERENCES session(id) ON DELETE CASCADE,
    type text NOT NULL,
    seq integer NOT NULL,
    time_created integer NOT NULL,
    time_updated integer NOT NULL,
    data text NOT NULL
);
CREATE UNIQUE INDEX session_message_session_seq_idx ON session_message (session_id, seq);
CREATE INDEX session_message_session_type_seq_idx ON session_message (session_id, type, seq);
CREATE INDEX session_message_session_time_created_id_idx ON session_message (session_id, time_created, id);
CREATE INDEX session_message_time_created_idx ON session_message (time_created);
PRAGMA foreign_keys=ON;
''')
s.commit()
cols = [r[1] for r in s.execute("PRAGMA table_info(session_message)")]
qc   = s.execute("PRAGMA quick_check").fetchone()[0]
fk   = s.execute("PRAGMA foreign_key_check").fetchall()
after_msg  = s.execute("SELECT count(*) FROM message").fetchone()[0]
after_part = s.execute("SELECT count(*) FROM part").fetchone()[0]
assert "seq" in cols, f"seq missing: {cols}"
assert qc == "ok", f"quick_check: {qc}"
assert not fk, f"fk violations: {fk[:5]}"
assert after_msg == before_msg and after_part == before_part, "history count changed!"
print(f"  fix-up OK: seq present; quick_check=ok; fk clean; message/part unchanged ({after_msg}/{after_part})")
s.close()
PY

log "6. Ensure repo on main + up to date (the pin lives on main)"
cd "$REPO"
git checkout main
git pull --ff-only origin main
grep -qE 'upstreamVersion = "1.17.2"' users/dev/home.base.nix \
  && grep -qE 'patchedRevision = "2"' users/dev/home.base.nix \
  || { echo "ABORT: main does not carry the 1.17.2-patched.2 pin"; exit 1; }

log "7. Apply home-manager (switch to 1.17.2-patched.2)"
nix run github:nix-community/home-manager/release-25.11 -- switch --flake "$REPO#cloudbox"
NEW="$(readlink -f "$HOME/.nix-profile/bin/opencode")"
echo "  opencode now: $NEW"
case "$NEW" in *1.17.2*) echo "  pin OK";; *) echo "ABORT: profile is not 1.17.2"; exit 1;; esac

log "8. Start serve"
sudo systemctl start opencode-serve.service
for i in $(seq 1 30); do curl -sf "$HEALTH" >/dev/null 2>&1 && break; sleep 1; done

log "9. Verify (automated)"
echo -n "  health: "; curl -sf "$HEALTH" && echo
python3 - "$DB" <<'PY'
import sqlite3, sys
c=sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
print("  session_message has seq:", "seq" in [r[1] for r in c.execute("PRAGMA table_info(session_message)")])
print("  message rows:", c.execute("SELECT count(*) FROM message").fetchone()[0])
c.close()
PY

cat <<'EOF'

=== Mechanical cutover done. NOW VERIFY (driver agent should do a-b, user does c-d): ===
  a. READ: GET http://127.0.0.1:4096/session then /session/<id>/message for an old
     session -> full history renders.
  b. WRITE: create a session + send a 1-word prompt to google-vertex/gemini-3.5-flash
     -> succeeds (no "session_message has no column named seq"); session_message rows
     appear with seq populated.
  c. QUESTION-TOOL GATE (instance-state-partition was dropped): in an interactive TUI,
     trigger the Question tool and SUBMIT -> MUST NOT hang. If it hangs, that fix needs
     re-engineering for 1.17 (patched.3 fast-follow).
  d. VIM: set `tui.vim: true` and confirm vim mode works (the re-port is build-validated
     only, not runtime-validated; fragile spots: keymap.dispatchCommand, vim context import).

=== Rollback (if something is wrong) ===
  systemctl --user stop pull-workstation.timer
  sudo systemctl stop opencode-serve.service
  for p in $(pgrep -f opencode); do case "$(readlink /proc/$p/exe)" in *opencode-patched*) kill -9 "$p";; esac; done
  cp ~/.local/share/opencode/opencode.db.bak-<TS>-precutover ~/.local/share/opencode/opencode.db
  cd ~/projects/workstation && git checkout main \
    && git checkout f0821c9 -- users/dev/home.base.nix \
    && git commit -m "revert: roll opencode pin back to 1.15.13-patched.3"
  nix run github:nix-community/home-manager/release-25.11 -- switch --flake ~/projects/workstation#cloudbox
  sudo systemctl start opencode-serve.service
EOF
echo
echo "DONE."
