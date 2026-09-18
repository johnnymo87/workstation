#!/usr/bin/env python3
"""Reap `opencode attach` TUIs whose session no longer exists.

WHY THIS EXISTS

`opencode-launch` opens an attach TUI for every session it starts. Nothing ever
closed them. Measured on cloudbox 2026-09-18: 108 attach processes, of which 48
pointed at sessions that no longer existed, holding roughly 11 GB between them.
They survived only until the nightly reset swept the tmux session away.

That accumulation is not merely waste. On 2026-09-15 a 34-session spin-up
created ~7-8 GB of new TUIs in five minutes on a host with ~12 GB available;
the kernel evicted ~12 GB of the coldest anon -- largely the OLD idle TUIs --
and host swap rose 17.17 -> 28.61 GB, stopping only when user-1000.slice hit
its 24 GiB swap ceiling. Reaping the dead ones removes both the standing cost
and the pool of cold anon that a future burst would push to swap.

THE ORACLE

The oracle is the `session` table in opencode.db, read read-only.

A CORRECTION, because the original rationale for that choice was wrong and is
worth not repeating: I first reported that `GET /session/<id>` on the front door
returns 404 for a LIVE session exactly as for a deleted one. It does not. It
answers 200 for live and 404 for dead, verified 5/5 and 2/2. My original test
sampled two ids that were BOTH already dead, so it could not have shown a
difference -- a control that cannot fail.

The database is still the better oracle here, for reasons that survive the
correction: it needs no network, it keeps working when a serve is wedged or the
door is down (exactly the conditions under which TUIs pile up), and a 404 from a
sick serve is indistinguishable from a 404 for a deleted session. But it is
chosen on those merits, not because the HTTP route is broken.

An oracle this tool trusts enough to kill on is an oracle whose FAILURE modes
have to be handled explicitly, because every one of them makes healthy TUIs look
orphaned:

  - database missing            -> kill nothing
  - database unreadable/corrupt -> kill nothing
  - session table empty         -> kill nothing (indistinguishable from
                                   "everything is orphaned", and the same shape
                                   as the 404 bug: a successful query meaning
                                   something other than it appears to)
  - implausible orphan fraction -> kill nothing, and say so

The last one is the backstop for failure modes nobody predicted. If nearly
every TUI looks dead, the likelier explanation is that the oracle is wrong than
that the world is. The real observed ratio is 48/108 = 0.44, so a default
threshold of 0.9 leaves enormous headroom while still refusing the
everything-looks-dead case.
"""
from __future__ import annotations

import argparse
import os
import re
import signal
import sqlite3
import sys
import time
from dataclasses import dataclass

DEFAULT_DB = os.path.expanduser("~/.local/share/opencode/opencode.db")
DEFAULT_GRACE_SECONDS = 600
DEFAULT_IDLE_GRACE_SECONDS = 1800
DEFAULT_DOOR_URL = "http://127.0.0.1:4700"
EXIT_REFUSED = 3
DEFAULT_MAX_ORPHAN_FRACTION = 0.9

_SESSION_RE = re.compile(r"(?:^|\0)--session\0([^\0]+)")


@dataclass
class Proc:
    pid: int
    sid: str
    age: float
    url: str
    idle: float | None


@dataclass
class Result:
    ok: bool
    reason: str = ""
    total: int = 0
    orphans: int = 0
    killed: int = 0
    skipped_young: int = 0
    skipped_active: int = 0


def _boot_time(proc_root):
    """Seconds since epoch at boot, from /proc/stat's btime line."""
    try:
        with open(os.path.join(proc_root, "stat")) as fh:
            for line in fh:
                if line.startswith("btime "):
                    return float(line.split()[1])
    except OSError:
        pass
    return None


