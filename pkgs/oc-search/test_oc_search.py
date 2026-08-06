#!/usr/bin/env python3
"""Tests for oc-search. Run: python3 pkgs/oc-search/test_oc_search.py

Wired into CI as the `oc-search` flake check (see flake.nix), which invokes
this file directly.

The load-bearing claim under test is EQUIVALENCE: for every query shape, the
indexed path and the scanning path must produce the same rows that a plain
`instr()` over the same fixture produces. That is the whole safety argument
for putting an index in front of a substring search, so it is tested
exhaustively (`test_index_matches_scan_for_every_substring`) rather than
spot-checked.
"""

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

sys.path.insert(0, str(Path(__file__).resolve().parent))

import oc_search  # noqa: E402


BASE_MS = 1_780_000_000_000


def make_db(path: str) -> sqlite3.Connection:
    conn = sqlite3.connect(path)
    conn.executescript(
        """
        CREATE TABLE session (
          id text PRIMARY KEY,
          title text NOT NULL,
          directory text NOT NULL,
          time_updated integer NOT NULL
        );
        CREATE TABLE part (
          id text PRIMARY KEY,
          message_id text NOT NULL,
          session_id text NOT NULL,
          time_created integer NOT NULL,
          time_updated integer NOT NULL,
          data text NOT NULL
        );
        """
    )
    return conn


def add_session(conn, sid, *, title="a title", directory="/tmp/proj"):
    conn.execute(
        "INSERT INTO session (id, title, directory, time_updated) VALUES (?,?,?,?)",
        (sid, title, directory, BASE_MS),
    )


_SEQ = [0]


def add_part(conn, sid, *, type="tool", text="", t=None):
    _SEQ[0] += 1
    n = _SEQ[0]
    data = json.dumps({"type": type, "text": text, "id": f"prt_{n}"})
    conn.execute(
        "INSERT INTO part (id, message_id, session_id, time_created, time_updated, data)"
        " VALUES (?,?,?,?,?,?)",
        (f"prt_{n}", f"msg_{n}", sid, BASE_MS + (t if t is not None else n), BASE_MS, data),
    )
    return f"prt_{n}"


class Fixture:
    """A temp opencode.db plus a temp sidecar index path."""

    def __init__(self):
        self.dir = tempfile.TemporaryDirectory()
        self.db = os.path.join(self.dir.name, "opencode.db")
        self.index = os.path.join(self.dir.name, "cache", "index.db")
        self.conn = make_db(self.db)

    def commit(self):
        self.conn.commit()

    def close(self):
        self.conn.close()
        self.dir.cleanup()

    def build_index(self, **kw):
        src = oc_search.open_source(self.db)
        try:
            return oc_search.build_index(
                src,
                self.index,
                self.db,
                rebuild=kw.get("rebuild", False),
                batch=kw.get("batch", 1_000_000),
                progress=False,
            )
        finally:
            src.close()

    def search(self, *argv) -> tuple[int, str, str]:
        """Run oc-search against this fixture. Last argument is the query.

        The query goes after `--` so that a needle beginning with a dash is
        still a needle -- the same escape hatch the shipped CLI gives humans.
        """
        flags = list(argv[:-1])
        query = argv[-1]
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = oc_search.run(
                flags
                + ["--db", self.db, "--index-path", self.index, "--timeout", "0", "--", query]
            )
        return rc, out.getvalue(), err.getvalue()

    def sessions(self, *argv) -> list[dict]:
        rc, out, _ = self.search("--json", *argv)
        assert rc == 0, rc
        return json.loads(out)


