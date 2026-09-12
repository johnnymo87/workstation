"""Tests for oc-tags. Run: python3 pkgs/oc-tags/test_oc_tags.py"""

from __future__ import annotations

import argparse
import contextlib
import io
import json
import os
import re
import sqlite3
import sys
import tempfile
import unittest
import unittest.mock
import xml.etree.ElementTree as ET
from unittest import mock
from pathlib import Path

# Allow `import oc_tags` when running from repo root or anywhere else.
sys.path.insert(0, str(Path(__file__).resolve().parent))

# Redirect HOME to a throwaway dir BEFORE importing oc_tags, because
# DEFAULT_TAGS_DB / DEFAULT_OPENCODE_DB are `os.path.expanduser` results
# computed at import time. Without this, any test that reaches a default path
# -- by regression, or simply by someone forgetting to pass --tags-db to a new
# main() test -- writes into the developer's REAL
# ~/.local/share/oc-tags/tags.db and reports nothing amiss.
#
# That is not hypothetical: the suite for the workstation-ueaf fix
# (`--tags-db` before the subcommand being silently discarded) did exactly this
# on its first, correctly-failing run, and a row had to be removed from the
# production DB by hand. A test that detects a data-integrity bug by causing it
# is only half a test.
#
# flake.nix's oc-tags-tests check already exports HOME="$TMPDIR", so this only
# closes the gap for a suite run directly (`python3 test_oc_tags.py`), which is
# how it is run while developing -- i.e. exactly when the code is most likely
# to be wrong.
_HOME_SANDBOX = tempfile.TemporaryDirectory(prefix="oc-tags-test-home-")
os.environ["HOME"] = _HOME_SANDBOX.name

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


