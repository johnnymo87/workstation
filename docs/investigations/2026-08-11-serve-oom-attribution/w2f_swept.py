#!/usr/bin/env python3
"""W2f: the sweeper ERASES the phantom-busy signature when it finalizes a row
(it writes $.error = MessageAbortedError with 'phantom-busy sweeper' in the
message). So counting live phantom-busy rows in a past window is a false
negative. Count the sweeper's fingerprint instead. Read-only."""
import sqlite3
import datetime

L = "/home/dev/.local/share/opencode/opencode.db"
con = sqlite3.connect(f"file:{L}?mode=ro", uri=True)
con.execute("PRAGMA query_only=1")


def ms(s):
    return int(datetime.datetime.fromisoformat(s).timestamp() * 1000)


Q = """
SELECT count(*) FROM message
WHERE time_created > ? AND time_created < ?
  AND json_extract(data, '$.role') = 'assistant'
  AND json_extract(data, '$.error.data.message') LIKE '%phantom-busy sweeper%'
"""
QANY = """
SELECT count(*) FROM message
WHERE time_created > ? AND time_created < ?
  AND json_extract(data, '$.role') = 'assistant'
  AND json_extract(data, '$.error') IS NOT NULL
"""

print("  swept-orphan fingerprint ('phantom-busy sweeper' in $.error) by window:")
for label, a, b in [
    ("08-08 20:36 OOM restart (4097)", "2026-08-08T20:00:00-04:00", "2026-08-08T21:00:00-04:00"),
    ("08-09 12:52 OOM restart (4097)", "2026-08-09T12:20:00-04:00", "2026-08-09T13:20:00-04:00"),
    ("control 08-07 12:20-13:20 (no OOM)", "2026-08-07T12:20:00-04:00", "2026-08-07T13:20:00-04:00"),
    ("whole clean window 08-05..08-11", "2026-08-05T00:00:00-04:00", "2026-08-11T12:00:00-04:00"),
]:
    swept = con.execute(Q, (ms(a), ms(b))).fetchone()[0]
    anyerr = con.execute(QANY, (ms(a), ms(b))).fetchone()[0]
    print(f"    {label:36} swept={swept:<4} any-error={anyerr}")

print("\n  all-time sweeper finalizations (for base rate):")
tot = con.execute("""
SELECT count(*) FROM message
WHERE json_extract(data, '$.error.data.message') LIKE '%phantom-busy sweeper%'
""").fetchone()[0]
print(f"    {tot}")
rows = con.execute("""
SELECT time_created FROM message
WHERE json_extract(data, '$.error.data.message') LIKE '%phantom-busy sweeper%'
ORDER BY time_created DESC LIMIT 12
""").fetchall()
print("  most recent swept rows (creation time):")
for (t,) in rows:
    print(f"    {datetime.datetime.fromtimestamp(t/1000):%Y-%m-%d %H:%M:%S}")
