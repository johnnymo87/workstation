"""Tests for session_owns.py. Run: python3 pkgs/session-owns/test_session_owns.py

Hermetic: temp sqlite fixtures and a temp claims dir; never reads the real
opencode.db, goose sessions.db or ~/.local/state/path-claims.
"""
import contextlib
import io
import json
import os
import sqlite3
import sys
import tempfile
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import session_owns as so  # noqa: E402

FMT = "%Y-%m-%d %H:%M:%S"


def utc(ts):
    return time.strftime(FMT, time.gmtime(ts))


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(lambda: __import__("shutil").rmtree(self.tmp, ignore_errors=True))
        self.wt = os.path.join(self.tmp, "repo", ".worktrees", "lgtm-pr-7")
        os.makedirs(self.wt)
        self.wt = os.path.realpath(self.wt)
        self.oc = os.path.join(self.tmp, "opencode.db")
        self.goose = os.path.join(self.tmp, "goose.db")
        self.claims = os.path.join(self.tmp, "claims")
        self.now = time.time()

    def owner(self, path=None, **kw):
        kw.setdefault("db_path", self.oc)
        kw.setdefault("goose_db_path", self.goose)
        kw.setdefault("claims_dir", self.claims)
        return so.session_owner(path or self.wt, **kw)

    def make_opencode(self, rows):
        con = sqlite3.connect(self.oc)
        con.execute("create table session (id text, directory text, time_updated integer)")
        con.executemany("insert into session values (?, ?, ?)", rows)
        con.commit()
        con.close()

    def make_goose(self, sessions, messages=(), with_messages=True):
        con = sqlite3.connect(self.goose)
        con.execute("create table sessions (id text, working_dir text, updated_at text)")
        if with_messages:
            con.execute("create table messages (id integer primary key, session_id text, created_timestamp integer)")
            con.executemany("insert into messages (session_id, created_timestamp) values (?, ?)", messages)
        con.executemany("insert into sessions values (?, ?, ?)", sessions)
        con.commit()
        con.close()

    def claim(self, name, path, expires_at, mtime=None, raw=None):
        os.makedirs(self.claims, exist_ok=True)
        fp = os.path.join(self.claims, name)
        with open(fp, "w") as fh:
            fh.write(raw if raw is not None else json.dumps(
                {"path": path, "expires_at": expires_at, "owner": "lgtm", "what": "goose review x"}))
        if mtime is not None:
            os.utime(fp, (mtime, mtime))
        return fp


class NothingThere(Base):
    def test_no_databases_no_claims_is_free(self):
        self.assertEqual(self.owner(), ("free", ""))

    def test_missing_opencode_db_answers_missing_param(self):
        self.assertEqual(self.owner(missing="unknown")[0], "unknown")


class Opencode(Base):
    def test_exact_and_subdir_match_recent(self):
        self.make_opencode([("ses_a", self.wt + "/src", int(self.now * 1000))])
        self.assertEqual(self.owner(), ("session", "opencode session ses_a"))

    def test_stale_row_is_free(self):
        self.make_opencode([("ses_a", self.wt, int((self.now - 30 * 86400) * 1000))])
        self.assertEqual(self.owner()[0], "free")

    def test_sibling_prefix_is_not_a_match(self):
        self.make_opencode([("ses_a", self.wt + "0", int(self.now * 1000))])
        self.assertEqual(self.owner()[0], "free")

    def test_corrupt_db_is_unknown(self):
        with open(self.oc, "w") as fh:
            fh.write("not a database")
        self.assertEqual(self.owner()[0], "unknown")


class Goose(Base):
    def test_updated_at_recent(self):
        self.make_goose([("g1", self.wt, utc(self.now - 3600))])
        self.assertEqual(self.owner(), ("session", "goose session g1"))

    def test_messages_clock_alone_keeps(self):
        self.make_goose([("g1", self.wt, utc(self.now - 30 * 86400))],
                        [("g1", int(self.now - 60))])
        self.assertEqual(self.owner()[0], "session")

    def test_stale_on_both_clocks_is_free(self):
        self.make_goose([("g1", self.wt, utc(self.now - 30 * 86400))],
                        [("g1", int(self.now - 30 * 86400))])
        self.assertEqual(self.owner()[0], "free")

    def test_active_seconds_window(self):
        self.make_goose([("g1", self.wt, utc(self.now - 3600))])
        self.assertEqual(self.owner(active_seconds=1800)[0], "free")

    def test_missing_messages_table_is_unknown(self):
        self.make_goose([("g1", self.wt, utc(self.now - 30 * 86400))], with_messages=False)
        self.assertEqual(self.owner()[0], "unknown")


