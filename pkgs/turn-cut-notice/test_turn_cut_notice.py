#!/usr/bin/env python3
"""Hermetic tests for turn-cut-notice: temp sqlite fixtures shaped like
opencode.db, a fake `honk` on disk, and a fake pigeon (no sockets)."""

import io
import json
import os
import sqlite3
import stat
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import turn_cut_notice as tcn  # noqa: E402

NOW = 1_795_500_000  # seconds
LIVE = "inv_live"
DEAD = "inv_dead"


def ms(s):
    return int(s * 1000)


class Fixture:
    def __init__(self, path):
        self.path = path
        c = sqlite3.connect(path)
        c.executescript(
            """
            CREATE TABLE session (id TEXT PRIMARY KEY, parent_id TEXT, title TEXT NOT NULL,
              directory TEXT NOT NULL, time_updated INTEGER NOT NULL, time_archived INTEGER);
            CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL,
              time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL);
            CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT NOT NULL, session_id TEXT NOT NULL,
              time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL);
            """
        )
        c.commit()
        c.close()
        self.n = 0

    def _c(self):
        return sqlite3.connect(self.path)

    def session(self, sid, *, parent=None, updated=NOW - 60, archived=None, title=None):
        with self._c() as c:
            c.execute(
                "INSERT INTO session VALUES (?,?,?,?,?,?)",
                (sid, parent, title or sid, f"/w/{sid}", ms(updated), archived),
            )

    def message(self, sid, *, role="assistant", created=NOW - 30, updated=None,
                completed=False, error=None, inv=LIVE, mid=None):
        self.n += 1
        mid = mid or f"msg_{self.n:04d}"
        d = {"role": role, "time": {"created": ms(created)}}
        if completed:
            d["time"]["completed"] = ms(created + 5)
        if error is not None:
            d["error"] = error
        if inv is not None and role == "assistant":
            d["serve"] = {"invocationId": inv}
        with self._c() as c:
            c.execute(
                "INSERT INTO message VALUES (?,?,?,?,?)",
                (mid, sid, ms(created), ms(updated if updated is not None else created), json.dumps(d)),
            )
        return mid

    def question(self, sid, mid, texts, status="running"):
        self.n += 1
        d = {"type": "tool", "tool": "question",
             "state": {"status": status, "input": {"questions": [{"question": t} for t in texts]}}}
        with self._c() as c:
            c.execute("INSERT INTO part VALUES (?,?,?,?,?,?)",
                      (f"prt_{self.n:04d}", mid, sid, ms(NOW), ms(NOW), json.dumps(d)))

    def part(self, sid, mid, data):
        self.n += 1
        with self._c() as c:
            c.execute("INSERT INTO part VALUES (?,?,?,?,?,?)",
                      (f"prt_{self.n:04d}", mid, sid, ms(NOW), ms(NOW), json.dumps(data)))

    def complete(self, mid):
        with self._c() as c:
            row = c.execute("SELECT data FROM message WHERE id=?", (mid,)).fetchone()
            d = json.loads(row[0])
            d["time"]["completed"] = ms(NOW + 10)
            c.execute("UPDATE message SET data=? WHERE id=?", (json.dumps(d), mid))


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.db = os.path.join(self.tmp.name, "opencode.db")
        self.fx = Fixture(self.db)

    def tearDown(self):
        self.tmp.cleanup()

    def snap(self, live=frozenset({LIVE})):
        return tcn.snapshot_opencode(self.db, set(live), now_s=NOW)

    def ids(self, snap):
        return [s["id"] for s in snap["sessions"]]


