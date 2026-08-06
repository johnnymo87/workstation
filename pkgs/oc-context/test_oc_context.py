#!/usr/bin/env python3
"""Tests for oc-context. Run: python3 pkgs/oc-context/test_oc_context.py

Wired into CI as the `oc-context` flake check (see flake.nix), which invokes
this file directly.
"""

from __future__ import annotations

import json
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import oc_context  # noqa: E402


NOW_MS = 1_800_000_000_000


def make_db(path: str) -> sqlite3.Connection:
    conn = sqlite3.connect(path)
    conn.executescript(
        """
        CREATE TABLE session (
          id text PRIMARY KEY,
          parent_id text,
          title text NOT NULL,
          directory text NOT NULL,
          agent text,
          time_updated integer NOT NULL
        );
        CREATE TABLE message (
          id text PRIMARY KEY,
          session_id text NOT NULL,
          time_created integer NOT NULL,
          data text NOT NULL
        );
        """
    )
    return conn


def add_session(conn, sid, *, parent=None, directory="/tmp/x", updated=NOW_MS, agent="build"):
    conn.execute(
        "INSERT INTO session (id, parent_id, title, directory, agent, time_updated)"
        " VALUES (?,?,?,?,?,?)",
        (sid, parent, f"title {sid}", directory, agent, updated),
    )


def add_assistant(
    conn,
    sid,
    mid,
    *,
    t,
    total=None,
    input_=2,
    output=100,
    reasoning=0,
    cache_read=0,
    cache_write=0,
    summary=False,
    model="claude-opus-5@default",
    provider="google-vertex-anthropic",
    agent="build",
    omit_total=False,
):
    tokens = {
        "input": input_,
        "output": output,
        "reasoning": reasoning,
        "cache": {"read": cache_read, "write": cache_write},
    }
    if not omit_total:
        tokens["total"] = (
            total
            if total is not None
            else input_ + output + reasoning + cache_read + cache_write
        )
    data = {
        "role": "assistant",
        "agent": agent,
        "modelID": model,
        "providerID": provider,
        "tokens": tokens,
        "time": {"created": t, "completed": t + 1000},
    }
    if summary:
        data["summary"] = True
    conn.execute(
        "INSERT INTO message (id, session_id, time_created, data) VALUES (?,?,?,?)",
        (mid, sid, t, json.dumps(data)),
    )


class TestParseArgs(unittest.TestCase):
    def test_defaults(self):
        args = oc_context.parse_args([])
        self.assertEqual(args.sessions, [])
        self.assertIsNone(args.recent)
        self.assertFalse(args.children)
        self.assertFalse(args.json)
        self.assertEqual(args.live_window, oc_context.DEFAULT_LIVE_WINDOW_S)
        self.assertEqual(args.server, oc_context.DEFAULT_SERVER)

    def test_server_default_is_the_front_door_not_a_serve(self):
        # frontdoor-exempt is NOT needed here precisely because we address the
        # door; assert it so a "helpful" edit to :4096 fails a test.
        self.assertIn(":4700", oc_context.DEFAULT_SERVER)

    def test_session_ids_positional(self):
        args = oc_context.parse_args(["ses_a", "ses_b"])
        self.assertEqual(args.sessions, ["ses_a", "ses_b"])

    def test_recent(self):
        self.assertEqual(oc_context.parse_args(["--recent", "6"]).recent, 6.0)

    def test_recent_must_be_positive(self):
        with self.assertRaises(SystemExit):
            oc_context.parse_args(["--recent", "0"])

    def test_live_window_must_be_positive(self):
        with self.assertRaises(SystemExit):
            oc_context.parse_args(["--live-window", "-1"])

    def test_ids_and_recent_are_mutually_exclusive(self):
        with self.assertRaises(SystemExit):
            oc_context.parse_args(["ses_a", "--recent", "6"])


