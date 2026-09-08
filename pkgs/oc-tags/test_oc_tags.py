"""Tests for oc-tags. Run: python3 pkgs/oc-tags/test_oc_tags.py"""

from __future__ import annotations

import contextlib
import io
import json
import os
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path

# Allow `import oc_tags` when running from repo root or anywhere else.
sys.path.insert(0, str(Path(__file__).resolve().parent))

import oc_tags  # noqa: E402


class TestParseArgs(unittest.TestCase):
    def test_report_defaults(self):
        args = oc_tags.parse_args(["report"])
        self.assertEqual(args.command, "report")
        self.assertEqual(args.days, 14)


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




# Without this guard, `python3 test_oc_tags.py` imports the module, defines
# every test, runs NONE, prints nothing and exits 0 -- the exact failure mode
# documented at the bottom of pkgs/oc-cost/test_oc_cost.py. The flake check
# runs this file directly, so the guard is what makes the check able to fail.
if __name__ == "__main__":
    unittest.main()