class ParseArgsTest(unittest.TestCase):
    """The old bash CLI's contract. lgtm and humans both depend on it."""

    def test_defaults_to_tool_parts(self):
        args = oc_search.parse_args(["hello"])
        self.assertEqual(args.query, "hello")
        self.assertEqual(oc_search.resolve_types(args), ["tool"])

    def test_types_space_separated(self):
        args = oc_search.parse_args(["--types", "tool,text", "mono"])
        self.assertEqual(oc_search.resolve_types(args), ["tool", "text"])
        self.assertEqual(args.query, "mono")

    def test_types_equals_form(self):
        args = oc_search.parse_args(["--types=tool,text", "mono"])
        self.assertEqual(oc_search.resolve_types(args), ["tool", "text"])

    def test_all_beats_types(self):
        args = oc_search.parse_args(["--all", "--types", "tool", "q"])
        self.assertIsNone(oc_search.resolve_types(args))

    def test_double_dash_protects_a_dash_leading_query(self):
        args = oc_search.parse_args(["--", "--weird-query"])
        self.assertEqual(args.query, "--weird-query")

    def test_missing_query_is_an_error(self):
        with self.assertRaises(SystemExit):
            with contextlib.redirect_stderr(io.StringIO()):
                oc_search.parse_args([])

    def test_two_queries_are_an_error(self):
        with self.assertRaises(SystemExit):
            with contextlib.redirect_stderr(io.StringIO()):
                oc_search.parse_args(["one", "two"])


class FtsPhraseTest(unittest.TestCase):
    def test_quotes_are_doubled(self):
        self.assertEqual(oc_search.fts_phrase('a"b'), '"a""b"')

    def test_plain(self):
        self.assertEqual(oc_search.fts_phrase("gh pr create"), '"gh pr create"')


class SearchBehaviourTest(unittest.TestCase):
    def setUp(self):
        self.f = Fixture()
        add_session(self.f.conn, "ses_a", title="alpha", directory="/tmp/a")
        add_session(self.f.conn, "ses_b", title="beta", directory="/tmp/b")
        add_part(self.f.conn, "ses_a", type="tool", text="gh pr create --fill", t=10)
        add_part(self.f.conn, "ses_a", type="tool", text="gh pr create again", t=20)
        add_part(self.f.conn, "ses_a", type="text", text="talking about kubectl", t=30)
        add_part(self.f.conn, "ses_b", type="text", text="gh pr create in text", t=40)
        add_part(self.f.conn, "ses_b", type="reasoning", text="thinking kubectl", t=50)
        self.f.commit()

    def tearDown(self):
        self.f.close()

    def test_default_scope_is_tool_only(self):
        rows = self.f.sessions("gh pr create")
        self.assertEqual([r["id"] for r in rows], ["ses_a"])
        self.assertEqual(rows[0]["matches"], 2)

    def test_types_widens_scope(self):
        rows = self.f.sessions("--types", "tool,text", "gh pr create")
        self.assertEqual({r["id"] for r in rows}, {"ses_a", "ses_b"})

    def test_all_includes_reasoning(self):
        rows = self.f.sessions("--all", "kubectl")
        self.assertEqual({r["id"] for r in rows}, {"ses_a", "ses_b"})
        rows = self.f.sessions("--types", "text", "kubectl")
        self.assertEqual({r["id"] for r in rows}, {"ses_a"})

    def test_sorted_by_most_recent_match(self):
        rows = self.f.sessions("--types", "tool,text", "gh pr create")
        self.assertEqual([r["id"] for r in rows], ["ses_b", "ses_a"])

    def test_no_match_exits_zero_and_says_so(self):
        # lgtm keys off empty stdout; an exit code change here would turn a
        # miss into a logged failure.
        rc, out, err = self.f.search("nothing-here-at-all")
        self.assertEqual(rc, 0)
        self.assertEqual(out, "")
        self.assertIn("no sessions matched", err)

    def test_table_columns(self):
        rc, out, _ = self.f.search("gh pr create")
        self.assertEqual(rc, 0)
        header = out.splitlines()[0].split()
        self.assertEqual(header, ["id", "title", "directory", "last_match", "matches"])
        self.assertIn("ses_a", out)

    def test_limit(self):
        rows = self.f.sessions("--types", "tool,text", "--limit", "1", "gh pr create")
        self.assertEqual(len(rows), 1)

    def test_session_deleted_but_parts_left_behind_is_dropped(self):
        self.f.conn.execute("DELETE FROM session WHERE id='ses_b'")
        self.f.commit()
        rows = self.f.sessions("--types", "tool,text", "gh pr create")
        self.assertEqual([r["id"] for r in rows], ["ses_a"])

    def test_scan_warns_loudly_when_there_is_no_index(self):
        _, _, err = self.f.search("gh pr create")
        self.assertIn("no usable index", err)
        self.assertIn("--index", err)


