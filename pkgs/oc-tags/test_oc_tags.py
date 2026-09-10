"""Tests for oc-tags. Run: python3 pkgs/oc-tags/test_oc_tags.py"""

from __future__ import annotations

import contextlib
import io
import json
import os
import re
import sqlite3
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

# Allow `import oc_tags` when running from repo root or anywhere else.
sys.path.insert(0, str(Path(__file__).resolve().parent))

import oc_tags  # noqa: E402

# Every fixture in this file timestamps its rows at FIXTURE_NOW_MS (2026-09-08
# 09:30 ET). Window selection, however, is relative to *now*: `days=N` spans
# [today_start - N days, today_start + 1 day]. Left on the wall clock, each of
# those tests is a time bomb that passes for N days after 2026-09-08 and then
# reports "No data in window" -- which is a false RED for an `assertIn` and a
# false GREEN for an `assertNotIn`. `days=1` duly broke CI on 2026-09-10 and
# blocked two unrelated dependency bumps.
#
# `calculate_window` already honours OC_TAGS_NOW_MS, so pin the clock for the
# whole suite. Tests that pass now_ms= explicitly still override this.
FIXTURE_NOW_MS = 1788874200000
os.environ["OC_TAGS_NOW_MS"] = str(FIXTURE_NOW_MS)


class TestParseArgs(unittest.TestCase):
    def test_report_defaults(self):
        args = oc_tags.parse_args(["report"])
        self.assertEqual(args.command, "report")
        self.assertEqual(args.days, 14)

    def test_serve_defaults(self):
        args = oc_tags.parse_args(["serve"])
        self.assertEqual(args.command, "serve")
        self.assertEqual(args.host, "127.0.0.1")
        self.assertEqual(args.port, 4710)


class TestAutoKey(unittest.TestCase):
    def test_worktree_keeps_slug(self):
        self.assertEqual(
            oc_tags.auto_key("/home/dev/projects/mono/.worktrees/fbm-transform-evidence"),
            "auto:mono/fbm-transform-evidence",
        )

    def test_primary_root(self):
        self.assertEqual(oc_tags.auto_key("/home/dev/projects/mono"), "auto:mono")

    def test_tmp_collapses(self):
        self.assertEqual(oc_tags.auto_key("/tmp/yt0p-verify"), "auto:tmp")
        self.assertEqual(oc_tags.auto_key("/tmp"), "auto:tmp")

    def test_nested_worktree_path(self):
        self.assertEqual(
            oc_tags.auto_key("/home/dev/projects/mono/.worktrees/w3-pr2/sub/dir"),
            "auto:mono/w3-pr2",
        )

    def test_missing_directory(self):
        self.assertEqual(oc_tags.auto_key(None), "auto:no-dir")
        self.assertEqual(oc_tags.auto_key(""), "auto:no-dir")

    def test_trailing_slash(self):
        self.assertEqual(oc_tags.auto_key("/home/dev/projects/mono/"), "auto:mono")

    def test_worktree_container_without_slug(self):
        self.assertEqual(oc_tags.auto_key("/home/dev/projects/mono/.worktrees"), "auto:mono")
        self.assertEqual(oc_tags.auto_key("/home/dev/projects/mono/.worktrees/"), "auto:mono")

    def test_doubled_slash_in_worktrees(self):
        self.assertEqual(
            oc_tags.auto_key("/home/dev/projects/mono/.worktrees//w3-pr2"),
            "auto:mono/w3-pr2",
        )

    def test_root_worktrees_slug(self):
        self.assertEqual(oc_tags.auto_key("/.worktrees/slug"), "auto:root/slug")

    def test_root_directory(self):
        self.assertEqual(oc_tags.auto_key("/"), "auto:root")

    def test_casing_is_lowercased(self):
        self.assertEqual(
            oc_tags.auto_key("/home/dev/projects/Mono/.worktrees/PR-123"),
            "auto:mono/pr-123",
        )


class TestRootOf(unittest.TestCase):
    def test_root_is_itself(self):
        self.assertEqual(oc_tags.root_of("a", {"a": None}), "a")

    def test_child_resolves_to_parent(self):
        self.assertEqual(oc_tags.root_of("b", {"a": None, "b": "a"}), "a")

    def test_dangling_parent_stops_at_self(self):
        # 983 live sessions point at a deleted parent. Attribute to the
        # topmost EXISTING ancestor -- here, the child itself.
        self.assertEqual(oc_tags.root_of("b", {"b": "gone"}), "b")

    def test_dangling_grandparent_stops_at_existing(self):
        self.assertEqual(oc_tags.root_of("c", {"b": "gone", "c": "b"}), "b")

    def test_cycle_guard(self):
        self.assertEqual(oc_tags.root_of("a", {"a": "b", "b": "a"}), "a")

    def test_unknown_session(self):
        self.assertEqual(oc_tags.root_of("zzz", {"a": None}), "zzz")

    def test_lasso_cycle(self):
        self.assertEqual(oc_tags.root_of("c", {"c": "b", "b": "a", "a": "b"}), "b")

    def test_empty_parents_map(self):
        self.assertEqual(oc_tags.root_of("a", {}), "a")