class TestGlobalDbFlagsBeforeSubcommand(unittest.TestCase):
    """`--tags-db X set ...` must not be silently discarded (workstation-ueaf).

    Every subparser re-declares --db/--tags-db. argparse applies a subparser's
    default over whatever the parent already parsed, so the pre-subcommand form
    used to lose the value and fall back to the REAL ~/.local/share paths --
    while printing success. That is the worst shape a bug can have: someone
    isolating a test run silently writes to the production tag DB and is told
    it worked. (Found by adversarial review of PR #491; reproduced on cloudbox
    by tagging into /tmp/probe.db and finding the row in the real tags.db.)

    Both orders must work, for every subcommand that takes these flags.
    """

    SUBCOMMAND_ARGV = {
        "set": ["mytag", "ses_x"],
        "ls": [],
        "rm": ["ses_x"],
        "report": [],
        "top": [],
        "serve": [],
    }

    def test_before_subcommand_is_honoured(self):
        for cmd, rest in self.SUBCOMMAND_ARGV.items():
            with self.subTest(command=cmd):
                args = oc_tags.parse_args(
                    ["--tags-db", "/tmp/t.db", "--db", "/tmp/o.db", cmd, *rest]
                )
                self.assertEqual(args.tags_db, "/tmp/t.db")
                self.assertEqual(args.db, "/tmp/o.db")

    def test_after_subcommand_still_works(self):
        # The form that always worked must keep working -- this is the half a
        # naive "just delete the duplicated options" fix would break.
        for cmd, rest in self.SUBCOMMAND_ARGV.items():
            with self.subTest(command=cmd):
                args = oc_tags.parse_args(
                    [cmd, "--tags-db", "/tmp/t.db", "--db", "/tmp/o.db", *rest]
                )
                self.assertEqual(args.tags_db, "/tmp/t.db")
                self.assertEqual(args.db, "/tmp/o.db")

    def test_after_subcommand_wins_over_before(self):
        # Ordinary argparse last-wins. Stated as a test so the behaviour is
        # deliberate rather than incidental.
        args = oc_tags.parse_args(
            ["--tags-db", "/tmp/first.db", "set", "--tags-db", "/tmp/second.db", "mytag", "ses_x"]
        )
        self.assertEqual(args.tags_db, "/tmp/second.db")

    def test_defaults_survive_when_neither_is_passed(self):
        for cmd, rest in self.SUBCOMMAND_ARGV.items():
            with self.subTest(command=cmd):
                args = oc_tags.parse_args([cmd, *rest])
                self.assertEqual(args.tags_db, oc_tags.DEFAULT_TAGS_DB)
                self.assertEqual(args.db, oc_tags.DEFAULT_OPENCODE_DB)

    def test_writes_land_in_the_named_db_not_the_default(self):
        # The parse-level assertions above are necessary but not sufficient:
        # this is the end-to-end shape the bug actually took.
        #
        # Both halves are load-bearing, and the second one is the one that was
        # missing. "The named file was written" catches a regression, but it
        # does not say WHERE a regression would write instead -- and the honest
        # answer is DEFAULT_TAGS_DB, i.e. the developer's real tag database.
        # So point that default at a decoy inside the tempdir and assert the
        # decoy stays absent. The test then proves "wrote here AND nowhere
        # else", and a regression damages a throwaway file rather than
        # production data.
        #
        # Patching the module attribute works because build_parser() reads
        # DEFAULT_TAGS_DB at call time, not at import time.
        with tempfile.TemporaryDirectory() as td:
            tags_db = os.path.join(td, "isolated.db")
            opencode_db = os.path.join(td, "absent-opencode.db")
            decoy = os.path.join(td, "decoy-default-tags.db")
            with mock.patch.object(oc_tags, "DEFAULT_TAGS_DB", decoy):
                with contextlib.redirect_stdout(io.StringIO()):
                    rc = oc_tags.main(
                        ["--tags-db", tags_db, "--db", opencode_db, "set", "isolation-probe", "ses_probe"]
                    )
            self.assertEqual(rc, 0)
            self.assertTrue(
                os.path.exists(tags_db),
                "write went somewhere other than --tags-db (this is the bug)",
            )
            self.assertFalse(
                os.path.exists(decoy),
                "write fell back to the DEFAULT tags.db -- in production that is the "
                "developer's real ~/.local/share/oc-tags/tags.db",
            )
            with oc_tags.open_store(tags_db, readonly=True) as conn:
                self.assertEqual(oc_tags.session_tags(conn).get("ses_probe"), "isolation-probe")

    def test_subcommand_roster_is_complete(self):
        # The tests above loop over SUBCOMMAND_ARGV, and a loop asserts nothing
        # about entries it does not contain: drop a subcommand from that dict
        # (or add one to the parser without adding it here) and the suite stays
        # green while covering less. Pin the roster to the parser itself.
        #
        # This reaches into argparse's private _SubParsersAction. That is a
        # deliberate trade: if the private shape ever changes, this test ERRORS
        # loudly on the next run, which is strictly better than the silent
        # coverage loss it exists to prevent.
        sub_actions = [
            a for a in oc_tags.build_parser()._actions
            if isinstance(a, argparse._SubParsersAction)
        ]
        self.assertEqual(len(sub_actions), 1, "expected exactly one subparser group")
        self.assertEqual(
            set(self.SUBCOMMAND_ARGV),
            set(sub_actions[0].choices),
            "SUBCOMMAND_ARGV has drifted from the parser's actual subcommands",
        )


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


    def _hit_rects(self, svg):
        """(tag, x, y, w, h) per hover target, read from rendered output."""
        ns = "{http://www.w3.org/2000/svg}"
        root = ET.fromstring(svg)
        out = []
        for g in root.iter(f"{ns}g"):
            if g.get("class") != "hz":
                continue
            r = g.find(f"{ns}rect")
            tag = g.find(f"{ns}g").find(f"{ns}text").text
            out.append((tag, float(r.get("x")), float(r.get("y")),
                        float(r.get("width")), float(r.get("height"))))
        return out

    def _bar_rects(self, svg):
        """(class, x, y, w, h) for painted band segments (not hover, not legend)."""
        ns = "{http://www.w3.org/2000/svg}"
        root = ET.fromstring(svg)
        out = []
        for r in root.iter(f"{ns}rect"):
            cls = r.get("class") or ""
            if not re.fullmatch(r"b\d+", cls):
                continue
            if float(r.get("x")) >= 825.0:          # legend swatch column
                continue
            out.append((cls, float(r.get("x")), float(r.get("y")),
                        float(r.get("width")), float(r.get("height"))))
        return out




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
        # A long tag on the LAST bucket is what forces the flip -- with a short
        # tag and few buckets the tooltip fits to the right and this test
        # silently stops exercising the flip at all.
        long_tag = "a-tag-long-enough-to-force-the-tooltip-to-flip"
        agg = oc_tags.Aggregate()
        agg.buckets = [f"d{i}" for i in range(8)]
        agg.series = {long_tag: {b: 5.0 for b in agg.buckets}}
        agg.totals = {long_tag: 40.0}
        agg.sources = {long_tag: "manual"}
        svg = oc_tags.render_svg(agg, {})
        ns = "{http://www.w3.org/2000/svg}"
        root = ET.fromstring(svg)
        boxes = [r for r in root.iter(f"{ns}rect") if r.get("class") == "ttbg"]
        hits = [r for r in root.iter(f"{ns}rect") if r.get("class") == "hit"]
        self.assertEqual(len(boxes), 8)
        for r in boxes:
            self.assertLessEqual(float(r.get("x")) + float(r.get("width")), 825.0)
        # The last bar's tooltip must actually be left of its bar.
        last_hit = max(hits, key=lambda r: float(r.get("x")))
        last_box = max(boxes, key=lambda r: float(r.get("x")))
        self.assertLess(
            float(last_box.get("x")), float(last_hit.get("x")),
            "right-edge tooltip did not flip left",
        )

    # --- dark mode (prefers-color-scheme, zero JS) ---

    def _css(self, svg):
        m = re.search(r"<style>(.*?)</style>", svg, re.S)
        self.assertIsNotNone(m, "no <style> block")
        return m.group(1)

    def _dark_block(self, svg):
        css = self._css(svg)
        m = re.search(
            r"@media\s*\(prefers-color-scheme:\s*dark\)\s*\{(.*?)\n    \}", css, re.S
        )
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
        # No hardcoded colour may survive as a presentation attribute at all,
        # since a @media rule cannot reach one.
        self.assertIsNone(
            re.search(r'(fill|stroke)="#[0-9a-fA-F]{3,6}"', svg),
            "a hardcoded colour attribute escaped the class refactor",
        )

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
        # Bounds too: the inversion alone would accept hsl(h,30%,1%) vs
        # hsl(h,80%,99%), which inverts correctly and is unreadable.
        self.assertTrue(25 <= auto_d <= 40, f"dark auto lightness {auto_d}% out of range")
        self.assertTrue(50 <= man_d <= 65, f"dark manual lightness {man_d}% out of range")

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

    def test_root_background_covers_letterbox_in_both_themes(self):
        # Standalone SVG: preserveAspectRatio letterboxes when the viewport
        # aspect differs from the viewBox, and everything below the fixed
        # height is canvas too. Only the ROOT element's background paints the
        # canvas -- the .bg rect stops at the viewBox. Without this, dark mode
        # renders a black chart framed by white. No other test catches it.
        svg = oc_tags.render_svg(self._sample_agg(), {})
        css = self._css(svg)
        light = css[: css.index("@media")]
        self.assertRegex(light, r"svg:root\s*\{[^}]*background\s*:\s*#ffffff")
        self.assertRegex(self._dark_block(svg), r"svg:root\s*\{[^}]*background\s*:\s*#000000")
        # `:root` alone would repaint a host HTML page if this SVG is inlined.
        self.assertNotRegex(css, r"(?<!svg):root\s*\{")

    def test_no_data_svg_also_paints_the_canvas(self):
        svg = oc_tags.render_svg(oc_tags.Aggregate(), {})
        self.assertRegex(self._dark_block(svg), r"svg:root\s*\{[^}]*background\s*:\s*#000000")

    # --- discrete bars, one per bucket ---

    def test_bands_render_as_bars_not_interpolated_areas(self):
        # A stacked area interpolates between buckets, drawing values that
        # never existed. Daily totals are discrete; bars say only what is true.
        agg = self._sample_agg()
        svg = oc_tags.render_svg(agg, {})
        self.assertNotIn("<path", svg)
        self.assertNotIn("<polyline", svg)
        self.assertEqual(len(self._bar_rects(svg)), 4)   # 2 bands x 2 buckets

    def test_bars_sit_inside_the_plot_and_do_not_overhang_edges(self):
        # Bucket centres used to be spread over M-1 gaps, putting the first and
        # last ON the axis edges -- as bars they would hang half off the plot.
        agg = self._sample_agg()
        svg = oc_tags.render_svg(agg, {})
        for _cls, x, _y, w, _h in self._bar_rects(svg):
            self.assertGreaterEqual(round(x, 3), 90.0)
            self.assertLessEqual(round(x + w, 3), 800.0)

    def test_bars_in_same_bucket_share_x_and_stack_without_gaps(self):
        agg = self._sample_agg()
        svg = oc_tags.render_svg(agg, {})
        by_x = {}
        for cls, x, y, w, h in self._bar_rects(svg):
            by_x.setdefault(round(x, 3), []).append((y, h, cls))
        self.assertEqual(len(by_x), 2)                    # two buckets
        for _x, segs in by_x.items():
            segs.sort()
            for (y1, h1, _c1), (y2, _h2, _c2) in zip(segs, segs[1:]):
                self.assertAlmostEqual(y1 + h1, y2, places=1)   # flush stack

    def test_bars_are_separated_by_a_gap(self):
        agg = self._sample_agg()
        svg = oc_tags.render_svg(agg, {})
        xs = sorted({round(x, 3) for _c, x, _y, _w, _h in self._bar_rects(svg)})
        w = self._bar_rects(svg)[0][3]
        self.assertGreater(xs[1] - xs[0], w, "bars should not touch")

    def test_hover_target_is_the_bar_itself(self):
        # The trapezoid hit-polygon existed only because the painted region was
        # not a rectangle. With bars it is, so the hit shape is exact.
        agg = self._sample_agg()
        svg = oc_tags.render_svg(agg, {})
        bars = {(round(x, 1), round(y, 1), round(w, 1), round(h, 1))
                for _c, x, y, w, h in self._bar_rects(svg)}
        for _tag, x, y, w, h in self._hit_rects(svg):
            self.assertIn((round(x, 1), round(y, 1), round(w, 1), round(h, 1)), bars)

    def test_metered_renders_as_per_bar_ticks_not_a_connected_line(self):
        # Same interpolation critique as the bands: no fabricated slope.
        agg = self._sample_agg()
        svg = oc_tags.render_svg(agg, {"2026-09-07": 12.0, "2026-09-08": 30.0})
        self.assertNotIn("<polyline", svg)
        ns = "{http://www.w3.org/2000/svg}"
        ticks = [l for l in ET.fromstring(svg).iter(f"{ns}line")
                 if (l.get("class") or "") == "met"]   # legend swatch is "met metsw"
        self.assertEqual(len(ticks), 2)
        for l in ticks:
            self.assertAlmostEqual(float(l.get("y1")), float(l.get("y2")), places=3)

    def test_metered_tick_omitted_for_buckets_with_no_metered_value(self):
        agg = self._sample_agg()
        svg = oc_tags.render_svg(agg, {"2026-09-08": 30.0})
        ns = "{http://www.w3.org/2000/svg}"
        ticks = [l for l in ET.fromstring(svg).iter(f"{ns}line")
                 if (l.get("class") or "") == "met"]
        self.assertEqual(len(ticks), 1)

    def test_partial_bucket_hatches_only_its_own_bar(self):
        agg = self._sample_agg()
        agg.partial_bucket = "2026-09-08"
        svg = oc_tags.render_svg(agg, {})
        ns = "{http://www.w3.org/2000/svg}"
        hatch = [r for r in ET.fromstring(svg).iter(f"{ns}rect")
                 if (r.get("fill") or "") == "url(#hatch)"]
        self.assertEqual(len(hatch), 1)
        hx, hw = float(hatch[0].get("x")), float(hatch[0].get("width"))
        last_x = max(round(x, 3) for _c, x, _y, _w, _h in self._bar_rects(svg))
        bar_w = self._bar_rects(svg)[0][3]
        self.assertAlmostEqual(hx, last_x, places=1)
        self.assertAlmostEqual(hw, bar_w, places=1)

    def test_single_bucket_still_renders_one_bar(self):
        agg = oc_tags.Aggregate()
        agg.buckets = ["2026-09-08"]
        agg.series = {"solo": {"2026-09-08": 9.0}}
        agg.totals = {"solo": 9.0}
        agg.sources = {"solo": "manual"}
        svg = oc_tags.render_svg(agg, {})
        self.assertEqual(len(self._bar_rects(svg)), 1)
        self.assertIsNotNone(ET.fromstring(svg))

    def test_many_buckets_still_fit(self):
        agg = oc_tags.Aggregate()
        agg.buckets = [f"h{i:02d}" for i in range(24)]
        agg.series = {"t": {b: 1.0 for b in agg.buckets}}
        agg.totals = {"t": 24.0}
        agg.sources = {"t": "manual"}
        svg = oc_tags.render_svg(agg, {})
        bars = self._bar_rects(svg)
        self.assertEqual(len(bars), 24)
        for _c, x, _y, w, _h in bars:
            self.assertGreater(w, 1.0)
            self.assertLessEqual(round(x + w, 3), 800.0)

    def test_metered_ticks_do_not_overlap_into_a_continuous_line(self):
        # bar_w/2 + 3 exceeds slot/2 once slot < 27.3px (30 daily buckets),
        # and overlapping ticks fuse into exactly the connected line that
        # switching to bars was meant to remove.
        agg = oc_tags.Aggregate()
        agg.buckets = [f"d{i:02d}" for i in range(31)]
        agg.series = {"t": {b: 1.0 for b in agg.buckets}}
        agg.totals = {"t": 31.0}
        agg.sources = {"t": "manual"}
        svg = oc_tags.render_svg(agg, {b: 2.0 for b in agg.buckets})
        ns = "{http://www.w3.org/2000/svg}"
        ticks = sorted(
            (float(l.get("x1")), float(l.get("x2")))
            for l in ET.fromstring(svg).iter(f"{ns}line")
            if (l.get("class") or "") == "met"
        )
        self.assertEqual(len(ticks), 31)
        for (_x1, x2), (nx1, _nx2) in zip(ticks, ticks[1:]):
            self.assertLess(x2, nx1, "metered ticks overlap into a continuous line")

    def test_hit_stroke_only_widens_segments_too_thin_to_hover(self):
        # A stroke is centred on the edge, so on a normal segment it pushes the
        # hit region into the neighbouring band; groups are emitted bottom-to-
        # top, so the band above wins. Only hairline segments may carry it.
        agg = self._sample_agg()
        svg = oc_tags.render_svg(agg, {})
        ns = "{http://www.w3.org/2000/svg}"
        for r in ET.fromstring(svg).iter(f"{ns}rect"):
            if r.get("class") != "hit":
                continue
            h = float(r.get("height"))
            sw = float(r.get("stroke-width") or 0)
            if h >= 4.0:
                self.assertEqual(sw, 0.0, "thick segment must not bleed into its neighbour")
            else:
                self.assertGreater(sw, 0.0, "hairline segment must stay grabbable")

    def test_bar_height_is_proportional_to_value(self):
        # Nothing previously pinned a bar's height to its dollars.
        agg = oc_tags.Aggregate()
        agg.buckets = ["d1"]
        agg.series = {"solo": {"d1": 10.0}}
        agg.totals = {"solo": 10.0}
        agg.sources = {"solo": "manual"}
        svg = oc_tags.render_svg(agg, {})
        (_cls, _x, y, _w, h) = self._bar_rects(svg)[0]
        self.assertAlmostEqual(y, 65.0, places=1)      # full height => plot top
        self.assertAlmostEqual(h, 460.0, places=1)     # full plot height

    def test_bands_paint_bottom_up_in_total_order(self):
        # b0 is the largest band and must sit at the BOTTOM of the stack.
        agg = self._sample_agg()
        svg = oc_tags.render_svg(agg, {})
        col = sorted(self._bar_rects(svg), key=lambda r: (round(r[1], 3), r[2]))
        first_bucket = [r for r in col if round(r[1], 3) == round(col[0][1], 3)]
        classes_top_down = [r[0] for r in first_bucket]
        self.assertEqual(classes_top_down, ["b1", "b0"], "stack order inverted")

    def test_every_painted_bar_has_a_hover_target(self):
        agg = self._sample_agg()
        svg = oc_tags.render_svg(agg, {})
        self.assertEqual(len(self._hit_rects(svg)), len(self._bar_rects(svg)))
        self.assertGreater(len(self._hit_rects(svg)), 0)

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



