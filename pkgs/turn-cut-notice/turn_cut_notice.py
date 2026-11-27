#!/usr/bin/env python3
"""turn-cut-notice: tell agent sessions that a planned serve restart cut their turn.

Called by reset-workspace (workstation-dg6). A turn running when the reset
restarts the opencode serve pool or goose-serve dies with the process: the
agent loop is in memory, a pending `question` is lost, and nothing re-prompts
the agent, so a worker mid-task just stops. This tool records which sessions
had a turn in flight immediately before each restart, then, once the serves
are back, sends each one a swarm message (through pigeon, the same route
lgtm-shepherd uses to wake sessions) saying the turn was cut and what to do.

    turn-cut-notice snapshot-opencode --db PATH --live-invocation-ids ID,ID --out FILE
    turn-cut-notice snapshot-goose --out FILE [--honk honk]
    turn-cut-notice notify --snapshot FILE [--snapshot FILE ...] [--db PATH]
                           [--pigeon-url URL] [--pigeon-token-file F] [--max N] [--dry-run]
                           [--resume-state FILE]
    turn-cut-notice resume-goose [--honk honk] [--resume-state FILE] [--reset-lock F]
                           [--pigeon-url URL] [--pigeon-token-file F] [--max N] [--dry-run]

`resume-goose` (workstation-6w7i.16) is the same notice for EVERY goose-serve
restart, not just the nightly one: a deploy, a crash, a restart by hand. It
needs no snapshot, because honkd records each turn a goose restart cut
(`honk list --json` lastError, kind "interrupted"), and that record clears as
soon as the session runs again. Run every minute by the goose-turn-resume
user timer.

Exit codes: 0 ok (including "nothing to do"), 1 something failed (the caller
logs a warning and carries on -- this tool must never fail a reset), 2 usage.

Stdlib only: it ships to devbox and cloudbox inside reset-workspace's closure.
Design: docs/plans/2026-11-24-reset-turn-cut-notice.md
"""

from __future__ import annotations

import argparse
import json
import os
import sqlite3
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

SENDER = "reset-workspace"
KIND = "reset.turn_cut"
RESUME_SENDER = "goose-turn-resume"
RESUME_KIND = "goose.turn_cut"
# honkd's record of a turn cut by a goose restart (honk crates/honkd/src/turn.rs).
# NOT its other "interrupted" message, "honkd could not tell whether goose got
# the prompt": there goose may never have seen the prompt, so "carry on" would
# be wrong, and pigeon's recover-inflight resends that one itself.
CUT_KIND = "interrupted"
CUT_MESSAGE = "goose restarted during the turn"
# Loop guard: a resume that makes goose crash again must not loop forever.
RESUME_CAP = 3
RESUME_CAP_WINDOW_S = 6 * 3600
RESUME_STATE_KEEP_S = 7 * 24 * 3600
DEFAULT_RESUME_STATE = os.path.join(
    os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state"),
    "goose-turn-resume", "state.json",
)
DEFAULT_RESET_LOCK = "/tmp/reset-workspace.lock"
DEFAULT_PIGEON_URL = "http://127.0.0.1:4731"
DEFAULT_TOKEN_FILE = "/run/secrets/pigeon_daemon_auth_token"
DEFAULT_MAX = 30
# Only sessions touched this recently are considered at all. A turn in flight
# right now has, by definition, touched its session recently; the bound keeps
# the scan to a handful of rows on an 11 GB opencode.db.
SESSION_WINDOW_S = 24 * 3600
# Fallback when no pool InvocationID could be read: an assistant row whose
# turn is still streaming has been updated within this window.
FALLBACK_UPDATED_WINDOW_S = 30 * 60
# A user message with no reply yet, this fresh, was accepted and not started.
USER_LAST_WINDOW_S = 10 * 60
QUESTION_TEXT_CAP = 600
# pigeon refuses a payload containing its envelope's close tag (400), which
# would lose the whole notice over one agent-written question.
CLOSE_TAG = "</swarm_message>"
# Sessions whose owner already retries a cut turn by itself. A notice there
# would start a SECOND run of the same work (and a coordinator's reply is
# posted to the human's chat at 03:0x):
#  - stall-watch coordinators: a cancelled run is CoordinatorBusy, and the
#    wake is kept and retried on the next tick (stallwatch/tick.py).
#  - lgtm review dispatches (pigeon session-origin "lgtm"): lgtm's watchdog
#    judges a dispatch by session liveness and re-dispatches a dead one.
STALL_WATCH_COORD_DIR = "/stall-watch/coord-sessions/"
STALL_WATCH_TITLE_PREFIX = "stallwatch-"
SELF_RETRYING_ORIGINS = {"lgtm"}