class IndexTest(unittest.TestCase):
    def setUp(self):
        self.f = Fixture()
        add_session(self.f.conn, "ses_a")
        add_session(self.f.conn, "ses_b")
        add_part(self.f.conn, "ses_a", type="tool", text="FbmEmployeeCutoffRepublish")
        add_part(self.f.conn, "ses_a", type="text", text="unrelated chatter")
        add_part(self.f.conn, "ses_b", type="tool", text="also FbmEmployeeCutoffRepublish")
        self.f.commit()

    def tearDown(self):
        self.f.close()

    def test_build_then_query_uses_index_and_says_nothing(self):
        res = self.f.build_index()
        self.assertEqual(res["indexed"], 3)
        self.assertTrue(res["up_to_date"])
        rc, out, err = self.f.search("FbmEmployeeCutoffRepublish")
        self.assertEqual(rc, 0)
        self.assertNotIn("no usable index", err)
        self.assertIn("ses_a", out)
        self.assertIn("ses_b", out)

    def test_index_is_incremental(self):
        self.f.build_index()
        add_part(self.f.conn, "ses_a", type="tool", text="brand new FbmEmployeeCutoffRepublish")
        self.f.commit()
        res = self.f.build_index()
        self.assertEqual(res["indexed"], 1)

    def test_stale_index_still_returns_the_tail(self):
        """The correctness guarantee: a stale index costs time, never truth."""
        self.f.build_index()
        add_part(self.f.conn, "ses_b", type="tool", text="late FbmEmployeeCutoffRepublish")
        add_part(self.f.conn, "ses_b", type="tool", text="later FbmEmployeeCutoffRepublish")
        self.f.commit()
        rows = self.f.sessions("FbmEmployeeCutoffRepublish")
        by_id = {r["id"]: r["matches"] for r in rows}
        self.assertEqual(by_id, {"ses_a": 1, "ses_b": 3})

    def test_interrupted_build_leaves_a_usable_smaller_index(self):
        """A partial index must be usable, not poisonous.

        The build commits its watermark alongside the rows it describes, so a
        killed build degrades to "indexed less", which the tail scan covers.
        Simulated here by the batch limit, which is the same code path.
        """
        self.f.build_index(rebuild=True, batch=1)
        src = oc_search.open_source(self.f.db)
        idx = oc_search.open_index_ro(self.f.index)
        usable, watermark, reason = oc_search.index_validity(src, idx, self.f.db)
        idx.close()
        src.close()
        self.assertTrue(usable, reason)
        self.assertGreater(watermark, 0)
        rows = self.f.sessions("FbmEmployeeCutoffRepublish")
        self.assertEqual({r["id"] for r in rows}, {"ses_a", "ses_b"})

    def test_index_batch_bounds_the_work(self):
        res = self.f.build_index(rebuild=True, batch=2)
        self.assertEqual(res["indexed"], 2)
        self.assertFalse(res["up_to_date"])
        # ...and the un-indexed remainder is still found.
        rows = self.f.sessions("FbmEmployeeCutoffRepublish")
        self.assertEqual({r["id"] for r in rows}, {"ses_a", "ses_b"})

    def test_index_for_another_db_is_rejected_loudly(self):
        self.f.build_index()
        src = oc_search.open_source(self.f.db)
        idx = oc_search.open_index_rw(self.f.index)
        oc_search.set_meta(idx, "source_db", "/somewhere/else/opencode.db")
        idx.commit()
        idx.close()
        src.close()
        rc, out, err = self.f.search("FbmEmployeeCutoffRepublish")
        self.assertEqual(rc, 0)
        self.assertIn("different opencode.db", err)
        self.assertIn("ses_a", out)  # still correct, via the fallback scan

    def test_watermark_row_replaced_invalidates_the_index(self):
        """Guards the one way rowid reuse could hide a match.

        SQLite only recycles a rowid at the top of the table, so a deletion
        that could shadow indexed content necessarily changes the watermark
        row. Rewriting it here stands in for "the newest sessions were deleted
        and new parts took their rowids".
        """
        self.f.build_index()
        self.f.conn.execute(
            "UPDATE part SET id='prt_impostor' WHERE rowid=(SELECT MAX(rowid) FROM part)"
        )
        self.f.commit()
        _, _, err = self.f.search("FbmEmployeeCutoffRepublish")
        self.assertIn("must be rebuilt", err)

    def test_short_query_falls_back_and_says_why(self):
        self.f.build_index()
        _, _, err = self.f.search("Fb")
        self.assertIn("trigram index", err)

    def test_no_index_flag_forces_a_scan(self):
        self.f.build_index()
        _, out, err = self.f.search("--no-index", "FbmEmployeeCutoffRepublish")
        self.assertIn("no usable index", err)
        self.assertIn("ses_a", out)