class TestChartBucketCap(unittest.TestCase):
    """The chart refuses windows it cannot draw legibly (workstation-9e7j).

    plot_w is a fixed 710px and bar_w = (710/M) * 0.78, so M=184 is the last
    count with a >=3px bar. Past that, stacked segments start rendering
    height="0.0" -- invisible AND excluded from hit-testing, so the dollars
    become unreachable rather than merely small.
    """

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.db = str(Path(self.tmp.name) / "opencode.db")
        self.tags_db = str(Path(self.tmp.name) / "tags.db")
        conn = sqlite3.connect(self.db)
        conn.execute("CREATE TABLE session (id TEXT PRIMARY KEY, parent_id TEXT, directory TEXT, title TEXT, time_created INTEGER, time_updated INTEGER)")
        conn.execute("CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, data TEXT)")
        conn.execute("INSERT INTO session VALUES ('s1', NULL, '/home/dev/projects/repo', 'T', 0, 0)")
        conn.execute(
            "INSERT INTO message VALUES ('m1', 's1', ?, ?)",
            (1788874200000, json.dumps({"role": "assistant", "cost": 5.0, "modelID": "m", "tokens": {"input": 1, "output": 1}})),
        )
        conn.commit()
        conn.close()

    def tearDown(self):
        self.tmp.cleanup()

    def _get(self, qs):
        return oc_tags.handle_request(
            "/", qs, db_path=self.db, tags_db=self.tags_db, now_ms=1788874200000
        )

    def test_bucket_count_formula_counts_the_trailing_day(self):
        # days=N spans N+1 calendar days (since=today-N, until=tomorrow).
        self.assertEqual(oc_tags.chart_bucket_count(1, "hour"), 48)
        self.assertEqual(oc_tags.chart_bucket_count(7, "day"), 8)
        self.assertEqual(oc_tags.chart_bucket_count(30, "hour"), 744)

    def test_daily_boundary_183_ok_184_rejected(self):
        self.assertEqual(self._get("days=183")[0], 200)
        self.assertEqual(self._get("days=184")[0], 400)

    def test_hourly_boundary_6_ok_7_rejected(self):
        self.assertEqual(self._get("days=6&bucket=hour")[0], 200)
        self.assertEqual(self._get("days=7&bucket=hour")[0], 400)

    def test_rejection_names_the_limit_and_a_concrete_fix(self):
        status, ctype, body = self._get("days=30&bucket=hour")
        self.assertEqual(status, 400)
        self.assertIn("744", body)   # what they asked for
        self.assertIn("184", body)   # the limit
        self.assertIn("days=6", body)          # how to keep hourly
        self.assertIn("bucket=day", body)      # how to keep the window
        # Under-reporting must be LOUD: say WHY, not just "invalid".
        self.assertIn("unhoverable", body)

    def test_explicit_hourly_is_never_silently_coarsened(self):
        # Absent a bucket param choose_bucket() already picks 'day', so this
        # path is reachable only when the caller EXPLICITLY typed bucket=hour.
        # Serving them day buckets under a 200 would discard the one parameter
        # they overrode -- the substitution least worth making silently.
        status, ctype, body = self._get("days=30&bucket=hour")
        self.assertEqual(status, 400)
        self.assertNotIn("<svg", body)

    def test_cap_is_enforced_before_the_database_is_touched(self):
        # A 365-day scan costs ~6.6s against the real 9GB message table, so the
        # rejection has to precede the query rather than merely discard its
        # result. Proven directly: make load_aggregate fatal, then show the
        # capped request still answers while an in-range one reaches it.
        calls = []

        def exploding(*a, **kw):
            calls.append(kw.get("days"))
            raise AssertionError("load_aggregate must not run for a capped request")

        with unittest.mock.patch.object(oc_tags, "load_aggregate", exploding):
            status, _, _ = self._get("days=365")
            self.assertEqual(status, 400)
            self.assertEqual(calls, [])
            # The patch is live, so an in-range request DOES reach it. Without
            # this the test would pass even if handle_request stopped calling
            # load_aggregate altogether.
            with self.assertRaises(AssertionError):
                self._get("days=7")
            self.assertEqual(calls, [7])

    def test_cli_aggregate_is_not_subject_to_the_chart_cap(self):
        # `oc-tags report --days 365` shares load_aggregate() but renders no
        # bars, so the geometry limit must not reach it.
        agg = oc_tags.load_aggregate(
            db_path=self.db, tags_db=self.tags_db, days=365, now_ms=1788874200000
        )
        self.assertGreater(len(agg.buckets), 184)