def log(msg: str) -> None:
    print(f"turn-cut-notice: {msg}", file=sys.stderr)


def _ro_connect(db: str) -> sqlite3.Connection:
    # mode=ro: never take the WAL write lock against live serves.
    conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=10)
    conn.row_factory = sqlite3.Row
    return conn


def _json(text: str | None) -> dict:
    if not text:
        return {}
    try:
        v = json.loads(text)
    except ValueError:
        return {}
    return v if isinstance(v, dict) else {}


def _write_json(path: str, obj: dict) -> None:
    tmp = f"{path}.tmp.{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, indent=1, sort_keys=True)
        f.write("\n")
    os.replace(tmp, path)


# --------------------------------------------------------------------------
# opencode


def question_texts(conn: sqlite3.Connection, message_id: str) -> list[str]:
    """Question texts of `question` tool calls still running on a message."""
    out: list[str] = []
    for row in conn.execute(
        "SELECT data FROM part WHERE message_id = ? ORDER BY id", (message_id,)
    ):
        d = _json(row["data"])
        if d.get("type") != "tool" or d.get("tool") != "question":
            continue
        state = d.get("state") or {}
        if state.get("status") not in ("running", "pending"):
            continue
        qs = (state.get("input") or {}).get("questions") or []
        for q in qs:
            if isinstance(q, dict) and isinstance(q.get("question"), str):
                out.append(q["question"].replace(CLOSE_TAG, "</swarm-message>")[:QUESTION_TEXT_CAP])
    return out


def latest_message(conn: sqlite3.Connection, session_id: str):
    return conn.execute(
        "SELECT id, time_created, time_updated, data FROM message"
        " WHERE session_id = ? ORDER BY time_created DESC, id DESC LIMIT 1",
        (session_id,),
    ).fetchone()


def classify_latest(row, live_ids: set[str], now_s: float) -> str | None:
    """Why this latest message means a turn in flight, or None."""
    if row is None:
        return None
    d = _json(row["data"])
    role = d.get("role")
    if role == "assistant":
        if (d.get("time") or {}).get("completed") is not None:
            return None
        if d.get("error") is not None:
            return None
        inv = (d.get("serve") or {}).get("invocationId")
        if live_ids:
            # Provenance gate: only a turn a serve we are about to restart is
            # running. A row from a serve that died earlier was not cut by
            # this reset, and telling it so would be a lie.
            return "assistant_running" if inv in live_ids else None
        if row["time_updated"] >= (now_s - FALLBACK_UPDATED_WINDOW_S) * 1000:
            return "assistant_running_unstamped"
        return None
    if role == "user":
        if row["time_created"] >= (now_s - USER_LAST_WINDOW_S) * 1000:
            return "user_unanswered"
        return None
    return None


def snapshot_opencode(db: str, live_ids: set[str], now_s: float | None = None) -> dict:
    now_s = time.time() if now_s is None else now_s
    conn = _ro_connect(db)
    try:
        sessions = conn.execute(
            "SELECT id, title, directory FROM session"
            " WHERE parent_id IS NULL AND time_archived IS NULL AND time_updated > ?",
            (int((now_s - SESSION_WINDOW_S) * 1000),),
        ).fetchall()
        hits = []
        for s in sessions:
            m = latest_message(conn, s["id"])
            why = classify_latest(m, live_ids, now_s)
            if why is None:
                continue
            hits.append(
                {
                    "id": s["id"],
                    "title": s["title"],
                    "directory": s["directory"],
                    "message_id": m["id"],
                    "message_created": m["time_created"],
                    "why": why,
                    "questions": question_texts(conn, m["id"]),
                }
            )
    finally:
        conn.close()
    hits.sort(key=lambda h: h["message_created"], reverse=True)
    return {
        "harness": "opencode",
        "taken_at": int(now_s),
        "live_invocation_ids": sorted(live_ids),
        "sessions": hits,
    }


