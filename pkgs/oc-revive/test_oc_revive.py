import os
import sys
import json
import signal
import fcntl
import unittest
from unittest import mock
import tempfile
import sqlite3
import subprocess
import time
from typing import Any

# Ensure pkgs/oc-revive is in sys.path
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import oc_revive


def init_test_db(db_path: str) -> sqlite3.Connection:
    conn = sqlite3.connect(db_path)
    cur = conn.cursor()
    cur.execute("""
        CREATE TABLE session (
            id TEXT PRIMARY KEY,
            project_id TEXT,
            parent_id TEXT,
            slug TEXT,
            directory TEXT,
            title TEXT,
            time_created INTEGER,
            time_updated INTEGER,
            agent TEXT,
            model TEXT
        );
    """)
    cur.execute("""
        CREATE TABLE message (
            id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL,
            time_created INTEGER,
            time_updated INTEGER,
            data TEXT NOT NULL
        );
    """)
    cur.execute("""
        CREATE TABLE part (
            id TEXT PRIMARY KEY,
            message_id TEXT NOT NULL,
            session_id TEXT NOT NULL,
            time_created INTEGER,
            time_updated INTEGER,
            data TEXT NOT NULL
        );
    """)
    conn.commit()
    return conn


def init_git_repo(path: str) -> str:
    os.makedirs(path, exist_ok=True)
    subprocess.run(["git", "init", "-b", "main"], cwd=path, check=True, capture_output=True)
    subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=path, check=True, capture_output=True)
    subprocess.run(["git", "config", "user.name", "Test User"], cwd=path, check=True, capture_output=True)
    with open(os.path.join(path, "README.md"), "w") as f:
        f.write("# Test\n")
    subprocess.run(["git", "add", "README.md"], cwd=path, check=True, capture_output=True)
    subprocess.run(["git", "commit", "-m", "Initial commit"], cwd=path, check=True, capture_output=True)
    return path