class TestWindowDerivedBuckets(unittest.TestCase):
    """Buckets come from the window, not from observed rows (workstation-6f0c).

    Deriving them from rows DELETED empty buckets: days=1 hourly drew 19
    contiguous bars for a 48-hour window with labels jumping 05 -> 08 -> 10.
    The area chart lied by interpolating across a gap; bars lied by removing
    it, which misleads about WHEN as well as HOW MUCH.
    """

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.db = str(Path(self.tmp.name) / "opencode.db")
        conn = sqlite3.connect(self.db)
        conn.execute("CREATE TABLE session (id TEXT PRIMARY KEY, parent_id TEXT, directory TEXT, title TEXT, time_created INTEGER, time_updated INTEGER)")
        conn.execute("CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, data TEXT)")
        conn.execute("INSERT INTO session VALUES ('s1', NULL, '/home/dev/projects/repo', 'T', 0, 0)")
        self.now = 1788874200000  # 2026-09-08 09:30 ET
        # Rows at 05, 08 and 09 -- UNEVEN gaps on purpose. With evenly spaced
        # rows the label-spacing test cannot fail: two data points yield one
        # interval, and a set of one element is trivially uniform.
        for i, off in enumerate((-4 * 3600 * 1000, -1 * 3600 * 1000, 0)):
            conn.execute(
                "INSERT INTO message VALUES (?, 's1', ?, ?)",
                (f"m{i}", self.now + off, json.dumps({"role": "assistant", "cost": 2.0, "modelID": "m", "tokens": {"input": 1, "output": 1}})),
            )
        conn.commit()
        conn.close()

    def tearDown(self):
        self.tmp.cleanup()

    def _agg(self, since_off_h, until_off_h, bucket="hour", now=None):
        return oc_tags.aggregate(
            self.db,
            since_ms=self.now + since_off_h * 3600 * 1000,
            until_ms=self.now + until_off_h * 3600 * 1000,
            bucket=bucket,
            session_tags={},
            dir_tags={},
            now_ms=self.now if now is None else now,
        )

    def test_empty_hours_between_data_are_kept_as_buckets(self):
        agg = self._agg(-5, 1)
        # Window is 04:30 -> 10:30, clamped to now (09:30). The bucket holding
        # since_ms counts: a row at 04:45 is inside the window and belongs to
        # hour 04, so omitting it would drop a slot that can hold data.
        # Data exists only in 05 and 09; 06/07/08 are the empties under test.
        self.assertEqual(
            agg.buckets,
            ["2026-09-08T04", "2026-09-08T05", "2026-09-08T06",
             "2026-09-08T07", "2026-09-08T08", "2026-09-08T09"],
        )

    def test_buckets_are_contiguous_in_time(self):
        agg = self._agg(-8, 1)
        hours = [int(b[-2:]) for b in agg.buckets]
        self.assertEqual(hours, list(range(hours[0], hours[0] + len(hours))))

    def test_no_buckets_are_drawn_beyond_now(self):
        # calculate_window ends at tomorrow 00:00, so without a clamp an hourly
        # view would draw a dozen empty FUTURE hours.
        agg = oc_tags.load_aggregate(db_path=self.db, tags_db="/nonexistent", days=1, now_ms=self.now)
        self.assertEqual(agg.buckets[-1], "2026-09-08T09")

    def test_clamping_to_now_keeps_the_partial_bucket_detectable(self):
        # The clamp is what makes the newest bucket the CURRENT one, which is
        # what partial-bucket detection depends on. Without it the newest
        # bucket would be 23:00 and an in-flight turn would go unlabelled.
        agg = oc_tags.load_aggregate(db_path=self.db, tags_db="/nonexistent", days=1, now_ms=self.now)
        self.assertEqual(agg.partial_bucket, "2026-09-08T09")

    def test_observed_data_is_never_dropped_off_the_axis(self):
        # A row timestamped ahead of now (clock skew between concurrent serves)
        # must still get a slot, or its dollars would count in the legend total
        # while appearing in no bar.
        conn = sqlite3.connect(self.db)
        conn.execute(
            "INSERT INTO message VALUES ('future', 's1', ?, ?)",
            (self.now + 6 * 3600 * 1000, json.dumps({"role": "assistant", "cost": 3.0, "modelID": "m", "tokens": {"input": 1, "output": 1}})),
        )
        conn.commit()
        conn.close()
        agg = self._agg(-2, 8)
        self.assertIn("2026-09-08T15", agg.buckets)
        # ...and the hours between now and that row must be filled in, not
        # skipped. Unioning the stray key onto a now-clamped range produced
        # [T07, T08, T09, T15]: data preserved, axis broken -- the same defect
        # in the code written to prevent the other one.
        hours = [int(b[-2:]) for b in agg.buckets]
        self.assertEqual(hours, list(range(hours[0], hours[0] + len(hours))))

    def test_partial_bucket_survives_a_later_bucket_being_appended(self):
        # Detection is membership, not "is the newest bucket". The union above
        # can append a clock-skewed bucket AFTER the current one, and the
        # in-flight bucket must still be labelled partial -- otherwise one
        # skewed row silently removes the under-reporting warning from a bar
        # that is genuinely still filling.
        conn = sqlite3.connect(self.db)
        conn.execute(
            "INSERT INTO message VALUES ('future', 's1', ?, ?)",
            (self.now + 6 * 3600 * 1000, json.dumps({"role": "assistant", "cost": 3.0, "modelID": "m", "tokens": {"input": 1, "output": 1}})),
        )
        conn.commit()
        conn.close()
        agg = self._agg(-2, 8)
        self.assertGreater(agg.buckets[-1], "2026-09-08T09")  # a later bucket exists
        self.assertEqual(agg.partial_bucket, "2026-09-08T09")  # yet 09 is still partial

    def test_empty_bucket_occupies_a_slot_rather_than_collapsing(self):
        # The geometric point of the fix: with 5 buckets the bars sit at 1/10
        # and 9/10 of the plot, not shoulder to shoulder in the middle.
        agg = self._agg(-5, 1)
        svg = oc_tags.render_svg(agg, oc_tags.CfpSpend())
        # Confine to the plot: the legend draws its swatches with the same
        # band classes, at x=825. Without this bound the match count is 3 and
        # the assertion measures the legend rather than the chart.
        xs = sorted(
            x for x in (float(m) for m in re.findall(r'<rect class="b\d+" x="([\d.]+)"', svg))
            if x < 800.0
        )
        self.assertEqual(len(xs), 3)
        # 6 slots across 710px. Rows at 05/08/09 sit in slots 1, 4 and 5, so
        # the 05->08 gap spans three slots (~355px). Collapsed to three
        # buckets the same bars would be ~237px apart, so this bound is what
        # distinguishes "empty slots occupy space" from "empty slots deleted".
        self.assertGreater(xs[1] - xs[0], 300.0)

    def test_a_zero_spend_day_now_counts_against_coverage(self):
        # Consequence of window-derived buckets, pinned deliberately rather
        # than discovered later: the coverage footer joins CFP notional spend
        # on day keys, and a day with no rows is now a bucket, so it joins.
        # Coverage therefore falls and that day reports 0.00 drift where it
        # used to be omitted. That is the more honest reading -- the day
        # really did have notional spend and no metered work -- but it does
        # change the number, most visibly after opencode.db is recreated while
        # the CFP history retains earlier days.
        agg = oc_tags.load_aggregate(db_path=self.db, tags_db="/nonexistent", days=4, now_ms=self.now)
        self.assertIn("2026-09-06", agg.buckets)  # a day with no rows at all
        svg = oc_tags.render_svg(
            agg, oc_tags.CfpSpend(), notional_by_day={"2026-09-06": 10.0, "2026-09-08": 10.0}
        )
        self.assertIn("of 5 days", svg)

    def test_the_current_bucket_is_always_marked_partial(self):
        # Also a consequence: the window always contains now, so the current
        # bucket always exists and is always labelled. Previously the label
        # appeared only once that bucket had rows, which meant an in-flight
        # turn that had not yet recorded cost went unmarked -- a false
        # negative on exactly the bar most likely to be under-reporting.
        empty = str(Path(self.tmp.name) / "empty.db")
        conn = sqlite3.connect(empty)
        conn.execute("CREATE TABLE session (id TEXT PRIMARY KEY, parent_id TEXT, directory TEXT, title TEXT, time_created INTEGER, time_updated INTEGER)")
        conn.execute("CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, data TEXT)")
        conn.commit()
        conn.close()
        agg = oc_tags.load_aggregate(db_path=empty, tags_db="/nonexistent", days=1, now_ms=self.now)
        self.assertEqual(agg.partial_bucket, "2026-09-08T09")

    def test_axis_labels_step_by_a_constant_time_interval(self):
        # Assert on TEXT NODES, not a whole-document substring: the bug was an
        # axis whose labels jumped 05 -> 08 -> 10 while looking contiguous.
        agg = self._agg(-8, 1)
        svg = oc_tags.render_svg(agg, oc_tags.CfpSpend())
        labels = [m for m in re.findall(r'<text class="axl"[^>]*font-size="10">([^<]+)</text>', svg)]
        hours = [int(x[-2:]) for x in labels if "T" in x]
        self.assertGreater(len(hours), 2)
        steps = {b - a for a, b in zip(hours, hours[1:])}
        self.assertEqual(len(steps), 1, f"labels not evenly spaced: {labels}")


# Without this guard, `python3 test_oc_tags.py` imports the module, defines
# every test, runs NONE, prints nothing and exits 0 -- the exact failure mode
# documented at the bottom of pkgs/oc-cost/test_oc_cost.py. The flake check
# runs this file directly, so the guard is what makes the check able to fail.
if __name__ == "__main__":
    unittest.main()
