#!/usr/bin/env bash
# Repair the v1.16 v2-schema poisoning of the shared opencode.db (cloudbox/devbox).
# Removes session_message.seq (+ its two indexes) so the pinned 1.15.13.x serve can
# insert session_message rows again. message/part/session history is untouched.
#
# Run DETACHED as root, because stopping opencode-serve kills the launching call:
#   /run/wrappers/bin/sudo --non-interactive /run/current-system/sw/bin/systemd-run \
#     --unit=oc-fix-$(date +%H%M%S) --collect \
#     /run/current-system/sw/bin/bash /path/to/fix.sh
#
# Logs to /tmp/opencode/oc-fix.log. Both hosts run as dev@, so HOME is /home/dev.
set -uo pipefail
export PATH=/run/current-system/sw/bin:/run/wrappers/bin:/usr/bin:/bin:/nix/var/nix/profiles/default/bin

USER_HOME=/home/dev
DB="$USER_HOME/.local/share/opencode/opencode.db"
LOG=/tmp/opencode/oc-fix.log
mkdir -p /tmp/opencode
exec >>"$LOG" 2>&1

echo "================ oc-fix START $(date -Is) ================"

# Always bring the serve back, even if the repair errors midway.
trap 'echo "[trap] ensuring opencode-serve is up"; systemctl start opencode-serve.service 2>&1 || true; echo "================ oc-fix END $(date -Is) ================"' EXIT

echo "[1] stopping opencode-serve.service"
systemctl stop opencode-serve.service
sleep 2

echo "[2] killing any process still holding $DB (leftover 1.15 or 1.16 re-poisoner)"
for pid in $(ls /proc 2>/dev/null | grep -E '^[0-9]+$'); do
  if ls -l "/proc/$pid/fd" 2>/dev/null | grep -q "$DB"; then
    echo "  killing pid $pid: $(readlink -f /proc/$pid/exe 2>/dev/null)"
    kill "$pid" 2>/dev/null || true
  fi
done
sleep 1

echo "[2b] backup (DB is quiescent now -> copy db + -wal + -shm for a faithful snapshot)"
BAK="$DB.bak-$(date +%Y-%m-%d)-prerepair"
cp -f "$DB" "$BAK" && echo "  backed up -> $BAK ($(du -h "$BAK" | cut -f1))"
for ext in -wal -shm; do [ -f "$DB$ext" ] && cp -f "$DB$ext" "$BAK$ext"; done

echo "[3] checkpoint WAL + repair schema (drop seq indexes + seq column)"
python3 - <<PY
import sqlite3
db = "$DB"
con = sqlite3.connect(db); cur = con.cursor()
try: cur.execute("PRAGMA wal_checkpoint(TRUNCATE)")
except Exception as e: print("  wal_checkpoint warn:", e)
cols = [r[1] for r in cur.execute("PRAGMA table_info(session_message)").fetchall()]
print("  before cols:", cols)
if "seq" not in cols:
    print("  no seq column -> already 1.15 schema")
else:
    for idx in ("session_message_session_type_seq_idx", "session_message_session_seq_idx"):
        cur.execute(f"DROP INDEX IF EXISTS {idx}"); print("  dropped index", idx)
    try:
        cur.execute("ALTER TABLE session_message DROP COLUMN seq"); con.commit()
        print("  dropped column seq via ALTER")
    except Exception as e:
        print("  ALTER failed, DROP TABLE + recreate:", e)
        cur.executescript("""
            DROP TABLE session_message;
            CREATE TABLE \`session_message\` (
              \`id\` text PRIMARY KEY, \`session_id\` text NOT NULL, \`type\` text NOT NULL,
              \`time_created\` integer NOT NULL, \`time_updated\` integer NOT NULL, \`data\` text NOT NULL,
              CONSTRAINT \`fk_session_message_session_id_session_id_fk\`
                FOREIGN KEY (\`session_id\`) REFERENCES \`session\`(\`id\`) ON DELETE CASCADE
            );
            CREATE INDEX \`session_message_time_created_idx\` ON \`session_message\` (\`time_created\`);
            CREATE INDEX \`session_message_session_time_created_id_idx\` ON \`session_message\` (\`session_id\`,\`time_created\`,\`id\`);
        """); con.commit(); print("  recreated session_message with 1.15 schema")
print("  after cols:", [r[1] for r in cur.execute("PRAGMA table_info(session_message)").fetchall()])
print("  quick_check:", cur.execute("PRAGMA quick_check").fetchone())
con.close()
PY

echo "[4] chown db files to dev:dev"
chown dev:dev "$DB" "$DB"-wal "$DB"-shm 2>/dev/null || true

echo "[5] starting opencode-serve.service"
systemctl start opencode-serve.service
sleep 4

echo "[6] verify"
echo "  is-active: $(systemctl is-active opencode-serve.service)"
echo "  MainPID exe: $(readlink -f /proc/$(systemctl show opencode-serve.service -p MainPID --value)/exe 2>/dev/null)"
echo "  health: $(curl -sf http://127.0.0.1:4096/global/health 2>&1 || echo FAILED)"
python3 - <<PY
import sqlite3
c = sqlite3.connect("file:$DB?mode=ro", uri=True).cursor()
cols = [r[1] for r in c.execute("PRAGMA table_info(session_message)").fetchall()]
print("  final session_message cols:", cols, "-> OK (1.15)" if "seq" not in cols else "-> STILL POISONED")
PY
echo "[6] verify done; trap guarantees serve is up"