class SnapshotOpencode(Base):
    def test_running_assistant_on_live_serve_is_cut(self):
        self.fx.session("ses_a")
        self.fx.message("ses_a")
        s = self.snap()
        self.assertEqual(self.ids(s), ["ses_a"])
        self.assertEqual(s["sessions"][0]["why"], "assistant_running")
        self.assertEqual(s["harness"], "opencode")
        self.assertEqual(s["taken_at"], NOW)

    def test_row_from_a_serve_that_died_earlier_is_not_ours(self):
        self.fx.session("ses_a")
        self.fx.message("ses_a", inv=DEAD)
        self.assertEqual(self.ids(self.snap()), [])

    def test_unstamped_row_is_ignored_when_live_ids_are_known(self):
        self.fx.session("ses_a")
        self.fx.message("ses_a", inv=None)
        self.assertEqual(self.ids(self.snap()), [])

    def test_completed_turn_is_not_cut(self):
        self.fx.session("ses_a")
        self.fx.message("ses_a", completed=True)
        self.assertEqual(self.ids(self.snap()), [])

    def test_errored_turn_is_not_cut(self):
        self.fx.session("ses_a")
        self.fx.message("ses_a", error={"name": "MessageAbortedError"})
        self.assertEqual(self.ids(self.snap()), [])

    def test_subagent_sessions_are_skipped(self):
        self.fx.session("ses_parent")
        self.fx.session("ses_child", parent="ses_parent")
        self.fx.message("ses_child")
        self.assertEqual(self.ids(self.snap()), [])

    def test_archived_sessions_are_skipped(self):
        self.fx.session("ses_a", archived=ms(NOW - 10))
        self.fx.message("ses_a")
        self.assertEqual(self.ids(self.snap()), [])

    def test_sessions_idle_for_a_day_are_not_scanned(self):
        self.fx.session("ses_a", updated=NOW - 25 * 3600)
        self.fx.message("ses_a")
        self.assertEqual(self.ids(self.snap()), [])

    def test_only_the_latest_message_counts(self):
        self.fx.session("ses_a")
        self.fx.message("ses_a", created=NOW - 600)            # old orphan
        self.fx.message("ses_a", created=NOW - 60, completed=True)
        self.assertEqual(self.ids(self.snap()), [])

    def test_fresh_unanswered_user_message_is_cut(self):
        self.fx.session("ses_a")
        self.fx.message("ses_a", role="user", created=NOW - 120)
        s = self.snap()
        self.assertEqual(self.ids(s), ["ses_a"])
        self.assertEqual(s["sessions"][0]["why"], "user_unanswered")

    def test_stale_unanswered_user_message_is_not(self):
        self.fx.session("ses_a")
        self.fx.message("ses_a", role="user", created=NOW - 3600)
        self.assertEqual(self.ids(self.snap()), [])

    def test_fallback_without_live_ids_uses_recent_update(self):
        self.fx.session("ses_new")
        self.fx.message("ses_new", inv=None, created=NOW - 7200, updated=NOW - 60)
        self.fx.session("ses_old")
        self.fx.message("ses_old", inv=DEAD, created=NOW - 7200, updated=NOW - 3600)
        s = self.snap(live=frozenset())
        self.assertEqual(self.ids(s), ["ses_new"])
        self.assertEqual(s["sessions"][0]["why"], "assistant_running_unstamped")

    def test_running_question_text_is_captured(self):
        self.fx.session("ses_a")
        mid = self.fx.message("ses_a")
        self.fx.question("ses_a", mid, ["Ship it via PR?", "Which tag?"])
        self.fx.question("ses_a", mid, ["already answered"], status="completed")
        self.fx.part("ses_a", mid, {"type": "tool", "tool": "bash", "state": {"status": "running"}})
        self.fx.part("ses_a", mid, {"type": "text", "text": "hi"})
        s = self.snap()
        self.assertEqual(s["sessions"][0]["questions"], ["Ship it via PR?", "Which tag?"])

    def test_question_text_is_capped(self):
        self.fx.session("ses_a")
        mid = self.fx.message("ses_a")
        self.fx.question("ses_a", mid, ["x" * 5000])
        q = self.snap()["sessions"][0]["questions"][0]
        self.assertEqual(len(q), tcn.QUESTION_TEXT_CAP)

    def test_most_recent_turn_first(self):
        self.fx.session("ses_old")
        self.fx.message("ses_old", created=NOW - 900)
        self.fx.session("ses_new")
        self.fx.message("ses_new", created=NOW - 10)
        self.assertEqual(self.ids(self.snap()), ["ses_new", "ses_old"])

    def test_snapshot_never_writes_the_db(self):
        self.fx.session("ses_a")
        self.fx.message("ses_a")
        os.chmod(self.db, stat.S_IRUSR)
        try:
            self.assertEqual(self.ids(self.snap()), ["ses_a"])
        finally:
            os.chmod(self.db, stat.S_IRUSR | stat.S_IWUSR)