def opencode_still_cut(conn: sqlite3.Connection, entry: dict) -> bool:
    """After the restart: is the snapshotted message still the session's
    latest, and still unfinished? A turn that finished in the gap before the
    restart, or a session someone has already re-prompted, needs no notice."""
    m = latest_message(conn, entry["id"])
    if m is None or m["id"] != entry["message_id"]:
        return False
    d = _json(m["data"])
    if d.get("role") == "assistant":
        return (d.get("time") or {}).get("completed") is None and d.get("error") is None
    return d.get("role") == "user"


# --------------------------------------------------------------------------
# goose


def snapshot_goose(honk: str = "honk", timeout: float = 15, now_s: float | None = None) -> dict:
    now_s = time.time() if now_s is None else now_s
    proc = subprocess.run(
        [honk, "list", "--json"], capture_output=True, text=True, timeout=timeout
    )
    if proc.returncode != 0:
        raise RuntimeError(f"honk list --json exited {proc.returncode}: {proc.stderr.strip()[:300]}")
    rows = json.loads(proc.stdout or "[]")
    if not isinstance(rows, list):
        raise RuntimeError("honk list --json did not return a list")
    hits = []
    for r in rows:
        if not isinstance(r, dict) or r.get("running") is not True:
            continue
        sid = r.get("sessionId")
        if not isinstance(sid, str) or not sid:
            continue
        hits.append(
            {
                "native_id": sid,
                "title": r.get("title"),
                "cwd": r.get("cwd"),
                "pending_requests": r.get("pendingRequests") or 0,
                "last_message_at": r.get("lastMessageAt"),
            }
        )
    hits.sort(key=lambda h: h.get("last_message_at") or "", reverse=True)
    return {"harness": "goose", "taken_at": int(now_s), "sessions": hits}


# --------------------------------------------------------------------------
# notice


def _utc(epoch: int) -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(epoch))


def notice_text(harness: str, taken_at: int, questions: list[str] | None = None,
                pending_requests: int = 0, resumer: bool = False) -> str:
    what = (
        "restarted the opencode serve pool" if harness == "opencode"
        else "restarted goose-serve"
    )
    if resumer:
        first = (
            f"goose-serve restarted (a deploy, a crash, or a restart by hand) at about "
            f"{_utc(taken_at)} while your turn was running. That turn was cut off "
            "mid-way and will not finish on its own; nothing else will prompt you about it."
        )
    else:
        first = (
            f"reset-workspace (the workspace reset, normally the nightly 08:00Z run) {what} "
            f"at about {_utc(taken_at)} while your turn was running. That turn was cut off "
            "mid-way and will not finish on its own; nothing else will prompt you about it."
        )
    lines = [
        first,
        "",
        "Tool calls that were running may or may not have completed, and any whose "
        "result you cannot see did not report back. Before redoing anything with side "
        "effects (push, commit, post, send, merge, deploy), check whether it already "
        "happened.",
    ]
    if questions:
        lines.append("")
        lines.append(
            "You were waiting for the human to answer this question, and the restart "
            "lost it: an answer given now cannot reach you. If you still need it, ask "
            "it again:"
        )
        for q in questions:
            lines.append(f"  - {q.replace(CLOSE_TAG, '</swarm-message>')}")
    elif pending_requests:
        lines.append("")
        lines.append(
            "A permission or input request was pending when the turn was cut; it is "
            "gone. Make the request again if you still need it."
        )
    lines += [
        "",
        "Then carry on with the task you were on. If the turn had in substance "
        "finished, there is nothing to do. "
        + ("goose-turn-resume is not a session: do not reply to it. (workstation-6w7i.16)"
           if resumer else
           "reset-workspace is not a session: do not reply to it. (workstation-dg6)"),
    ]
    return "\n".join(lines)