def _process_age(proc_root, pid, boot):
    """Age in seconds from /proc/<pid>/stat field 22, or None.

    NOT st_mtime of /proc/<pid>: that is the procfs INODE creation time, and
    those dentries are ordinary reclaimable dcache. Under memory pressure the
    inode is evicted and the next lookup makes a fresh one whose mtime is now --
    so every process reads as newly born. The direction is safe (everything
    looks young, so nothing is reaped) but the tool would go inert during
    exactly the memory crunch it exists to prevent, and silently.

    field 22 is starttime in clock ticks since boot. Split after the LAST ')'
    because comm is parenthesised and may itself contain spaces or brackets.
    """
    if boot is None:
        return None
    try:
        with open(os.path.join(proc_root, str(pid), "stat")) as fh:
            raw = fh.read()
    except OSError:
        return None
    try:
        fields = raw[raw.rindex(")") + 1:].split()
        starttime_ticks = float(fields[19])
    except (ValueError, IndexError):
        return None
    hz = os.sysconf("SC_CLK_TCK") or 100
    return time.time() - (boot + starttime_ticks / hz)


def _stdin_idle_seconds(proc_root, pid):
    """Seconds since the TUI last read from its terminal, or None.

    fd 0 is the pty opencode attach reads keystrokes from; its atime advances on
    every read. A TUI whose argv names a dead session may still be in ACTIVE USE
    -- on session.deleted the TUI navigates to its home screen and stays alive,
    and a human can start a new session or switch sessions inside it, after
    which argv is stale but the process is someone's working window. argv is
    launch intent, not current state, so recent input is the veto.
    """
    try:
        return time.time() - os.stat(os.path.join(proc_root, str(pid), "fd", "0")).st_atime
    except OSError:
        return None


def _iter_attach_processes(proc_root):
    """Yield (pid, session_id, age_seconds) for each attach TUI we can identify.

    A process we cannot identify is never yielded: if we cannot tell which
    session it belongs to, we cannot judge whether it is orphaned, so it must
    not be a candidate. Matching is on argv[0] basename plus the literal
    `attach` subcommand, so a shell whose command line merely MENTIONS the
    string is not caught.
    """
    boot = _boot_time(proc_root)
    try:
        entries = os.listdir(proc_root)
    except OSError:
        return
    for name in entries:
        if not name.isdigit():
            continue
        path = os.path.join(proc_root, name)
        try:
            with open(os.path.join(path, "cmdline"), "rb") as fh:
                raw = fh.read().decode("utf-8", "replace")
        except OSError:
            continue
        parts = [p for p in raw.split("\0") if p]
        if len(parts) < 2:
            continue
        if os.path.basename(parts[0]) != "opencode" or parts[1] != "attach":
            continue
        m = _SESSION_RE.search(raw)
        if not m:
            continue
        pid = int(name)
        age = _process_age(proc_root, pid, boot)
        if age is None:
            # Cannot establish age -> cannot apply the grace period -> do not
            # judge it. Same rule as an unparseable session id.
            continue
        url = parts[2] if len(parts) > 2 else ""
        yield Proc(pid=pid, sid=m.group(1), age=age, url=url,
                   idle=_stdin_idle_seconds(proc_root, pid))


def _load_session_ids(db_path):
    """Return the set of session ids, or None if the oracle is untrustworthy."""
    try:
        conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
        rows = conn.execute("SELECT id FROM session").fetchall()
        conn.close()
    except sqlite3.Error:
        return None
    ids = {r[0] for r in rows}
    if not ids:
        # Empty is not "no sessions exist"; it is "this table did not tell us
        # anything", and acting on it would kill every TUI on the box.
        return None
    return ids


def _default_killer(pid):
    os.kill(pid, signal.SIGTERM)