class TestCatalog(unittest.TestCase):
    def test_from_server_payload(self):
        payload = {
            "providers": [
                {
                    "id": "google-vertex-anthropic",
                    "models": {
                        "claude-opus-5@default": {"limit": {"context": 1000000}},
                        "broken": {"limit": {}},
                    },
                },
                {"models": {"orphan": {"limit": {"context": 1}}}},
            ]
        }
        cat = oc_context.catalog_from_server_payload(payload)
        self.assertEqual(cat, {("google-vertex-anthropic", "claude-opus-5@default"): 1000000})

    def test_from_models_json(self):
        payload = {
            "google-vertex": {
                "models": {"gemini-3.6-flash": {"limit": {"context": 1048576, "output": 65536}}}
            },
            "junk": "not-a-dict",
        }
        cat = oc_context.catalog_from_models_json(payload)
        self.assertEqual(cat, {("google-vertex", "gemini-3.6-flash"): 1048576})

    def test_lookup_exact(self):
        cat = {("p", "m@default"): 500}
        self.assertEqual(oc_context.lookup_window(cat, "p", "m@default"), 500)

    def test_lookup_longest_prefix_within_provider(self):
        cat = {("p", "claude"): 100, ("p", "claude-opus"): 200, ("q", "claude-opus-5"): 900}
        self.assertEqual(oc_context.lookup_window(cat, "p", "claude-opus-5@default"), 200)

    def test_lookup_misses(self):
        self.assertIsNone(oc_context.lookup_window({}, "p", "m"))
        self.assertIsNone(oc_context.lookup_window({("p", "m"): 1}, None, "m"))
        self.assertIsNone(oc_context.lookup_window({("p", "m"): 1}, "p", None))