class Pigeon:
    def __init__(self, url: str, token_file: str | None, timeout: float = 10):
        self.url = url.rstrip("/")
        self.timeout = timeout
        self.token = None
        if token_file:
            try:
                with open(token_file, encoding="utf-8") as f:
                    self.token = f.read().strip() or None
            except OSError:
                self.token = None

    def _req(self, method: str, path: str, body: dict | None = None):
        data = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(self.url + path, data=data, method=method)
        if data is not None:
            req.add_header("Content-Type", "application/json")
        if self.token:
            req.add_header("Authorization", f"Bearer {self.token}")
        with urllib.request.urlopen(req, timeout=self.timeout) as resp:
            return resp.status, json.loads(resp.read() or b"{}")

    def goose_ids(self) -> dict[str, str]:
        """goose native id -> pigeon session id (gse_...)."""
        _, body = self._req("GET", "/sessions")
        out: dict[str, str] = {}
        for s in body.get("sessions") or []:
            native = s.get("backend_session_id")
            sid = s.get("session_id")
            if (
                isinstance(native, str) and isinstance(sid, str)
                and sid.startswith("gse_")
                and str(s.get("backend_kind") or "").startswith("goose")
            ):
                out[native] = sid
        return out

    def origin(self, session_id: str) -> str | None:
        """pigeon's declared origin for an opencode session (e.g. "lgtm"), or
        None when none is recorded (404)."""
        try:
            _, body = self._req(
                "GET", "/session-origin?session_id=" + urllib.parse.quote(session_id)
            )
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return None
            raise
        o = body.get("origin")
        return o if isinstance(o, str) else None

    def send(self, to: str, payload: str, sender: str = SENDER, kind: str = KIND) -> str:
        status, body = self._req(
            "POST", "/swarm/send",
            {"from": sender, "to": to, "kind": kind, "priority": "normal", "payload": payload},
        )
        if status != 202 or not body.get("accepted"):
            raise RuntimeError(f"pigeon answered {status}: {body}")
        return str(body.get("msg_id"))


def is_stall_watch_coordinator(entry: dict) -> bool:
    return STALL_WATCH_COORD_DIR in str(entry.get("cwd") or "") or str(
        entry.get("title") or ""
    ).startswith(STALL_WATCH_TITLE_PREFIX)


def plan_notices(snapshots: list[dict], db: str | None, goose_ids: dict[str, str] | None,
                 origin_of=None):
    """Yield (to, harness, label, payload) for every snapshot entry that still
    needs a notice, and (None, harness, label, reason) for each skip."""
    conn = None
    try:
        for snap in snapshots:
            harness = snap.get("harness")
            taken_at = int(snap.get("taken_at") or time.time())
            for e in snap.get("sessions") or []:
                if harness == "opencode":
                    label = f"{e['id']} ({e.get('title') or ''})"
                    if db:
                        if conn is None:
                            conn = _ro_connect(db)
                        if not opencode_still_cut(conn, e):
                            yield None, harness, label, "turn finished or session re-prompted before the notice"
                            continue
                    origin = None
                    if origin_of is not None:
                        try:
                            origin = origin_of(e["id"])
                        except Exception as err:  # noqa: BLE001 -- unknown origin: notify
                            log(f"WARNING: could not read pigeon session-origin for {e['id']} ({err}); notifying anyway")
                    if origin in SELF_RETRYING_ORIGINS:
                        yield None, harness, label, f"owned by {origin}, which recovers its own cut runs"
                        continue
                    yield e["id"], harness, label, notice_text(
                        "opencode", taken_at, questions=e.get("questions") or []
                    )
                elif harness == "goose":
                    native = e["native_id"]
                    label = f"{native} ({e.get('title') or ''})"
                    if is_stall_watch_coordinator(e):
                        yield None, harness, label, "stall-watch coordinator; stall-watch retries its own cut runs"
                        continue
                    to = (goose_ids or {}).get(native)
                    if not to:
                        yield None, harness, label, "pigeon does not know this goose session; cannot message it"
                        continue
                    yield to, harness, label, notice_text(
                        "goose", taken_at, pending_requests=int(e.get("pending_requests") or 0)
                    )
                else:
                    yield None, str(harness), "?", "unknown harness in snapshot"
    finally:
        if conn is not None:
            conn.close()