def reap(
    proc_root="/proc",
    db=DEFAULT_DB,
    grace_seconds=DEFAULT_GRACE_SECONDS,
    idle_grace_seconds=DEFAULT_IDLE_GRACE_SECONDS,
    door_url=DEFAULT_DOOR_URL,
    max_orphan_fraction=DEFAULT_MAX_ORPHAN_FRACTION,
    dry_run=False,
    killer=None,
    log=lambda msg: None,
):
    killer = killer or _default_killer
    all_procs = list(_iter_attach_processes(proc_root))
    # Judge only TUIs attached to the door this database belongs to. A serve on
    # a scratch database (oc-throwaway-serve) hands out session ids that will
    # never appear in the production db, so judging those TUIs against it would
    # reap every one of them. Different door -> cannot judge -> leave alone.
    procs = [p for p in all_procs if not door_url or p.url == door_url]
    foreign = len(all_procs) - len(procs)
    if foreign:
        log(f"ignoring {foreign} attach process(es) on another door")
    if not procs:
        return Result(ok=True, reason="no attach processes", total=0)

    ids = _load_session_ids(db)
    if ids is None:
        msg = f"oracle unusable: cannot read sessions from {db}; killing nothing"
        log(msg)
        return Result(ok=False, reason=msg, total=len(procs))

    orphans = [p for p in procs if p.sid not in ids]
    fraction = len(orphans) / len(procs)
    if fraction > max_orphan_fraction:
        msg = (
            f"implausible fraction: {len(orphans)}/{len(procs)} attach processes "
            f"look orphaned ({fraction:.0%} > {max_orphan_fraction:.0%}); suspecting "
            f"the instrument rather than the world, killing nothing"
        )
        log(msg)
        return Result(ok=False, reason=msg, total=len(procs), orphans=len(orphans))

    killed = 0
    skipped_young = 0
    skipped_active = 0
    for p in orphans:
        if p.age < grace_seconds:
            # A TUI can exist before its session row is committed.
            skipped_young += 1
            log(f"skip pid={p.pid} session={p.sid} age={p.age:.0f}s < grace")
            continue
        if p.idle is not None and p.idle < idle_grace_seconds:
            # Someone is typing in it. argv names a dead session, but the TUI
            # stays alive on session.deleted and a human can start or switch
            # sessions inside it, so argv is launch intent and this is state.
            skipped_active += 1
            log(f"skip pid={p.pid} session={p.sid} stdin idle {p.idle:.0f}s < idle-grace")
            continue
        if dry_run:
            log(f"would kill pid={p.pid} session={p.sid} age={p.age:.0f}s")
            continue
        try:
            killer(p.pid)
            killed += 1
            log(f"killed pid={p.pid} session={p.sid} age={p.age:.0f}s")
        except (OSError, ProcessLookupError) as exc:
            log(f"could not kill pid={p.pid}: {exc}")
    return Result(
        ok=True,
        total=len(procs),
        orphans=len(orphans),
        killed=killed,
        skipped_young=skipped_young,
        skipped_active=skipped_active,
    )


def main(argv=None):
    ap = argparse.ArgumentParser(description=(__doc__ or "").split("\n")[0])
    ap.add_argument("--db", default=os.environ.get("OC_ATTACH_REAP_DB", DEFAULT_DB))
    ap.add_argument("--proc-root", default=os.environ.get("OC_ATTACH_REAP_PROC_ROOT", "/proc"))
    ap.add_argument("--grace-seconds", type=int, default=DEFAULT_GRACE_SECONDS)
    ap.add_argument("--idle-grace-seconds", type=int, default=DEFAULT_IDLE_GRACE_SECONDS)
    ap.add_argument("--door-url", default=os.environ.get("OC_FRONTDOOR_URL", DEFAULT_DOOR_URL))
    ap.add_argument("--max-orphan-fraction", type=float, default=DEFAULT_MAX_ORPHAN_FRACTION)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args(argv)

    def log(msg):
        if not args.quiet:
            print(f"oc-attach-reap: {msg}", file=sys.stderr)

    res = reap(
        proc_root=args.proc_root,
        db=args.db,
        grace_seconds=args.grace_seconds,
        idle_grace_seconds=args.idle_grace_seconds,
        door_url=args.door_url,
        max_orphan_fraction=args.max_orphan_fraction,
        dry_run=args.dry_run,
        log=log,
    )
    log(
        f"total={res.total} orphans={res.orphans} killed={res.killed} "
        f"skipped_young={res.skipped_young} skipped_active={res.skipped_active} "
        f"ok={res.ok}"
    )
    # A refusal is a DISTINCT code from a crash. The unit whitelists this one so
    # a declining sweep is not "failed", while an uncaught exception still exits
    # 1 and stays red -- otherwise the tool could die every run and look healthy.
    return 0 if res.ok else EXIT_REFUSED


if __name__ == "__main__":
    raise SystemExit(main())