class Claims(Base):
    def test_live_claim_protects_exact_path(self):
        self.claim("lgtm-review-o_r-7.json", self.wt, self.now + 3600)
        v, d = self.owner()
        self.assertEqual(v, "session")
        self.assertIn("lgtm-review-o_r-7.json", d)

    def test_live_claim_under_candidate_protects_parent(self):
        self.claim("c.json", self.wt + "/sub", self.now + 3600)
        self.assertEqual(self.owner(os.path.dirname(self.wt))[0], "session")

    def test_claim_matches_through_symlinked_candidate(self):
        link = os.path.join(self.tmp, "link")
        os.symlink(self.wt, link)
        self.claim("c.json", self.wt, self.now + 3600)
        self.assertEqual(self.owner(link)[0], "session")

    def test_other_path_is_free(self):
        self.claim("c.json", self.wt + "0", self.now + 3600)
        self.assertEqual(self.owner()[0], "free")

    def test_expired_claim_is_free(self):
        self.claim("c.json", self.wt, self.now - 1)
        self.assertEqual(self.owner()[0], "free")

    def test_claims_ignore_the_activity_window(self):
        # A live claim is an assertion about NOW; a 30-minute window does not shorten it.
        self.claim("c.json", self.wt, self.now + 7200)
        self.assertEqual(self.owner(active_seconds=60)[0], "session")

    def test_far_future_expiry_is_capped_by_mtime_ttl(self):
        old = self.now - so.CLAIM_MAX_TTL_SECONDS - 60
        self.claim("c.json", self.wt, self.now + 10 * 86400, mtime=old)
        self.assertEqual(self.owner()[0], "free")

    def test_stale_garbage_is_ignored_unread(self):
        old = self.now - so.CLAIM_MAX_TTL_SECONDS - 60
        self.claim("c.json", None, None, mtime=old, raw="{not json")
        self.assertEqual(self.owner()[0], "free")

    def test_fresh_garbage_is_unknown(self):
        self.claim("c.json", None, None, raw="{not json")
        self.assertEqual(self.owner()[0], "unknown")

    def test_relative_path_is_unknown(self):
        self.claim("c.json", "relative/dir", self.now + 3600)
        self.assertEqual(self.owner()[0], "unknown")

    def test_dotfiles_and_non_json_are_skipped(self):
        self.claim(".c.json.tmp", None, None, raw="{partial")
        self.claim("notes.txt", None, None, raw="whatever")
        self.assertEqual(self.owner()[0], "free")

    def test_session_beats_unknown(self):
        self.claim("a.json", None, None, raw="{not json")
        self.claim("b.json", self.wt, self.now + 3600)
        self.assertEqual(self.owner()[0], "session")

    def test_unlistable_dir_is_unknown(self):
        with open(self.claims, "w") as fh:
            fh.write("a file where a directory should be")
        self.assertEqual(self.owner()[0], "unknown")

    def test_env_seam(self):
        self.claim("c.json", self.wt, self.now + 3600)
        old = os.environ.get("PATH_CLAIMS_DIR")
        os.environ["PATH_CLAIMS_DIR"] = self.claims
        try:
            self.assertEqual(so.session_owns(self.wt, self.oc, goose_db_path=self.goose), "session")
        finally:
            if old is None:
                del os.environ["PATH_CLAIMS_DIR"]
            else:
                os.environ["PATH_CLAIMS_DIR"] = old


class Cli(Base):
    def run_main(self, *args):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = so.main(list(args))
        return rc, out.getvalue().strip()

    def common(self):
        return ["--opencode-db", self.oc, "--goose-db", self.goose, "--claims-dir", self.claims]

    def test_free_exits_1(self):
        self.assertEqual(self.run_main(*self.common(), self.wt), (1, "free"))

    def test_session_exits_0_and_names_owner(self):
        self.make_goose([("g9", self.wt, utc(self.now))])
        self.assertEqual(self.run_main(*self.common(), self.wt), (0, "session goose session g9"))

    def test_unknown_exits_2(self):
        with open(self.goose, "w") as fh:
            fh.write("not a database")
        rc, out = self.run_main(*self.common(), self.wt)
        self.assertEqual(rc, 2)
        self.assertTrue(out.startswith("unknown goose: "), out)

    def test_opencode_missing_flag(self):
        rc, _ = self.run_main(*self.common(), "--opencode-missing", "unknown", self.wt)
        self.assertEqual(rc, 2)


if __name__ == "__main__":
    unittest.main()
