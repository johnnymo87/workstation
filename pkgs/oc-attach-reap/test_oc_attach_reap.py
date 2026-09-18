#!/usr/bin/env python3
"""Tests for oc-attach-reap.

THIS TOOL KILLS PROCESSES, so the suite is built around the ways it could kill
the WRONG ones rather than around the happy path.

The oracle is opencode.db, read read-only, and the tests below spend most of
their effort on what happens when that oracle is missing, unreadable, empty,
stale or implausible -- because every one of those makes healthy TUIs look
orphaned, and this tool kills what looks orphaned.

They also cover the two ways a TUI can be alive while its argv says otherwise:
it is attached to a different door (a scratch serve whose ids this database has
never seen), or a human is typing in it right now (on session.deleted the TUI
stays alive on its home screen, so argv is launch intent rather than state).
"""
import os
import sqlite3
import sys
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import oc_attach_reap as R  # noqa: E402


class Fixture:
    """A fake /proc and a fake opencode.db."""

    def __init__(self, tmp):
        self.tmp = tmp
        self.proc = os.path.join(tmp, "proc")
        os.makedirs(self.proc, exist_ok=True)
        # Age now comes from /proc/<pid>/stat field 22 + /proc/stat btime, not
        # from the procfs inode mtime (which is reclaimable dcache and resets
        # under memory pressure -- silently making every process look newborn).
        self.boot = time.time() - 10_000_000
        with open(os.path.join(self.proc, "stat"), "w") as fh:
            fh.write("cpu  1 2 3 4\nbtime %d\n" % int(self.boot))
        self.db = os.path.join(tmp, "opencode.db")
        conn = sqlite3.connect(self.db)
        conn.execute("CREATE TABLE session (id TEXT PRIMARY KEY, time_archived INTEGER)")
        conn.commit()
        conn.close()
        self._pid = 1000

    def add_session(self, sid):
        conn = sqlite3.connect(self.db)
        conn.execute("INSERT OR IGNORE INTO session (id) VALUES (?)", (sid,))
        conn.commit()
        conn.close()

    def add_proc(self, cmdline, age_seconds=3600, idle_seconds=99999):
        self._pid += 1
        d = os.path.join(self.proc, str(self._pid))
        os.makedirs(os.path.join(d, "fd"), exist_ok=True)
        with open(os.path.join(d, "cmdline"), "wb") as fh:
            fh.write(b"\0".join(c.encode() for c in cmdline) + b"\0")
        hz = os.sysconf("SC_CLK_TCK") or 100
        start_ticks = int((time.time() - age_seconds - self.boot) * hz)
        # comm deliberately contains a space and a bracket: field 22 must be
        # found by splitting after the LAST ')', not by naive whitespace split.
        # state + fields 4..21, so that starttime lands at field 22 exactly.
        fields = " ".join(str(i) for i in range(4, 22))
        with open(os.path.join(d, "stat"), "w") as fh:
            fh.write(f"{self._pid} (opencode (tui)) S {fields} {start_ticks} 0 0\n")
        # fd/0 stands in for the pty the TUI reads keystrokes from; its atime is
        # how we tell "nobody has touched this" from "someone is typing in it".
        fd0 = os.path.join(d, "fd", "0")
        with open(fd0, "w") as fh:
            fh.write("pty")
        t = time.time() - idle_seconds
        os.utime(fd0, (t, t))
        return self._pid

    def add_tui(self, sid, age_seconds=3600, idle_seconds=99999,
                url="http://127.0.0.1:4700"):
        return self.add_proc(
            ["/nix/store/x/bin/opencode", "attach", url,
             "--session", sid, "--dir", "/home/dev/projects/x"],
            age_seconds, idle_seconds,
        )