class TestPathPSelection(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.repo = init_git_repo(os.path.join(self.tmpdir.name, "repo"))
        self.worktrees_dir = os.path.join(self.repo, ".worktrees")
        os.makedirs(self.worktrees_dir, exist_ok=True)
        self.db_path = os.path.join(self.tmpdir.name, "opencode.db")
        self.db_conn = init_test_db(self.db_path)

    def tearDown(self):
        self.db_conn.close()
        self.tmpdir.cleanup()

    def test_base_strips_trailing_epoch_r_suffix(self):
        self.assertEqual(oc_revive.compute_base_slug("foo"), "foo")
        self.assertEqual(oc_revive.compute_base_slug("foo-r1727780000"), "foo")
        self.assertEqual(oc_revive.compute_base_slug("foo-r1727780000-r1727780001"), "foo-r1727780000")
        self.assertEqual(oc_revive.compute_base_slug("foo-bar"), "foo-bar")
        self.assertEqual(oc_revive.compute_base_slug("foo-r123"), "foo-r123")

    def test_path_p_never_referenced_by_session_row(self):
        # Current epoch candidate would be base-r<epoch>
        epoch = 1700000000
        slug = "feature-a"
        dead_dir = os.path.join(self.worktrees_dir, slug)
        candidate_0 = os.path.join(self.worktrees_dir, f"{slug}-r{epoch}")
        candidate_1 = os.path.join(self.worktrees_dir, f"{slug}-r{epoch + 1}")

        # Seed row matching candidate_0 exactly
        cur = self.db_conn.cursor()
        cur.execute(
            "INSERT INTO session (id, directory, time_created, time_updated) VALUES (?, ?, ?, ?)",
            ("ses_1", candidate_0, 1000, 1000),
        )
        # Seed row matching candidate_1 as a subdirectory prefix (e.g. candidate_1/sub)
        cur.execute(
            "INSERT INTO session (id, directory, time_created, time_updated) VALUES (?, ?, ?, ?)",
            ("ses_2", os.path.join(candidate_1, "sub"), 1000, 1000),
        )
        self.db_conn.commit()

        # The chosen P must not be candidate_0 or candidate_1; it must advance to candidate_2 (epoch + 2)
        p = oc_revive.choose_revive_path(self.repo, dead_dir, self.db_conn, start_epoch=epoch)
        expected_2 = os.path.join(self.worktrees_dir, f"{slug}-r{epoch + 2}")
        self.assertEqual(p, expected_2)

    def test_path_p_realpath_session_row(self):
        # Test symlinked repo: candidate P in symlinked repo resolves to real repo path.
        # If DB references realpath, candidate must be rejected.
        real_repo = self.repo
        symlink_repo = os.path.join(self.tmpdir.name, "symlink-repo")
        os.symlink(real_repo, symlink_repo)

        epoch = 1700000000
        slug = "symlink-test"
        dead_dir = os.path.join(symlink_repo, ".worktrees", slug)
        real_p0 = os.path.join(real_repo, ".worktrees", f"{slug}-r{epoch}")

        # Seed DB with realpath
        cur = self.db_conn.cursor()
        cur.execute(
            "INSERT INTO session (id, directory, time_created, time_updated) VALUES (?, ?, ?, ?)",
            ("ses_real", real_p0, 1000, 1000),
        )
        self.db_conn.commit()

        # Choosing path using symlink_repo must see that real_p0 is referenced and advance to epoch + 1
        p = oc_revive.choose_revive_path(symlink_repo, dead_dir, self.db_conn, start_epoch=epoch)
        expected_1 = os.path.join(symlink_repo, ".worktrees", f"{slug}-r{epoch + 1}")
        self.assertEqual(p, expected_1)

    def test_path_p_never_dead_dir_and_never_existing_or_prunable_worktree(self):
        epoch = 1700000000
        slug = "collide-test"
        # dead_dir has the exact name of candidate 0 (collide-test-r1700000000).
        # compute_base_slug strips -r1700000000 to "collide-test", so candidate 0
        # would collide with dead_dir. dead_dir does not exist on disk, so ONLY
        # the dead_dir check rejects candidate 0.
        dead_dir = os.path.join(self.worktrees_dir, f"{slug}-r{epoch}")

        # 1. Existing worktree (and prunable worktree) in git at candidate 1
        cand_1 = os.path.join(self.worktrees_dir, f"{slug}-r{epoch + 1}")
        # Add a git worktree at cand_1
        subprocess.run(["git", "worktree", "add", "-b", "wt-branch", cand_1, "main"], cwd=self.repo, check=True, capture_output=True)
        # Remove cand_1 from disk without git worktree remove -> it becomes "prunable" in git worktree list --porcelain
        import shutil
        shutil.rmtree(cand_1)

        # Verify it shows as prunable in git worktree list --porcelain
        out = subprocess.run(["git", "worktree", "list", "--porcelain"], cwd=self.repo, capture_output=True, text=True, check=True).stdout
        self.assertIn("prunable", out)
        self.assertIn(cand_1, out)

        # choose_revive_path must skip candidate 0 (equals dead_dir) and cand_1 (in worktree list as prunable)
        p = oc_revive.choose_revive_path(self.repo, dead_dir, self.db_conn, start_epoch=epoch)
        expected_2 = os.path.join(self.worktrees_dir, f"{slug}-r{epoch + 2}")
        self.assertEqual(p, expected_2)


class TestBranchCandidates(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.repo = init_git_repo(os.path.join(self.tmpdir.name, "repo"))
        self.worktrees_dir = os.path.join(self.repo, ".worktrees")
        os.makedirs(self.worktrees_dir, exist_ok=True)
        self.db_path = os.path.join(self.tmpdir.name, "opencode.db")
        self.db_conn = init_test_db(self.db_path)
        self._part_seq = 0

    def tearDown(self):
        self.db_conn.close()
        self.tmpdir.cleanup()

    def _add_session(self, sid: str, dead_dir: str):
        cur = self.db_conn.cursor()
        cur.execute(
            "INSERT INTO session (id, project_id, directory, time_created, time_updated) VALUES (?, ?, ?, ?, ?)",
            (sid, "proj_1", dead_dir, 1000, 1000),
        )
        self.db_conn.commit()

    def _add_bash_part(self, sid: str, output: str, t: int = 1000):
        self._part_seq += 1
        pid = f"prt_{self._part_seq}"
        mid = f"msg_{self._part_seq}"
        data = {
            "type": "tool",
            "tool": "bash",
            "state": {
                "status": "completed",
                "output": output,
            },
        }
        import json
        cur = self.db_conn.cursor()
        cur.execute(
            "INSERT INTO part (id, message_id, session_id, time_created, time_updated, data) VALUES (?, ?, ?, ?, ?, ?)",
            (pid, mid, sid, t, t, json.dumps(data)),
        )
        self.db_conn.commit()

    def _commit_branch(self, branch: str, msg: str = "A commit") -> str:
        main_tip = subprocess.run(["git", "rev-parse", "main"], cwd=self.repo, capture_output=True, text=True, check=True).stdout.strip()
        tree = subprocess.run(["git", "rev-parse", "main^{tree}"], cwd=self.repo, capture_output=True, text=True, check=True).stdout.strip()
        commit_res = subprocess.run(
            ["git", "commit-tree", tree, "-p", main_tip, "-m", msg],
            cwd=self.repo,
            capture_output=True,
            text=True,
            check=True,
        )
        commit_sha = commit_res.stdout.strip()
        subprocess.run(["git", "update-ref", f"refs/heads/{branch}", commit_sha], cwd=self.repo, check=True, capture_output=True)
        return commit_sha

    def test_sanitize_slug(self):
        self.assertEqual(oc_revive.sanitize_slug("feat/cool_feature-1.0"), "feat/cool_feature-1.0")
        self.assertEqual(oc_revive.sanitize_slug("feat@bar#baz"), "feat-bar-baz")
        self.assertEqual(oc_revive.sanitize_slug("hello world!"), "hello-world-")

    def test_slug_only(self):
        sid = "ses_slug_only"
        dead_dir = os.path.join(self.worktrees_dir, "my-feature")
        self._add_session(sid, dead_dir)
        tip_sha = self._commit_branch("my-feature")

        candidates = oc_revive.find_branch_candidates(self.repo, sid, dead_dir, self.db_conn)
        self.assertEqual(len(candidates), 1)
        c = candidates[0]
        self.assertEqual(c["branch"], "my-feature")
        self.assertEqual(c["source"], "slug")
        self.assertEqual(c["tip"], tip_sha)
        self.assertEqual(c["action"], "add")

    def test_bash_evidence_only(self):
        sid = "ses_bash_only"
        dead_dir = os.path.join(self.worktrees_dir, "random-slug")
        self._add_session(sid, dead_dir)
        tip_sha = self._commit_branch("actual-feature")
        short_sha = tip_sha[:7]

        self._add_bash_part(sid, f"[actual-feature {short_sha}] Implement feature")

        candidates = oc_revive.find_branch_candidates(self.repo, sid, dead_dir, self.db_conn)
        self.assertEqual(len(candidates), 1)
        c = candidates[0]
        self.assertEqual(c["branch"], "actual-feature")
        self.assertEqual(c["source"], "bash-evidence")
        self.assertEqual(c["tip"], tip_sha)

    def test_both_agreeing(self):
        sid = "ses_both_agree"
        dead_dir = os.path.join(self.worktrees_dir, "common-feat")
        self._add_session(sid, dead_dir)
        tip_sha = self._commit_branch("common-feat")
        short_sha = tip_sha[:7]

        self._add_bash_part(sid, f"[common-feat {short_sha}] Implement common feature")

        candidates = oc_revive.find_branch_candidates(self.repo, sid, dead_dir, self.db_conn)
        self.assertEqual(len(candidates), 1)
        c = candidates[0]
        self.assertEqual(c["branch"], "common-feat")
        self.assertEqual(c["source"], "both")
        self.assertEqual(c["tip"], tip_sha)

    def test_both_disagreeing(self):
        sid = "ses_both_disagree"
        dead_dir = os.path.join(self.worktrees_dir, "slug-feat")
        self._add_session(sid, dead_dir)
        slug_tip = self._commit_branch("slug-feat")
        bash_tip = self._commit_branch("bash-feat")
        short_sha = bash_tip[:7]

        self._add_bash_part(sid, f"[bash-feat {short_sha}] Work on bash feat")

        candidates = oc_revive.find_branch_candidates(self.repo, sid, dead_dir, self.db_conn)
        self.assertEqual(len(candidates), 2)
        branches = {c["branch"]: c for c in candidates}
        self.assertIn("slug-feat", branches)
        self.assertIn("bash-feat", branches)
        self.assertEqual(branches["slug-feat"]["source"], "slug")
        self.assertEqual(branches["bash-feat"]["source"], "bash-evidence")

    def test_bash_evidence_not_ancestor_rejected(self):
        sid = "ses_not_ancestor"
        dead_dir = os.path.join(self.worktrees_dir, "random-slug")
        self._add_session(sid, dead_dir)
        self._commit_branch("feat-x", msg="Feat X commit")
        other_sha = self._commit_branch("other-branch", msg="Other branch commit")
        short_other = other_sha[:7]

        # Bash output claims feat-x has commit other_sha, but other_sha is NOT on feat-x
        self._add_bash_part(sid, f"[feat-x {short_other}] Commit from another branch")

        candidates = oc_revive.find_branch_candidates(self.repo, sid, dead_dir, self.db_conn)
        # Should reject feat-x because other_sha is not ancestor of feat-x
        self.assertEqual(len(candidates), 0)

    def test_detached_head_ignored(self):
        sid = "ses_detached"
        dead_dir = os.path.join(self.worktrees_dir, "random-slug")
        self._add_session(sid, dead_dir)
        sha = subprocess.run(["git", "rev-parse", "main"], cwd=self.repo, capture_output=True, text=True, check=True).stdout.strip()
        short_sha = sha[:7]

        self._add_bash_part(sid, f"[detached HEAD {short_sha}] Commit in detached head")

        candidates = oc_revive.find_branch_candidates(self.repo, sid, dead_dir, self.db_conn)
        self.assertEqual(len(candidates), 0)

    def test_branch_no_longer_exists_rejected(self):
        sid = "ses_gone"
        dead_dir = os.path.join(self.worktrees_dir, "random-slug")
        self._add_session(sid, dead_dir)
        sha = subprocess.run(["git", "rev-parse", "main"], cwd=self.repo, capture_output=True, text=True, check=True).stdout.strip()
        short_sha = sha[:7]

        # Branch gone-branch never created in git
        self._add_bash_part(sid, f"[gone-branch {short_sha}] Commit")

        candidates = oc_revive.find_branch_candidates(self.repo, sid, dead_dir, self.db_conn)
        self.assertEqual(len(candidates), 0)

    def test_trunk_branch_rejected(self):
        sid = "ses_trunk"
        # Slug matches trunk branch "main"
        dead_dir = os.path.join(self.worktrees_dir, "main")
        self._add_session(sid, dead_dir)

        candidates = oc_revive.find_branch_candidates(self.repo, sid, dead_dir, self.db_conn)
        # Trunk candidate must be refused
        self.assertEqual(len(candidates), 0)

    def test_branch_checked_out_in_primary_root_rejected(self):
        sid = "ses_root_branch"
        # Create branch root-branch and check it out in primary root
        subprocess.run(["git", "checkout", "-b", "root-branch"], cwd=self.repo, check=True, capture_output=True)
        dead_dir = os.path.join(self.worktrees_dir, "root-branch")
        self._add_session(sid, dead_dir)

        candidates = oc_revive.find_branch_candidates(self.repo, sid, dead_dir, self.db_conn)
        self.assertEqual(len(candidates), 0)

    def test_branch_checked_out_in_linked_worktree_rejected(self):
        sid = "ses_linked_wt"
        # Create a linked worktree checking out linked-branch
        wt_path = os.path.join(self.worktrees_dir, "live-wt")
        subprocess.run(["git", "worktree", "add", "-b", "linked-branch", wt_path, "main"], cwd=self.repo, check=True, capture_output=True)
        dead_dir = os.path.join(self.worktrees_dir, "linked-branch")
        self._add_session(sid, dead_dir)

        candidates = oc_revive.find_branch_candidates(self.repo, sid, dead_dir, self.db_conn)
        self.assertEqual(len(candidates), 0)

    def test_last_bash_evidence_picked(self):
        sid = "ses_last_evidence"
        dead_dir = os.path.join(self.worktrees_dir, "random-slug")
        self._add_session(sid, dead_dir)
        sha1 = self._commit_branch("early-branch")
        sha2 = self._commit_branch("late-branch")

        self._add_bash_part(sid, f"[early-branch {sha1[:7]}] First commit", t=100)
        self._add_bash_part(sid, f"[late-branch {sha2[:7]}] Second commit", t=200)

        candidates = oc_revive.find_branch_candidates(self.repo, sid, dead_dir, self.db_conn)
        self.assertEqual(len(candidates), 1)
        self.assertEqual(candidates[0]["branch"], "late-branch")

    def test_root_commit_syntax(self):
        sid = "ses_root_commit"
        dead_dir = os.path.join(self.worktrees_dir, "random-slug")
        self._add_session(sid, dead_dir)
        sha = self._commit_branch("root-feat")

        self._add_bash_part(sid, f"[root-feat (root-commit) {sha[:7]}] Initial root commit")

        candidates = oc_revive.find_branch_candidates(self.repo, sid, dead_dir, self.db_conn)
        self.assertEqual(len(candidates), 1)
        self.assertEqual(candidates[0]["branch"], "root-feat")


class TestPlan(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.repo = init_git_repo(os.path.join(self.tmpdir.name, "repo"))
        self.worktrees_dir = os.path.join(self.repo, ".worktrees")
        os.makedirs(self.worktrees_dir, exist_ok=True)
        self.db_path = os.path.join(self.tmpdir.name, "opencode.db")
        self.db_conn = init_test_db(self.db_path)
        self.snapshot_dir = os.path.join(self.tmpdir.name, "snapshots")
        os.environ["OPENCODE_SNAPSHOT_DIR"] = self.snapshot_dir
        os.environ["OPENCODE_DB"] = self.db_path

    def tearDown(self):
        self.db_conn.close()
        self.tmpdir.cleanup()
        os.environ.pop("OPENCODE_SNAPSHOT_DIR", None)
        os.environ.pop("OPENCODE_DB", None)

    def _add_session(
        self,
        sid: str,
        dead_dir: str,
        parent_id: str | None = None,
        project_id: str = "proj_test",
    ):
        cur = self.db_conn.cursor()
        cur.execute(
            "INSERT INTO session (id, project_id, parent_id, directory, time_created, time_updated) VALUES (?, ?, ?, ?, ?, ?)",
            (sid, project_id, parent_id, dead_dir, 1000, 1000),
        )
        self.db_conn.commit()

    def _add_message(self, mid: str, sid: str, role: str, completed: bool = True, t: int | None = None):
        import json
        if t is None:
            t = int(time.time() * 1000)
        data = {
            "role": role,
            "time": {"created": t},
        }
        if completed:
            data["time"]["completed"] = t + 50
        cur = self.db_conn.cursor()
        cur.execute(
            "INSERT INTO message (id, session_id, time_created, time_updated, data) VALUES (?, ?, ?, ?, ?)",
            (mid, sid, t, t, json.dumps(data)),
        )
        self.db_conn.commit()

    def test_plan_session_not_found(self):
        plan = oc_revive.plan_revive("ses_nonexistent", db_path=self.db_path)
        self.assertFalse(plan["revivable"])
        self.assertTrue(plan["reason"].startswith("session_not_found:"))
        self.assertEqual(plan["candidates"], [])

    def test_plan_child_session(self):
        sid = "ses_child"
        dead_dir = os.path.join(self.worktrees_dir, "child-feat")
        self._add_session(sid, dead_dir, parent_id="ses_parent")
        plan = oc_revive.plan_revive(sid, db_path=self.db_path)
        self.assertFalse(plan["revivable"])
        self.assertTrue(plan["reason"].startswith("child_session:"))

    def test_plan_directory_exists(self):
        sid = "ses_live_dir"
        live_dir = os.path.join(self.worktrees_dir, "live-feat")
        os.makedirs(live_dir, exist_ok=True)
        self._add_session(sid, live_dir)
        plan = oc_revive.plan_revive(sid, db_path=self.db_path)
        self.assertFalse(plan["revivable"])
        self.assertTrue(plan["reason"].startswith("directory_exists:"))

    def test_plan_invalid_directory_shape(self):
        # 1. Not in .worktrees
        sid1 = "ses_bad_shape1"
        bad_dir1 = os.path.join(self.repo, "not_worktrees", "feat")
        self._add_session(sid1, bad_dir1)
        plan1 = oc_revive.plan_revive(sid1, db_path=self.db_path)
        self.assertFalse(plan1["revivable"])
        self.assertTrue(plan1["reason"].startswith("invalid_directory_shape:"))

        # 2. Nested under .worktrees
        sid2 = "ses_bad_shape2"
        bad_dir2 = os.path.join(self.worktrees_dir, "nested", "feat")
        self._add_session(sid2, bad_dir2)
        plan2 = oc_revive.plan_revive(sid2, db_path=self.db_path)
        self.assertFalse(plan2["revivable"])
        self.assertTrue(plan2["reason"].startswith("invalid_directory_shape:"))

    def test_plan_not_a_git_repo(self):
        sid = "ses_no_git"
        non_git_repo = os.path.join(self.tmpdir.name, "non_git")
        os.makedirs(non_git_repo, exist_ok=True)
        bad_dir = os.path.join(non_git_repo, ".worktrees", "feat")
        self._add_session(sid, bad_dir)
        plan = oc_revive.plan_revive(sid, db_path=self.db_path)
        self.assertFalse(plan["revivable"])
        self.assertTrue(plan["reason"].startswith("not_a_git_repo:"))

    def test_is_session_busy_incomplete_recent(self):
        sid = "ses_busy_recent"
        # Incomplete assistant message created 10 seconds ago
        t_recent = int((time.time() - 10) * 1000)
        self._add_message("msg_recent", sid, role="assistant", completed=False, t=t_recent)
        self.assertTrue(oc_revive.is_session_busy(self.db_conn, sid))

    def test_is_session_busy_incomplete_stale(self):
        sid = "ses_busy_stale"
        # Incomplete assistant message created 700 seconds ago (> default 600s)
        t_stale = int((time.time() - 700) * 1000)
        self._add_message("msg_stale", sid, role="assistant", completed=False, t=t_stale)
        self.assertFalse(oc_revive.is_session_busy(self.db_conn, sid))

        # Test threshold overridable by env var OPENCODE_BUSY_THRESHOLD_SECONDS
        sid_env = "ses_busy_env"
        t_40s = int((time.time() - 40) * 1000)
        self._add_message("msg_40s", sid_env, role="assistant", completed=False, t=t_40s)
        with mock.patch.dict(os.environ, {"OPENCODE_BUSY_THRESHOLD_SECONDS": "30"}):
            self.assertFalse(oc_revive.is_session_busy(self.db_conn, sid_env))
        with mock.patch.dict(os.environ, {"OPENCODE_BUSY_THRESHOLD_SECONDS": "60"}):
            self.assertTrue(oc_revive.is_session_busy(self.db_conn, sid_env))

    def test_is_session_busy_trailing_user_not_busy(self):
        sid = "ses_trailing_user"
        # Trailing user message must NOT be treated as busy (deliberate false negative)
        t_user = int((time.time() - 5) * 1000)
        self._add_message("msg_user", sid, role="user", completed=True, t=t_user)
        self.assertFalse(oc_revive.is_session_busy(self.db_conn, sid))

    def test_plan_busy_session(self):
        sid = "ses_busy"
        dead_dir = os.path.join(self.worktrees_dir, "busy-feat")
        self._add_session(sid, dead_dir)
        # Add an in-flight assistant message (completed=False, recent)
        self._add_message("msg_busy", sid, role="assistant", completed=False)

        plan = oc_revive.plan_revive(sid, db_path=self.db_path)
        self.assertFalse(plan["revivable"])
        self.assertTrue(plan["reason"].startswith("busy_session:"))

    def test_plan_idle_session_with_completed_assistant_message(self):
        sid = "ses_idle"
        dead_dir = os.path.join(self.worktrees_dir, "idle-feat")
        self._add_session(sid, dead_dir)
        # Completed assistant message
        self._add_message("msg_done", sid, role="assistant", completed=True, t=2000)
        # Create branch idle-feat so candidates exist
        subprocess.run(["git", "branch", "idle-feat", "main"], cwd=self.repo, check=True, capture_output=True)

        plan = oc_revive.plan_revive(sid, db_path=self.db_path)
        self.assertTrue(plan["revivable"])
        self.assertIsNone(plan["reason"])
        self.assertEqual(len(plan["candidates"]), 1)
        self.assertEqual(plan["candidates"][0]["branch"], "idle-feat")

    def test_plan_no_candidates(self):
        sid = "ses_no_cands"
        dead_dir = os.path.join(self.worktrees_dir, "no-such-branch")
        self._add_session(sid, dead_dir)
        plan = oc_revive.plan_revive(sid, db_path=self.db_path)
        self.assertFalse(plan["revivable"])
        self.assertTrue(plan["reason"].startswith("no_candidates:"))

    def test_snapshot_reporting(self):
        import hashlib
        sid = "ses_snapshot"
        dead_dir = os.path.join(self.worktrees_dir, "snap-feat")
        project_id = "proj_abc"
        self._add_session(sid, dead_dir, project_id=project_id)

        # Expected snapshot path
        sha1_dir = hashlib.sha1(dead_dir.encode("utf-8")).hexdigest()
        expected_snap = os.path.join(self.snapshot_dir, project_id, sha1_dir)

        # Snapshot does not exist yet
        plan = oc_revive.plan_revive(sid, db_path=self.db_path)
        self.assertFalse(plan["snapshot"]["exists"])
        self.assertEqual(plan["snapshot"]["path"], expected_snap)

        # Now create snapshot directory on disk
        os.makedirs(expected_snap, exist_ok=True)
        plan2 = oc_revive.plan_revive(sid, db_path=self.db_path)
        self.assertTrue(plan2["snapshot"]["exists"])
        self.assertEqual(plan2["snapshot"]["path"], expected_snap)


import http.server
import threading


class FakeDoorHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        # Suppress server logging in test output
        pass

    def do_POST(self):
        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length).decode("utf-8")
        parsed = None
        if body:
            try:
                parsed = json.loads(body)
            except Exception:
                parsed = body

        server: FakeDoor = self.server  # type: ignore

        if "/move" in self.path:
            server.move_calls.append({"path": self.path, "body": parsed, "raw": body})
            if server.on_move:
                server.on_move(self.path, parsed)
            if server.move_status == 0:  # simulate connection drop
                self.close_connection = True
                return
            self.send_response(server.move_status)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            if server.move_body:
                self.wfile.write(server.move_body.encode("utf-8"))
            return

        if "/prompt_async" in self.path:
            server.prompt_async_calls.append({"path": self.path, "body": parsed})
            if server.on_prompt_async:
                server.on_prompt_async(self.path, parsed)
            self.send_response(server.prompt_async_status)
            self.end_headers()
            return

        self.send_response(404)
        self.end_headers()

    def do_GET(self):
        server: FakeDoor = self.server  # type: ignore
        server.get_calls.append(self.path)
        if server.get_status == 0:
            self.close_connection = True
            return
        self.send_response(server.get_status)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        import json
        self.wfile.write(json.dumps(server.get_response_data).encode("utf-8"))


class FakeDoor(http.server.HTTPServer):
    def __init__(self):
        super().__init__(("127.0.0.1", 0), FakeDoorHandler)
        self.move_calls = []
        self.prompt_async_calls = []
        self.get_calls = []
        self.move_status = 204
        self.move_body = ""
        self.get_status = 200
        self.get_response_data = {}
        self.prompt_async_status = 204
        self.on_prompt_async: Any = None
        self.on_move: Any = None
        self.thread = threading.Thread(target=self.serve_forever)
        self.thread.daemon = True
        self.thread.start()

    def stop(self):
        self.shutdown()
        self.server_close()
        self.thread.join(timeout=2)


class TestApply(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.repo = init_git_repo(os.path.join(self.tmpdir.name, "repo"))
        self.worktrees_dir = os.path.join(self.repo, ".worktrees")
        os.makedirs(self.worktrees_dir, exist_ok=True)
        self.db_path = os.path.join(self.tmpdir.name, "opencode.db")
        self.db_conn = init_test_db(self.db_path)
        self.door = FakeDoor()
        self.door_url = f"http://127.0.0.1:{self.door.server_port}"
        os.environ["OPENCODE_FRONTDOOR_URL"] = self.door_url
        os.environ["OPENCODE_DB"] = self.db_path
        os.environ["OPENCODE_NOTICE_POLL_TIMEOUT"] = "0.05"
        self._part_seq = 0

    def tearDown(self):
        self.door.stop()
        self.db_conn.close()
        self.tmpdir.cleanup()
        os.environ.pop("OPENCODE_FRONTDOOR_URL", None)
        os.environ.pop("OPENCODE_DB", None)
        os.environ.pop("OPENCODE_NOTICE_POLL_TIMEOUT", None)

    def _add_session(self, sid: str, dead_dir: str):
        cur = self.db_conn.cursor()
        cur.execute(
            "INSERT INTO session (id, project_id, directory, time_created, time_updated) VALUES (?, ?, ?, ?, ?)",
            (sid, "proj_1", dead_dir, 1000, 1000),
        )
        self.db_conn.commit()

    def _add_user_message(self, sid: str, agent: str | None = None, model: dict | None = None):
        import json
        data = {"role": "user", "time": {"created": 1500}}
        if agent is not None:
            data["agent"] = agent
        if model is not None:
            data["model"] = model
        cur = self.db_conn.cursor()
        cur.execute(
            "INSERT INTO message (id, session_id, time_created, time_updated, data) VALUES (?, ?, ?, ?, ?)",
            (f"msg_user_{sid}", sid, 1500, 1500, json.dumps(data)),
        )
        self.db_conn.commit()

    def _add_message(self, sid: str, mid: str, role: str, completed: bool = True, t: int | None = None):
        if t is None:
            t = int(time.time() * 1000)
        data = {
            "role": role,
            "time": {"created": t},
        }
        if completed:
            data["time"]["completed"] = t + 50
        cur = self.db_conn.cursor()
        cur.execute(
            "INSERT INTO message (id, session_id, time_created, time_updated, data) VALUES (?, ?, ?, ?, ?)",
            (mid, sid, t, t, json.dumps(data)),
        )
        self.db_conn.commit()

    def _commit_branch(self, branch: str, msg: str = "A commit") -> str:
        main_tip = subprocess.run(["git", "rev-parse", "main"], cwd=self.repo, capture_output=True, text=True, check=True).stdout.strip()
        tree = subprocess.run(["git", "rev-parse", "main^{tree}"], cwd=self.repo, capture_output=True, text=True, check=True).stdout.strip()
        commit_res = subprocess.run(
            ["git", "commit-tree", tree, "-p", main_tip, "-m", msg],
            cwd=self.repo,
            capture_output=True,
            text=True,
            check=True,
        )
        commit_sha = commit_res.stdout.strip()
        subprocess.run(["git", "update-ref", f"refs/heads/{branch}", commit_sha], cwd=self.repo, check=True, capture_output=True)
        return commit_sha

    def test_apply_success(self):
        sid = "ses_apply_success"
        dead_dir = os.path.join(self.worktrees_dir, "my-feat")
        self._add_session(sid, dead_dir)
        self._add_user_message(sid, agent="coder", model={"providerID": "anthropic", "modelID": "claude-3-5"})
        tip_sha = self._commit_branch("my-feat")

        new_path = os.path.join(self.worktrees_dir, "my-feat-r1700000000")
        self.door.move_status = 204
        self.door.get_response_data = {"id": sid, "directory": new_path}

        # Simulate door/serve landing the notice in DB upon prompt_async
        def on_prompt(path, body):
            text = body["parts"][0]["text"]
            thread_conn = sqlite3.connect(self.db_path)
            cur = thread_conn.cursor()
            cur.execute(
                "INSERT INTO part (id, message_id, session_id, time_created, time_updated, data) VALUES (?, ?, ?, ?, ?, ?)",
                ("prt_notice", "msg_notice", sid, 2000, 2000, json.dumps({"type": "text", "text": text})),
            )
            thread_conn.commit()
            thread_conn.close()

        self.door.on_prompt_async = on_prompt

        res = oc_revive.apply_revive(
            sid=sid,
            branch="my-feat",
            path=new_path,
            action="add",
            expect_tip=tip_sha,
            expect_old_dir=dead_dir,
            db_path=self.db_path,
            frontdoor_url=self.door_url,
        )
        self.assertTrue(res["ok"])
        self.assertEqual(res["path"], new_path)
        self.assertTrue(os.path.isdir(new_path))

        # Check door calls
        self.assertEqual(len(self.door.move_calls), 1)
        move_body = self.door.move_calls[0]["body"]
        self.assertEqual(move_body, {"destination": {"directory": new_path}})
        # Ensure NO moveChanges and NO sessionID
        self.assertNotIn("moveChanges", move_body)
        self.assertNotIn("sessionID", move_body)

        # Check notice prompt_async
        self.assertEqual(len(self.door.prompt_async_calls), 1)
        notice_body = self.door.prompt_async_calls[0]["body"]
        self.assertTrue(notice_body["noReply"])
        self.assertEqual(notice_body["agent"], "coder")
        self.assertEqual(notice_body["model"], {"providerID": "anthropic", "modelID": "claude-3-5"})
        self.assertTrue(notice_body["parts"][0]["synthetic"])
        self.assertEqual(notice_body["parts"][0]["metadata"]["source"], "oc-revive")
        self.assertIn(f"oc-revive-marker: {sid} {new_path}", notice_body["parts"][0]["text"])

    def test_apply_door_400_rolls_back(self):
        sid = "ses_apply_400"
        dead_dir = os.path.join(self.worktrees_dir, "feat-400")
        self._add_session(sid, dead_dir)
        tip_sha = self._commit_branch("feat-400")
        new_path = os.path.join(self.worktrees_dir, "feat-400-r1700000000")

        self.door.move_status = 400
        self.door.move_body = json.dumps({"error": "bad_request", "message": "Failed"})
        self.door.get_response_data = {"id": sid, "directory": dead_dir}

        with self.assertRaises(oc_revive.ReviveError) as ctx:
            oc_revive.apply_revive(
                sid=sid,
                branch="feat-400",
                path=new_path,
                action="add",
                expect_tip=tip_sha,
                expect_old_dir=dead_dir,
                db_path=self.db_path,
                frontdoor_url=self.door_url,
            )
        self.assertIn("Door returned 400", str(ctx.exception))
        # Worktree must have been rolled back (removed)!
        self.assertFalse(os.path.exists(new_path))

    def test_apply_door_500_no_rollback(self):
        sid = "ses_apply_500"
        dead_dir = os.path.join(self.worktrees_dir, "feat-500")
        self._add_session(sid, dead_dir)
        tip_sha = self._commit_branch("feat-500")
        new_path = os.path.join(self.worktrees_dir, "feat-500-r1700000000")

        self.door.move_status = 500
        self.door.get_response_data = {"id": sid, "directory": dead_dir}

        with self.assertRaises(oc_revive.ReviveError) as ctx:
            oc_revive.apply_revive(
                sid=sid,
                branch="feat-500",
                path=new_path,
                action="add",
                expect_tip=tip_sha,
                expect_old_dir=dead_dir,
                db_path=self.db_path,
                frontdoor_url=self.door_url,
            )
        self.assertIn("ambiguous", str(ctx.exception).lower())
        # Worktree must REMAINS on disk!
        self.assertTrue(os.path.isdir(new_path))

    def test_apply_door_504_no_rollback(self):
        sid = "ses_apply_504"
        dead_dir = os.path.join(self.worktrees_dir, "feat-504")
        self._add_session(sid, dead_dir)
        tip_sha = self._commit_branch("feat-504")
        new_path = os.path.join(self.worktrees_dir, "feat-504-r1700000000")

        self.door.move_status = 504
        self.door.get_response_data = {"id": sid, "directory": dead_dir}

        with self.assertRaises(oc_revive.ReviveError) as ctx:
            oc_revive.apply_revive(
                sid=sid,
                branch="feat-504",
                path=new_path,
                action="add",
                expect_tip=tip_sha,
                expect_old_dir=dead_dir,
                db_path=self.db_path,
                frontdoor_url=self.door_url,
            )
        # Worktree must REMAINS on disk!
        self.assertTrue(os.path.isdir(new_path))

    def test_apply_transport_error_no_rollback(self):
        sid = "ses_apply_conn"
        dead_dir = os.path.join(self.worktrees_dir, "feat-conn")
        self._add_session(sid, dead_dir)
        tip_sha = self._commit_branch("feat-conn")
        new_path = os.path.join(self.worktrees_dir, "feat-conn-r1700000000")

        # Simulate drop connection
        self.door.move_status = 0
        self.door.get_response_data = {"id": sid, "directory": dead_dir}

        with self.assertRaises(oc_revive.ReviveError):
            oc_revive.apply_revive(
                sid=sid,
                branch="feat-conn",
                path=new_path,
                action="add",
                expect_tip=tip_sha,
                expect_old_dir=dead_dir,
                db_path=self.db_path,
                frontdoor_url=self.door_url,
            )
        # Worktree must REMAINS on disk!
        self.assertTrue(os.path.isdir(new_path))

    def test_apply_204_but_get_shows_old_dir_no_rollback(self):
        sid = "ses_apply_old_get"
        dead_dir = os.path.join(self.worktrees_dir, "feat-old-get")
        self._add_session(sid, dead_dir)
        tip_sha = self._commit_branch("feat-old-get")
        new_path = os.path.join(self.worktrees_dir, "feat-old-get-r1700000000")

        self.door.move_status = 204
        self.door.get_response_data = {"id": sid, "directory": dead_dir}  # still old dir!

        with self.assertRaises(oc_revive.ReviveError) as ctx:
            oc_revive.apply_revive(
                sid=sid,
                branch="feat-old-get",
                path=new_path,
                action="add",
                expect_tip=tip_sha,
                expect_old_dir=dead_dir,
                db_path=self.db_path,
                frontdoor_url=self.door_url,
            )
        self.assertIn("not verified", str(ctx.exception).lower())
        # Worktree must REMAINS on disk!
        self.assertTrue(os.path.isdir(new_path))

    def test_apply_idempotent_retry(self):
        sid = "ses_idempotent"
        dead_dir = os.path.join(self.worktrees_dir, "feat-idem")
        new_path = os.path.join(self.worktrees_dir, "feat-idem-r1700000000")
        os.makedirs(new_path, exist_ok=True)
        # Session already at new_path!
        self._add_session(sid, new_path)
        tip_sha = self._commit_branch("feat-idem")

        # Should skip worktree add and move, but still reconcile notice!
        res = oc_revive.apply_revive(
            sid=sid,
            branch="feat-idem",
            path=new_path,
            action="add",
            expect_tip=tip_sha,
            expect_old_dir=dead_dir,
            db_path=self.db_path,
            frontdoor_url=self.door_url,
        )
        self.assertTrue(res["ok"])
        self.assertEqual(len(self.door.move_calls), 0)
        self.assertEqual(len(self.door.prompt_async_calls), 1)

    def test_apply_plan_changed_when_tip_moved(self):
        sid = "ses_plan_changed"
        dead_dir = os.path.join(self.worktrees_dir, "feat-tip-moved")
        self._add_session(sid, dead_dir)
        old_tip = self._commit_branch("feat-tip-moved", msg="old commit")
        # Tip moves:
        new_tip = self._commit_branch("feat-tip-moved", msg="new commit")
        new_path = os.path.join(self.worktrees_dir, "feat-tip-moved-r1700000000")

        with self.assertRaises(oc_revive.ReviveError) as ctx:
            oc_revive.apply_revive(
                sid=sid,
                branch="feat-tip-moved",
                path=new_path,
                action="add",
                expect_tip=old_tip,  # expects old_tip, but branch is now at new_tip
                expect_old_dir=dead_dir,
                db_path=self.db_path,
                frontdoor_url=self.door_url,
            )
        self.assertIn("plan-changed", str(ctx.exception))
        self.assertFalse(os.path.exists(new_path))

    def test_apply_rollback_safety_check_references_p(self):
        sid = "ses_rollback_safety"
        dead_dir = os.path.join(self.worktrees_dir, "feat-ref")
        self._add_session(sid, dead_dir)
        tip_sha = self._commit_branch("feat-ref")
        new_path = os.path.join(self.worktrees_dir, "feat-ref-r1700000000")

        # Manually create worktree to test rollback safety directly
        subprocess.run(["git", "worktree", "add", new_path, "feat-ref"], cwd=self.repo, check=True, capture_output=True)
        self.assertTrue(os.path.isdir(new_path))

        # Seed another session row that references new_path
        cur = self.db_conn.cursor()
        cur.execute(
            "INSERT INTO session (id, directory, time_created, time_updated) VALUES (?, ?, ?, ?)",
            ("ses_other", new_path, 1000, 1000),
        )
        self.db_conn.commit()

        # rollback_if_safe must NOT remove new_path because ses_other references it!
        rolled_back = oc_revive.rollback_if_safe(
            self.repo,
            new_path,
            self.db_conn,
            sid,
            self.door_url,
        )
        self.assertFalse(rolled_back)
        self.assertTrue(os.path.isdir(new_path))

    def test_apply_notice_omits_absent_agent_and_model(self):
        sid = "ses_absent_model"
        dead_dir = os.path.join(self.worktrees_dir, "feat-no-model")
        self._add_session(sid, dead_dir)
        # User message with NO agent and NO model
        self._add_user_message(sid, agent=None, model=None)
        tip_sha = self._commit_branch("feat-no-model")
        new_path = os.path.join(self.worktrees_dir, "feat-no-model-r1700000000")

        self.door.move_status = 204
        self.door.get_response_data = {"id": sid, "directory": new_path}

        oc_revive.apply_revive(
            sid=sid,
            branch="feat-no-model",
            path=new_path,
            action="add",
            expect_tip=tip_sha,
            expect_old_dir=dead_dir,
            db_path=self.db_path,
            frontdoor_url=self.door_url,
        )
        self.assertEqual(len(self.door.prompt_async_calls), 1)
        notice_body = self.door.prompt_async_calls[0]["body"]
        self.assertNotIn("agent", notice_body)
        self.assertNotIn("model", notice_body)

    def test_apply_marker_skips_second_notice(self):
        sid = "ses_marker_skip"
        dead_dir = os.path.join(self.worktrees_dir, "feat-marker")
        tip_sha = self._commit_branch("feat-marker")
        new_path = os.path.join(self.worktrees_dir, "feat-marker-r1700000000")
        os.makedirs(new_path, exist_ok=True)
        # Real retry: session is already at new_path (P)
        self._add_session(sid, new_path)

        # Seed marker in part table
        cur = self.db_conn.cursor()
        cur.execute(
            "INSERT INTO part (id, message_id, session_id, time_created, time_updated, data) VALUES (?, ?, ?, ?, ?, ?)",
            ("prt_m", "msg_m", sid, 1000, 1000, json.dumps({"type": "text", "text": f"notice oc-revive-marker: {sid} {new_path}"})),
        )
        self.db_conn.commit()

        self.door.move_status = 204
        self.door.get_response_data = {"id": sid, "directory": new_path}

        oc_revive.apply_revive(
            sid=sid,
            branch="feat-marker",
            path=new_path,
            action="add",
            expect_tip=tip_sha,
            expect_old_dir=dead_dir,
            db_path=self.db_path,
            frontdoor_url=self.door_url,
        )
        # Should NOT send prompt_async
        self.assertEqual(len(self.door.prompt_async_calls), 0)

    def test_apply_directory_neither_target_nor_expect_old_dir_aborts(self):
        sid = "ses_mismatch"
        dead_dir = os.path.join(self.worktrees_dir, "feat-expected")
        actual_dir = os.path.join(self.worktrees_dir, "feat-unexpected")
        self._add_session(sid, actual_dir)
        tip_sha = self._commit_branch("feat-expected")
        new_path = os.path.join(self.worktrees_dir, "feat-expected-r1700000000")

        with self.assertRaises(oc_revive.ReviveError) as ctx:
            oc_revive.apply_revive(
                sid=sid,
                branch="feat-expected",
                path=new_path,
                action="add",
                expect_tip=tip_sha,
                expect_old_dir=dead_dir,
                db_path=self.db_path,
                frontdoor_url=self.door_url,
            )
        self.assertIn("directory-mismatch", str(ctx.exception))
        self.assertEqual(len(self.door.move_calls), 0)
        self.assertEqual(len(self.door.prompt_async_calls), 0)
        self.assertFalse(os.path.exists(new_path))

    def test_apply_refuses_session_busy_after_plan(self):
        sid = "ses_apply_busy"
        dead_dir = os.path.join(self.worktrees_dir, "feat-apply-busy")
        self._add_session(sid, dead_dir)
        tip_sha = self._commit_branch("feat-apply-busy")
        new_path = os.path.join(self.worktrees_dir, "feat-apply-busy-r1700000000")

        # Session became busy after plan: trailing incomplete recent assistant message
        self._add_message(
            sid=sid,
            mid="msg_apply_busy",
            role="assistant",
            completed=False,
            t=int(time.time() * 1000),
        )

        with self.assertRaises(oc_revive.ReviveError) as ctx:
            oc_revive.apply_revive(
                sid=sid,
                branch="feat-apply-busy",
                path=new_path,
                action="add",
                expect_tip=tip_sha,
                expect_old_dir=dead_dir,
                db_path=self.db_path,
                frontdoor_url=self.door_url,
            )
        self.assertIn("busy_session", str(ctx.exception))
        self.assertEqual(len(self.door.move_calls), 0)
        self.assertEqual(len(self.door.prompt_async_calls), 0)
        self.assertFalse(os.path.exists(new_path))

    def test_apply_retry_notice_names_dead_dir_not_p(self):
        import hashlib
        sid = "ses_retry_notice"
        dead_dir = os.path.join(self.worktrees_dir, "feat-old")
        new_path = os.path.join(self.worktrees_dir, "feat-old-r1700000000")
        os.makedirs(new_path, exist_ok=True)
        # Session already at new_path (real retry!)
        self._add_session(sid, new_path)
        tip_sha = self._commit_branch("feat-old")

        self.door.move_status = 204
        self.door.get_response_data = {"id": sid, "directory": new_path}

        res = oc_revive.apply_revive(
            sid=sid,
            branch="feat-old",
            path=new_path,
            action="add",
            expect_tip=tip_sha,
            expect_old_dir=dead_dir,
            db_path=self.db_path,
            frontdoor_url=self.door_url,
        )
        self.assertTrue(res["ok"])
        self.assertEqual(len(self.door.prompt_async_calls), 1)
        notice_body = self.door.prompt_async_calls[0]["body"]
        notice_text = notice_body["parts"][0]["text"]

        # Notice must name dead_dir as deleted
        self.assertIn(f"({dead_dir}) was deleted", notice_text)
        # Notice must NOT claim new_path (P) was deleted
        self.assertNotIn(f"({new_path}) was deleted", notice_text)

        # Snapshot path must be sha1(dead_dir), NOT sha1(new_path)
        sha1_dead = hashlib.sha1(dead_dir.encode("utf-8")).hexdigest()
        sha1_p = hashlib.sha1(new_path.encode("utf-8")).hexdigest()
        self.assertIn(sha1_dead, notice_text)
        self.assertNotIn(sha1_p, notice_text)

    def test_apply_step_8_p_missing_on_disk_aborts(self):
        import shutil
        sid = "ses_step8_missing"
        dead_dir = os.path.join(self.worktrees_dir, "feat-step8")
        self._add_session(sid, dead_dir)
        tip_sha = self._commit_branch("feat-step8")
        new_path = os.path.join(self.worktrees_dir, "feat-step8-r1700000000")

        self.door.move_status = 204
        self.door.get_response_data = {"id": sid, "directory": new_path}

        # Simulate race condition: nightly sweeper removes P before Step 8
        def on_prompt(path, body):
            if os.path.exists(new_path):
                shutil.rmtree(new_path)

        self.door.on_prompt_async = on_prompt

        with self.assertRaises(oc_revive.ReviveError) as ctx:
            oc_revive.apply_revive(
                sid=sid,
                branch="feat-step8",
                path=new_path,
                action="add",
                expect_tip=tip_sha,
                expect_old_dir=dead_dir,
                db_path=self.db_path,
                frontdoor_url=self.door_url,
            )
        self.assertIn("missing on disk after move", str(ctx.exception))

    def test_apply_sigterm_safety(self):
        sid = "ses_sigterm"
        dead_dir = os.path.join(self.worktrees_dir, "feat-sigterm")
        self._add_session(sid, dead_dir)
        tip_sha = self._commit_branch("feat-sigterm")
        new_path = os.path.join(self.worktrees_dir, "feat-sigterm-r1700000000")

        self.door.move_status = 204
        self.door.get_response_data = {"id": sid, "directory": new_path}

        signal_delivered = False

        def on_prompt(path, body):
            nonlocal signal_delivered
            signal_delivered = True
            # Deliver SIGTERM during Step 7
            os.kill(os.getpid(), signal.SIGTERM)

        self.door.on_prompt_async = on_prompt

        parent_sigterm_called = False

        def parent_handler(signum, frame):
            nonlocal parent_sigterm_called
            parent_sigterm_called = True

        prev_handler = signal.signal(signal.SIGTERM, parent_handler)
        try:
            res = oc_revive.apply_revive(
                sid=sid,
                branch="feat-sigterm",
                path=new_path,
                action="add",
                expect_tip=tip_sha,
                expect_old_dir=dead_dir,
                db_path=self.db_path,
                frontdoor_url=self.door_url,
            )
            self.assertTrue(signal_delivered)
            self.assertTrue(res["ok"])
            self.assertEqual(len(self.door.move_calls), 1)
            self.assertEqual(len(self.door.prompt_async_calls), 1)
            self.assertTrue(os.path.isdir(new_path))
            self.assertTrue(parent_sigterm_called)
        finally:
            signal.signal(signal.SIGTERM, prev_handler)

    def test_apply_flock_bounded(self):
        sid = "ses_flock"
        dead_dir = os.path.join(self.worktrees_dir, "feat-flock")
        self._add_session(sid, dead_dir)
        tip_sha = self._commit_branch("feat-flock")
        new_path = os.path.join(self.worktrees_dir, "feat-flock-r1700000000")

        # Determine git common dir and lock path
        res = subprocess.run(
            ["git", "-C", self.repo, "rev-parse", "--git-common-dir"],
            capture_output=True,
            text=True,
            check=True,
        )
        git_common = res.stdout.strip()
        if not os.path.isabs(git_common):
            git_common = os.path.normpath(os.path.join(self.repo, git_common))
        lock_path = os.path.join(git_common, "oc-revive.lock")

        # Acquire lock from external fd
        lock_fd = os.open(lock_path, os.O_CREAT | os.O_RDWR)
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            start = time.time()
            with mock.patch.dict(os.environ, {"OPENCODE_LOCK_TIMEOUT_SECONDS": "0.1"}):
                with self.assertRaises(oc_revive.ReviveError) as ctx:
                    oc_revive.apply_revive(
                        sid=sid,
                        branch="feat-flock",
                        path=new_path,
                        action="add",
                        expect_tip=tip_sha,
                        expect_old_dir=dead_dir,
                        db_path=self.db_path,
                        frontdoor_url=self.door_url,
                    )
            elapsed = time.time() - start
            self.assertIn("Timed out waiting for lock", str(ctx.exception))
            self.assertLess(elapsed, 1.0)
        finally:
            fcntl.flock(lock_fd, fcntl.LOCK_UN)
            os.close(lock_fd)

    def test_action_reuse_rejected(self):
        with self.assertRaises(oc_revive.ReviveError) as ctx:
            oc_revive.apply_revive(
                sid="ses_x",
                branch="feat-x",
                path="/tmp/path",
                action="reuse",
                expect_tip="abc",
                expect_old_dir="/tmp/old",
                db_path=self.db_path,
                frontdoor_url=self.door_url,
            )
        self.assertIn("Action 'reuse' not permitted", str(ctx.exception))

    def test_db_never_written_during_apply(self):
        import hashlib
        sid = "ses_db_ro"
        dead_dir = os.path.join(self.worktrees_dir, "feat-ro")
        self._add_session(sid, dead_dir)
        tip_sha = self._commit_branch("feat-ro")
        new_path = os.path.join(self.worktrees_dir, "feat-ro-r1700000000")

        self.door.move_status = 204
        self.door.get_response_data = {"id": sid, "directory": new_path}

        with open(self.db_path, "rb") as f:
            hash_before = hashlib.sha256(f.read()).hexdigest()

        oc_revive.apply_revive(
            sid=sid,
            branch="feat-ro",
            path=new_path,
            action="add",
            expect_tip=tip_sha,
            expect_old_dir=dead_dir,
            db_path=self.db_path,
            frontdoor_url=self.door_url,
        )

        with open(self.db_path, "rb") as f:
            hash_after = hashlib.sha256(f.read()).hexdigest()

        self.assertEqual(hash_before, hash_after)


class TestConstants(unittest.TestCase):
    def test_move_timeout_seconds_derived_and_at_least_90(self):
        self.assertGreaterEqual(oc_revive.MOVE_TIMEOUT_SECONDS, 90)
        self.assertEqual(oc_revive.DOOR_FORWARD_TIMEOUT_SECONDS, 60)
        self.assertEqual(oc_revive.DOOR_RESOLVE_WORST_CASE_SECONDS, 15)
        self.assertEqual(
            oc_revive.MOVE_TIMEOUT_SECONDS,
            oc_revive.DOOR_FORWARD_TIMEOUT_SECONDS
            + oc_revive.DOOR_RESOLVE_WORST_CASE_SECONDS
            + oc_revive.TIMEOUT_MARGIN_SECONDS,
        )

    def test_default_frontdoor_and_no_direct_serve_addresses(self):
        # 1. Default front door is http://127.0.0.1:4700
        with mock.patch.dict(os.environ, {}, clear=True):
            os.environ.pop("OPENCODE_FRONTDOOR_URL", None)
            self.assertEqual(oc_revive.DEFAULT_FRONTDOOR_URL, "http://127.0.0.1:4700")

        # 2. Shipped code pkgs/oc-revive/oc_revive.py must NOT address individual serves (127.0.0.1:4096-4099)
        src_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "oc_revive.py")
        with open(src_path, "r", encoding="utf-8") as f:
            src = f.read()

        import re
        forbidden_pattern = re.compile(r"127\.0\.0\.1:409[6-9]|localhost:409[6-9]")
        self.assertIsNone(
            forbidden_pattern.search(src),
            "Shipped code must not address individual serves (127.0.0.1:4096-4099)",
        )


import io


class TestCLI(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.repo = init_git_repo(os.path.join(self.tmpdir.name, "repo"))
        self.worktrees_dir = os.path.join(self.repo, ".worktrees")
        os.makedirs(self.worktrees_dir, exist_ok=True)
        self.db_path = os.path.join(self.tmpdir.name, "opencode.db")
        self.db_conn = init_test_db(self.db_path)
        self.door = FakeDoor()
        self.door_url = f"http://127.0.0.1:{self.door.server_port}"
        os.environ["OPENCODE_FRONTDOOR_URL"] = self.door_url
        os.environ["OPENCODE_DB"] = self.db_path
        os.environ["OPENCODE_NOTICE_POLL_TIMEOUT"] = "0.05"

    def tearDown(self):
        self.door.stop()
        self.db_conn.close()
        self.tmpdir.cleanup()
        os.environ.pop("OPENCODE_FRONTDOOR_URL", None)
        os.environ.pop("OPENCODE_DB", None)
        os.environ.pop("OPENCODE_NOTICE_POLL_TIMEOUT", None)

    def _add_session(self, sid: str, dead_dir: str):
        cur = self.db_conn.cursor()
        cur.execute(
            "INSERT INTO session (id, project_id, directory, time_created, time_updated) VALUES (?, ?, ?, ?, ?)",
            (sid, "proj_1", dead_dir, 1000, 1000),
        )
        self.db_conn.commit()

    def _commit_branch(self, branch: str, msg: str = "A commit") -> str:
        main_tip = subprocess.run(["git", "rev-parse", "main"], cwd=self.repo, capture_output=True, text=True, check=True).stdout.strip()
        tree = subprocess.run(["git", "rev-parse", "main^{tree}"], cwd=self.repo, capture_output=True, text=True, check=True).stdout.strip()
        commit_res = subprocess.run(
            ["git", "commit-tree", tree, "-p", main_tip, "-m", msg],
            cwd=self.repo,
            capture_output=True,
            text=True,
            check=True,
        )
        commit_sha = commit_res.stdout.strip()
        subprocess.run(["git", "update-ref", f"refs/heads/{branch}", commit_sha], cwd=self.repo, check=True, capture_output=True)
        return commit_sha

    def test_cli_plan_json_output(self):
        sid = "ses_cli_plan"
        dead_dir = os.path.join(self.worktrees_dir, "cli-feat")
        self._add_session(sid, dead_dir)
        self._commit_branch("cli-feat")

        stdout = io.StringIO()
        stderr = io.StringIO()
        with mock.patch("sys.stdout", stdout), mock.patch("sys.stderr", stderr):
            rc = oc_revive.main(["plan", sid])
        self.assertEqual(rc, 0)
        parsed = json.loads(stdout.getvalue())
        self.assertTrue(parsed["revivable"])
        self.assertEqual(parsed["sid"], sid)

    def test_cli_plan_unrevivable_exits_0(self):
        stdout = io.StringIO()
        stderr = io.StringIO()
        with mock.patch("sys.stdout", stdout), mock.patch("sys.stderr", stderr):
            rc = oc_revive.main(["plan", "ses_nonexistent"])
        self.assertEqual(rc, 0)
        parsed = json.loads(stdout.getvalue())
        self.assertFalse(parsed["revivable"])
        self.assertTrue(parsed["reason"].startswith("session_not_found:"))

    def test_cli_apply_invocation(self):
        sid = "ses_cli_apply"
        dead_dir = os.path.join(self.worktrees_dir, "cli-apply-feat")
        self._add_session(sid, dead_dir)
        tip_sha = self._commit_branch("cli-apply-feat")
        new_path = os.path.join(self.worktrees_dir, "cli-apply-feat-r1700000000")

        self.door.move_status = 204
        self.door.get_response_data = {"id": sid, "directory": new_path}

        stdout = io.StringIO()
        with mock.patch("sys.stdout", stdout):
            rc = oc_revive.main([
                "apply",
                sid,
                "--branch",
                "cli-apply-feat",
                "--path",
                new_path,
                "--action",
                "add",
                "--expect-tip",
                tip_sha,
                "--expect-old-dir",
                dead_dir,
            ])
        self.assertEqual(rc, 0)
        self.assertTrue(os.path.isdir(new_path))

    def test_cli_apply_missing_expect_old_dir_exits_2(self):
        stderr = io.StringIO()
        with mock.patch("sys.stderr", stderr):
            rc = oc_revive.main([
                "apply",
                "ses_test",
                "--branch", "feat",
                "--path", "/path",
                "--action", "add",
                "--expect-tip", "sha",
            ])
        self.assertEqual(rc, 2)
        self.assertIn("--expect-old-dir", stderr.getvalue())

    def test_cli_interactive_declined(self):
        sid = "ses_cli_decline"
        dead_dir = os.path.join(self.worktrees_dir, "cli-decline")
        self._add_session(sid, dead_dir)
        self._commit_branch("cli-decline")

        stdout = io.StringIO()
        stdin = io.StringIO("n\n")  # user declines
        with mock.patch("sys.stdout", stdout), mock.patch("sys.stdin", stdin):
            rc = oc_revive.main([sid])
        self.assertEqual(rc, 0)
        out = stdout.getvalue()
        self.assertIn("Plan for session", out)
        self.assertIn("Aborted", out)

    def test_cli_interactive_confirmed(self):
        sid = "ses_cli_confirm"
        dead_dir = os.path.join(self.worktrees_dir, "cli-confirm")
        self._add_session(sid, dead_dir)
        tip_sha = self._commit_branch("cli-confirm")

        self.door.move_status = 204

        def on_move(path, body):
            dest = body["destination"]["directory"]
            self.door.get_response_data = {"id": sid, "directory": dest}

        self.door.on_move = on_move

        stdout = io.StringIO()
        stdin = io.StringIO("y\n")  # user confirms
        with mock.patch("sys.stdout", stdout), mock.patch("sys.stdin", stdin):
            rc = oc_revive.main([sid])
        self.assertEqual(rc, 0)
        out = stdout.getvalue()
        self.assertIn("Successfully revived", out)
        # Verify the created worktree path matches the moved destination and exists on disk
        dest_path = self.door.get_response_data["directory"]
        self.assertTrue(os.path.isdir(dest_path))


if __name__ == "__main__":
    unittest.main()