class EquivalenceTest(unittest.TestCase):
    """Indexed results == scanned results == raw instr(), for every substring.

    Trigram FTS5 is only a legitimate substitute for `instr` if it is exact in
    both directions. This walks every substring of length >= 3 of a corpus
    chosen to include the awkward shapes: repeated trigrams, overlapping
    matches, punctuation, unicode, JSON metacharacters and quotes.
    """

    CORPUS = [
        "FbmEmployeeCutoffRepublishService",
        "aaaa aaab aaaa",
        "gh pr create --fill --base main",
        "kubectl -n prod exec -it pod/foo -- bash",
        'a "quoted" thing with \\ backslash',
        "DATA-4297 and DATA-42970",
        "rules_oci // bazel:target",
        "unicode: naïve — 日本語 test",
        "mono mono mono",
        "abcabcabc",
    ]

    @classmethod
    def setUpClass(cls):
        cls.f = Fixture()
        for i, text in enumerate(cls.CORPUS):
            sid = f"ses_{i}"
            add_session(cls.f.conn, sid)
            add_part(cls.f.conn, sid, type="tool", text=text)
        cls.f.commit()
        cls.f.build_index()

    @classmethod
    def tearDownClass(cls):
        cls.f.close()

    def truth(self, needle: str) -> set[str]:
        conn = sqlite3.connect(self.f.db)
        try:
            rows = conn.execute(
                "SELECT DISTINCT session_id FROM part WHERE instr(data, ?) > 0", (needle,)
            ).fetchall()
        finally:
            conn.close()
        return {r[0] for r in rows}

    def test_index_matches_scan_for_every_substring(self):
        checked = 0
        for text in self.CORPUS:
            for start in range(len(text)):
                for length in range(oc_search.MIN_TRIGRAM_LEN, len(text) - start + 1):
                    needle = text[start : start + length]
                    if "\x00" in needle:
                        continue
                    expected = self.truth(needle)
                    indexed = {r["id"] for r in self.f.sessions(needle)}
                    scanned = {r["id"] for r in self.f.sessions("--no-index", needle)}
                    self.assertEqual(
                        indexed, expected, f"indexed path disagrees on {needle!r}"
                    )
                    self.assertEqual(
                        scanned, expected, f"scan path disagrees on {needle!r}"
                    )
                    checked += 1
        self.assertGreater(checked, 1000)

    def test_case_sensitivity_matches_instr(self):
        # instr() is byte-exact; the index is built `case_sensitive 1` so it
        # must be too. A case-folding index would silently over-report.
        self.assertEqual(self.truth("fbmemployee"), set())
        self.assertEqual({r["id"] for r in self.f.sessions("fbmemployee")}, set())
        self.assertEqual({r["id"] for r in self.f.sessions("FbmEmployee")}, {"ses_0"})