class TestStore(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = str(Path(self.tmp.name) / "tags.db")

    def tearDown(self):
        self.tmp.cleanup()

    def test_open_store_readonly(self):
        with oc_tags.open_store(self.path) as st:
            oc_tags.set_session_tag(st, "ses_1", "test-tag")
        with oc_tags.open_store(self.path, readonly=True) as st:
            self.assertEqual(oc_tags.session_tags(st), {"ses_1": "test-tag"})
            with self.assertRaises(sqlite3.OperationalError):
                st.execute("INSERT INTO session_tag VALUES ('x', 'y', 1)")

    def test_set_and_get_session_tag(self):
        with oc_tags.open_store(self.path) as st:
            oc_tags.set_session_tag(st, "ses_a", "billing")
            self.assertEqual(oc_tags.session_tags(st), {"ses_a": "billing"})

    def test_one_tag_per_session_overwrites(self):
        with oc_tags.open_store(self.path) as st:
            oc_tags.set_session_tag(st, "ses_a", "billing")
            oc_tags.set_session_tag(st, "ses_a", "infra")
            # A stacked area's top edge must equal the total; two tags on one
            # session would double count. Last write wins.
            self.assertEqual(oc_tags.session_tags(st), {"ses_a": "infra"})

    def test_tag_normalised_to_lowercase(self):
        with oc_tags.open_store(self.path) as st:
            oc_tags.set_session_tag(st, "ses_a", "  Infra  ")
            self.assertEqual(oc_tags.session_tags(st), {"ses_a": "infra"})

    def test_empty_tag_rejected(self):
        with oc_tags.open_store(self.path) as st:
            with self.assertRaises(ValueError):
                oc_tags.set_session_tag(st, "ses_a", "   ")

    def test_tag_rejects_auto_prefix(self):
        with oc_tags.open_store(self.path) as st:
            with self.assertRaises(ValueError):
                oc_tags.set_session_tag(st, "ses_a", "auto:foo")
            with self.assertRaises(ValueError):
                oc_tags.set_session_tag(st, "ses_a", "  AUTO:foo  ")

    def test_empty_pattern_rejected(self):
        with oc_tags.open_store(self.path) as st:
            with self.assertRaises(ValueError):
                oc_tags.set_dir_tag(st, "   ", "tag")
            with self.assertRaises(ValueError):
                oc_tags.set_dir_tag(st, "", "tag")

    def test_dir_tags_ordered_by_pattern(self):
        with oc_tags.open_store(self.path) as st:
            oc_tags.set_dir_tag(st, "zzz", "t1")
            oc_tags.set_dir_tag(st, "aaa", "t2")
            oc_tags.set_dir_tag(st, "mmm", "t3")
            self.assertEqual(
                list(oc_tags.dir_tags(st).keys()),
                ["aaa", "mmm", "zzz"],
            )

    def test_concurrency_pragmas(self):
        with oc_tags.open_store(self.path) as st:
            mode = st.execute("PRAGMA journal_mode").fetchone()[0]
            self.assertEqual(mode.lower(), "wal")
            timeout = st.execute("PRAGMA busy_timeout").fetchone()[0]
            self.assertEqual(timeout, 5000)

    def test_rollback_on_exception(self):
        with self.assertRaises(RuntimeError):
            with oc_tags.open_store(self.path) as st:
                oc_tags.set_session_tag(st, "ses_fail", "tag")
                raise RuntimeError("boom")
        with oc_tags.open_store(self.path) as st:
            self.assertEqual(oc_tags.session_tags(st), {})

    def test_dir_tag_roundtrip(self):
        with oc_tags.open_store(self.path) as st:
            oc_tags.set_dir_tag(st, "/home/dev/projects/mono/.worktrees/fbm-*", "fbm")
            self.assertEqual(
                oc_tags.dir_tags(st),
                {"/home/dev/projects/mono/.worktrees/fbm-*": "fbm"},
            )

    def test_rm_session_tag(self):
        with oc_tags.open_store(self.path) as st:
            oc_tags.set_session_tag(st, "ses_a", "billing")
            self.assertTrue(oc_tags.rm_session_tag(st, "ses_a"))
            self.assertEqual(oc_tags.session_tags(st), {})
            self.assertFalse(oc_tags.rm_session_tag(st, "ses_a"))

    def test_rm_dir_tag_strips_whitespace(self):
        with oc_tags.open_store(self.path) as st:
            oc_tags.set_dir_tag(st, "  /home/dev/projects/mono  ", "mono")
            self.assertTrue(oc_tags.rm_dir_tag(st, "   /home/dev/projects/mono   \n"))
            self.assertEqual(oc_tags.dir_tags(st), {})

    def test_schema_created_idempotently(self):
        with oc_tags.open_store(self.path) as st:
            oc_tags.set_session_tag(st, "ses_a", "billing")
        with oc_tags.open_store(self.path) as st:
            self.assertEqual(oc_tags.session_tags(st), {"ses_a": "billing"})


class TestEffectiveTag(unittest.TestCase):
    def test_session_tag_wins(self):
        self.assertEqual(
            oc_tags.effective_tag(
                "ses_a", "/home/dev/projects/mono",
                session_tag_map={"ses_a": "billing"},
                dir_tag_map={"/home/dev/projects/mono": "monorepo"},
            ),
            ("billing", "manual"),
        )

    def test_dir_pattern_next(self):
        self.assertEqual(
            oc_tags.effective_tag(
                "ses_a", "/home/dev/projects/mono/.worktrees/fbm-webhook-res",
                session_tag_map={},
                dir_tag_map={"/home/dev/projects/mono/.worktrees/fbm-*": "fbm"},
            ),
            ("fbm", "manual"),
        )

    def test_auto_fallback(self):
        self.assertEqual(
            oc_tags.effective_tag("ses_a", "/home/dev/projects/mono", {}, {}),
            ("auto:mono", "auto"),
        )

    def test_longest_pattern_wins(self):
        # Specific beats general, so a broad `mono/*` rule never shadows a
        # narrow one added later.
        self.assertEqual(
            oc_tags.effective_tag(
                "ses_a", "/home/dev/projects/mono/.worktrees/fbm-webhook-res",
                session_tag_map={},
                dir_tag_map={
                    "/home/dev/projects/mono/*": "mono-all",
                    "/home/dev/projects/mono/.worktrees/fbm-*": "fbm",
                },
            ),
            ("fbm", "manual"),
        )

    def test_pattern_tie_break_deterministic(self):
        # Two equal-length patterns matching the same directory.
        # Alphabetical tie-break: max(matches, key=lambda p: (len(p), p))
        # 'dir/*/sub' vs '*/dir/sub' - length 9.
        # 'dir/*/sub' > '*/dir/sub', so 'dir/*/sub' must win.
        self.assertEqual(
            oc_tags.effective_tag(
                "ses_a", "dir/dir/sub",
                session_tag_map={},
                dir_tag_map={
                    "*/dir/sub": "first",
                    "dir/*/sub": "second",
                },
            ),
            ("second", "manual"),
        )

    def test_trailing_slash_normalization(self):
        # Trailing slash on directory matches pattern without trailing slash
        self.assertEqual(
            oc_tags.effective_tag(
                "ses_a", "/home/dev/projects/mono/",
                session_tag_map={},
                dir_tag_map={"/home/dev/projects/mono": "mono-tag"},
            ),
            ("mono-tag", "manual"),
        )
        # Trailing slash on pattern matches directory without trailing slash
        self.assertEqual(
            oc_tags.effective_tag(
                "ses_a", "/home/dev/projects/mono",
                session_tag_map={},
                dir_tag_map={"/home/dev/projects/mono/": "mono-tag"},
            ),
            ("mono-tag", "manual"),
        )

    def test_no_directory(self):
        self.assertEqual(
            oc_tags.effective_tag("ses_a", None, {}, {}), ("auto:no-dir", "auto")
        )


class TestBucketing(unittest.TestCase):
    def test_hour_bucket_et(self):
        # 2026-09-08T13:30:00Z == 09:30 ET (EDT, UTC-4)
        self.assertEqual(oc_tags.bucket_key(1788874200000, "hour"), "2026-09-08T09")

    def test_day_bucket_et(self):
        self.assertEqual(oc_tags.bucket_key(1788874200000, "day"), "2026-09-08")

    def test_utc_midnight_is_previous_et_day(self):
        # 2026-09-08T02:00:00Z is 2026-09-07 22:00 ET. A UTC bucket would put
        # this on the wrong side of the 0-ET spend-cap reset.
        self.assertEqual(oc_tags.bucket_key(1788832800000, "day"), "2026-09-07")

    def test_choose_bucket_size(self):
        self.assertEqual(oc_tags.choose_bucket(1), "hour")
        self.assertEqual(oc_tags.choose_bucket(3), "hour")
        self.assertEqual(oc_tags.choose_bucket(4), "day")
        self.assertEqual(oc_tags.choose_bucket(30), "day")


def _fixture_db(path):
    conn = sqlite3.connect(path)
    conn.executescript(
        """
        CREATE TABLE session (id TEXT PRIMARY KEY, parent_id TEXT,
                              directory TEXT, title TEXT, cost REAL,
                              time_created INTEGER, time_updated INTEGER);
        CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT,
                              time_created INTEGER, data TEXT);
        """
    )
    sessions = [
        # id,        parent,   directory,                                       title
        ("root_a", None, "/home/dev/projects/mono", "FBM OOS webhook investigation"),
        ("kid_a", "root_a", "/home/dev/projects/mono", "subagent"),
        ("root_b", None, "/home/dev/projects/mono/.worktrees/w3-pr2", "w3 pr2"),
        # dangling parent: parent row does not exist
        ("orphan", "deleted_parent", "/home/dev/projects/salmon", "orphan"),
        ("tmp_s", None, "/tmp/yt0p-verify", "throwaway"),
    ]
    for sid, par, d, title in sessions:
        conn.execute(
            "INSERT INTO session VALUES (?,?,?,?,0,?,?)",
            (sid, par, d, title, 1788874200000, 1788874200000),
        )

    def msg(mid, sid, ts, cost, model: str | None = "claude-opus-5@default",
            provider="google-vertex-anthropic", role="assistant", tokens=None):
        data = {
            "role": role, "cost": cost, "modelID": model, "providerID": provider,
            "time": {"created": ts},
            "tokens": tokens or {"input": 10, "output": 20,
                                 "cache": {"read": 100, "write": 5}},
        }
        conn.execute("INSERT INTO message VALUES (?,?,?,?)",
                     (mid, sid, ts, json.dumps(data)))

    t = 1788874200000                    # 2026-09-08 09:30 ET
    msg("m1", "root_a", t, 1.50)
    msg("m2", "kid_a", t, 0.50)          # rolls up to root_a
    msg("m3", "root_b", t, 2.00)
    msg("m4", "orphan", t, 0.25)
    msg("m5", "tmp_s", t, 0.10)
    # zero-token error row: $0 is correct, must not crash
    msg("m6", "root_a", t, 0.0, tokens={"input": 0, "output": 0,
                                        "cache": {"read": 0, "write": 0}})
    # a user message must never be counted
    msg("m7", "root_a", t, 99.0, role="user")
    # unpriced model with tokens.total: must use total (5000), not sum of parts (3600)
    msg("m8", "root_b", t, 0.0, model="claude-brand-new@default",
        tokens={"total": 5000, "input": 1000, "output": 2000, "cache": {"read": 500, "write": 100}})
    # outside the window (much older)
    msg("m9", "root_a", t - 90 * 86400 * 1000, 5.00)
    # unpriced model with missing total and null modelID:
    # fallback to input+output+cache.read+cache.write = 200; model defaults to "unknown"
    msg("m10", "root_a", t, 0.0, model=None,
        tokens={"input": 50, "output": 50, "cache": {"read": 90, "write": 10}})
    conn.commit()
    conn.close()


class TestAggregate(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.db = str(Path(self.tmp.name) / "opencode.db")
        _fixture_db(self.db)

    def tearDown(self):
        self.tmp.cleanup()

    def _agg(self, session_tags=None, dir_tags=None):
        return oc_tags.aggregate(
            self.db,
            since_ms=1788874200000 - 86400 * 1000,
            until_ms=1788874200000 + 86400 * 1000,
            bucket="day",
            session_tags=session_tags or {},
            dir_tags=dir_tags or {},
        )

    def test_child_cost_rolls_up_to_root(self):
        rows = self._agg()
        # root_a: 1.50 + 0.50 (child) + 0.0 = 2.00; the $99 user row excluded
        self.assertAlmostEqual(rows.totals["auto:mono"], 2.00)

    def test_worktree_slug_preserved(self):
        rows = self._agg()
        self.assertIn("auto:mono/w3-pr2", rows.totals)

    def test_orphan_attributed_not_dropped(self):
        rows = self._agg()
        self.assertAlmostEqual(rows.totals["auto:salmon"], 0.25)

    def test_manual_tag_applied(self):
        rows = self._agg(session_tags={"root_a": "billing"})
        self.assertAlmostEqual(rows.totals["billing"], 2.00)
        self.assertNotIn("auto:mono", rows.totals)

    def test_window_excludes_old_rows(self):
        rows = self._agg()
        self.assertNotIn(5.00, rows.totals.values())

    def test_unpriced_models_reported(self):
        rows = self._agg()
        self.assertIn("claude-brand-new@default", rows.unpriced)
        self.assertEqual(rows.unpriced["claude-brand-new@default"]["messages"], 1)
        self.assertEqual(rows.unpriced["claude-brand-new@default"]["tokens"], 5000)
        self.assertIn("unknown", rows.unpriced)
        self.assertEqual(rows.unpriced["unknown"]["messages"], 1)
        self.assertEqual(rows.unpriced["unknown"]["tokens"], 200)

    def test_root_totals_and_meta(self):
        rows = self._agg()
        self.assertAlmostEqual(rows.root_totals["root_a"], 2.00)
        self.assertEqual(
            rows.root_meta["root_a"],
            {
                "title": "FBM OOS webhook investigation",
                "directory": "/home/dev/projects/mono",
                "tag": "auto:mono",
                "source": "auto",
            },
        )
        self.assertAlmostEqual(rows.root_totals["root_b"], 2.00)
        self.assertEqual(
            rows.root_meta["root_b"],
            {
                "title": "w3 pr2",
                "directory": "/home/dev/projects/mono/.worktrees/w3-pr2",
                "tag": "auto:mono/w3-pr2",
                "source": "auto",
            },
        )

    def test_partial_bucket_in_flight_vs_past(self):
        t = 1788874200000  # 2026-09-08 09:30 ET
        # When now_ms is in the current bucket (day: 2026-09-08):
        agg_now = oc_tags.aggregate(
            self.db,
            since_ms=t - 86400 * 1000,
            until_ms=t + 86400 * 1000,
            bucket="day",
            session_tags={},
            dir_tags={},
            now_ms=t,
        )
        self.assertEqual(agg_now.partial_bucket, "2026-09-08")

        # When the window ends in the past relative to now_ms:
        agg_past = oc_tags.aggregate(
            self.db,
            since_ms=t - 86400 * 1000,
            until_ms=t + 86400 * 1000,
            bucket="day",
            session_tags={},
            dir_tags={},
            now_ms=t + 10 * 86400 * 1000,  # 10 days later
        )
        self.assertIsNone(agg_past.partial_bucket)

    def test_totals_ordered_descending_by_dollars(self):
        rows = self._agg()
        totals_list = list(rows.totals.values())
        self.assertEqual(totals_list, sorted(totals_list, reverse=True))

    def test_aggregate_transaction_lifecycle(self):
        executed = []
        real_connect = oc_tags.connect_ro

        class ConnectionProxy:
            def __init__(self, target):
                self._target = target
            def execute(self, sql, *args):
                executed.append(sql.strip().split()[0].upper())
                return self._target.execute(sql, *args)
            def rollback(self):
                executed.append("ROLLBACK")
                return self._target.rollback()
            def close(self):
                return self._target.close()
            def __getattr__(self, name):
                return getattr(self._target, name)

        def tracking_connect(path):
            return ConnectionProxy(real_connect(path))

        try:
            oc_tags.connect_ro = tracking_connect
            self._agg()
            self.assertIn("BEGIN", executed)
            self.assertIn("ROLLBACK", executed)
        finally:
            oc_tags.connect_ro = real_connect

    def test_buckets_are_populated(self):
        rows = self._agg()
        self.assertEqual(set(rows.series["auto:mono"]), {"2026-09-08"})


class TestCli(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.db = str(Path(self.tmp.name) / "opencode.db")
        self.tags_db = str(Path(self.tmp.name) / "tags.db")
        _fixture_db(self.db)

    def tearDown(self):
        self.tmp.cleanup()

    def test_set_session_with_explicit_id_resolves_to_root(self):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            # kid_a's parent is root_a; must resolve to root_a
            rc = oc_tags.main(["set", "billing", "kid_a", "--db", self.db, "--tags-db", self.tags_db])
        self.assertEqual(rc, 0)
        with oc_tags.open_store(self.tags_db) as st:
            self.assertEqual(oc_tags.session_tags(st), {"root_a": "billing"})

    def test_set_session_with_opencode_session_id_env(self):
        buf = io.StringIO()
        old_env = os.environ.get("OPENCODE_SESSION_ID")
        try:
            os.environ["OPENCODE_SESSION_ID"] = "kid_a"
            with contextlib.redirect_stdout(buf):
                rc = oc_tags.main(["set", "billing", "--db", self.db, "--tags-db", self.tags_db])
            self.assertEqual(rc, 0)
            with oc_tags.open_store(self.tags_db) as st:
                self.assertEqual(oc_tags.session_tags(st), {"root_a": "billing"})
        finally:
            if old_env is None:
                os.environ.pop("OPENCODE_SESSION_ID", None)
            else:
                os.environ["OPENCODE_SESSION_ID"] = old_env

    def test_set_without_session_id_or_env_fails(self):
        buf = io.StringIO()
        err = io.StringIO()
        old_env = os.environ.get("OPENCODE_SESSION_ID")
        try:
            os.environ.pop("OPENCODE_SESSION_ID", None)
            with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(err):
                rc = oc_tags.main(["set", "billing", "--db", self.db, "--tags-db", self.tags_db])
            self.assertNotEqual(rc, 0)
            self.assertIn("OPENCODE_SESSION_ID", err.getvalue())
        finally:
            if old_env is not None:
                os.environ["OPENCODE_SESSION_ID"] = old_env

    def test_set_dir_tag(self):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = oc_tags.main([
                "set", "--dir", "/home/dev/projects/mono/.worktrees/*", "mono-wt",
                "--tags-db", self.tags_db,
            ])
        self.assertEqual(rc, 0)
        with oc_tags.open_store(self.tags_db) as st:
            self.assertEqual(
                oc_tags.dir_tags(st),
                {"/home/dev/projects/mono/.worktrees/*": "mono-wt"},
            )

    def test_rm_dir_tag(self):
        with oc_tags.open_store(self.tags_db) as st:
            oc_tags.set_dir_tag(st, "/home/dev/projects/mono/.worktrees/*", "mono-wt")
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = oc_tags.main([
                "rm", "--dir", "/home/dev/projects/mono/.worktrees/*",
                "--tags-db", self.tags_db,
            ])
        self.assertEqual(rc, 0)
        with oc_tags.open_store(self.tags_db) as st:
            self.assertEqual(oc_tags.dir_tags(st), {})

    def test_rm_session_tag(self):
        with oc_tags.open_store(self.tags_db) as st:
            oc_tags.set_session_tag(st, "root_a", "billing")
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = oc_tags.main(["rm", "root_a", "--tags-db", self.tags_db])
        self.assertEqual(rc, 0)
        with oc_tags.open_store(self.tags_db) as st:
            self.assertEqual(oc_tags.session_tags(st), {})

    def test_ls_without_counts_and_with_counts(self):
        with oc_tags.open_store(self.tags_db) as st:
            oc_tags.set_session_tag(st, "root_a", "billing")
            oc_tags.set_dir_tag(st, "/home/dev/projects/mono/.worktrees/*", "mono-wt")

        # Without --counts
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = oc_tags.main(["ls", "--tags-db", self.tags_db])
        self.assertEqual(rc, 0)
        out = buf.getvalue()
        self.assertIn("root_a", out)
        self.assertIn("billing", out)
        self.assertIn("mono-wt", out)

        # With --counts
        buf_counts = io.StringIO()
        with contextlib.redirect_stdout(buf_counts):
            rc = oc_tags.main(["ls", "--counts", "--tags-db", self.tags_db])
        self.assertEqual(rc, 0)
        out_counts = buf_counts.getvalue()
        self.assertIn("tag", out_counts)
        self.assertIn("billing", out_counts)
        self.assertIn("mono-wt", out_counts)

    def test_report_output_table(self):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = oc_tags.main(["report", "--days", "7", "--db", self.db, "--tags-db", self.tags_db])
        self.assertEqual(rc, 0)
        out = buf.getvalue()
        self.assertIn("Consumed at list price (USD) -- not billed.", out)
        self.assertIn("tag", out)
        self.assertIn("total", out)
        self.assertIn("share", out)
        self.assertIn("auto:mono", out)
        self.assertIn("Unpriced models:", out)

    def test_report_empty_window(self):
        # Empty opencode db
        empty_db = str(Path(self.tmp.name) / "empty.db")
        conn = sqlite3.connect(empty_db)
        conn.executescript(
            """
            CREATE TABLE session (id TEXT PRIMARY KEY, parent_id TEXT, directory TEXT, title TEXT);
            CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, data TEXT);
            """
        )
        conn.close()

        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = oc_tags.main(["report", "--days", "1", "--db", empty_db, "--tags-db", self.tags_db])
        self.assertEqual(rc, 0)
        out = buf.getvalue()
        self.assertIn("No assistant messages found", out)

    def test_top_auto_source_roots_appear_and_manual_do_not(self):
        # Manually tag root_a
        with oc_tags.open_store(self.tags_db) as st:
            oc_tags.set_session_tag(st, "root_a", "billing")

        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = oc_tags.main(["top", "--days", "7", "--db", self.db, "--tags-db", self.tags_db])
        self.assertEqual(rc, 0)
        out = buf.getvalue()
        # root_b (auto) should appear
        self.assertIn("root_b", out)
        self.assertIn("w3 pr2", out)
        # root_a (manual) must NOT appear
        self.assertNotIn("root_a", out)
        self.assertNotIn("FBM OOS webhook investigation", out)

    def test_top_ordering_and_min_filter(self):
        # Without --min, orphan ($0.25) appears
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = oc_tags.main(["top", "--days", "7", "--db", self.db, "--tags-db", self.tags_db])
        self.assertEqual(rc, 0)
        out = buf.getvalue()
        self.assertIn("orphan", out)
        # Verify ordering: root_a ($2.00) appears before orphan ($0.25)
        pos_root = out.find("root_a")
        pos_orphan = out.find("orphan")
        self.assertLess(pos_root, pos_orphan)

        # With --min 1.0, orphan ($0.25) is filtered out
        buf_min = io.StringIO()
        with contextlib.redirect_stdout(buf_min):
            rc = oc_tags.main(["top", "--days", "7", "--min", "1.0", "--db", self.db, "--tags-db", self.tags_db])
        self.assertEqual(rc, 0)
        out_min = buf_min.getvalue()
        self.assertIn("root_a", out_min)
        self.assertNotIn("orphan", out_min)

    def test_top_dir_hint_for_shared_prefix(self):
        # Add 3 sessions sharing a directory prefix
        conn = sqlite3.connect(self.db)
        t = 1788874200000
        for i in range(3):
            sid = f"wt_{i}"
            conn.execute(
                "INSERT INTO session VALUES (?,?,?,?,0,?,?)",
                (sid, None, f"/home/dev/projects/mono/.worktrees/pr-{i}", f"PR {i}", t, t),
            )
            data = {"role": "assistant", "cost": 1.00, "modelID": "m", "tokens": {"input": 1, "output": 1}}
            conn.execute(
                "INSERT INTO message VALUES (?,?,?,?)",
                (f"m_wt_{i}", sid, t, json.dumps(data)),
            )
        conn.commit()
        conn.close()

        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = oc_tags.main(["top", "--days", "7", "--db", self.db, "--tags-db", self.tags_db])
        self.assertEqual(rc, 0)
        out = buf.getvalue()
        self.assertIn("--dir", out)
        self.assertIn("/home/dev/projects/mono/.worktrees/*", out)

    def test_top_dir_hint_worktree_ranking_not_skewed_by_double_counting(self):
        conn = sqlite3.connect(self.db)
        t = 1788874200000
        # Repo A: 3 worktree sessions
        for i in range(3):
            sid = f"repoA_{i}"
            conn.execute(
                "INSERT INTO session VALUES (?,?,?,?,0,?,?)",
                (sid, None, f"/home/dev/projects/repoA/.worktrees/wt-{i}", f"RepoA {i}", t, t),
            )
            data = {"role": "assistant", "cost": 1.00, "modelID": "m", "tokens": {"input": 1, "output": 1}}
            conn.execute(
                "INSERT INTO message VALUES (?,?,?,?)",
                (f"m_repoA_{i}", sid, t, json.dumps(data)),
            )
        # Repo B: 4 worktree sessions
        for i in range(4):
            sid = f"repoB_{i}"
            conn.execute(
                "INSERT INTO session VALUES (?,?,?,?,0,?,?)",
                (sid, None, f"/home/dev/projects/repoB/.worktrees/wt-{i}", f"RepoB {i}", t, t),
            )
            data = {"role": "assistant", "cost": 1.00, "modelID": "m", "tokens": {"input": 1, "output": 1}}
            conn.execute(
                "INSERT INTO message VALUES (?,?,?,?)",
                (f"m_repoB_{i}", sid, t, json.dumps(data)),
            )
        conn.commit()
        conn.close()

        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = oc_tags.main(["top", "--days", "7", "--db", self.db, "--tags-db", self.tags_db])
        self.assertEqual(rc, 0)
        out = buf.getvalue()
        # Repo B (4 roots) must appear before Repo A (3 roots) in hints
        pos_b = out.find("/home/dev/projects/repoB/.worktrees/*")
        pos_a = out.find("/home/dev/projects/repoA/.worktrees/*")
        self.assertNotEqual(pos_b, -1)
        self.assertNotEqual(pos_a, -1)
        self.assertLess(pos_b, pos_a)

    def test_top_dir_hint_primary_root_does_not_hint_parent_container(self):
        conn = sqlite3.connect(self.db)
        t = 1788874200000
        for i in range(3):
            sid = f"mono_{i}"
            conn.execute(
                "INSERT INTO session VALUES (?,?,?,?,0,?,?)",
                (sid, None, "/home/dev/projects/mono", f"Mono {i}", t, t),
            )
            data = {"role": "assistant", "cost": 1.00, "modelID": "m", "tokens": {"input": 1, "output": 1}}
            conn.execute(
                "INSERT INTO message VALUES (?,?,?,?)",
                (f"m_mono_{i}", sid, t, json.dumps(data)),
            )
        conn.commit()
        conn.close()

        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = oc_tags.main(["top", "--days", "7", "--db", self.db, "--tags-db", self.tags_db])
        self.assertEqual(rc, 0)
        out = buf.getvalue()
        self.assertNotIn("/home/dev/projects/*", out)
        self.assertIn("'/home/dev/projects/mono'", out)

    def test_load_aggregate_helper(self):
        agg = oc_tags.load_aggregate(db_path=self.db, tags_db=self.tags_db, days=7)
        self.assertIsNotNone(agg.window)
        self.assertIn("root_a", agg.root_totals)

    def test_broken_pipe_suppressed(self):
        class BrokenPipeWriter:
            def write(self, s):
                raise BrokenPipeError(32, "Broken pipe")
            def flush(self):
                raise BrokenPipeError(32, "Broken pipe")

        with contextlib.redirect_stdout(BrokenPipeWriter()):
            rc = oc_tags.main(["top", "--days", "7", "--db", self.db, "--tags-db", self.tags_db])
        self.assertEqual(rc, 0)


class TestCfp(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()

    def tearDown(self):
        self.tmp.cleanup()

    def test_missing_directory_returns_empty(self):
        missing = str(Path(self.tmp.name) / "does-not-exist")
        self.assertEqual(oc_tags.cfp_metered_by_day(missing), {})

    def test_history_jsonl_sums_spend_and_enterprise(self):
        h = Path(self.tmp.name) / "history.jsonl"
        lines = [
            json.dumps({"day": "2026-09-05", "spend": 105.25, "enterpriseSpend": 95.75}),
            json.dumps({"day": "2026-09-06", "spend": 100.00, "enterpriseSpend": 100.00}),
        ]
        h.write_text("\n".join(lines) + "\n", encoding="utf-8")

        res = oc_tags.cfp_metered_by_day(self.tmp.name)
        self.assertAlmostEqual(res["2026-09-05"], 201.00)
        self.assertAlmostEqual(res["2026-09-06"], 200.00)

    def test_malformed_and_torn_lines_skipped(self):
        h = Path(self.tmp.name) / "history.jsonl"
        lines = [
            json.dumps({"day": "2026-09-05", "spend": 100.0, "enterpriseSpend": 50.0}),
            '{"day": "2026-09-06", "spend": 100.0, torn line...',
            'not json',
            "",
            json.dumps({"day": "2026-09-07", "spend": 80.0, "enterpriseSpend": 70.0}),
        ]
        h.write_text("\n".join(lines), encoding="utf-8")

        res = oc_tags.cfp_metered_by_day(self.tmp.name)
        self.assertEqual(set(res.keys()), {"2026-09-05", "2026-09-07"})
        self.assertAlmostEqual(res["2026-09-05"], 150.0)
        self.assertAlmostEqual(res["2026-09-07"], 150.0)

    def test_today_totals_from_spend_json_files(self):
        h = Path(self.tmp.name) / "history.jsonl"
        h.write_text(
            json.dumps({"day": "2026-09-07", "spend": 100.0, "enterpriseSpend": 100.0}) + "\n",
            encoding="utf-8",
        )
        s1 = Path(self.tmp.name) / "spend.json"
        s1.write_text(json.dumps({"day": "2026-09-08", "total": 103.50}), encoding="utf-8")
        s2 = Path(self.tmp.name) / "spend-enterprise.json"
        s2.write_text(json.dumps({"day": "2026-09-08", "total": 101.50}), encoding="utf-8")

        res = oc_tags.cfp_metered_by_day(self.tmp.name)
        self.assertAlmostEqual(res["2026-09-07"], 200.00)
        self.assertAlmostEqual(res["2026-09-08"], 205.00)

    def test_single_spend_file_partial(self):
        s1 = Path(self.tmp.name) / "spend.json"
        s1.write_text(json.dumps({"day": "2026-09-08", "total": 103.50}), encoding="utf-8")

        res = oc_tags.cfp_metered_by_day(self.tmp.name)
        self.assertAlmostEqual(res["2026-09-08"], 103.50)

    def test_history_jsonl_reads_notional_vertex_cost(self):
        h = Path(self.tmp.name) / "history.jsonl"
        lines = [
            json.dumps({"day": "2026-09-05", "spend": 105.25, "enterpriseSpend": 95.75, "notionalVertexCost": 333.88}),
        ]
        h.write_text("\n".join(lines) + "\n", encoding="utf-8")
        spend = oc_tags.cfp_spend_by_day(self.tmp.name)
        self.assertAlmostEqual(spend.metered["2026-09-05"], 201.00)
        self.assertAlmostEqual(spend.notional["2026-09-05"], 333.88)

    def test_spend_json_reads_notional_vertex_cost(self):
        s1 = Path(self.tmp.name) / "spend.json"
        s1.write_text(json.dumps({"day": "2026-09-08", "total": 103.50, "notionalVertexCost": 150.0}), encoding="utf-8")
        spend = oc_tags.cfp_spend_by_day(self.tmp.name)
        self.assertAlmostEqual(spend.metered["2026-09-08"], 103.50)
        self.assertAlmostEqual(spend.notional["2026-09-08"], 150.0)

    def test_non_numeric_spend_in_history_jsonl_skipped_without_aborting_remaining_lines(self):
        h = Path(self.tmp.name) / "history.jsonl"
        lines = [
            json.dumps({"day": "2026-09-05", "spend": 100.0, "enterpriseSpend": 50.0}),
            json.dumps({"day": "2026-09-06", "spend": "invalid_number", "enterpriseSpend": 50.0}),
            json.dumps({"day": "2026-09-07", "spend": 80.0, "enterpriseSpend": 70.0}),
        ]
        h.write_text("\n".join(lines) + "\n", encoding="utf-8")
        res = oc_tags.cfp_metered_by_day(self.tmp.name)
        self.assertEqual(set(res.keys()), {"2026-09-05", "2026-09-07"})
        self.assertAlmostEqual(res["2026-09-05"], 150.0)
        self.assertAlmostEqual(res["2026-09-07"], 150.0)

    def test_cfp_oserror_warns_on_stderr(self):
        h = Path(self.tmp.name) / "history.jsonl"
        h.write_text("data\n", encoding="utf-8")
        from unittest import mock
        with mock.patch("builtins.open", side_effect=PermissionError("Permission denied")):
            err = io.StringIO()
            with contextlib.redirect_stderr(err):
                res = oc_tags.cfp_spend_by_day(self.tmp.name)
            self.assertEqual(res.metered, {})
            self.assertIn("Permission denied", err.getvalue())


class TestRenderSvg(unittest.TestCase):
    def _sample_agg(self):
        agg = oc_tags.Aggregate()
        agg.buckets = ["2026-09-07", "2026-09-08"]
        agg.series = {
            "tag_a": {"2026-09-07": 10.0, "2026-09-08": 20.0},
            "tag_b": {"2026-09-07": 5.0, "2026-09-08": 15.0},
        }
        agg.totals = {"tag_a": 30.0, "tag_b": 20.0}
        agg.sources = {"tag_a": "manual", "tag_b": "auto"}
        return agg

    def _hover_groups(self, svg):
        """Only the <g class="hz"> blocks -- the legend also names tags."""
        return re.findall(r'<g class="hz">.*?\n  </g>', svg, re.S)

    def test_render_svg_starts_with_svg_and_parses_xml(self):
        agg = self._sample_agg()
        svg = oc_tags.render_svg(agg, {"2026-09-07": 15.0, "2026-09-08": 35.0})
        self.assertTrue(svg.strip().startswith("<svg"))
        root = ET.fromstring(svg)
        self.assertEqual(root.tag, "{http://www.w3.org/2000/svg}svg" if "}" in root.tag else "svg")
        self.assertIn("Consumed at list price (USD) — not billed", svg)

    def test_render_svg_empty_aggregate_renders_valid_no_data(self):
        agg = oc_tags.Aggregate()
        svg = oc_tags.render_svg(agg, {})
        self.assertTrue(svg.strip().startswith("<svg"))
        root = ET.fromstring(svg)
        self.assertIsNotNone(root)
        self.assertIn("No data", svg)

    def test_render_svg_escapes_script_tag(self):
        agg = self._sample_agg()
        evil = "<script>alert(1)</script>"
        agg.series[evil] = {"2026-09-07": 1.0, "2026-09-08": 1.0}
        agg.totals[evil] = 2.0
        agg.sources[evil] = "manual"
        svg = oc_tags.render_svg(agg, {})
        root = ET.fromstring(svg)
        self.assertIsNone(root.find(".//script"))
        self.assertIn("&lt;script&gt;", svg)

    def test_render_svg_hide_removes_band_and_legend(self):
        agg = self._sample_agg()
        svg = oc_tags.render_svg(agg, {}, hide=frozenset(["tag_a"]))
        self.assertNotIn("tag_a", svg)
        self.assertIn("tag_b", svg)

    def test_render_svg_top_n_creates_other_band_matching_tail_sum(self):
        agg = oc_tags.Aggregate()
        agg.buckets = ["2026-09-07", "2026-09-08"]
        # 5 tags
        for i in range(5):
            tname = f"t{i}"
            val = (5 - i) * 10.0
            agg.series[tname] = {"2026-09-07": val / 2, "2026-09-08": val / 2}
            agg.totals[tname] = val
            agg.sources[tname] = "manual"
        # Top 2 -> t0 (50), t1 (40); tail -> t2(30) + t3(20) + t4(10) = 60
        svg = oc_tags.render_svg(agg, {}, top_n=2)
        root = ET.fromstring(svg)
        self.assertIsNotNone(root)
        self.assertIn("other", svg)
        self.assertIn("$60.00", svg)
        self.assertIn("t0", svg)
        self.assertIn("t1", svg)
        self.assertNotIn("t2", svg)

    def test_render_svg_unpriced_entry_survives_top_n_truncation(self):
        agg = oc_tags.Aggregate()
        agg.buckets = ["2026-09-07", "2026-09-08"]
        for i in range(5):
            tname = f"t{i}"
            agg.series[tname] = {"2026-09-07": 10.0, "2026-09-08": 10.0}
            agg.totals[tname] = 20.0
        agg.unpriced = {"test-model": {"messages": 5, "tokens": 120000}}
        svg = oc_tags.render_svg(agg, {}, top_n=2)
        self.assertIn("unpriced", svg)
        self.assertIn("120.0K tok", svg)
        self.assertNotIn("unpriced: $", svg)

    def test_render_svg_metered_line_and_cap_hit_headline(self):
        agg = self._sample_agg()
        agg.cap_hits["2026-09-08"] = "12:37"
        svg = oc_tags.render_svg(agg, {"2026-09-07": 100.0, "2026-09-08": 204.0})
        self.assertIn("billed (capped)", svg)
        self.assertIn("cap hit at 12:37", svg)

    def test_render_svg_drift_warning_when_ratio_outside_bounds(self):
        agg = self._sample_agg()
        spend = oc_tags.CfpSpend(
            metered={"2026-09-07": 15.0},
            notional={"2026-09-07": 50.0},
        )
        svg = oc_tags.render_svg(agg, spend)
        self.assertIn("Drift warning", svg)

    def test_render_svg_coverage_ratio_excludes_unmatched_buckets_and_discloses_count(self):
        agg = self._sample_agg()
        # agg has buckets 2026-09-07 ($15.00) and 2026-09-08 ($35.00), total $50.00.
        # Only 2026-09-07 is present in notional ($15.00).
        spend = oc_tags.CfpSpend(
            metered={"2026-09-07": 15.0},
            notional={"2026-09-07": 15.0},
        )
        svg = oc_tags.render_svg(agg, spend)
        # Correct computation: matching list $15.00 / notional $15.00 = 100.0%, 1 of 2 days.
        # Naive computation would yield $50.00 / $15.00 = 333.3%.
        self.assertIn("Coverage: 100.0% vs CFP notional ($15.00 / $15.00, 1 of 2 days)", svg)
        self.assertNotIn("333.3%", svg)
        self.assertNotIn("$50.00 / $15.00", svg)
        self.assertIn("1 of 2 days", svg)

    def test_render_svg_coverage_no_excluded_days_omits_count(self):
        agg = self._sample_agg()
        spend = oc_tags.CfpSpend(
            metered={"2026-09-07": 15.0, "2026-09-08": 35.0},
            notional={"2026-09-07": 15.0, "2026-09-08": 35.0},
        )
        svg = oc_tags.render_svg(agg, spend)
        self.assertIn("Coverage: 100.0% vs CFP notional ($50.00 / $50.00)", svg)
        self.assertNotIn("of 2 days", svg)

    def test_render_svg_coverage_fallback_when_no_matching_days(self):
        agg = self._sample_agg()
        spend = oc_tags.CfpSpend(metered={}, notional={})
        svg = oc_tags.render_svg(agg, spend)
        self.assertIn("Total list price: $50.00", svg)
        self.assertNotIn("Coverage:", svg)

    def test_render_svg_drift_warning_inside_band_renders_no_warning(self):
        agg = self._sample_agg()
        # Both days match perfectly 1.0 ratio, within [0.90, 1.05]
        spend = oc_tags.CfpSpend(
            metered={"2026-09-07": 15.0, "2026-09-08": 35.0},
            notional={"2026-09-07": 15.0, "2026-09-08": 35.0},
        )
        svg = oc_tags.render_svg(agg, spend)
        self.assertNotIn("Drift warning", svg)


    # --- hover tooltips (zero-JS) ---

    def test_hover_tooltip_shows_tag_and_bucket_dollars(self):
        agg = self._sample_agg()
        svg = oc_tags.render_svg(agg, {})
        self.assertIn('class="hz"', svg)
        self.assertIn("tag_a", svg)
        self.assertIn("$20.00", svg)   # tag_a on 2026-09-08
        self.assertIn("$5.00", svg)    # tag_b on 2026-09-07

    def test_hover_tooltip_hidden_until_hover_via_css_only(self):
        agg = self._sample_agg()
        svg = oc_tags.render_svg(agg, {})
        self.assertIn(".hz:hover", svg)
        self.assertRegex(svg, r"\.hz\s+\.tt\s*\{[^}]*opacity\s*:\s*0")

    def test_hover_layer_contains_no_javascript(self):
        agg = self._sample_agg()
        svg = oc_tags.render_svg(agg, {"2026-09-08": 12.0})
        self.assertNotIn("<script", svg.lower())
        self.assertNotIn("javascript:", svg.lower())
        # Catch ANY on*= handler rather than a hand-enumerated list, which had
        # missed onmousemove, SMIL onbegin/onend, onfocusin and onerror.
        self.assertIsNone(
            re.search(r"\bon[a-z]+\s*=", svg, re.I),
            "an event handler attribute leaked into the SVG",
        )

    def test_hover_tooltip_escapes_tag_markup(self):
        agg = oc_tags.Aggregate()
        agg.buckets = ["2026-09-08"]
        agg.series = {"<script>x</script>": {"2026-09-08": 7.0}}
        agg.totals = {"<script>x</script>": 7.0}
        agg.sources = {"<script>x</script>": "manual"}
        svg = oc_tags.render_svg(agg, {})
        self.assertNotIn("<script", svg.lower())
        self.assertIn("&lt;script&gt;", svg)
        self.assertIsNotNone(ET.fromstring(svg))

    def test_hover_tooltip_omits_zero_value_segments(self):
        agg = oc_tags.Aggregate()
        agg.buckets = ["2026-09-07", "2026-09-08"]
        agg.series = {
            "tag_a": {"2026-09-07": 0.0, "2026-09-08": 4.0},
            "zeroed": {"2026-09-07": 0.0, "2026-09-08": 0.0},
        }
        agg.totals = {"tag_a": 4.0, "zeroed": 0.0}
        agg.sources = {"tag_a": "manual", "zeroed": "manual"}
        svg = oc_tags.render_svg(agg, {})
        hover = "".join(self._hover_groups(svg))
        self.assertNotIn("zeroed", hover)
        self.assertIn("tag_a", hover)
        self.assertEqual(len(self._hover_groups(svg)), 1)

    def test_hover_tooltip_respects_hide(self):
        agg = self._sample_agg()
        svg = oc_tags.render_svg(agg, {}, hide=frozenset({"tag_b"}))
        hover = "".join(self._hover_groups(svg))
        self.assertNotIn("tag_b", hover)
        self.assertIn("tag_a", hover)

    def test_hover_tooltip_stays_within_canvas(self):
        long_tag = "a-very-long-tag-name-that-would-overflow-the-right-edge"
        agg = oc_tags.Aggregate()
        agg.buckets = ["2026-09-08"]
        agg.series = {long_tag: {"2026-09-08": 3.0}}
        agg.totals = {long_tag: 3.0}
        agg.sources = {long_tag: "manual"}
        svg = oc_tags.render_svg(agg, {})
        root = ET.fromstring(svg)
        canvas_w = float(root.get("viewBox").split()[2])
        ns = "{http://www.w3.org/2000/svg}"
        found = 0
        for rect in root.iter(f"{ns}rect"):
            if rect.get("class") != "ttbg":
                continue
            found += 1
            x = float(rect.get("x")); w = float(rect.get("width"))
            self.assertGreaterEqual(x, 0.0)
            self.assertLessEqual(x + w, canvas_w)
        self.assertGreater(found, 0)


    def _hit_polys(self, svg):
        """(tag, [(x, y), ...]) per hover target, read from rendered output."""
        ns = "{http://www.w3.org/2000/svg}"
        root = ET.fromstring(svg)
        out = []
        for g in root.iter(f"{ns}g"):
            if g.get("class") != "hz":
                continue
            poly = g.find(f"{ns}polygon")
            tag = g.find(f"{ns}g").find(f"{ns}text").text
            pts = [tuple(map(float, s.split(","))) for s in poly.get("points").split()]
            out.append((tag, pts))
        return out

    def test_hit_shape_is_polygon_matching_painted_trapezoid(self):
        # A stacked area interpolates between buckets, so the painted segment is
        # a trapezoid. An axis-aligned rect named the wrong tag on 29.7% of
        # hoverable pixels of real data; the hit shape must be a polygon.
        agg = self._sample_agg()
        svg = oc_tags.render_svg(agg, {})
        self.assertNotIn('<rect class="hit"', svg)
        polys = self._hit_polys(svg)
        self.assertTrue(polys)
        for _tag, pts in polys:
            self.assertEqual(len(pts), 6, "expected a 6-point trapezoid hit shape")

    def test_hit_polygons_tile_adjacent_bands_without_overlap(self):
        # tag_b stacks directly on tag_a. At every shared x, tag_a's top edge
        # must equal tag_b's bottom edge -- exact tiling means no pixel can be
        # claimed by two bands, which is what removes the wrong-tag failure.
        agg = self._sample_agg()
        svg = oc_tags.render_svg(agg, {})
        by_tag = {}
        for tag, pts in self._hit_polys(svg):
            by_tag.setdefault(tag, []).append(pts)
        self.assertIn("tag_a", by_tag)
        self.assertIn("tag_b", by_tag)
        for a_pts, b_pts in zip(by_tag["tag_a"], by_tag["tag_b"]):
            # polygon order: (xl,tl) (sx,top) (xr,tr) (xr,br) (sx,bot) (xl,bl)
            a_top = [a_pts[0], a_pts[1], a_pts[2]]
            b_bot = [b_pts[5], b_pts[4], b_pts[3]]
            for (ax, ay), (bx, by) in zip(a_top, b_bot):
                self.assertAlmostEqual(ax, bx, places=1)
                self.assertAlmostEqual(ay, by, places=1)

    def test_hit_polygon_side_edges_sit_at_bucket_midpoint_value(self):
        # Steeply-changing band: the side edge must be the MEAN of the two
        # bucket boundaries, matching linear interpolation of the paint.
        agg = oc_tags.Aggregate()
        agg.buckets = ["d1", "d2", "d3"]
        agg.series = {"spike": {"d1": 1.0, "d2": 100.0, "d3": 1.0}}
        agg.totals = {"spike": 102.0}
        agg.sources = {"spike": "manual"}
        svg = oc_tags.render_svg(agg, {})
        polys = [p for t, p in self._hit_polys(svg) if t == "spike"]
        self.assertEqual(len(polys), 3)
        tops = [p[1][1] for p in polys]           # top y at each bucket centre
        mid_right_of_d1 = polys[0][2][1]          # d1's right edge top
        mid_left_of_d2 = polys[1][0][1]           # d2's left edge top
        self.assertAlmostEqual(mid_right_of_d1, (tops[0] + tops[1]) / 2, places=1)
        self.assertAlmostEqual(mid_left_of_d2, (tops[0] + tops[1]) / 2, places=1)
        self.assertAlmostEqual(mid_right_of_d1, mid_left_of_d2, places=1)

    def test_hover_layer_painted_after_legend(self):
        # The legend lives at x >= 825 and is drawn later in document order, so
        # a hover layer emitted before it would render UNDER it.
        agg = self._sample_agg()
        svg = oc_tags.render_svg(agg, {})
        hover_at = svg.index("<!-- hover -->")
        # Every legend swatch (x=825) and label (x=843) must precede the layer.
        self.assertGreater(hover_at, svg.rindex('x="825"'))
        self.assertGreater(hover_at, svg.rindex('x="843"'))
        # And nothing but hover groups may follow it.
        self.assertNotIn('x="843"', svg[hover_at:])

    def test_hit_declares_pointer_events_explicitly(self):
        # fill="transparent" works only because visiblePainted counts a painted
        # fill; state pointer-events outright so an editor switching to
        # fill="none" does not silently kill every tooltip.
        agg = self._sample_agg()
        svg = oc_tags.render_svg(agg, {})
        self.assertRegex(svg, r"\.hz\s+\.hit\s*\{[^}]*pointer-events\s*:\s*all")

    def test_right_edge_tooltip_flips_left_of_plot(self):
        # Clamping alone pushed right-edge tooltips into the legend column.
        agg = oc_tags.Aggregate()
        agg.buckets = ["d1", "d2"]
        agg.series = {"t": {"d1": 5.0, "d2": 5.0}}
        agg.totals = {"t": 10.0}
        agg.sources = {"t": "manual"}
        svg = oc_tags.render_svg(agg, {})
        ns = "{http://www.w3.org/2000/svg}"
        root = ET.fromstring(svg)
        boxes = [r for r in root.iter(f"{ns}rect") if r.get("class") == "ttbg"]
        self.assertTrue(boxes)
        for r in boxes:
            self.assertLessEqual(float(r.get("x")) + float(r.get("width")), 825.0)

    # --- dark mode (prefers-color-scheme, zero JS) ---

    def _css(self, svg):
        m = re.search(r"<style>(.*?)</style>", svg, re.S)
        self.assertIsNotNone(m, "no <style> block")
        return m.group(1)

    def _dark_block(self, svg):
        css = self._css(svg)
        m = re.search(r"@media\s*\(prefers-color-scheme:\s*dark\)\s*\{(.*)\}", css, re.S)
        self.assertIsNotNone(m, "no prefers-color-scheme: dark block")
        return m.group(1)

    def test_dark_mode_uses_media_query_not_a_param(self):
        # The theme follows the OS. Deliberately NOT a GET param.
        agg = self._sample_agg()
        svg = oc_tags.render_svg(agg, {})
        self.assertIn("prefers-color-scheme: dark", self._css(svg))
        self.assertNotIn("theme=", svg)

    def test_dark_mode_background_is_true_black(self):
        agg = self._sample_agg()
        dark = self._dark_block(oc_tags.render_svg(agg, {}))
        self.assertRegex(dark, r"\.bg\s*\{[^}]*fill\s*:\s*#000000")

    def test_chrome_colors_are_classed_not_hardcoded(self):
        # A media query cannot retheme a presentation attribute, so chrome must
        # carry classes. The background must not be a literal white fill.
        agg = self._sample_agg()
        svg = oc_tags.render_svg(agg, {})
        self.assertNotIn('fill="#ffffff"', svg)
        self.assertIn('class="bg"', svg)

    def test_dark_mode_keeps_auto_bands_recessive(self):
        # The saturation encoding must INVERT for dark. On white, auto bands are
        # pale so they recede. On black, pale would make the untagged backlog the
        # brightest thing on screen, inverting the hierarchy -- so in dark mode
        # auto must be DARKER than manual, not lighter.
        agg = self._sample_agg()   # tag_a = manual, tag_b = auto
        svg = oc_tags.render_svg(agg, {})
        css = self._css(svg)
        dark = self._dark_block(svg)
        light = css[: css.index("@media")]

        def lightness(block, cls):
            m = re.search(rf"\.{cls}\s*\{{[^}}]*fill\s*:\s*hsl\([^)]*?,\s*[\d.]+%,\s*([\d.]+)%\)", block)
            self.assertIsNotNone(m, f"no hsl fill for .{cls} in block")
            return float(m.group(1))

        man_l, auto_l = lightness(light, "b0"), lightness(light, "b1")
        man_d, auto_d = lightness(dark, "b0"), lightness(dark, "b1")
        self.assertGreater(auto_l, man_l, "on white, auto should be paler than manual")
        self.assertLess(auto_d, man_d, "on black, auto must be DARKER than manual")

    def test_dark_mode_hover_highlight_flips_to_light(self):
        # A black highlight is invisible on a black background.
        agg = self._sample_agg()
        dark = self._dark_block(oc_tags.render_svg(agg, {}))
        self.assertRegex(dark, r"\.hz:hover\s+\.hit\s*\{[^}]*fill\s*:\s*#f|\.hz:hover\s+\.hit\s*\{[^}]*fill\s*:\s*#ffffff")

    def test_dark_mode_tooltip_stays_distinct_from_background(self):
        # The tooltip is near-black by default; on a true-black page it would
        # vanish, so dark mode must lift it and/or give it a border.
        agg = self._sample_agg()
        dark = self._dark_block(oc_tags.render_svg(agg, {}))
        m = re.search(r"\.ttbg\s*\{([^}]*)\}", dark)
        self.assertIsNotNone(m, "dark mode does not restyle .ttbg")
        body = m.group(1)
        self.assertNotIn("#000000", body)
        self.assertRegex(body, r"stroke\s*:", "tooltip needs a border to separate it from black")

    def test_no_data_svg_is_themed_too(self):
        svg = oc_tags.render_svg(oc_tags.Aggregate(), {})
        self.assertIn("No data", svg)
        self.assertIn("prefers-color-scheme: dark", svg)
        self.assertNotIn('fill="#ffffff"', svg)

    def test_dark_mode_adds_no_javascript(self):
        agg = self._sample_agg()
        svg = oc_tags.render_svg(agg, {})
        self.assertNotIn("<script", svg.lower())
        self.assertIsNone(re.search(r"\bon[a-z]+\s*=", svg, re.I))

class TestServer(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.db = str(Path(self.tmp.name) / "opencode.db")
        self.tags_db = str(Path(self.tmp.name) / "tags.db")

        conn = sqlite3.connect(self.db)
        conn.execute("CREATE TABLE session (id TEXT PRIMARY KEY, parent_id TEXT, directory TEXT, title TEXT, time_created INTEGER, time_updated INTEGER)")
        conn.execute("CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, data TEXT)")
        t = 1788874200000
        conn.execute("INSERT INTO session VALUES ('s1', NULL, '/home/dev/projects/repo', 'Title 1', 0, 0)")
        data = {"role": "assistant", "cost": 5.0, "modelID": "model", "tokens": {"input": 1, "output": 1}}
        conn.execute("INSERT INTO message VALUES ('m1', 's1', ?, ?)", (t, json.dumps(data)))
        conn.commit()
        conn.close()

    def tearDown(self):
        self.tmp.cleanup()

    def test_healthz_returns_200_ok(self):
        status, ctype, body = oc_tags.handle_request("/healthz", "")
        self.assertEqual(status, 200)
        self.assertIn("text/plain", ctype)
        self.assertEqual(body.strip(), "ok")

    def test_unknown_path_returns_404(self):
        status, ctype, body = oc_tags.handle_request("/nope", "")
        self.assertEqual(status, 404)

    def test_bad_days_returns_400(self):
        status, ctype, body = oc_tags.handle_request("/", "days=banana", db_path=self.db, tags_db=self.tags_db)
        self.assertEqual(status, 400)
        status, ctype, body = oc_tags.handle_request("/", "days=-5", db_path=self.db, tags_db=self.tags_db)
        self.assertEqual(status, 400)

    def test_root_returns_200_svg(self):
        status, ctype, body = oc_tags.handle_request("/", "days=7", db_path=self.db, tags_db=self.tags_db)
        self.assertEqual(status, 200)
        self.assertIn("image/svg+xml", ctype)
        self.assertTrue(body.strip().startswith("<svg"))

    def test_days_1_selects_hourly_bucketing(self):
        status, ctype, body = oc_tags.handle_request("/", "days=1", db_path=self.db, tags_db=self.tags_db)
        self.assertEqual(status, 200)
        # An hour bucket, not a day bucket: the axis label carries the hour.
        # Assert the label itself -- a bare "T" is also absent from the
        # "No data in window" placeholder, so it cannot tell an hourly chart
        # from an empty one.
        self.assertIn("09-08T09", body)
        self.assertNotIn("No data in window", body)

    def test_hide_param_filtered(self):
        # Tag session
        with oc_tags.open_store(self.tags_db) as st:
            oc_tags.set_session_tag(st, "s1", "tag_x")
        status, ctype, body = oc_tags.handle_request("/", "days=7&hide=tag_x", db_path=self.db, tags_db=self.tags_db)
        self.assertEqual(status, 200)
        self.assertNotIn("tag_x", body)

    def test_database_locked_returns_503(self):
        from unittest import mock
        with mock.patch("oc_tags.load_aggregate", side_effect=sqlite3.OperationalError("database is locked")):
            status, ctype, body = oc_tags.handle_request("/", "days=7", db_path=self.db, tags_db=self.tags_db)
            self.assertEqual(status, 503)
            self.assertIn("database is locked", body)




# Without this guard, `python3 test_oc_tags.py` imports the module, defines
# every test, runs NONE, prints nothing and exits 0 -- the exact failure mode
# documented at the bottom of pkgs/oc-cost/test_oc_cost.py. The flake check
# runs this file directly, so the guard is what makes the check able to fail.
if __name__ == "__main__":
    unittest.main()
