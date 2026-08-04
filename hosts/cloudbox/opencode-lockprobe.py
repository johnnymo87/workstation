#!/usr/bin/env python3
"""W2d — read-only instrumentation of opencode.db write-lock contention.

Spec: docs/plans/2026-08-03-w2d-lockprobe-spec.md   Bead: workstation-yvxh.12

Measures TWO distinct quantities and never conflates them:

  H (hold)     exclusive POSIX WRITE lock on byte 120 of opencode.db-shm,
               from /proc/locks. Direct, holder PID visible.
  F (residual) contiguous hrtimer_nanosleep runs on a serve's MAIN thread,
               from /proc/<pid>/wchan. This is the hold time REMAINING when a
               contender arrived -- NOT the hold duration. See the spec.

Everything here is read-only procfs. No lock is ever taken on the database.

Serve discovery uses a systemd unit GLOB, so no serve port is named anywhere in
this file -- that keeps it clear of the front-door opacity guard by
construction rather than by exemption.
"""

from __future__ import annotations

import json
import os
import signal
import subprocess
import sys
import time

# --- configuration (env-overridable; the overrides exist so the state machine
# --- is testable against synthetic procfs fixtures without root or a serve).
DB = os.environ.get("LOCKPROBE_DB", "/home/dev/.local/share/opencode/opencode.db")
LOCKS = os.environ.get("LOCKPROBE_LOCKS", "/proc/locks")
WCHAN_FMT = os.environ.get("LOCKPROBE_WCHAN_FMT", "/proc/{pid}/wchan")
OUT = os.environ.get("LOCKPROBE_OUT", "/var/lib/opencode-lockprobe/episodes.jsonl")
HZ = float(os.environ.get("LOCKPROBE_HZ", "100"))
ROLLUP_SEC = float(os.environ.get("LOCKPROBE_ROLLUP_SEC", "300"))
REDISCOVER_SEC = float(os.environ.get("LOCKPROBE_REDISCOVER_SEC", "30"))
HOLD_DETAIL_MS = float(os.environ.get("LOCKPROBE_HOLD_DETAIL_MS", "100"))
FREEZE_DETAIL_MS = float(os.environ.get("LOCKPROBE_FREEZE_DETAIL_MS", "100"))
MAX_BYTES = int(os.environ.get("LOCKPROBE_MAX_BYTES", str(64 * 1024 * 1024)))
RUN_SECONDS = float(os.environ.get("LOCKPROBE_DURATION", "0"))  # 0 = forever
# Static "pid:port,pid:port" discovery override for tests. The literal "none"
# means an explicitly EMPTY serve set -- distinct from unset, which means "use
# real systemd discovery". An empty string cannot carry that distinction, and
# conflating them let a zero-serve test silently fall through to the live pool.
DISCOVER_STATIC = os.environ.get("LOCKPROBE_DISCOVER_STATIC", "")
SHM_INO_OVERRIDE = os.environ.get("LOCKPROBE_SHM_INO", "")

# WAL index lock bytes (sqlite3: wal.c). 120 is the one that serialises writers.
WRITE_BYTE = 120
LOCK_BYTES = range(120, 128)
LOCK_BYTE_NAMES = {120: "write", 121: "ckpt", 122: "recover"}
FREEZE_WCHAN = "hrtimer_nanosleep"

# Histogram edges in ms. Deliberately fine below 100ms (where the bulk lives)
# and coarse above 1s (where only the tail matters).
EDGES = [0, 5, 10, 20, 50, 100, 200, 500, 1000, 2000, 5000, 10000]


def bucket(ms: float) -> str:
    lo = 0
    for e in EDGES:
        if ms < e:
            return f"{lo}-{e}"
        lo = e
    return f"{EDGES[-1]}+"


class Emitter:
    """JSONL sink with a hard size cap.

    On hitting the cap it stops writing DETAIL records but keeps writing
    rollups, so a capped run degrades to counts-only instead of dying quietly.
    """

    def __init__(self, path: str, max_bytes: int):
        self.path = path
        self.max_bytes = max_bytes
        self.capped = False
        d = os.path.dirname(path)
        if d:
            os.makedirs(d, exist_ok=True)
        self.fh = open(path, "a", buffering=1)
        self.size = os.path.getsize(path) if os.path.exists(path) else 0

    def emit(self, rec: dict, detail: bool = True) -> None:
        if detail and self.capped:
            return
        if detail and self.size >= self.max_bytes:
            self.capped = True
            warn = {
                "t": time.time(),
                "type": "cap_reached",
                "bytes": self.size,
                "max_bytes": self.max_bytes,
                "note": "detail records suppressed; rollups continue",
            }
            line = json.dumps(warn) + "\n"
            self.fh.write(line)
            self.size += len(line)
            log("CAP REACHED at %d bytes -- detail suppressed, rollups continue" % self.size)
            return
        line = json.dumps(rec) + "\n"
        self.fh.write(line)
        self.size += len(line)