def notify(snapshots: list[dict], db: str | None, pigeon: Pigeon, max_n: int,
           dry_run: bool = False, resume_state: str | None = None) -> int:
    failed = 0
    goose_ids: dict[str, str] | None = None
    if any(s.get("harness") == "goose" and s.get("sessions") for s in snapshots):
        try:
            goose_ids = pigeon.goose_ids()
        except Exception as e:  # noqa: BLE001 -- any failure: report, keep going
            log(f"WARNING: could not read pigeon /sessions ({e}); goose sessions cannot be messaged")
            failed += 1
            goose_ids = {}
    sent = skipped = 0
    seen: set[str] = set()
    for to, harness, label, payload in plan_notices(snapshots, db, goose_ids, pigeon.origin):
        if to is None:
            skipped += 1
            log(f"skip {harness} {label}: {payload}")
            continue
        if to in seen:
            continue
        seen.add(to)
        if sent >= max_n:
            skipped += 1
            log(f"skip {harness} {label}: over the cap of {max_n} notices")
            continue
        if dry_run:
            sent += 1
            log(f"would notify {harness} {label} -> {to}")
            continue
        try:
            msg_id = pigeon.send(to, payload)
            sent += 1
            log(f"notified {harness} {label} -> {to} ({msg_id})")
            if harness == "goose" and resume_state:
                # So goose-turn-resume does not tell the same cut turn twice.
                try:
                    st = load_resume_state(resume_state)
                    record_sent(st, label.split(" ", 1)[0], int(time.time()))
                    save_resume_state(resume_state, st)
                except Exception as e:  # noqa: BLE001 -- worst case: a 2nd notice
                    log(f"WARNING: could not record the notice in {resume_state}: {e}")
        except Exception as e:  # noqa: BLE001
            failed += 1
            log(f"WARNING: notice to {harness} {label} -> {to} failed: {e}")
    log(f"{'dry run: ' if dry_run else ''}{sent} notified, {skipped} skipped, {failed} failed")
    return 1 if failed else 0


# --------------------------------------------------------------------------
# resume-goose (workstation-6w7i.16)


def load_resume_state(path: str) -> dict:
    try:
        with open(path, encoding="utf-8") as f:
            st = json.load(f)
    except (OSError, ValueError):
        st = {}
    if not isinstance(st, dict):
        st = {}
    st.setdefault("sent", {})      # native id -> [epoch, ...] notices sent
    st.setdefault("decided", {})   # native id -> lastError.at already judged
    return st


def save_resume_state(path: str, st: dict) -> None:
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    _write_json(path, st)


def record_sent(st: dict, native: str, at: int) -> None:
    st.setdefault("sent", {}).setdefault(native, []).append(int(at))


def prune_resume_state(st: dict, now_s: int) -> None:
    keep = now_s - RESUME_STATE_KEEP_S
    for sid in list(st["sent"]):
        st["sent"][sid] = [t for t in st["sent"][sid] if t >= keep]
        if not st["sent"][sid]:
            del st["sent"][sid]
    for sid in list(st["decided"]):
        if int(st["decided"][sid]) < keep:
            del st["decided"][sid]


def honk_rows(honk: str, timeout: float = 30) -> list:
    proc = subprocess.run([honk, "list", "--json"], capture_output=True, text=True,
                          timeout=timeout)
    if proc.returncode != 0:
        raise RuntimeError(f"honk list --json exited {proc.returncode}: {proc.stderr.strip()[:300]}")
    rows = json.loads(proc.stdout or "[]")
    if not isinstance(rows, list):
        raise RuntimeError("honk list --json did not return a list")
    return rows