class FakePigeon(tcn.Pigeon):
    def __init__(self, sessions=None, fail_sessions=False, fail_to=(), origins=None,
                 fail_origin=False):
        super().__init__("http://pigeon.invalid", None)
        self.sessions = sessions or []
        self.origins = origins or {}
        self.fail_origin = fail_origin
        self.fail_sessions = fail_sessions
        self.fail_to = set(fail_to)
        self.sent = []

    def _req(self, method, path, body=None):
        if path == "/sessions":
            if self.fail_sessions:
                raise OSError("connection refused")
            return 200, {"ok": True, "sessions": self.sessions}
        if path.startswith("/session-origin?session_id="):
            if self.fail_origin:
                raise OSError("connection refused")
            sid = path.split("=", 1)[1]
            if sid not in self.origins:
                raise tcn.urllib.error.HTTPError(path, 404, "nf", {}, None)
            return 200, {"session_id": sid, "origin": self.origins[sid]}
        if path == "/swarm/send":
            if body["to"] in self.fail_to:
                return 409, {"error": "nope"}
            self.sent.append(body)
            return 202, {"accepted": True, "msg_id": f"msg_{len(self.sent)}"}
        raise AssertionError(path)


def goose_row(native, gse, kind="goose-acp"):
    return {"session_id": gse, "backend_session_id": native, "backend_kind": kind}


