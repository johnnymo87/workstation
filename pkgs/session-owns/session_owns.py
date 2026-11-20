# ONE definition of "does a live agent session own this directory", shared by
# every cleanup guard on these hosts (bd workstation-6w7i.19):
#
#   - users/dev/disk-cleanup.nix sessionOwnsPy: this file's text, interpolated
#     into tmp-scratch-sweep, venv-sweep, cargo-reap and bazel-reap's probes;
#   - disk-cleanup's GUARD 1b (cleanup_worktrees), via bin/session-owns;
#   - git-work's `work --prune-merged`, via bin/session-owns.
#
# Until 2026-11-20 those were three slightly different queries: GUARD 1b
# matched opencode directories exactly while the sweepers matched
# subdirectories, and only sessionOwnsPy read goose's messages clock. Each
# difference was a direction in which one guard deleted what another kept.
#
# THIS FILE IS A LIBRARY, NOT A SCRIPT. It is pasted into other python
# programs, so it must not execute anything at import: no `__main__` block.
# bin/session-owns (pkgs/session-owns/default.nix) appends its own entry point.
#
# Three sources, combined as session > unknown > free. Only "free" permits
# removal. Anything that goes wrong -- unreadable, corrupt, locked -- is
# "unknown", because an empty answer from a probe that never ran looks exactly
# like "nothing lives here".
#
# 1. opencode's session table (~/.local/share/opencode/opencode.db). An opencode
#    session's working directory is a ROW, not any process's cwd: the serve
#    that owns it runs from its own directory and holds no handle inside the
#    tree (measured on cloudbox 2026-09-01, when a sweeper deleted a live
#    session's directory with /proc showing nothing there). Live = time_updated
#    inside the window. A MISSING db is a parameter (`missing`): "free" on a
#    host that never runs opencode, "unknown" for a caller that knows opencode
#    is installed and would otherwise go silently inert.
#
# 2. goose's sessions table (~/.local/share/goose/sessions/sessions.db,
#    sessions.working_dir). Every row counts, whatever its session_type: a
#    subagent has its OWN working_dir. Live = updated_at (UTC text) OR any of
#    its messages' created_timestamp (epoch s) inside the window; either clock
#    alone saying "recent" keeps the tree. A MISSING goose db is always "free"
#    (goose is not installed).
#
# 3. PATH CLAIMS (~/.local/state/path-claims/*.json; seam: $PATH_CLAIMS_DIR).
#    Some agents work in a directory no session table names. lgtm's goose
#    review turns run with a PRIVATE GOOSE_PATH_ROOT, and their sessions.db
#    records the review root's empty cwd as working_dir, while the agent `cd`s
#    into <repo>/.worktrees/lgtm-pr-<N> for every command. So those runs
#    REGISTER the directory they work in instead:
#
#      {"path": "/abs/dir", "expires_at": <epoch seconds>,
#       "owner": "lgtm", "what": "goose review lgr-..."}
#
#    Writers write atomically (a dot-prefixed temp file renamed into place);
#    the reader skips dot-files and anything not ending in .json. A claim is
#    live while now < min(expires_at, mtime + CLAIM_MAX_TTL_SECONDS); it is
#    checked against NOW, not against the caller's activity window, because it
#    is an assertion rather than an inference from last activity. The 24h cap
#    bounds the damage from a claim that is never removed or names a bogus far
#    future: a file whose mtime is older than that is ignored unread. A FRESH
#    claim that cannot be parsed is "unknown" (keeps everything for at most
#    24h), because it might name the directory about to be deleted.
#
# Matching, for all three: an owner directory protects a candidate when it IS
# the candidate or lies UNDER it (a session that ran `cd src` inside a
# worktree, a clone inside a scratch dir). Candidates are the path as given
# plus its realpath.
import json
import os
import sqlite3
import time

SESSION_ACTIVE_DAYS = 7
OPENCODE_SESSION_DB_DEFAULT = os.path.expanduser(
    "~/.local/share/opencode/opencode.db")
GOOSE_SESSION_DB_DEFAULT = os.path.expanduser(
    "~/.local/share/goose/sessions/sessions.db")
CLAIM_MAX_TTL_SECONDS = 24 * 3600


def path_claims_dir_default():
    """Resolved at call time so a test (or a caller) can set PATH_CLAIMS_DIR."""
    return os.environ.get("PATH_CLAIMS_DIR") or os.path.expanduser(
        "~/.local/state/path-claims")


def _path_matches(directory, candidates):
    directory = directory.rstrip("/") or "/"
    return any(directory == c or directory.startswith(c + "/") for c in candidates)


def opencode_session_owner(candidates, db_path, missing, cutoff_s):
    """(verdict, detail) for opencode's session table."""
    if not os.path.isfile(db_path):
        return (missing, "opencode db missing: %s" % db_path)
    cutoff_ms = int(cutoff_s * 1000)
    try:
        # Read-only URI: a concurrent serve is writing this database and
        # must never be disturbed by a cleanup probe.
        con = sqlite3.connect("file:%s?mode=ro" % db_path, uri=True, timeout=10)
        try:
            # Filter in SQL by TIME only, then match paths in python: a LIKE
            # would treat the '_' in worktree names as a wildcard, and an
            # exact `in (...)` misses a session in a subdirectory. Recent
            # sessions are few; the stale rows are excluded by the predicate.
            rows = con.execute(
                "select id, directory from session where time_updated >= ? "
                "order by time_updated desc",
                (cutoff_ms,),
            ).fetchall()
        finally:
            con.close()
    except Exception as exc:
        return ("unknown", "opencode: %s" % exc)
    for sid, directory in rows:
        if directory and _path_matches(directory, candidates):
            return ("session", "opencode session %s" % sid)
    return ("free", "")


