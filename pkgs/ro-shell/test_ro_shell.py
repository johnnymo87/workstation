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

BASE_PARENT = os.path.join(os.environ.get("HOME", "/tmp"), ".cache", "ro-shell-tests")
os.makedirs(BASE_PARENT, exist_ok=True)
TEST_BASE = tempfile.mkdtemp(dir=BASE_PARENT)
SHARED_ROOT = os.path.join(TEST_BASE, "shared")
THROWAWAY_ROOT = os.path.join(TEST_BASE, "throwaway")
os.makedirs(SHARED_ROOT, exist_ok=True)
os.makedirs(THROWAWAY_ROOT, exist_ok=True)

os.environ["TMPDIR"] = THROWAWAY_ROOT
os.environ["RO_SHELL_TMP_ROOTS"] = THROWAWAY_ROOT


def tearDownModule():
    shutil.rmtree(TEST_BASE, ignore_errors=True)


def real(repo, *args):
    return subprocess.run([REAL_GIT, "-C", repo, *args], capture_output=True, text=True, check=True).stdout


def make_repo(parent=None):
    if parent is None:
        parent = SHARED_ROOT
    d = tempfile.mkdtemp(dir=parent)
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
    env = dict(os.environ, RO_SHELL_REAL_GIT=REAL_GIT, RO_SHELL_TMP_ROOTS=THROWAWAY_ROOT)
    return subprocess.run([os.path.join(SHIM_DIR, "git"), *args], cwd=repo, env=env,
                          capture_output=True, text=True)


ALLOWED = [
    ["status"], ["diff"], ["diff", "--stat", "HEAD"], ["diff", "--output-indicator-new=>"],
    ["log", "--oneline"], ["show", "HEAD"],
    ["blame", "f.txt"], ["rev-parse", "HEAD"], ["ls-files"], ["grep", "one"],
    ["branch"], ["branch", "-a"], ["branch", "--contains", "HEAD"], ["tag"], ["tag", "-l"],
    ["worktree", "list"], ["stash", "list"],
    ["reflog"], ["reflog", "HEAD"], ["reflog", "main"], ["reflog", "show", "HEAD"], ["reflog", "-n", "3"],
    ["config", "--get", "user.name"],
    ["config", "--list"], ["remote", "-v"], ["--no-pager", "log", "-1"], ["-C", ".", "status"],
    ["st"], ["lg"], ["--version"], ["merge-base", "HEAD", "HEAD"], ["cat-file", "-p", "HEAD"],
    ["submodule", "--quiet", "status"], ["notes"],
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
    ["submodule", "update"], ["gc"], ["reflog", "expire", "--all"],
    ["reflog", "-n", "1", "delete", "HEAD@{0}"],
    ["config", "user.name", "x"],
    ["config", "--unset", "user.name"], ["diff", "--output=/tmp/ro-shell-test-out"],
    ["log", "--output=/tmp/ro-shell-test-out"],
    ["-c", "alias.x=reset", "x", "--hard"], ["-c", "core.pager=sh", "log"],
    ["--exec-path=/tmp", "status"], ["bang"], ["stash", "pop"], ["notes", "add", "-m", "x"],
    ["grep", "-Ols", "one"], ["grep", "--open-files-in-pager=sh", "one"],
    ["help", "-w"], ["help", "--web"],
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
        source_shim = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ro_git.py")
        r = subprocess.run([sys.executable, source_shim, "status"], cwd=self.repo, env=env,
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, REFUSED)
        self.assertIn("misconfigured", r.stderr)

    def test_throwaway_repo_allows_mutations(self):
        t_repo = make_repo(parent=THROWAWAY_ROOT)
        try:
            for args in [["commit", "--allow-empty", "-m", "msg"], ["stash"], ["reset", "--hard"], ["checkout", "-b", "x"]]:
                with self.subTest(args=args):
                    r = shim(t_repo, args)
                    self.assertNotEqual(r.returncode, REFUSED, r.stderr)
                    self.assertNotIn("ro-shell: refused", r.stderr)
        finally:
            shutil.rmtree(t_repo, ignore_errors=True)

    def test_init_and_clone_allowed(self):
        new_repo = os.path.join(THROWAWAY_ROOT, "new_repo")
        r = shim(self.repo, ["init", new_repo])
        self.assertNotEqual(r.returncode, REFUSED, r.stderr)
        self.assertNotIn("ro-shell: refused", r.stderr)

    def test_worktree_operations(self):
        wt_path = os.path.join(THROWAWAY_ROOT, "wt")
        r = shim(self.repo, ["worktree", "add", "--detach", wt_path, "HEAD"])
        self.assertNotEqual(r.returncode, REFUSED, r.stderr)
        self.assertNotIn("ro-shell: refused", r.stderr)

        # Inside that worktree, stash is REFUSED because common dir is shared repo
        r_stash = shim(wt_path, ["stash"])
        self.assertEqual(r_stash.returncode, REFUSED, r_stash.stderr)
        self.assertIn("ro-shell: refused", r_stash.stderr)

        # Worktree remove --force on temp path succeeds
        r_rm = shim(self.repo, ["worktree", "remove", "--force", wt_path])
        self.assertNotEqual(r_rm.returncode, REFUSED, r_rm.stderr)
        self.assertNotIn("ro-shell: refused", r_rm.stderr)

        # Worktree add with branch creation is refused
        r_b = shim(self.repo, ["worktree", "add", "-b", "nb", os.path.join(THROWAWAY_ROOT, "wt2"), "HEAD"])
        self.assertEqual(r_b.returncode, REFUSED, r_b.stderr)
        self.assertIn("ro-shell: refused", r_b.stderr)

        # Worktree add to non-temp path is refused
        non_temp_wt = os.path.join(SHARED_ROOT, "wt_nontemp")
        r_nt = shim(self.repo, ["worktree", "add", "--detach", non_temp_wt, "HEAD"])
        self.assertEqual(r_nt.returncode, REFUSED, r_nt.stderr)
        self.assertIn("ro-shell: refused", r_nt.stderr)


sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))