def cut_turns(rows: list) -> list[dict]:
    """Sessions honkd says a goose restart cut, and that have not run since."""
    out = []
    for r in rows:
        if not isinstance(r, dict) or r.get("running") is True:
            continue
        err = r.get("lastError")
        sid = r.get("sessionId")
        if not isinstance(err, dict) or not isinstance(sid, str) or not sid:
            continue
        if err.get("kind") != CUT_KIND or err.get("message") != CUT_MESSAGE:
            continue
        try:
            at = int(err.get("at"))
        except (TypeError, ValueError):
            continue
        out.append({"native_id": sid, "title": r.get("title"), "cwd": r.get("cwd"), "at": at})
    out.sort(key=lambda e: e["at"])
    return out


def reset_lock_held(path: str) -> bool:
    """True while reset-workspace holds its lock: it restarts goose-serve and
    sends its own notices. Probe the flock, not the file (never unlinked)."""
    if not os.path.exists(path):
        return False
    import fcntl
    try:
        with open(path) as f:
            fcntl.flock(f, fcntl.LOCK_SH | fcntl.LOCK_NB)
            fcntl.flock(f, fcntl.LOCK_UN)
        return False
    except OSError:
        return True


def resume_goose(rows: list, pigeon: Pigeon, state_path: str, max_n: int,
                 dry_run: bool = False, now_s: int | None = None) -> int:
    now_s = int(time.time()) if now_s is None else int(now_s)
    st = load_resume_state(state_path)
    prune_resume_state(st, now_s)
    todo = []
    for e in cut_turns(rows):
        sid, at = e["native_id"], e["at"]
        label = f"{sid} ({e.get('title') or ''})"
        if any(t >= at for t in st["sent"].get(sid, [])):
            continue  # already told about this cut (by us or by reset-workspace)
        if st["decided"].get(sid) == at:
            continue  # judged and skipped before; stay quiet
        if is_stall_watch_coordinator(e):
            log(f"skip goose {label}: stall-watch coordinator; stall-watch retries its own cut runs")
            st["decided"][sid] = at
            continue
        recent = [t for t in st["sent"].get(sid, []) if t >= now_s - RESUME_CAP_WINDOW_S]
        if len(recent) >= RESUME_CAP:
            log(f"skip goose {label}: already resumed {len(recent)} times in "
                f"{RESUME_CAP_WINDOW_S // 3600}h; not looping (needs a human)")
            st["decided"][sid] = at
            continue
        todo.append((e, label))
    failed = sent = 0
    if todo:
        try:
            goose_ids = pigeon.goose_ids()
        except Exception as err:  # noqa: BLE001 -- retry next run
            log(f"WARNING: could not read pigeon /sessions ({err}); retrying next run")
            goose_ids = None
            failed += 1
        for e, label in todo if goose_ids is not None else []:
            sid, at = e["native_id"], e["at"]
            to = goose_ids.get(sid)
            if not to:
                log(f"skip goose {label}: pigeon does not know this goose session; cannot message it")
                st["decided"][sid] = at
                continue
            if sent >= max_n:
                log(f"skip goose {label}: over the cap of {max_n} notices this run; next run")
                continue
            if dry_run:
                sent += 1
                log(f"would resume goose {label} -> {to}")
                continue
            try:
                msg_id = pigeon.send(to, notice_text("goose", at, resumer=True),
                                     sender=RESUME_SENDER, kind=RESUME_KIND)
                record_sent(st, sid, now_s)
                sent += 1
                log(f"resumed goose {label} -> {to} ({msg_id})")
            except Exception as err:  # noqa: BLE001 -- not recorded: retried next run
                failed += 1
                log(f"WARNING: notice to goose {label} -> {to} failed: {err}")
    if not dry_run:
        save_resume_state(state_path, st)
    if todo or failed:
        log(f"{'dry run: ' if dry_run else ''}{sent} resumed, {failed} failed")
    return 1 if failed else 0