def goose_session_owner(candidates, goose_db_path, cutoff_s):
    """(verdict, detail) for goose's sessions table."""
    if not goose_db_path or not os.path.isfile(goose_db_path):
        return ("free", "")
    cutoff_text = time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime(cutoff_s))
    try:
        # Read-only: a live goose-serve or honkd is writing this database.
        con = sqlite3.connect("file:%s?mode=ro" % goose_db_path, uri=True, timeout=10)
        try:
            rows = con.execute(
                "select s.id, s.working_dir from sessions s "
                "where s.updated_at >= ? "
                "or exists (select 1 from messages m "
                "           where m.session_id = s.id and m.created_timestamp >= ?) "
                "order by s.updated_at desc",
                (cutoff_text, int(cutoff_s)),
            ).fetchall()
        finally:
            con.close()
    except Exception as exc:
        return ("unknown", "goose: %s" % exc)
    for sid, working_dir in rows:
        if working_dir and _path_matches(working_dir, candidates):
            return ("session", "goose session %s" % sid)
    return ("free", "")


def claim_owner(candidates, claims_dir, now=None):
    """(verdict, detail) for the path-claims directory. See the header."""
    if now is None:
        now = time.time()
    if not claims_dir or not os.path.exists(claims_dir):
        return ("free", "")
    try:
        names = sorted(os.listdir(claims_dir))
    except Exception as exc:
        return ("unknown", "claims: %s" % exc)
    unknown = None
    for name in names:
        if name.startswith(".") or not name.endswith(".json"):
            continue
        fp = os.path.join(claims_dir, name)
        try:
            mtime = os.stat(fp).st_mtime
        except FileNotFoundError:
            continue  # released between listdir and stat
        except Exception as exc:
            unknown = unknown or "claim %s: %s" % (name, exc)
            continue
        if mtime < now - CLAIM_MAX_TTL_SECONDS:
            continue
        try:
            with open(fp, encoding="utf-8") as fh:
                claim = json.load(fh)
            path = claim["path"]
            expires_at = float(claim["expires_at"])
            if not isinstance(path, str) or not path.startswith("/"):
                raise ValueError("path is not absolute: %r" % (path,))
        except FileNotFoundError:
            continue
        except Exception as exc:
            unknown = unknown or "claim %s unreadable: %s" % (name, exc)
            continue
        if now >= min(expires_at, mtime + CLAIM_MAX_TTL_SECONDS):
            continue
        if _path_matches(path, candidates):
            what = claim.get("what") or claim.get("owner") or "?"
            return ("session", "claim %s (%s)" % (name, what))
    if unknown:
        return ("unknown", unknown)
    return ("free", "")


def session_owner(p, db_path=None, missing="free", active_seconds=None,
                  goose_db_path=None, claims_dir=None, now=None):
    """(verdict, detail): verdict is 'session' | 'free' | 'unknown'.

    Only 'free' permits removal. `detail` names the owner (or the failure).
    """
    if db_path is None:
        db_path = OPENCODE_SESSION_DB_DEFAULT
    if goose_db_path is None:
        goose_db_path = GOOSE_SESSION_DB_DEFAULT
    if claims_dir is None:
        claims_dir = path_claims_dir_default()
    if now is None:
        now = time.time()
    candidates = {p.rstrip("/") or "/"}
    try:
        candidates.add(os.path.realpath(p))
    except OSError:
        pass
    if active_seconds is None:
        active_seconds = SESSION_ACTIVE_DAYS * 86400
    cutoff_s = now - active_seconds
    results = (
        opencode_session_owner(candidates, db_path, missing, cutoff_s),
        goose_session_owner(candidates, goose_db_path, cutoff_s),
        claim_owner(candidates, claims_dir, now),
    )
    for v in ("session", "unknown"):
        for verdict, detail in results:
            if verdict == v:
                return (verdict, detail)
    return ("free", "")


def session_owns(p, db_path, missing="free", active_seconds=None,
                 goose_db_path=None, claims_dir=None):
    """'session' | 'free' | 'unknown'. Only 'free' permits removal."""
    return session_owner(p, db_path, missing, active_seconds,
                         goose_db_path, claims_dir)[0]


def main(argv):
    """bin/session-owns: print '<verdict>[ <detail>]'; exit 0 session, 1 free, 2 unknown."""
    import argparse
    ap = argparse.ArgumentParser(prog="session-owns")
    ap.add_argument("path")
    ap.add_argument("--opencode-db", default=None)
    ap.add_argument("--opencode-missing", choices=("free", "unknown"), default="free")
    ap.add_argument("--goose-db", default=None)
    ap.add_argument("--claims-dir", default=None)
    ap.add_argument("--active-seconds", type=float, default=None)
    args = ap.parse_args(argv)
    try:
        verdict, detail = session_owner(
            args.path, args.opencode_db, args.opencode_missing,
            args.active_seconds, args.goose_db, args.claims_dir)
    except Exception as exc:  # never let a crash read as "free"
        verdict, detail = "unknown", "probe crashed: %s" % exc
    print(("%s %s" % (verdict, detail)).rstrip())
    return {"session": 0, "free": 1}.get(verdict, 2)