class Notify(Base):
    def oc_snap(self):
        return self.snap()

    def test_opencode_notice_sent_through_pigeon(self):
        self.fx.session("ses_a")
        mid = self.fx.message("ses_a")
        self.fx.question("ses_a", mid, ["Merge now?"])
        p = FakePigeon()
        with mock.patch("sys.stderr", io.StringIO()):
            rc = tcn.notify([self.oc_snap()], self.db, p, 30)
        self.assertEqual(rc, 0)
        self.assertEqual(len(p.sent), 1)
        b = p.sent[0]
        self.assertEqual((b["from"], b["to"], b["kind"]), ("reset-workspace", "ses_a", "reset.turn_cut"))
        self.assertIn("Merge now?", b["payload"])
        self.assertIn("opencode serve pool", b["payload"])
        self.assertNotIn("</swarm_message>", b["payload"])

    def test_turn_that_finished_before_the_restart_is_skipped(self):
        self.fx.session("ses_a")
        mid = self.fx.message("ses_a")
        snap = self.oc_snap()
        self.fx.complete(mid)
        p = FakePigeon()
        with mock.patch("sys.stderr", io.StringIO()):
            self.assertEqual(tcn.notify([snap], self.db, p, 30), 0)
        self.assertEqual(p.sent, [])

    def test_session_already_reprompted_is_skipped(self):
        self.fx.session("ses_a")
        self.fx.message("ses_a")
        snap = self.oc_snap()
        self.fx.message("ses_a", role="user", created=NOW + 5)
        p = FakePigeon()
        with mock.patch("sys.stderr", io.StringIO()):
            tcn.notify([snap], self.db, p, 30)
        self.assertEqual(p.sent, [])

    def test_without_db_no_recheck(self):
        self.fx.session("ses_a")
        mid = self.fx.message("ses_a")
        snap = self.oc_snap()
        self.fx.complete(mid)
        p = FakePigeon()
        with mock.patch("sys.stderr", io.StringIO()):
            tcn.notify([snap], None, p, 30)
        self.assertEqual(len(p.sent), 1)

    def test_goose_session_mapped_to_pigeon_id(self):
        snap = {"harness": "goose", "taken_at": NOW,
                "sessions": [{"native_id": "20261124_2", "title": "w", "pending_requests": 1}]}
        p = FakePigeon(sessions=[goose_row("20261124_2", "gse_x"),
                                 {"session_id": "ses_y", "backend_session_id": "20261124_2",
                                  "backend_kind": "opencode-plugin-direct"}])
        with mock.patch("sys.stderr", io.StringIO()):
            self.assertEqual(tcn.notify([snap], None, p, 30), 0)
        self.assertEqual([b["to"] for b in p.sent], ["gse_x"])
        self.assertIn("goose-serve", p.sent[0]["payload"])
        self.assertIn("permission or input request", p.sent[0]["payload"])

    def test_unknown_goose_session_is_skipped_not_failed(self):
        snap = {"harness": "goose", "taken_at": NOW, "sessions": [{"native_id": "20261124_9"}]}
        p = FakePigeon(sessions=[])
        err = io.StringIO()
        with mock.patch("sys.stderr", err):
            self.assertEqual(tcn.notify([snap], None, p, 30), 0)
        self.assertEqual(p.sent, [])
        self.assertIn("pigeon does not know", err.getvalue())

    def test_pigeon_sessions_failure_still_sends_opencode(self):
        self.fx.session("ses_a")
        self.fx.message("ses_a")
        gsnap = {"harness": "goose", "taken_at": NOW, "sessions": [{"native_id": "g1"}]}
        p = FakePigeon(fail_sessions=True)
        with mock.patch("sys.stderr", io.StringIO()):
            rc = tcn.notify([self.oc_snap(), gsnap], self.db, p, 30)
        self.assertEqual(rc, 1)
        self.assertEqual([b["to"] for b in p.sent], ["ses_a"])

    def test_send_failure_is_reported_and_others_still_go(self):
        for sid in ("ses_a", "ses_b"):
            self.fx.session(sid)
            self.fx.message(sid)
        p = FakePigeon(fail_to={"ses_a"})
        with mock.patch("sys.stderr", io.StringIO()):
            rc = tcn.notify([self.oc_snap()], self.db, p, 30)
        self.assertEqual(rc, 1)
        self.assertEqual([b["to"] for b in p.sent], ["ses_b"])

    def test_cap(self):
        for i in range(5):
            self.fx.session(f"ses_{i}")
            self.fx.message(f"ses_{i}", created=NOW - 100 + i)
        p = FakePigeon()
        err = io.StringIO()
        with mock.patch("sys.stderr", err):
            self.assertEqual(tcn.notify([self.oc_snap()], self.db, p, 2), 0)
        self.assertEqual([b["to"] for b in p.sent], ["ses_4", "ses_3"])
        self.assertEqual(err.getvalue().count("over the cap"), 3)

    def test_same_target_twice_gets_one_notice(self):
        self.fx.session("ses_a")
        self.fx.message("ses_a")
        s = self.oc_snap()
        p = FakePigeon()
        with mock.patch("sys.stderr", io.StringIO()):
            tcn.notify([s, s], self.db, p, 30)
        self.assertEqual(len(p.sent), 1)

    def test_lgtm_review_sessions_are_left_to_lgtm(self):
        for sid in ("ses_review", "ses_worker"):
            self.fx.session(sid)
            self.fx.message(sid)
        p = FakePigeon(origins={"ses_review": "lgtm", "ses_worker": "human"})
        err = io.StringIO()
        with mock.patch("sys.stderr", err):
            self.assertEqual(tcn.notify([self.oc_snap()], self.db, p, 30), 0)
        self.assertEqual([b["to"] for b in p.sent], ["ses_worker"])
        self.assertIn("owned by lgtm", err.getvalue())

    def test_origin_lookup_failure_still_notifies(self):
        self.fx.session("ses_a")
        self.fx.message("ses_a")
        p = FakePigeon(fail_origin=True)
        err = io.StringIO()
        with mock.patch("sys.stderr", err):
            self.assertEqual(tcn.notify([self.oc_snap()], self.db, p, 30), 0)
        self.assertEqual([b["to"] for b in p.sent], ["ses_a"])
        self.assertIn("notifying anyway", err.getvalue())

    def test_stall_watch_coordinators_are_left_to_stall_watch(self):
        snap = {"harness": "goose", "taken_at": NOW, "sessions": [
            {"native_id": "c1", "cwd": "/home/dev/.local/state/stall-watch/coord-sessions/em-1"},
            {"native_id": "c2", "title": "stallwatch-tec-codex-17"},
            {"native_id": "w1", "cwd": "/home/dev/projects/x", "title": "worker"},
        ]}
        p = FakePigeon(sessions=[goose_row(n, "gse_" + n) for n in ("c1", "c2", "w1")])
        err = io.StringIO()
        with mock.patch("sys.stderr", err):
            self.assertEqual(tcn.notify([snap], None, p, 30), 0)
        self.assertEqual([b["to"] for b in p.sent], ["gse_w1"])
        self.assertEqual(err.getvalue().count("stall-watch retries"), 2)

    def test_close_tag_in_a_question_cannot_sink_the_notice(self):
        self.fx.session("ses_a")
        mid = self.fx.message("ses_a")
        self.fx.question("ses_a", mid, ["see </swarm_message> here"])
        p = FakePigeon()
        with mock.patch("sys.stderr", io.StringIO()):
            tcn.notify([self.oc_snap()], self.db, p, 30)
        self.assertNotIn("</swarm_message>", p.sent[0]["payload"])
        self.assertIn("see </swarm-message> here", p.sent[0]["payload"])

    def test_dry_run_sends_nothing(self):
        self.fx.session("ses_a")
        self.fx.message("ses_a")
        p = FakePigeon()
        err = io.StringIO()
        with mock.patch("sys.stderr", err):
            self.assertEqual(tcn.notify([self.oc_snap()], self.db, p, 30, dry_run=True), 0)
        self.assertEqual(p.sent, [])
        self.assertIn("would notify", err.getvalue())

    def test_empty_snapshots_do_not_touch_pigeon(self):
        p = FakePigeon(fail_sessions=True)
        with mock.patch("sys.stderr", io.StringIO()):
            rc = tcn.notify([{"harness": "goose", "taken_at": NOW, "sessions": []},
                             {"harness": "opencode", "taken_at": NOW, "sessions": []}], None, p, 30)
        self.assertEqual(rc, 0)