def log(msg: str) -> None:
    """Operational chatter -> stdout -> journal. Data goes to the JSONL file."""
    print(f"lockprobe: {msg}", flush=True)


def discover_serves() -> dict[str, str]:
    """Return {pid: port}. Uses a systemd unit GLOB -- never names a port."""
    if DISCOVER_STATIC == "none":
        return {}
    if DISCOVER_STATIC:
        out = {}
        for tok in DISCOVER_STATIC.split(","):
            tok = tok.strip()
            if not tok:
                continue
            pid, _, port = tok.partition(":")
            out[pid] = port or "?"
        return out
    try:
        res = subprocess.run(
            ["systemctl", "show", "opencode-serve@*.service",
             "--property=Id", "--property=MainPID", "--no-pager"],
            capture_output=True, text=True, timeout=10,
        )
    except (OSError, subprocess.SubprocessError) as e:
        log(f"discovery failed: {e}")
        return {}
    serves: dict[str, str] = {}
    unit = None
    for line in res.stdout.splitlines():
        if line.startswith("Id="):
            unit = line[3:].strip()
        elif line.startswith("MainPID="):
            pid = line[8:].strip()
            if unit and pid and pid != "0":
                # "opencode-serve@4096.service" -> instance name after '@'
                inst = unit.split("@", 1)[1].rsplit(".", 1)[0] if "@" in unit else "?"
                serves[pid] = inst
            unit = None
    return serves


def shm_inode() -> str | None:
    if SHM_INO_OVERRIDE:
        return SHM_INO_OVERRIDE
    try:
        return str(os.stat(DB + "-shm").st_ino)
    except OSError as e:
        log(f"cannot stat {DB}-shm: {e}")
        return None


def read_locks(shm_ino: str) -> dict[tuple[str, int], None]:
    """Currently-held exclusive locks on the -shm index bytes -> {(pid, byte)}."""
    held: dict[tuple[str, int], None] = {}
    try:
        with open(LOCKS) as f:
            for line in f:
                p = line.split()
                # id: POSIX ADVISORY WRITE <pid> <maj:min:ino> <start> <end>
                if len(p) < 8 or p[1] != "POSIX" or p[3] != "WRITE":
                    continue
                if p[5].rsplit(":", 1)[-1] != shm_ino:
                    continue
                try:
                    b = int(p[6])
                except ValueError:
                    continue
                if b in LOCK_BYTES:
                    held[(p[4], b)] = None
    except OSError:
        pass
    return held


def read_wchan(pid: str) -> str:
    try:
        with open(WCHAN_FMT.format(pid=pid)) as f:
            return f.read().strip()
    except OSError:
        return ""