class CheckCommandTest(unittest.TestCase):
    def test_bypasses_refused(self):
        import ro_shell
        for cmd in ["/nix/store/abc-git-2.50/bin/git stash", "/run/current-system/sw/bin/git reset --hard",
                    "PATH=/usr/bin git stash", "env PATH=/x git stash", "export PATH=/x; git stash",
                    "RO_SHELL_TMP_ROOTS=/ git stash", "export RO_SHELL_TMP_ROOTS=/; git stash",
                    "command -p git stash", "x=1 PATH=/y git status",
                    "bash -lc 'command -v git'", "bash -lc 'git stash'", "bash -cl 'git stash'",
                    "bash -l -c 'git stash'", "bash -il 'git stash'",
                    "bash -i -c 'git stash'", "bash -ic 'git stash'", "bash -ci 'git stash'",
                    "bash --interactive -c 'git stash'", "sh -i -c 'git stash'",
                    "bash --login -c 'git stash'", "sh -l -c 'git stash'",
                    "/bin/bash -lc 'git stash'", "bash -c 'bash -lc \"git stash\"'",
                    "sh -c \"bash --login -c 'git stash'\""]:
            with self.subTest(cmd=cmd):
                self.assertIsNotNone(ro_shell.check_command(cmd))

    def test_normal_commands_pass(self):
        import ro_shell
        for cmd in ["git diff | head", "rg -n foo src/", "cd sub && git log -1", "echo $PATH",
                    "ls ~/projects/git-tools", "cat .gitignore",
                    "bash -c 'ls -l'", "ls -l", 'sh -c "wc -l"']:
            with self.subTest(cmd=cmd):
                self.assertIsNone(ro_shell.check_command(cmd))