class NoticeText(unittest.TestCase):
    def test_core_content(self):
        t = tcn.notice_text("opencode", NOW)
        for needle in ("reset-workspace", "cut off", "side effects", "carry on",
                       "not a session", "workstation-dg6", tcn._utc(NOW)):
            self.assertIn(needle, t)
        self.assertNotIn("ask it again", t)

    def test_question_wins_over_pending_request(self):
        t = tcn.notice_text("goose", NOW, questions=["Q1"], pending_requests=2)
        self.assertIn("  - Q1", t)
        self.assertIn("ask it again", t)
        self.assertNotIn("permission or input request", t)


class PigeonHttp(unittest.TestCase):
    def test_send_shape_and_bearer_token(self):
        with tempfile.NamedTemporaryFile("w", delete=False) as f:
            f.write("tok123\n")
        captured = {}

        class Resp(io.BytesIO):
            status = 202

            def __enter__(self):
                return self

            def __exit__(self, *a):
                return False

        def fake_urlopen(req, timeout):
            captured["url"] = req.full_url
            captured["auth"] = req.get_header("Authorization")
            captured["body"] = json.loads(req.data)
            captured["timeout"] = timeout
            return Resp(b'{"accepted": true, "msg_id": "msg_1"}')

        try:
            p = tcn.Pigeon("http://127.0.0.1:4731/", f.name)
            with mock.patch("urllib.request.urlopen", fake_urlopen):
                self.assertEqual(p.send("gse_x", "hello"), "msg_1")
        finally:
            os.unlink(f.name)
        self.assertEqual(captured["url"], "http://127.0.0.1:4731/swarm/send")
        self.assertEqual(captured["auth"], "Bearer tok123")
        self.assertEqual(captured["body"]["from"], "reset-workspace")
        self.assertEqual(captured["body"]["payload"], "hello")
        self.assertLessEqual(captured["timeout"], 10)

    def test_origin_404_is_none(self):
        def fake_urlopen(req, timeout):
            raise tcn.urllib.error.HTTPError(req.full_url, 404, "nf", {}, None)
        p = tcn.Pigeon("http://x", None)
        with mock.patch("urllib.request.urlopen", fake_urlopen):
            self.assertIsNone(p.origin("ses_a"))

    def test_missing_token_file_sends_no_auth(self):
        p = tcn.Pigeon("http://x", "/nonexistent/token")
        self.assertIsNone(p.token)