def main() -> int:
    shm_ino = shm_inode()
    if shm_ino is None:
        log("FATAL: no -shm inode; is opencode running? refusing to report a false quiet")
        return 1

    em = Emitter(OUT, MAX_BYTES)
    period = 1.0 / HZ
    serves = discover_serves()
    log(f"start db={DB} shm_ino={shm_ino} hz={HZ:g} serves={len(serves)} out={OUT}")
    if not serves:
        log("WARNING: zero serves discovered -- freeze side is blind until rediscovery")
    em.emit({"t": time.time(), "type": "start", "shm_ino": shm_ino, "hz": HZ,
             "serves": serves, "res_ms": period * 1000}, detail=False)

    open_holds: dict[tuple[str, int], float] = {}
    open_freeze: dict[str, dict] = {}
    stop = {"now": False}

    def on_term(_sig, _frm):
        stop["now"] = True

    signal.signal(signal.SIGTERM, on_term)
    signal.signal(signal.SIGINT, on_term)

    def new_counters():
        return {
            "samples": 0,
            "holds": {},        # byte -> count
            "hold_hist": {},    # bucket -> count
            "hold_max_ms": 0.0,
            "freezes": 0,
            "freeze_hist": {},
            "freeze_max_ms": 0.0,
            "freeze_validated": 0,
        }

    c = new_counters()
    t_start = time.time()
    t_rollup = t_start
    t_disc = t_start

    while not stop["now"]:
        now = time.time()
        c["samples"] += 1

        # ---- hold side (H): /proc/locks
        cur = read_locks(shm_ino)
        for k in cur:
            if k not in open_holds:
                open_holds[k] = now
        for k in list(open_holds):
            if k not in cur:
                start = open_holds.pop(k)
                dur_ms = (now - start) * 1000.0
                pid, b = k
                name = LOCK_BYTE_NAMES.get(b, f"byte{b}")
                c["holds"][name] = c["holds"].get(name, 0) + 1
                c["hold_hist"][bucket(dur_ms)] = c["hold_hist"].get(bucket(dur_ms), 0) + 1
                c["hold_max_ms"] = max(c["hold_max_ms"], dur_ms)
                if dur_ms >= HOLD_DETAIL_MS:
                    em.emit({"t": round(start, 3), "type": "hold", "pid": pid,
                             "byte": b, "byte_name": name, "dur_ms": round(dur_ms, 1),
                             "res_ms": round(period * 1000, 2)})

        writers_now = {pid for (pid, b) in cur if b == WRITE_BYTE}

        # ---- freeze side (F): main-thread wchan. tid == pid for the main thread.
        for pid, port in serves.items():
            w = read_wchan(pid)
            if w == FREEZE_WCHAN:
                st = open_freeze.get(pid)
                if st is None:
                    open_freeze[pid] = {"start": now, "port": port, "holder": None}
                    st = open_freeze[pid]
                # Coincidence: a byte-120 hold by ANOTHER pid during our freeze
                # is near-conclusive evidence this is a SQLite busy-wait rather
                # than some other synchronous sleep.
                if st["holder"] is None:
                    other = writers_now - {pid}
                    if other:
                        st["holder"] = sorted(other)[0]
            else:
                st = open_freeze.pop(pid, None)
                if st is not None:
                    dur_ms = (now - st["start"]) * 1000.0
                    c["freezes"] += 1
                    c["freeze_hist"][bucket(dur_ms)] = c["freeze_hist"].get(bucket(dur_ms), 0) + 1
                    c["freeze_max_ms"] = max(c["freeze_max_ms"], dur_ms)
                    if st["holder"]:
                        c["freeze_validated"] += 1
                    if dur_ms >= FREEZE_DETAIL_MS:
                        em.emit({"t": round(st["start"], 3), "type": "freeze",
                                 "pid": pid, "port": st["port"],
                                 "dur_ms": round(dur_ms, 1),
                                 "overlapped_hold_pid": st["holder"],
                                 "res_ms": round(period * 1000, 2)})

        # ---- rediscovery. The nightly reset changes every PID; a sampler
        # ---- pinned to boot-time PIDs reports a confident empty distribution.
        if now - t_disc >= REDISCOVER_SEC:
            t_disc = now
            fresh = discover_serves()
            if fresh and set(fresh) != set(serves):
                gone = set(serves) - set(fresh)
                for pid in gone:
                    open_freeze.pop(pid, None)
                log(f"serve pids changed: {sorted(serves)} -> {sorted(fresh)}")
                em.emit({"t": now, "type": "pids_changed",
                         "old": serves, "new": fresh}, detail=False)
                serves = fresh
            elif not fresh:
                log("WARNING: rediscovery found zero serves")

        # ---- rollup. This doubles as the HEARTBEAT: it is what distinguishes
        # ---- "genuinely quiet" from "instrument broken". Analysis must check
        # ---- rollup continuity before quoting any distribution.
        if now - t_rollup >= ROLLUP_SEC:
            span = now - t_rollup
            rec = {
                "t": round(now, 3), "type": "rollup", "span_s": round(span, 1),
                "samples": c["samples"], "hz": round(c["samples"] / span, 1) if span else 0,
                "serves_found": len(serves), "pids": sorted(serves),
                "holds": c["holds"], "hold_hist": c["hold_hist"],
                "hold_max_ms": round(c["hold_max_ms"], 1),
                "freezes": c["freezes"], "freeze_hist": c["freeze_hist"],
                "freeze_max_ms": round(c["freeze_max_ms"], 1),
                "freeze_validated": c["freeze_validated"],
                "res_ms": round(period * 1000, 2),
                "capped": em.capped,
            }
            em.emit(rec, detail=False)
            log(f"rollup samples={c['samples']} hz={rec['hz']} serves={len(serves)} "
                f"holds={sum(c['holds'].values())} hold_max={rec['hold_max_ms']}ms "
                f"freezes={c['freezes']} freeze_max={rec['freeze_max_ms']}ms")
            c = new_counters()
            t_rollup = now

        if RUN_SECONDS and (now - t_start) >= RUN_SECONDS:
            break

        drift = time.time() - now
        time.sleep(max(0.0, period - drift))

    # Final rollup so a SIGTERM (nightly reset, reboot) does not silently drop
    # the tail of the window.
    now = time.time()
    span = max(now - t_rollup, 1e-9)
    em.emit({"t": round(now, 3), "type": "rollup", "final": True,
             "span_s": round(span, 1), "samples": c["samples"],
             "hz": round(c["samples"] / span, 1),
             "serves_found": len(serves), "pids": sorted(serves),
             "holds": c["holds"], "hold_hist": c["hold_hist"],
             "hold_max_ms": round(c["hold_max_ms"], 1),
             "freezes": c["freezes"], "freeze_hist": c["freeze_hist"],
             "freeze_max_ms": round(c["freeze_max_ms"], 1),
             "freeze_validated": c["freeze_validated"],
             "res_ms": round(period * 1000, 2), "capped": em.capped}, detail=False)
    log("exit (final rollup written)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
