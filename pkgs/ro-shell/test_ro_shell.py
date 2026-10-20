#!/usr/bin/env python3
"""Tests for ro-shell: the read-only git shim and the MCP shell tool.

Env:
  RO_SHELL_BIN       the packaged ro-shell (MCP server) -- B2 tests
  RO_SHELL_SHIM_DIR  dir containing the shim installed as `git`
  RO_SHELL_REAL_GIT  the real git binary
"""
import json, os, shutil, subprocess, sys, tempfile, unittest

SHIM_DIR = os.environ["RO_SHELL_SHIM_DIR"]
REAL_GIT = os.environ["RO_SHELL_REAL_GIT"]
REFUSED = 3


def real(repo, *args):
    return subprocess.run([REAL_GIT, "-C", repo, *args], capture_output=True, text=True, check=True).stdout


def make_repo():
    d = tempfile.mkdtemp()
    real(d, "init", "-q", "-b", "main")
    real(d, "config", "user.email", "t@example.com")
    real(d, "config", "user.name", "t")
    real(d, "config", "alias.st", "status")
    real(d, "config", "alias.lg", "log --oneline")
    real(d, "config", "alias.co", "checkout")
    real(d, "config", "alias.ci", "commit")
    real(d, "config", "alias.bang", "!rm -rf .")
    with open(os.path.join(d, "f.txt"), "w") as fh:
        fh.write("one\n")
    real(d, "add", "f.txt")
    real(d, "commit", "-qm", "init")
    with open(os.path.join(d, "f.txt"), "a") as fh:
        fh.write("uncommitted\n")  # the peer's precious uncommitted work
    return d


def snapshot(repo):
    with open(os.path.join(repo, "f.txt")) as fh:
        content = fh.read()
    return (real(repo, "status", "--porcelain"), real(repo, "stash", "list"),
            real(repo, "for-each-ref"), content)


def shim(repo, args):
    env = dict(os.environ, RO_SHELL_REAL_GIT=REAL_GIT)
    return subprocess.run([os.path.join(SHIM_DIR, "git"), *args], cwd=repo, env=env,
                          capture_output=True, text=True)


ALLOWED = [
    ["status"], ["diff"], ["diff", "--stat", "HEAD"], ["log", "--oneline"], ["show", "HEAD"],
    ["blame", "f.txt"], ["rev-parse", "HEAD"], ["ls-files"], ["grep", "one"],
    ["branch"], ["branch", "-a"], ["branch", "--contains", "HEAD"], ["tag"], ["tag", "-l"],
    ["worktree", "list"], ["stash", "list"], ["reflog"], ["config", "--get", "user.name"],
    ["config", "--list"], ["remote", "-v"], ["--no-pager", "log", "-1"], ["-C", ".", "status"],
    ["st"], ["lg"], ["--version"], ["merge-base", "HEAD", "HEAD"], ["cat-file", "-p", "HEAD"],
]

REFUSED_CASES = [
    ["stash"], ["stash", "push"], ["checkout", "."], ["checkout", "--", "f.txt"], ["co", "."],
    ["ci", "-am", "x"], ["reset", "--hard"], ["restore", "f.txt"], ["clean", "-fd"],
    ["switch", "-c", "x"], ["commit", "-am", "x"], ["push"], ["pull"], ["fetch"],
    ["rebase", "main"], ["merge", "main"], ["cherry-pick", "HEAD"], ["revert", "HEAD"],
    ["apply", "x.patch"], ["am"], ["rm", "f.txt"], ["mv", "f.txt", "g.txt"],
    ["checkout-index", "-a", "-f"], ["read-tree", "-u", "HEAD"], ["update-ref", "refs/heads/x", "HEAD"],
    ["branch", "-D", "main"], ["branch", "newbranch"], ["branch", "-m", "x"], ["tag", "v1"],
    ["tag", "-d", "v1"], ["worktree", "remove", "x"], ["worktree", "add", "x"],
    ["submodule", "update"], ["gc"], ["reflog", "expire", "--all"], ["config", "user.name", "x"],
    ["config", "--unset", "user.name"], ["diff", "--output=/tmp/ro-shell-test-out"],
    ["-c", "alias.x=reset", "x", "--hard"], ["-c", "core.pager=sh", "log"],
    ["--exec-path=/tmp", "status"], ["bang"], ["stash", "pop"], ["notes", "add", "-m", "x"],
]


class ShimTest(unittest.TestCase):
    def setUp(self):
        self.repo = make_repo()

    def tearDown(self):
        shutil.rmtree(self.repo, ignore_errors=True)

    def test_allowed(self):
        for args in ALLOWED:
            with self.subTest(args=args):
                r = shim(self.repo, args)
                self.assertNotEqual(r.returncode, REFUSED, r.stderr)
                self.assertNotIn("ro-shell: refused", r.stderr)

    def test_refused_and_repo_untouched(self):
        before = snapshot(self.repo)
        for args in REFUSED_CASES:
            with self.subTest(args=args):
                r = shim(self.repo, args)
                self.assertEqual(r.returncode, REFUSED, (args, r.stdout, r.stderr))
                self.assertIn("ro-shell: refused", r.stderr)
        self.assertEqual(snapshot(self.repo), before)
        self.assertFalse(os.path.exists("/tmp/ro-shell-test-out"))

    def test_misconfigured_shim_refuses(self):
        env = dict(os.environ)
        env.pop("RO_SHELL_REAL_GIT", None)
        r = subprocess.run([os.path.join(SHIM_DIR, "git"), "status"], cwd=self.repo, env=env,
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, REFUSED)


if __name__ == "__main__":
    unittest.main(verbosity=2)