class ReapTest(unittest.TestCase):
    def setUp(self):
        import tempfile
        self.tmpdir = tempfile.mkdtemp()
        self.f = Fixture(self.tmpdir)
        self.killed = []

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def run_reap(self, **kw):
        kw.setdefault("proc_root", self.f.proc)
        kw.setdefault("db", self.f.db)
        kw.setdefault("killer", self.killed.append)
        return R.reap(**kw)

    # ---- the basic contract -------------------------------------------------

    def test_orphaned_tui_is_killed(self):
        """A TUI whose session is gone from the database is the whole point."""
        self.f.add_session("ses_live")
        self.f.add_tui("ses_live")
        pid = self.f.add_tui("ses_gone")
        res = self.run_reap()
        self.assertEqual(self.killed, [pid])
        self.assertEqual(res.killed, 1)

    def test_live_tui_is_left_alone(self):
        """The failure that matters: killing a TUI someone is using."""
        self.f.add_session("ses_live")
        self.f.add_tui("ses_live")
        self.run_reap()
        self.assertEqual(self.killed, [])

    def test_mixed_population(self):
        self.f.add_session("ses_a")
        live = self.f.add_tui("ses_a")
        dead1 = self.f.add_tui("ses_x")
        dead2 = self.f.add_tui("ses_y")
        self.run_reap()
        self.assertEqual(sorted(self.killed), sorted([dead1, dead2]))
        self.assertNotIn(live, self.killed)

    # ---- fail CLOSED when the oracle is not trustworthy ----------------------

    def test_missing_database_kills_nothing(self):
        """If the oracle is absent every TUI looks orphaned. Kill none."""
        self.f.add_tui("ses_x")
        res = self.run_reap(db=os.path.join(self.tmpdir, "nope.db"))
        self.assertEqual(self.killed, [])
        self.assertFalse(res.ok)
        # Must refuse because the ORACLE is unusable, not because the orphan
        # fraction happened to look high. Without this, removing the existence
        # check still passes: the fraction backstop catches it and the test
        # cannot tell the two apart.
        self.assertIn("oracle unusable", res.reason)

    def test_unreadable_database_kills_nothing(self):
        self.f.add_tui("ses_x")
        bad = os.path.join(self.tmpdir, "garbage.db")
        with open(bad, "wb") as fh:
            fh.write(b"this is not a sqlite file")
        res = self.run_reap(db=bad)
        self.assertEqual(self.killed, [])
        self.assertFalse(res.ok)
        self.assertIn("oracle unusable", res.reason)

    def test_empty_session_table_kills_nothing(self):
        """An empty table is indistinguishable from 'everything is orphaned'.

        This is the shape of the frontdoor-404 bug: a technically successful
        query that means something other than what it appears to.
        """
        for _ in range(5):
            self.f.add_tui("ses_x")
        res = self.run_reap()
        self.assertEqual(self.killed, [])
        self.assertFalse(res.ok)
        self.assertIn("oracle unusable", res.reason)

    def test_implausible_orphan_fraction_refuses(self):
        """If nearly everything looks orphaned, suspect the oracle, not the world."""
        self.f.add_session("ses_live")
        self.f.add_tui("ses_live")
        for i in range(20):
            self.f.add_tui(f"ses_dead{i}")
        res = self.run_reap(max_orphan_fraction=0.9)
        self.assertEqual(self.killed, [])
        self.assertFalse(res.ok)
        self.assertIn("implausible fraction", res.reason)

    def test_plausible_fraction_proceeds(self):
        """The real cloudbox ratio (48/108) must NOT trip the guard."""
        for i in range(60):
            self.f.add_session(f"ses_live{i}")
            self.f.add_tui(f"ses_live{i}")
        for i in range(48):
            self.f.add_tui(f"ses_dead{i}")
        res = self.run_reap(max_orphan_fraction=0.9)
        self.assertEqual(len(self.killed), 48)
        self.assertTrue(res.ok)

    # ---- grace period -------------------------------------------------------

    def test_young_tui_is_spared(self):
        """A TUI can exist before its session row is committed."""
        self.f.add_session("ses_live")
        self.f.add_tui("ses_live")
        self.f.add_tui("ses_new", age_seconds=10)
        self.run_reap(grace_seconds=600)
        self.assertEqual(self.killed, [])

    def test_old_tui_past_grace_is_killed(self):
        self.f.add_session("ses_live")
        self.f.add_tui("ses_live")
        pid = self.f.add_tui("ses_old", age_seconds=1200)
        self.run_reap(grace_seconds=600)
        self.assertEqual(self.killed, [pid])

    # ---- identification -----------------------------------------------------

    def test_process_without_session_flag_is_never_killed(self):
        """Cannot identify it -> cannot judge it -> do not touch it."""
        self.f.add_proc(["/x/bin/opencode", "attach", "http://127.0.0.1:4700"])
        self.run_reap()
        self.assertEqual(self.killed, [])

    def test_unrelated_processes_are_never_killed(self):
        self.f.add_session("ses_live")
        self.f.add_tui("ses_live")
        self.f.add_proc(["/x/bin/nvim", "--listen", "/tmp/x.sock"])
        self.f.add_proc(["/x/bin/opencode", "serve", "--port", "4096"])
        self.f.add_proc(["bash", "-c", "echo opencode attach --session ses_x"])
        # DECOYS THAT DEFEAT LOOSE MATCHING. Each carries --session as its own
        # argv element pointing at a dead session, so a substring test on the
        # whole command line would reap them. Only checking argv[0] basename
        # and the literal `attach` subcommand rejects these.
        self.f.add_proc(["/x/bin/opencode", "run", "--session", "ses_dead1"])
        self.f.add_proc(["/x/bin/not-opencode", "attach", "--session", "ses_dead2"])
        self.f.add_proc(["bash", "-c", "wrapper", "attach", "--session", "ses_dead3"])
        self.run_reap()
        self.assertEqual(self.killed, [])

    def test_tui_in_active_use_is_spared(self):
        """argv names a dead session, but someone is typing in the window.

        On session.deleted the TUI does not exit: it navigates to its home
        screen and stays alive, and a human can then start a new session or
        switch sessions inside it. argv is launch INTENT; recent input on the
        pty is current STATE, and state wins.
        """
        self.f.add_session("ses_live")
        self.f.add_tui("ses_live")
        self.f.add_tui("ses_gone", idle_seconds=60)
        res = self.run_reap(idle_grace_seconds=1800)
        self.assertEqual(self.killed, [])
        self.assertEqual(res.skipped_active, 1)

    def test_idle_tui_past_idle_grace_is_killed(self):
        self.f.add_session("ses_live")
        self.f.add_tui("ses_live")
        pid = self.f.add_tui("ses_gone", idle_seconds=99999)
        self.run_reap(idle_grace_seconds=1800)
        self.assertEqual(self.killed, [pid])

    def test_tui_on_another_door_is_never_judged(self):
        """A scratch serve hands out ids the production db has never seen.

        oc-throwaway-serve runs serves on their own databases. Judging those
        TUIs against the production db would find every one of them 'orphaned'.
        """
        self.f.add_session("ses_live")
        self.f.add_tui("ses_live")
        self.f.add_tui("ses_scratch", url="http://127.0.0.1:9999")
        res = self.run_reap(door_url="http://127.0.0.1:4700")
        self.assertEqual(self.killed, [])
        self.assertEqual(res.total, 1)

    def test_archived_session_tui_is_spared(self):
        """Archived rows remain in the table, so their TUIs are not orphans."""
        conn = sqlite3.connect(self.f.db)
        conn.execute("INSERT INTO session (id, time_archived) VALUES (?, ?)",
                     ("ses_archived", 1234567890))
        conn.commit()
        conn.close()
        self.f.add_session("ses_live")
        self.f.add_tui("ses_live")
        self.f.add_tui("ses_archived")
        self.run_reap()
        self.assertEqual(self.killed, [])

    def test_process_with_unreadable_age_is_never_judged(self):
        """No age -> no grace period can be applied -> do not touch it."""
        self.f.add_session("ses_live")
        self.f.add_tui("ses_live")
        pid = self.f.add_tui("ses_gone")
        os.remove(os.path.join(self.f.proc, str(pid), "stat"))
        self.run_reap()
        self.assertEqual(self.killed, [])

    def test_dry_run_kills_nothing_but_reports(self):
        self.f.add_session("ses_live")
        self.f.add_tui("ses_live")
        self.f.add_tui("ses_gone")
        res = self.run_reap(dry_run=True)
        self.assertEqual(self.killed, [])
        self.assertEqual(res.orphans, 1)
        self.assertEqual(res.killed, 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