class RunCommandTest(unittest.TestCase):
    def setUp(self):
        self.repo = make_repo()
        os.environ["RO_SHELL_SHIM_DIR"] = SHIM_DIR

    def tearDown(self):
        shutil.rmtree(self.repo, ignore_errors=True)

    def test_indirect_git_hits_shim(self):
        import ro_shell
        before = snapshot(self.repo)
        for cmd in ["sh -c 'git stash'", "echo stash | xargs git", "find . -maxdepth 0 -exec git stash \\;",
                    "bash -c 'cd . && git checkout -- f.txt'", "git co .", "(git reset --hard)"]:
            with self.subTest(cmd=cmd):
                code, out = ro_shell.run_command(cmd, self.repo, 30)
                self.assertIn("ro-shell: refused", out)
        self.assertEqual(snapshot(self.repo), before)

    def test_read_only_git_works_and_cwd_honoured(self):
        import ro_shell
        code, out = ro_shell.run_command("git diff --stat && pwd", self.repo, 30)
        self.assertEqual(code, 0, out)
        self.assertIn("f.txt", out)
        self.assertIn(os.path.realpath(self.repo), os.path.realpath(out.strip().splitlines()[-1]))

    def test_timeout(self):
        import ro_shell
        code, out = ro_shell.run_command("sleep 5", self.repo, 1)
        self.assertIn("timed out", out)

    def test_profile_markers_in_child_env(self):
        import ro_shell
        code, out = ro_shell.run_command(
            "echo $__ETC_PROFILE_DONE$__NIXOS_SET_ENVIRONMENT_DONE$__HM_SESS_VARS_SOURCED",
            self.repo, 30
        )
        self.assertEqual(code, 0, out)
        self.assertEqual(out.strip(), "111")

    def test_interactive_shell_hits_shim(self):
        import ro_shell
        before = snapshot(self.repo)
        code, out = ro_shell.run_command("bash -i -c 'git stash'", self.repo, 30)
        self.assertIn("ro-shell: refused", out)
        self.assertEqual(snapshot(self.repo), before)

    def test_child_env_lacks_sensitive_vars(self):
        import ro_shell
        code, out = ro_shell.run_command('echo "[$RO_SHELL_REAL_GIT][$RO_SHELL_TMP_ROOTS]"', self.repo, 30)
        self.assertEqual(code, 0, out)
        self.assertEqual(out.strip(), "[][]")


@unittest.skipUnless(os.environ.get("RO_SHELL_BIN"), "packaged binary only")
class McpStdioTest(unittest.TestCase):
    """End-to-end over stdio JSON-RPC against the PACKAGED binary."""

    def rpc(self, proc, msg):
        proc.stdin.write(json.dumps(msg) + "\n")
        proc.stdin.flush()
        if "id" not in msg:
            return None
        while True:
            line = proc.stdout.readline()
            self.assertTrue(line, "server closed stdout")
            resp = json.loads(line)
            if resp.get("id") == msg["id"]:
                return resp

    def test_tools_list_and_call(self):
        repo = make_repo()
        proc = subprocess.Popen([os.environ["RO_SHELL_BIN"]], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, text=True)
        try:
            self.rpc(proc, {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
                "protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "t", "version": "0"}}})
            self.rpc(proc, {"jsonrpc": "2.0", "method": "notifications/initialized"})
            tools = self.rpc(proc, {"jsonrpc": "2.0", "id": 2, "method": "tools/list"})["result"]["tools"]
            self.assertEqual([t["name"] for t in tools], ["shell"])
            r = self.rpc(proc, {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {
                "name": "shell", "arguments": {"command": "pwd; git stash"},
                "_meta": {"agent-working-dir": repo}}})["result"]
            text = "".join(c.get("text", "") for c in r["content"])
            self.assertIn(os.path.realpath(repo), text)       # goose's per-call working dir honoured
            self.assertIn("ro-shell: refused", text)
            r = self.rpc(proc, {"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {
                "name": "shell", "arguments": {"command": "/nix/store/x-git/bin/git stash"}}})["result"]
            self.assertTrue(r.get("isError"), r)
            r = self.rpc(proc, {"jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": {
                "name": "shell", "arguments": {"command": 'echo "[$RO_SHELL_REAL_GIT]"; git status'},
                "_meta": {"agent-working-dir": repo}}})["result"]
            text = "".join(c.get("text", "") for c in r["content"])
            self.assertIn("[]", text)
            self.assertIn("On branch main", text)
        finally:
            proc.kill()
            if proc.stdin:
                proc.stdin.close()
            if proc.stdout:
                proc.stdout.close()
            proc.wait()
            shutil.rmtree(repo, ignore_errors=True)


if __name__ == "__main__":
    unittest.main(verbosity=2)