# --------------------------------------------------------------------------
# CLI


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="turn-cut-notice", description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)

    so = sub.add_parser("snapshot-opencode")
    so.add_argument("--db", required=True)
    so.add_argument("--live-invocation-ids", default="",
                    help="comma-separated systemd InvocationIDs of the pool serves about to restart")
    so.add_argument("--out", required=True)

    sg = sub.add_parser("snapshot-goose")
    sg.add_argument("--honk", default=os.environ.get("TURN_CUT_HONK", "honk"))
    sg.add_argument("--timeout", type=float, default=15)
    sg.add_argument("--out", required=True)

    nt = sub.add_parser("notify")
    nt.add_argument("--snapshot", action="append", default=[], required=True)
    nt.add_argument("--db", help="opencode.db, to re-check opencode entries after the restart")
    nt.add_argument("--pigeon-url", default=os.environ.get("PIGEON_DAEMON_URL", DEFAULT_PIGEON_URL))
    nt.add_argument("--pigeon-token-file", default=DEFAULT_TOKEN_FILE)
    nt.add_argument("--max", type=int, default=DEFAULT_MAX)
    nt.add_argument("--dry-run", action="store_true")
    nt.add_argument("--resume-state", default=DEFAULT_RESUME_STATE,
                    help="goose-turn-resume's state file; goose notices are recorded there")

    rg = sub.add_parser("resume-goose")
    rg.add_argument("--honk", default=os.environ.get("TURN_CUT_HONK", "honk"))
    rg.add_argument("--resume-state", default=DEFAULT_RESUME_STATE)
    rg.add_argument("--reset-lock", default=DEFAULT_RESET_LOCK)
    rg.add_argument("--pigeon-url", default=os.environ.get("PIGEON_DAEMON_URL", DEFAULT_PIGEON_URL))
    rg.add_argument("--pigeon-token-file", default=DEFAULT_TOKEN_FILE)
    rg.add_argument("--max", type=int, default=DEFAULT_MAX)
    rg.add_argument("--dry-run", action="store_true")

    a = ap.parse_args(argv)
    try:
        if a.cmd == "snapshot-opencode":
            ids = {i.strip() for i in a.live_invocation_ids.split(",") if i.strip()}
            if not ids:
                log("no live pool InvocationID given; falling back to rows updated in the last 30 min")
            snap = snapshot_opencode(a.db, ids)
            _write_json(a.out, snap)
            log(f"opencode: {len(snap['sessions'])} turn(s) in flight")
            return 0
        if a.cmd == "snapshot-goose":
            snap = snapshot_goose(a.honk, a.timeout)
            _write_json(a.out, snap)
            log(f"goose: {len(snap['sessions'])} turn(s) in flight")
            return 0
        if a.cmd == "notify":
            snaps = []
            for p in a.snapshot:
                try:
                    with open(p, encoding="utf-8") as f:
                        snaps.append(json.load(f))
                except (OSError, ValueError) as e:
                    log(f"WARNING: unreadable snapshot {p}: {e}")
            pigeon = Pigeon(a.pigeon_url, a.pigeon_token_file)
            db = a.db if a.db and os.path.exists(a.db) else None
            rc = notify(snaps, db, pigeon, a.max, a.dry_run, a.resume_state)
            return rc if len(snaps) == len(a.snapshot) else 1
        if a.cmd == "resume-goose":
            if reset_lock_held(a.reset_lock):
                log("reset-workspace in progress; it tells its own cut turns. Next run.")
                return 0
            rows = honk_rows(a.honk)
            pigeon = Pigeon(a.pigeon_url, a.pigeon_token_file)
            return resume_goose(rows, pigeon, a.resume_state, a.max, a.dry_run)
    except Exception as e:  # noqa: BLE001 -- a reset must never die of this tool
        log(f"WARNING: {a.cmd} failed: {type(e).__name__}: {e}")
        return 1
    return 2


if __name__ == "__main__":
    sys.exit(main())