class GooseSnapshot(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()

    def tearDown(self):
        self.tmp.cleanup()

    def fake_honk(self, body, rc=0):
        path = os.path.join(self.tmp.name, "honk")
        with open(path, "w") as f:
            f.write("#!/bin/sh\n")
            f.write('[ "$1 $2" = "list --json" ] || exit 9\n')
            f.write(f"cat <<'EOF'\n{body}\nEOF\nexit {rc}\n")
        os.chmod(path, 0o755)
        return path

    def test_running_sessions_only(self):
        rows = [
            {"sessionId": "20261124_2", "running": True, "title": "w", "cwd": "/w",
             "pendingRequests": 0, "lastMessageAt": "2026-11-24T09:00:00Z"},
            {"sessionId": "20261124_3", "running": True, "lastMessageAt": "2026-11-24T09:05:00Z"},
            {"sessionId": "20261124_1", "running": False},
            {"running": True},
        ]
        s = tcn.snapshot_goose(self.fake_honk(json.dumps(rows)), now_s=NOW)
        self.assertEqual([e["native_id"] for e in s["sessions"]], ["20261124_3", "20261124_2"])
        self.assertEqual(s["harness"], "goose")

    def test_honk_failure_raises(self):
        with self.assertRaises(RuntimeError):
            tcn.snapshot_goose(self.fake_honk("boom", rc=3), now_s=NOW)

    def test_cli_failure_is_exit_1_not_a_crash(self):
        out = os.path.join(self.tmp.name, "g.json")
        with mock.patch("sys.stderr", io.StringIO()) as err:
            rc = tcn.main(["snapshot-goose", "--honk", "/nonexistent/honk", "--out", out])
        self.assertEqual(rc, 1)
        self.assertIn("WARNING", err.getvalue())
        self.assertFalse(os.path.exists(out))


def cut_row(sid, at, title="w", cwd="/w", running=False, message=None, kind="interrupted"):
    return {"sessionId": sid, "title": title, "cwd": cwd, "running": running,
            "lastError": {"kind": kind, "message": message or tcn.CUT_MESSAGE, "at": at}}


def plain_row(sid, title="w", cwd="/w", running=False):
    return {"sessionId": sid, "title": title, "cwd": cwd, "running": running, "lastError": None}


def journal_line(sid, at, cursor, message=None, kind="interrupted"):
    fields = {"message": f"Session {sid}: turn failed (kind={kind} ...): x", "sid": sid,
              "kind": kind, "error_message": message or tcn.CUT_MESSAGE}
    return json.dumps({"__CURSOR": cursor, "__REALTIME_TIMESTAMP": str(at * 1_000_000),
                       "MESSAGE": json.dumps({"level": "WARN", "fields": fields})})


class ResumeGoose(unittest.TestCase):
    """workstation-6w7i.16: resume turns cut by ANY goose-serve restart."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.state = os.path.join(self.tmp.name, "gtr", "state.json")

    def tearDown(self):
        self.tmp.cleanup()

    def run_(self, rows, pigeon, now=NOW + 60, max_n=30, dry=False, cuts=None, alert=None):
        if cuts is None:
            cuts = tcn.cut_turns_from_list(rows)
        err = io.StringIO()
        with mock.patch("sys.stderr", err):
            rc = tcn.resume_goose(cuts, rows, pigeon, self.state, max_n, dry, now_s=now,
                                  alert_cmd=alert)
        return rc, err.getvalue()

    def test_cut_turn_gets_a_resume_notice(self):
        p = FakePigeon(sessions=[goose_row("g1", "gse_1")])
        rc, _ = self.run_([cut_row("g1", NOW)], p)
        self.assertEqual(rc, 0)
        self.assertEqual(len(p.sent), 1)
        b = p.sent[0]
        self.assertEqual((b["from"], b["to"], b["kind"]), ("goose-turn-resume", "gse_1", "goose.turn_cut"))
        self.assertIn("goose-serve restarted", b["payload"])
        self.assertIn("carry on with the task", b["payload"])
        self.assertIn("state of the world", b["payload"])
        self.assertNotIn("reset-workspace (the workspace reset", b["payload"])

    def test_only_once_per_cut(self):
        p = FakePigeon(sessions=[goose_row("g1", "gse_1")])
        self.run_([cut_row("g1", NOW)], p)
        self.run_([cut_row("g1", NOW)], p, now=NOW + 120)
        self.assertEqual(len(p.sent), 1)

    def test_a_later_cut_of_the_same_session_is_told_again(self):
        p = FakePigeon(sessions=[goose_row("g1", "gse_1")])
        self.run_([cut_row("g1", NOW)], p)
        self.run_([cut_row("g1", NOW + 600)], p, now=NOW + 660)
        self.assertEqual(len(p.sent), 2)

    def test_running_again_is_still_resumed(self):
        # pigeon starts a queued message within a second of the cut; the earlier
        # task was still never resumed.
        p = FakePigeon(sessions=[goose_row("g1", "gse_1")])
        self.run_([cut_row("g1", NOW, running=True)], p)
        self.assertEqual(len(p.sent), 1)

    def test_cut_erased_from_honk_list_is_caught_from_the_journal(self):
        # The intervening turn ended cleanly and cleared lastError.
        p = FakePigeon(sessions=[goose_row("g1", "gse_1")])
        cuts, cursor = tcn.parse_honkd_journal([
            journal_line("g1", NOW, "c1"),
            journal_line("g2", NOW, "c2", message="honkd could not tell whether goose got the prompt"),
            json.dumps({"__CURSOR": "c3", "MESSAGE": "unrelated"}),
            "not json",
        ])
        self.assertEqual(cuts, [{"native_id": "g1", "at": NOW}])
        self.assertEqual(cursor, "c3")
        self.run_([plain_row("g1")], p, cuts=cuts)
        self.assertEqual(len(p.sent), 1)

    def test_journal_and_list_sightings_of_one_cut_send_one_notice(self):
        p = FakePigeon(sessions=[goose_row("g1", "gse_1")])
        rows = [cut_row("g1", NOW)]
        cuts = tcn.cut_turns_from_list(rows) + [{"native_id": "g1", "at": NOW + 1}]
        self.run_(rows, p, cuts=cuts)
        self.run_(rows, p, cuts=cuts, now=NOW + 120)
        self.assertEqual(len(p.sent), 1)

    def test_loop_guard_holds_alerts_once_and_releases(self):
        p = FakePigeon(sessions=[goose_row("g1", "gse_1")])
        alerts = os.path.join(self.tmp.name, "alerts")
        alert = os.path.join(self.tmp.name, "alert.sh")
        with open(alert, "w") as f:
            f.write(f'#!/bin/sh\necho "$2" >> {alerts}\n')
        os.chmod(alert, 0o755)
        for i in range(4):
            self.run_([cut_row("g1", NOW + i * 600)], p, now=NOW + i * 600 + 60, alert=alert)
        self.assertEqual(len(p.sent), tcn.RESUME_CAP)
        _, err = self.run_([cut_row("g1", NOW + 1800)], p, now=NOW + 1900, alert=alert)
        with open(alerts) as f:
            self.assertEqual(f.read().split(), ["resume-cap:g1"], "alerted once")
        later = NOW + tcn.RESUME_CAP_WINDOW_S + 1000
        self.run_([plain_row("g1")], p, now=later, cuts=[], alert=alert)
        self.assertEqual(len(p.sent), tcn.RESUME_CAP + 1, "held cut goes out once the window opens")

    def test_pacing_keeps_the_rest_pending_oldest_first(self):
        sids = [f"g{i}" for i in range(5)]
        p = FakePigeon(sessions=[goose_row(s, "gse_" + s) for s in sids])
        rows = [cut_row(s, NOW + i) for i, s in enumerate(sids)]
        _, err = self.run_(rows, p, max_n=2)
        self.assertEqual([b["to"] for b in p.sent], ["gse_g0", "gse_g1"])
        self.assertIn("3 pending", err)
        self.run_([plain_row(s) for s in sids], p, max_n=2, cuts=[], now=NOW + 120)
        self.assertEqual([b["to"] for b in p.sent][2:], ["gse_g2", "gse_g3"])

    def test_other_errors_and_delivery_unknown_are_ignored(self):
        p = FakePigeon(sessions=[goose_row(s, "gse_" + s) for s in ("a", "c", "d")])
        rows = [
            cut_row("a", NOW, kind="network", message="connection reset"),
            cut_row("c", NOW, message="honkd could not tell whether goose got the prompt"),
            plain_row("d"),
        ]
        self.run_(rows, p)
        self.assertEqual(p.sent, [])

    def test_stall_watch_coordinator_skipped_once_quietly(self):
        p = FakePigeon(sessions=[goose_row("g1", "gse_1")])
        row = cut_row("g1", NOW, cwd="/home/dev/.local/state/stall-watch/coord-sessions/x")
        _, err1 = self.run_([row], p)
        _, err2 = self.run_([row], p, now=NOW + 120)
        self.assertEqual(p.sent, [])
        self.assertIn("stall-watch coordinator", err1)
        self.assertEqual(err2, "")

    def test_unroutable_skipped_quietly_next_time(self):
        p = FakePigeon(sessions=[])
        _, err1 = self.run_([cut_row("g1", NOW)], p)
        _, err2 = self.run_([cut_row("g1", NOW)], p, now=NOW + 120)
        self.assertIn("pigeon does not know", err1)
        self.assertEqual(err2, "")

    def test_send_failure_is_retried_next_run(self):
        p = FakePigeon(sessions=[goose_row("g1", "gse_1")], fail_to={"gse_1"})
        rc, _ = self.run_([cut_row("g1", NOW)], p)
        self.assertEqual(rc, 1)
        p.fail_to = set()
        rc, _ = self.run_([plain_row("g1")], p, now=NOW + 120, cuts=[])
        self.assertEqual(rc, 0)
        self.assertEqual(len(p.sent), 1, "a cut seen once is kept pending")

    def test_pigeon_down_is_retried(self):
        p = FakePigeon(fail_sessions=True)
        rc, _ = self.run_([cut_row("g1", NOW)], p)
        self.assertEqual(rc, 1)
        p.fail_sessions = False
        p.sessions = [goose_row("g1", "gse_1")]
        self.run_([cut_row("g1", NOW)], p, now=NOW + 120)
        self.assertEqual(len(p.sent), 1)

    def test_reset_workspace_notice_suppresses_the_resumer(self):
        snap = {"harness": "goose", "taken_at": NOW - 30,
                "sessions": [{"native_id": "g1", "title": "w"}]}
        p = FakePigeon(sessions=[goose_row("g1", "gse_1")])
        with mock.patch("sys.stderr", io.StringIO()), mock.patch("time.time", return_value=NOW + 30):
            tcn.notify([snap], None, p, 30, resume_state=self.state)
        self.assertEqual(len(p.sent), 1)
        self.run_([cut_row("g1", NOW)], p, now=NOW + 90)
        self.assertEqual(len(p.sent), 1, "the reset already told it")

    def test_dry_run_sends_and_records_nothing(self):
        p = FakePigeon(sessions=[goose_row("g1", "gse_1")])
        self.run_([cut_row("g1", NOW)], p, dry=True)
        self.assertEqual(p.sent, [])
        self.assertFalse(os.path.exists(self.state))

    def test_cli_skips_while_reset_lock_held(self):
        lock = os.path.join(self.tmp.name, "lock")
        open(lock, "w").close()
        import fcntl
        with open(lock) as f:
            fcntl.flock(f, fcntl.LOCK_EX)
            err = io.StringIO()
            with mock.patch("sys.stderr", err):
                rc = tcn.main(["resume-goose", "--honk", "/nonexistent/honk",
                               "--reset-lock", lock, "--resume-state", self.state])
        self.assertEqual(rc, 0)
        self.assertIn("reset-workspace in progress", err.getvalue())

    def test_cli_holds_while_goose_just_started(self):
        err = io.StringIO()
        with mock.patch("sys.stderr", err), mock.patch.object(tcn, "goose_uptime_s", return_value=10.0):
            rc = tcn.main(["resume-goose", "--honk", "/nonexistent/honk",
                           "--reset-lock", "/nonexistent.lock", "--resume-state", self.state])
        self.assertEqual(rc, 0)
        self.assertIn("holding resumes", err.getvalue())

    def test_cli_honk_failure_is_exit_1(self):
        with mock.patch("sys.stderr", io.StringIO()), \
                mock.patch.object(tcn, "goose_uptime_s", return_value=None):
            rc = tcn.main(["resume-goose", "--honk", "/nonexistent/honk",
                           "--reset-lock", "/nonexistent.lock", "--resume-state", self.state])
        self.assertEqual(rc, 1)


class Cli(Base):
    def test_snapshot_opencode_writes_file(self):
        self.fx.session("ses_a", updated=NOW)
        self.fx.message("ses_a")
        out = os.path.join(self.tmp.name, "oc.json")
        with mock.patch("time.time", return_value=NOW), mock.patch("sys.stderr", io.StringIO()):
            rc = tcn.main(["snapshot-opencode", "--db", self.db,
                           "--live-invocation-ids", f" {LIVE} ,other", "--out", out])
        self.assertEqual(rc, 0)
        with open(out) as f:
            snap = json.load(f)
        self.assertEqual([s["id"] for s in snap["sessions"]], ["ses_a"])
        self.assertEqual(snap["live_invocation_ids"], [LIVE, "other"])

    def test_snapshot_opencode_missing_db_is_exit_1(self):
        with mock.patch("sys.stderr", io.StringIO()):
            rc = tcn.main(["snapshot-opencode", "--db", "/nonexistent.db",
                           "--live-invocation-ids", LIVE, "--out", os.path.join(self.tmp.name, "x")])
        self.assertEqual(rc, 1)

    def test_notify_unreadable_snapshot_is_exit_1(self):
        with mock.patch("sys.stderr", io.StringIO()):
            rc = tcn.main(["notify", "--snapshot", "/nonexistent.json", "--dry-run"])
        self.assertEqual(rc, 1)


if __name__ == "__main__":
    unittest.main(verbosity=1)
