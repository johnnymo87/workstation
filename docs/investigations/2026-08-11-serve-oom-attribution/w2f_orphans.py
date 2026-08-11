#!/usr/bin/env python3
"""W2f: orphan impact of the two production serve@4097 OOM restarts.

Read-only (mode=ro + query_only). Phantom-busy = assistant message row with
time.completed NULL AND error NULL, which is the signature the sweeper targets.
"""
import sqlite3
import datetime

L = "/home/dev/.local/share/opencode/opencode.db"
con = sqlite3.connect(f"file:{L}?mode=ro", uri=True)
con.execute("PRAGMA query_only=1")

Q = """
SELECT id, session_id, time_created,
       json_extract(data, '$.time.completed'),
       json_extract(data, '$.error')
FROM message
WHERE time_created > ? AND time_created < ?
  AND json_extract(data, '$.role') = 'assistant'
"""


def ms(s):
    return int(datetime.datetime.fromisoformat(s).timestamp() * 1000)


windows = {
    "08-08 20:36 OOM restart (4097)": ("2026-08-08T20:00:00-04:00", "2026-08-08T21:00:00-04:00"),
    "08-09 12:52 OOM restart (4097)": ("2026-08-09T12:20:00-04:00", "2026-08-09T13:20:00-04:00"),
    "control: 08-07 same hour, no OOM": ("2026-08-07T12:20:00-04:00", "2026-08-07T13:20:00-04:00"),
}
for label, (a, b) in windows.items():
    rows = con.execute(Q, (ms(a), ms(b))).fetchall()
    orph = [r for r in rows if r[3] is None and r[4] is None]
    print(f"  {label}")
    print(f"      assistant rows={len(rows):>4}   phantom-busy(orphan)={len(orph)}")
    for r in orph[:6]:
        t = datetime.datetime.fromtimestamp(r[2] / 1000)
        print(f"        msg={r[0][:24]} ses={r[1][:24]} created={t:%m-%d %H:%M:%S}")

tot = con.execute("""
SELECT count(*) FROM message
WHERE json_extract(data, '$.role') = 'assistant'
  AND json_extract(data, '$.time.completed') IS NULL
  AND json_extract(data, '$.error') IS NULL
""").fetchone()[0]
print(f"\n  TOTAL phantom-busy rows in DB right now: {tot}")
