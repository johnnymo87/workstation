#!/usr/bin/env python3
"""Print the swarm_send id of a program's stall-watch coordinator.

Usage: find-coordinator.py <tag>     one program
       find-coordinator.py --all     every program with a bound coordinator

Read-only. Exit 0 = reachable coordinator printed; 1 = none / not usable;
2 = this host has no stall-watch (coordinators run on cloudbox).
"""
import datetime
import json
import os
import sqlite3
import sys
import tomllib
import urllib.request

STATE_DB = os.path.expanduser("~/.local/state/stall-watch/state.db")
PROGRAMS = os.path.expanduser("~/projects/eng-agent-platform/stallwatch/programs.toml")
PIGEON = os.environ.get("PIGEON_DAEMON_URL", "http://127.0.0.1:4731")
TOKEN_FILE = "/run/secrets/pigeon_daemon_auth_token"


def load_programs():
    try:
        with open(PROGRAMS, "rb") as f:
            return {p["tag"]: p for p in tomllib.load(f).get("program", []) if "tag" in p}
    except OSError as e:
        print(f"warning: cannot read {PROGRAMS} ({e}); enabled/mode/heartbeat unchecked",
              file=sys.stderr)
        return None


def pigeon_sessions():
    """gse_ id -> pigeon session row, or None if pigeon is unreachable."""
    req = urllib.request.Request(f"{PIGEON}/sessions")
    if os.access(TOKEN_FILE, os.R_OK):
        with open(TOKEN_FILE) as f:
            req.add_header("Authorization", f"Bearer {f.read().strip()}")
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return {s["session_id"]: s for s in json.load(r).get("sessions", [])}
    except Exception as e:  # noqa: BLE001 - report and continue without the cross-check
        print(f"warning: pigeon {PIGEON}/sessions unreachable ({e}); routing unchecked",
              file=sys.stderr)
        return None


def heartbeat_on(prog):
    # Mirrors stallwatch config.heartbeat_effective: on, and not past heartbeat_until.
    until = prog.get("heartbeat_until")
    return bool(prog.get("heartbeat")) and (
        until is None or datetime.date.today() <= datetime.date.fromisoformat(str(until)))


def describe(tag, gse, programs, sessions):
    """Return (ok, line)."""
    if not gse:
        return False, f"{tag}: no bound coordinator"
    hb = "?"
    if programs is not None:
        prog = programs.get(tag)
        if prog is None:
            return False, f"{tag}: {gse} is in state.db but not in programs.toml; nothing reads it"
        if not prog.get("enabled", True) or prog.get("mode", "json") != "tools":
            return False, f"{tag}: {gse} belongs to a disabled or non-tools program; nothing reads it"
        hb = "on" if heartbeat_on(prog) else "off"
    if sessions is not None:
        s = sessions.get(gse)
        if s is None or s.get("state") != "running" or "swarm" not in (s.get("pull_sources") or []):
            return False, f"{tag}: {gse} is not routable in pigeon (row={s and s.get('state')})"
    return True, f"{tag}  to={gse}  heartbeat={hb}"


def main(argv):
    if len(argv) != 2 or argv[1] in ("-h", "--help"):
        print((__doc__ or "").strip(), file=sys.stderr)
        return 1
    if not os.path.exists(STATE_DB):
        print("no stall-watch on THIS host. Coordinators run on cloudbox; "
              "this host cannot see or reach them. Ask the human to forward the finding.")
        return 2
    con = sqlite3.connect(f"file:{STATE_DB}?mode=ro", uri=True)
    programs, sessions = load_programs(), pigeon_sessions()
    if argv[1] == "--all":
        rows = con.execute("SELECT tag, pigeon_session FROM program"
                           " WHERE pigeon_session IS NOT NULL ORDER BY tag").fetchall()
        for tag, gse in rows:
            print(describe(tag, gse, programs, sessions)[1])
        return 0
    tag = argv[1]
    row = con.execute("SELECT pigeon_session FROM program WHERE tag=?", (tag,)).fetchone()
    ok, line = describe(tag, row and row[0], programs, sessions)
    print(line)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