class TestLiveSessions(unittest.TestCase):
    def _write(self, d: Path, name: str, doc: dict) -> None:
        (d / name).write_text(json.dumps(doc))

    def test_fresh_heartbeat_counts_stale_does_not(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            self._write(
                d,
                "serve-0-a.json",
                {
                    "heartbeat": NOW_MS - 5_000,
                    "directory": "/proj/live",
                    "sessions": {"ses_live": {"activity": "working", "error": False}},
                },
            )
            self._write(
                d,
                "serve-0-b.json",
                {
                    "heartbeat": NOW_MS - 3 * 86_400_000,
                    "directory": "/proj/dead",
                    "sessions": {"ses_dead": {"activity": "idle"}},
                },
            )
            live = oc_context.read_live_sessions(str(d), NOW_MS, 120)
        self.assertEqual(set(live), {"ses_live"})
        self.assertEqual(live["ses_live"]["activity"], "working")
        self.assertEqual(live["ses_live"]["serve_directory"], "/proj/live")

    def test_empty_sessions_map_and_malformed_files_are_skipped(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            self._write(d, "serve-0-empty.json", {"heartbeat": NOW_MS, "sessions": {}})
            (d / "serve-0-bad.json").write_text("{not json")
            self._write(d, "serve-0-nohb.json", {"sessions": {"ses_x": {}}})
            live = oc_context.read_live_sessions(str(d), NOW_MS, 120)
        self.assertEqual(live, {})

    def test_missing_dir_is_not_fatal(self):
        self.assertEqual(oc_context.read_live_sessions("/nonexistent/dir", NOW_MS, 120), {})


class TestMessageTotals(unittest.TestCase):
    def test_uses_total_when_present(self):
        self.assertEqual(oc_context.message_total_tokens({"tokens": {"total": 42}}), 42)

    def test_recomputes_when_total_absent(self):
        data = {
            "tokens": {
                "input": 2,
                "output": 100,
                "reasoning": 7,
                "cache": {"read": 500, "write": 30},
            }
        }
        self.assertEqual(oc_context.message_total_tokens(data), 639)

    def test_zero_and_missing_are_zero(self):
        self.assertEqual(oc_context.message_total_tokens({}), 0)
        self.assertEqual(oc_context.message_total_tokens({"tokens": {"total": 0}}), 0)


class DbTestCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.path = str(Path(self._tmp.name) / "opencode.db")
        w = make_db(self.path)
        self.write = w
        self.addCleanup(self._tmp.cleanup)
        self.addCleanup(w.close)

    def ro(self):
        self.write.commit()
        conn = oc_context.open_db(self.path)
        self.addCleanup(conn.close)
        return conn


class TestLastContextMessage(DbTestCase):
    def test_picks_newest_assistant_message(self):
        add_session(self.write, "s1")
        add_assistant(self.write, "s1", "m1", t=1000, cache_read=100_000)
        add_assistant(self.write, "s1", "m2", t=2000, cache_read=200_000)
        msg = oc_context.last_context_message(self.ro(), "s1")
        self.assertEqual(oc_context.message_total_tokens(msg), 200_102)

    def test_skips_compaction_summary_messages(self):
        """The trap: a compaction call runs on a DIFFERENT, cheap model against
        the pre-compaction transcript. Reporting it as 'current context' would
        divide the old context by the wrong model's window. OpenCode's own TUI
        does exactly that for one message after every compaction."""
        add_session(self.write, "s1")
        add_assistant(self.write, "s1", "m1", t=1000, cache_read=300_000)
        add_assistant(
            self.write,
            "s1",
            "m2",
            t=2000,
            summary=True,
            input_=677_000,
            output=1386,
            cache_read=0,
            model="gemini-3.6-flash",
            provider="google-vertex",
            agent="compaction",
        )
        msg = oc_context.last_context_message(self.ro(), "s1")
        assert msg is not None
        self.assertEqual(msg["modelID"], "claude-opus-5@default")
        self.assertEqual(oc_context.message_total_tokens(msg), 300_102)

    def test_skips_in_flight_zero_token_message(self):
        add_session(self.write, "s1")
        add_assistant(self.write, "s1", "m1", t=1000, cache_read=50_000)
        add_assistant(
            self.write, "s1", "m2", t=2000, input_=0, output=0, omit_total=True
        )
        msg = oc_context.last_context_message(self.ro(), "s1")
        assert msg is not None
        self.assertEqual(msg["time"]["created"], 1000)

    def test_ignores_user_messages(self):
        add_session(self.write, "s1")
        add_assistant(self.write, "s1", "m1", t=1000, cache_read=50_000)
        self.write.execute(
            "INSERT INTO message (id, session_id, time_created, data) VALUES (?,?,?,?)",
            ("m2", "s1", 2000, json.dumps({"role": "user", "tokens": {"total": 9}})),
        )
        msg = oc_context.last_context_message(self.ro(), "s1")
        assert msg is not None
        self.assertEqual(msg["role"], "assistant")

    def test_session_with_no_assistant_messages(self):
        add_session(self.write, "s1")
        self.assertIsNone(oc_context.last_context_message(self.ro(), "s1"))

    def test_last_compaction_ms(self):
        add_session(self.write, "s1")
        add_assistant(self.write, "s1", "m1", t=1000, summary=True)
        add_assistant(self.write, "s1", "m2", t=5000, summary=True)
        add_assistant(self.write, "s1", "m3", t=9000)
        conn = self.ro()
        self.assertEqual(oc_context.last_compaction_ms(conn, "s1"), 5000)

    def test_last_compaction_none(self):
        add_session(self.write, "s1")
        add_assistant(self.write, "s1", "m1", t=1000)
        self.assertIsNone(oc_context.last_compaction_ms(self.ro(), "s1"))


class TestSelectSessions(DbTestCase):
    def setUp(self):
        super().setUp()
        add_session(self.write, "root1", updated=NOW_MS - 1000)
        add_session(self.write, "root2", updated=NOW_MS - 10 * 3600 * 1000)
        add_session(self.write, "child1", parent="root1", updated=NOW_MS - 1000)

    def test_roots_only_by_default(self):
        rows = oc_context.select_sessions(
            self.ro(), ids=None, recent_hours=None, include_children=False, now_ms=NOW_MS
        )
        self.assertEqual({r["id"] for r in rows}, {"root1", "root2"})

    def test_children_included_on_request(self):
        rows = oc_context.select_sessions(
            self.ro(), ids=None, recent_hours=None, include_children=True, now_ms=NOW_MS
        )
        self.assertEqual({r["id"] for r in rows}, {"root1", "root2", "child1"})

    def test_recent_window(self):
        rows = oc_context.select_sessions(
            self.ro(), ids=None, recent_hours=1, include_children=True, now_ms=NOW_MS
        )
        self.assertEqual({r["id"] for r in rows}, {"root1", "child1"})

    def test_explicit_ids(self):
        rows = oc_context.select_sessions(
            self.ro(),
            ids=["root2", "child1"],
            recent_hours=None,
            include_children=True,
            now_ms=NOW_MS,
        )
        self.assertEqual({r["id"] for r in rows}, {"root2", "child1"})

    def test_sorted_by_recency(self):
        rows = oc_context.select_sessions(
            self.ro(), ids=None, recent_hours=None, include_children=False, now_ms=NOW_MS
        )
        self.assertEqual([r["id"] for r in rows], ["root1", "root2"])


class TestBuildRows(DbTestCase):
    def test_percent_headroom_and_sort_order(self):
        add_session(self.write, "big", directory="/proj/big")
        add_assistant(self.write, "big", "m1", t=1000, cache_read=800_000, output=0, input_=0)
        add_session(self.write, "small", directory="/proj/small")
        add_assistant(self.write, "small", "m2", t=1000, cache_read=100_000, output=0, input_=0)
        add_session(self.write, "silent", directory="/proj/silent")

        conn = self.ro()
        sessions = oc_context.select_sessions(
            conn, ids=None, recent_hours=None, include_children=False, now_ms=NOW_MS
        )
        catalog = {("google-vertex-anthropic", "claude-opus-5@default"): 1_000_000}
        live = {"big": {"activity": "working", "error": False}}
        rows = oc_context.build_rows(conn, sessions, catalog, live, NOW_MS)

        self.assertEqual([r["session_id"] for r in rows], ["big", "small", "silent"])
        self.assertEqual(rows[0]["percent"], 80.0)
        self.assertEqual(rows[0]["headroom"], 200_000)
        self.assertTrue(rows[0]["live"])
        self.assertEqual(rows[0]["activity"], "working")
        self.assertEqual(rows[1]["percent"], 10.0)
        self.assertFalse(rows[1]["live"])
        # Unmeasurable sessions sink, and say so rather than reporting 0%.
        self.assertIsNone(rows[2]["percent"])
        self.assertIsNone(rows[2]["tokens"])

    def test_unknown_model_yields_tokens_but_no_percent(self):
        add_session(self.write, "s1")
        add_assistant(self.write, "s1", "m1", t=1000, cache_read=5_000, model="mystery")
        conn = self.ro()
        sessions = oc_context.select_sessions(
            conn, ids=None, recent_hours=None, include_children=False, now_ms=NOW_MS
        )
        rows = oc_context.build_rows(conn, sessions, {}, {}, NOW_MS)
        self.assertEqual(rows[0]["tokens"], 5_102)
        self.assertIsNone(rows[0]["context_window"])
        self.assertIsNone(rows[0]["percent"])

    def test_model_reported_is_the_messages_model_not_the_sessions(self):
        add_session(self.write, "s1", agent="build")
        add_assistant(
            self.write, "s1", "m1", t=1000, model="gemini-3.6-flash", provider="google-vertex"
        )
        conn = self.ro()
        sessions = oc_context.select_sessions(
            conn, ids=None, recent_hours=None, include_children=False, now_ms=NOW_MS
        )
        catalog = {("google-vertex", "gemini-3.6-flash"): 1_048_576}
        rows = oc_context.build_rows(conn, sessions, catalog, {}, NOW_MS)
        self.assertEqual(rows[0]["model_id"], "gemini-3.6-flash")
        self.assertEqual(rows[0]["context_window"], 1_048_576)


class TestRendering(unittest.TestCase):
    def test_human_tokens(self):
        self.assertEqual(oc_context.human_tokens(None), "-")
        self.assertEqual(oc_context.human_tokens(950), "950")
        self.assertEqual(oc_context.human_tokens(1_500), "1.5k")
        self.assertEqual(oc_context.human_tokens(1_000_000), "1.00M")

    def test_human_age(self):
        self.assertEqual(oc_context.human_age(None, NOW_MS), "-")
        self.assertEqual(oc_context.human_age(NOW_MS - 5_000, NOW_MS), "5s")
        self.assertEqual(oc_context.human_age(NOW_MS - 600_000, NOW_MS), "10m")
        self.assertEqual(oc_context.human_age(NOW_MS - 7_200_000, NOW_MS), "2h")
        self.assertEqual(oc_context.human_age(NOW_MS - 5 * 86_400_000, NOW_MS), "5d")

    def test_short_model(self):
        self.assertEqual(oc_context.short_model("claude-opus-5@default"), "claude-opus-5")
        self.assertEqual(oc_context.short_model(None), "-")

    def test_render_table_marks_error_and_na(self):
        rows = [
            {
                "session_id": "ses_a",
                "percent": 61.2,
                "tokens": 612_000,
                "context_window": 1_000_000,
                "model_id": "claude-opus-5@default",
                "activity": "idle",
                "error": True,
                "live": True,
                "measured_at_ms": NOW_MS - 60_000,
                "last_compaction_ms": None,
                "directory": "/proj/a",
            },
            {
                "session_id": "ses_b",
                "percent": None,
                "tokens": None,
                "context_window": None,
                "model_id": None,
                "activity": None,
                "error": False,
                "live": False,
                "measured_at_ms": None,
                "last_compaction_ms": None,
                "directory": "/proj/b",
            },
        ]
        out = oc_context.render_table(rows, NOW_MS)
        self.assertIn("61.2", out)
        self.assertIn("idle!", out)
        self.assertIn("n/a", out)
        self.assertIn("/proj/b", out)


class TestMainSmoke(DbTestCase):
    def test_json_output_end_to_end(self):
        import io
        import contextlib

        add_session(self.write, "s1", directory="/proj/one")
        add_assistant(self.write, "s1", "m1", t=NOW_MS, cache_read=250_000)
        self.write.commit()

        with tempfile.TemporaryDirectory() as models_dir, tempfile.TemporaryDirectory() as state:
            models = Path(models_dir) / "models.json"
            models.write_text(
                json.dumps(
                    {
                        "google-vertex-anthropic": {
                            "models": {
                                "claude-opus-5@default": {"limit": {"context": 1_000_000}}
                            }
                        }
                    }
                )
            )
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                rc = oc_context.main(
                    [
                        "s1",
                        "--db",
                        self.path,
                        "--models-json",
                        str(models),
                        "--state-dir",
                        state,
                        "--no-server",
                        "--json",
                    ]
                )
        self.assertEqual(rc, 0)
        payload = json.loads(buf.getvalue())
        self.assertEqual(payload["sessions"][0]["session_id"], "s1")
        self.assertEqual(payload["sessions"][0]["context_window"], 1_000_000)
        self.assertEqual(payload["sessions"][0]["tokens"], 250_102)
        self.assertEqual(payload["sessions"][0]["percent"], 25.0)

    def test_missing_db_is_an_error(self):
        self.assertEqual(oc_context.main(["--db", "/nonexistent/x.db"]), 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