class ParallelScanTest(unittest.TestCase):
    def setUp(self):
        self.f = Fixture()
        add_session(self.f.conn, "ses_a")
        for i in range(200):
            add_part(self.f.conn, "ses_a", type="tool", text=f"needle-{i % 7} filler")
        self.f.commit()

    def tearDown(self):
        self.f.close()

    def test_split_ranges_cover_every_row_exactly_once(self):
        for jobs in (1, 2, 3, 8, 64):
            rows = self.f.sessions("--no-index", "--jobs", str(jobs), "needle-3")
            self.assertEqual(len(rows), 1, jobs)
            self.assertEqual(rows[0]["matches"], 200 // 7 + (1 if 200 % 7 > 3 else 0), jobs)

    def test_parallel_and_serial_agree(self):
        serial = self.f.sessions("--no-index", "--jobs", "1", "needle-")
        parallel = self.f.sessions("--no-index", "--jobs", "16", "needle-")
        self.assertEqual(serial, parallel)


class DeadlineTest(unittest.TestCase):
    def setUp(self):
        self.f = Fixture()
        add_session(self.f.conn, "ses_a")
        for i in range(400):
            add_part(self.f.conn, "ses_a", type="tool", text="x" * 200)
        self.f.commit()

    def tearDown(self):
        self.f.close()

    def test_expired_deadline_reports_instead_of_dying_silently(self):
        """The lgtm failure mode, inverted.

        Tonight's log line was `Command failed: oc-search ...` with an empty
        stderr, because the only thing that ended the run was the caller's
        SIGTERM. A tripped deadline must instead exit non-zero WITH an
        explanation on stderr, which is what lands in the caller's log.
        """
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = oc_search.run(
                [
                    "x",
                    "--db",
                    self.f.db,
                    "--index-path",
                    self.f.index,
                    "--timeout",
                    "0.000001",
                    "--jobs",
                    "1",
                ]
            )
        self.assertEqual(rc, 2)
        self.assertIn("aborted after", err.getvalue())
        self.assertIn("--index", err.getvalue())

    def test_zero_timeout_means_no_deadline(self):
        d = oc_search.Deadline(0)
        self.assertIsNone(d.deadline)
        self.assertFalse(d.expired())


class IndexInfoTest(unittest.TestCase):
    def test_reports_missing_index(self):
        f = Fixture()
        add_session(f.conn, "ses_a")
        add_part(f.conn, "ses_a")
        f.commit()
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = oc_search.run(["--index-info", "--db", f.db, "--index-path", f.index])
        self.assertEqual(rc, 0)
        self.assertFalse(json.loads(out.getvalue())["exists"])
        f.close()

    def test_reports_unindexed_tail(self):
        f = Fixture()
        add_session(f.conn, "ses_a")
        add_part(f.conn, "ses_a")
        f.commit()
        f.build_index()
        add_part(f.conn, "ses_a")
        f.commit()
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            oc_search.run(["--index-info", "--db", f.db, "--index-path", f.index])
        info = json.loads(out.getvalue())
        self.assertTrue(info["usable"])
        self.assertGreaterEqual(info["unindexed_rows_estimate"], 1)
        f.close()


class IfExistsTest(unittest.TestCase):
    """The timer must never create an 11 GB index nobody asked for."""

    def setUp(self):
        self.f = Fixture()
        add_session(self.f.conn, "ses_a")
        add_part(self.f.conn, "ses_a", type="tool", text="FbmEmployeeCutoffRepublish")
        self.f.commit()

    def tearDown(self):
        self.f.close()

    def test_refuses_to_create_one(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = oc_search.run(
                ["--index", "--if-exists", "--db", self.f.db, "--index-path", self.f.index]
            )
        self.assertEqual(rc, 0)
        self.assertIn("nothing to refresh", out.getvalue())
        self.assertFalse(os.path.exists(self.f.index))

    def test_refreshes_an_existing_one(self):
        self.f.build_index()
        add_part(self.f.conn, "ses_a", type="tool", text="more FbmEmployeeCutoffRepublish")
        self.f.commit()
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = oc_search.run(
                ["--index", "--if-exists", "--db", self.f.db, "--index-path", self.f.index]
            )
        self.assertEqual(rc, 0)
        self.assertIn("indexed 1 rows", out.getvalue())


class Fts5CapabilityTest(unittest.TestCase):
    def test_this_sqlite_can_do_trigram_fts(self):
        """If this ever fails, the index is not buildable on this platform.

        Asserted rather than assumed because every exactness claim in this
        package depends on it, and macOS/nix python builds are not all alike.
        """
        ok, why = oc_search.fts5_trigram_available()
        self.assertTrue(ok, why)


class MissingDatabaseTest(unittest.TestCase):
    def test_reports_and_exits_one(self):
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            rc = oc_search.run(["q", "--db", "/nonexistent/opencode.db"])
        self.assertEqual(rc, 1)
        self.assertIn("database not found", err.getvalue())


if __name__ == "__main__":
    unittest.main(verbosity=2)
