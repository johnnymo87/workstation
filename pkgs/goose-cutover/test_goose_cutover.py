"""Strict tests for goose-cutover (L3a, bead workstation-6w7i.27.3)."""

from contextlib import contextmanager
import json
import os
from pathlib import Path
import sys
import unittest
from typing import Any, Callable, Optional

sys.path.insert(0, str(Path(__file__).resolve().parent))
import goose_cutover


class RunResult:
    def __init__(self, rc: int, stdout: str = "", stderr: str = ""):
        self.rc = rc
        self.stdout = stdout
        self.stderr = stderr

    def __iter__(self):
        return iter((self.rc, self.stdout, self.stderr))


class FakeFlockContext:
    def __init__(self, runner: "FakeRunner", path: str, shared: bool, nonblocking: bool):
        self.runner = runner
        self.path = path
        self.shared = shared
        self.nonblocking = nonblocking

    def __enter__(self):
        if self.path in self.runner.flock_busy:
            raise BlockingIOError(f"Resource temporarily unavailable: {self.path}")
        if self.path in self.runner.locks_held and not self.shared:
            raise BlockingIOError(f"Resource locked: {self.path}")
        self.runner.locks_held.add(self.path)
        self.runner.lock_events.append(("acquire", self.path))
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        if self.path in self.runner.locks_held:
            self.runner.locks_held.remove(self.path)
        self.runner.lock_events.append(("release", self.path))


class FakeRunner(goose_cutover.Runner):
    """STRICT FakeRunner: raises AssertionError on unexpected commands."""

    def __init__(self):
        self.files: dict[str, str] = {}
        self.links: dict[str, str] = {}
        self.env: dict[str, str] = {}
        self.calls: list[dict[str, Any]] = []
        self.cmd_handlers: list[
            tuple[
                Callable[[list[str], Optional[str], Optional[str]], bool],
                Callable[[list[str], Optional[str], Optional[dict[str, str]], Optional[str]], RunResult],
            ]
        ] = []
        self.sleep_calls: list[float] = []
        self.current_time: float = 1700000000.0
        self.locks_held: set[str] = set()
        self.flock_busy: set[str] = set()
        self.lock_events: list[tuple[str, str]] = []
        self.current_link_target = "/nix/store/old-goose"
        self.pr_state = "OPEN"
        self.honkd_pid = "777"
        self.goose_pid = "555"

    def run(
        self,
        argv: list[str],
        user: Optional[str] = None,
        env: Optional[dict[str, str]] = None,
        check: bool = True,
        timeout: Optional[float] = None,
        cwd: Optional[str] = None,
    ) -> RunResult:
        self.calls.append({
            "argv": list(argv),
            "user": user,
            "env": dict(env) if env else None,
            "check": check,
            "timeout": timeout,
            "cwd": cwd,
        })
        for pred, handler in self.cmd_handlers:
            if pred(argv, user, cwd):
                res = handler(argv, user, env, cwd)
                if check and res.rc != 0:
                    prog = argv[0] if argv else "command"
                    raise RuntimeError(f"{prog} failed (exit {res.rc}): {res.stderr.strip()[:1000]}")
                return res
        raise AssertionError(f"FakeRunner: unexpected command: {argv!r} (user={user}, cwd={cwd})")

    def read_file(self, path: str) -> str:
        if path not in self.files:
            raise FileNotFoundError(f"No such file: {path}")
        return self.files[path]

    def write_file(self, path: str, content: str) -> None:
        self.files[path] = content

    def exists(self, path: str) -> bool:
        return path in self.files or path in self.links

    def readlink(self, path: str) -> str:
        if path not in self.links:
            raise FileNotFoundError(f"No such link: {path}")
        return self.links[path]

    def listdir(self, path: str) -> list[str]:
        prefix = path.rstrip("/") + "/"
        entries = set()
        for p in list(self.files.keys()) + list(self.links.keys()):
            if p.startswith(prefix):
                rest = p[len(prefix):]
                name = rest.split("/")[0]
                entries.add(name)
        return sorted(list(entries))

    def now(self) -> float:
        return self.current_time

    def sleep(self, seconds: float) -> None:
        self.sleep_calls.append(seconds)
        self.current_time += seconds

    def flock(self, path: str, shared: bool = False, nonblocking: bool = True):
        return FakeFlockContext(self, path, shared, nonblocking)

    @contextmanager
    def hold_dev_lock(self, path: str):
        if path in self.flock_busy or path in self.locks_held:
            raise BlockingIOError(f"Dev lock {path} busy")
        self.locks_held.add(path)
        self.lock_events.append(("acquire_dev", path))
        try:
            yield
        finally:
            if path in self.locks_held:
                self.locks_held.remove(path)
            self.lock_events.append(("release_dev", path))

    def get_env(self, key: str, default: Optional[str] = None) -> Optional[str]:
        return self.env.get(key, default)


def setup_standard_runner() -> FakeRunner:
    runner = FakeRunner()
    runner.files["/proc/self/cgroup"] = "0::/system.slice/goose-cutover@prepare-902.service\n"
    runner.files["/proc/sys/kernel/hostname"] = "cloudbox\n"
    runner.env["INVOCATION_ID"] = "test-invocation-123"
    runner.env["GOOSE_HOST_REPORTS_DIR"] = "/var/lib/goose-cutover/host-reports"
    runner.env["GOOSE_CUTOVER_HOSTS"] = "devbox,mac"
    runner.env["HONK_BIN"] = "/home/dev/.nix-profile/bin/honk"
    runner.files["/run/secrets/github_api_token"] = "gh-secret-token\n"
    runner.files["/run/secrets/pigeon_goose_acp_token"] = "acp-secret-token\n"
    runner.files["/home/dev/.nix-profile/bin/goose-upgrade-probe"] = "binary"
    runner.files["/home/dev/.nix-profile/bin/honk"] = "binary"

    runner.files["/proc/555/cmdline"] = "/var/lib/goose/current/bin/goose\0"
    runner.links["/proc/555/exe"] = "/nix/store/cand-goose-1.54.0-patched.19/bin/goose"
    runner.links["/proc/777/exe"] = "/nix/store/cand-goose-1.54.0-patched.19/bin/goose"

    # Host reports
    runner.files["/var/lib/goose-cutover/host-reports/devbox.json"] = json.dumps({
        "host": "devbox",
        "ts": runner.current_time - 3600,
        "link_current": "/nix/store/devbox-goose",
        "honk_version": "0.5.0",
    })
    runner.files["/var/lib/goose-cutover/host-reports/mac.json"] = json.dumps({
        "host": "mac",
        "ts": runner.current_time - 3600,
        "link_current": "/nix/store/mac-goose",
        "honk_version": "0.5.0",
    })

    # Standard handlers
    def std_handler(argv: list[str], user: Optional[str], env: Optional[dict[str, str]], cwd: Optional[str]) -> RunResult:
        cmd = argv[0]

        if cmd == "goose-link":
            sub = argv[1]
            if sub == "status":
                return RunResult(0, f"current={runner.current_link_target}\nprevious=<none>\npinned=/nix/store/old-goose\npinned_is_current=yes\n")
            if sub == "set":
                runner.current_link_target = argv[2]
                return RunResult(0, f"goose-link: current={runner.current_link_target}\n")

        if cmd == "gh":
            if argv[1:3] == ["pr", "view"]:
                return RunResult(0, json.dumps({
                    "state": runner.pr_state,
                    "baseRefName": "main",
                    "labels": [{"name": "goose-upgrade"}],
                    "headRefOid": "headsha123",
                    "mergeable": "MERGEABLE",
                    "files": [{"path": "pkgs/goose/default.nix"}],
                    "statusCheckRollup": [{"name": "ci", "conclusion": "SUCCESS"}],
                    "mergeCommit": ({"oid": getattr(runner, "merge_commit", "mergesha123")}
                                    if getattr(runner, "merge_commit", "mergesha123") else None),
                }))
            if argv[1:3] == ["pr", "merge"]:
                runner.pr_state = "MERGED"
                return RunResult(0, "Merged\n")
            if argv[1:3] == ["pr", "edit"]:
                return RunResult(0, "Updated\n")
            if argv[1:3] == ["pr", "create"]:
                return RunResult(0, "https://github.com/johnnymo87/workstation/pull/999\n")

        if cmd == "git":
            if "rev-parse" in argv:
                if "origin/main" in argv:
                    return RunResult(0, "mainsha123\n")
                if "refs/remotes/origin/pr/902/merge^1" in argv:
                    return RunResult(0, "mainsha123\n")
            if "fetch" in argv:
                return RunResult(0, "")
            if "worktree" in argv:
                return RunResult(0, "")
            if "revert" in argv or "push" in argv:
                return RunResult(0, "")

        if cmd == "nix":
            if argv[1] == "build":
                for i, a in enumerate(argv):
                    if a == "--out-link":
                        target = argv[i + 1]
                        if "candidate" in target:
                            runner.links[target] = "/nix/store/cand-goose-1.54.0-patched.19"
                        elif "toplevel" in target:
                            runner.links[target] = "/nix/store/toplevel-123"
                        elif "hm" in target:
                            runner.links[target] = "/nix/store/hm-123"
                return RunResult(0, "")

        if "goose-upgrade-probe" in cmd:
            return RunResult(0, "All probe checks passed\n")

        honk_bin = runner.get_env("HONK_BIN") or "/home/dev/.nix-profile/bin/honk"
        if cmd == honk_bin:
            if argv[1:3] == ["list", "--json"]:
                return RunResult(0, json.dumps([]))
            if argv[1] == "launch":
                return RunResult(0, "native=sess_123 gse=123 tag=goose-upgrade prompt=PONG\n")
            if argv[1] == "--version":
                return RunResult(0, "honk 0.5.0\n")

        if cmd == "timeout":
            if any(honk_bin in a for a in argv) and "tail" in argv:
                return RunResult(0, "Turn complete: PONG\n")

        if cmd == "sqlite3":
            if "SELECT max(id)" in " ".join(argv):
                return RunResult(0, "100\n")
            if ".backup" in " ".join(argv):
                return RunResult(0, "")

        if cmd == "journalctl":
            if "stall-watch" in " ".join(argv):
                ts_ms = int(runner.current_time * 1000)
                return RunResult(0, json.dumps({"ts": ts_ms, "ok": True, "runs": 0, "coordinator": {"runs": 0}}) + "\n")
            if "honkd" in " ".join(argv):
                return RunResult(0, "Upstream control connection re-initialized successfully\n")

        if cmd == "curl":
            if "/status" in argv[-1]:
                return RunResult(0, '{"status":"ok"}\n')
            if any("/acp" in a for a in argv):
                return RunResult(0, json.dumps({
                    "id": 1,
                    "jsonrpc": "2.0",
                    "result": {"agentInfo": {"name": "goose", "version": "1.54.0"}}
                }))

        if cmd == "systemctl":
            if "is-active" in argv:
                return RunResult(3, "inactive\n")
            if "show" in argv:
                full = " ".join(argv)
                if "ExecMainStartTimestampMonotonic" in full:
                    return RunResult(0, "ExecMainStartTimestampMonotonic=1000\n")
                if "MainPID" in full:
                    if "honkd" in full:
                        return RunResult(0, "MainPID=777\n")
                    return RunResult(0, "MainPID=555\n")
                if "ExecStart" in full:
                    return RunResult(0, "ExecStart={ path=/nix/store/cand-goose-1.54.0-patched.19/bin/goose ; argv_0=goose }\n")
            if argv[1] == "start":
                return RunResult(0, "")
            if argv[1] == "stop":
                return RunResult(0, "")
            if argv[1] == "restart":
                return RunResult(0, "")
            if argv[1:3] == ["--user", "stop"]:
                return RunResult(0, "")
            if argv[1:3] == ["--user", "start"]:
                return RunResult(0, "")
            if argv[1:3] == ["--user", "restart"]:
                return RunResult(0, "")

        if cmd == "sudo":
            if argv[1:3] == ["systemctl", "start"]:
                return RunResult(0, "")

        if cmd == "flock":
            if argv[1:3] == ["-n", "/var/lib/goose-cutover/run.lock"]:
                return RunResult(0, "")

        if cmd == "readlink":
            if argv[-1] == "/nix/var/nix/profiles/system":
                return RunResult(0, "/nix/store/old-system-toplevel\n")
            if argv[-1] == "/proc/555/exe":
                return RunResult(0, "/nix/store/cand-goose-1.54.0-patched.19/bin/goose\n")
            if argv[-1] == "/proc/777/exe":
                return RunResult(0, "/nix/store/cand-goose-1.54.0-patched.19/bin/goose\n")

        if "switch-to-configuration" in cmd:
            return RunResult(0, "")

        if cmd == "nix-env":
            return RunResult(0, "")

        if "activate" in cmd:
            return RunResult(0, "")

        if "opencode-drift-alert" in cmd:
            return RunResult(0, "")

        if cmd == "rm":
            return RunResult(0, "")

        raise AssertionError(f"Unhandled command in std_handler: {argv!r}")

    runner.cmd_handlers.append((lambda a, u, c: True, std_handler))
    return runner


class TestGooseCutover(unittest.TestCase):
    def test_strict_fakerunner_raises_on_unhandled_command(self):
        runner = FakeRunner()
        with self.assertRaises(AssertionError) as cm:
            runner.run(["unhandled-command", "foo"])
        self.assertIn("unhandled-command", str(cm.exception))

    def test_launcher_refuses_in_goose_serve_cgroup(self):
        runner = setup_standard_runner()
        runner.files["/proc/self/cgroup"] = "0::/system.slice/goose-serve.service\n"
        rc = goose_cutover.main(["prepare", "902"], runner=runner)
        self.assertEqual(rc, 2)
        self.assertFalse(any("systemctl" in c["argv"] for c in runner.calls))

    def test_launcher_refuses_when_run_lock_busy(self):
        runner = setup_standard_runner()
        runner.cmd_handlers.insert(0, (
            lambda a, u, c: a[:3] == ["flock", "-n", "/var/lib/goose-cutover/run.lock"],
            lambda a, u, e, c: RunResult(1, "", "resource busy")
        ))
        rc = goose_cutover.main(["prepare", "902"], runner=runner)
        self.assertEqual(rc, 2)
        self.assertFalse(any("systemctl" in c["argv"] for c in runner.calls))

    def test_launcher_proceeds_when_run_lock_unopenable(self):
        # Fresh host: run.lock absent and not creatable by the caller (flock rc 66).
        runner = setup_standard_runner()
        runner.files["/proc/self/cgroup"] = "0::/user.slice/user-1000.slice/session-1.scope\n"
        runner.cmd_handlers.insert(0, (
            lambda a, u, c: a[:3] == ["flock", "-n", "/var/lib/goose-cutover/run.lock"],
            lambda a, u, e, c: RunResult(66, "", "cannot open lock file: Permission denied")
        ))
        rc = goose_cutover.main(["prepare", "902", "--dry-run", "--allow-noop"], runner=runner)
        self.assertEqual(rc, 0)
        self.assertTrue(any("systemctl" in c["argv"] for c in runner.calls))

    def test_launcher_starts_systemd_unit(self):
        runner = setup_standard_runner()
        runner.files["/proc/self/cgroup"] = "0::/user.slice/user-1000.slice/session-1.scope\n"
        rc = goose_cutover.main(["prepare", "902", "--dry-run", "--allow-noop"], runner=runner)
        self.assertEqual(rc, 0)
        started = [c["argv"] for c in runner.calls if "systemctl" in c["argv"]]
        self.assertTrue(any("goose-cutover@prepare-dry-noop-902.service" in " ".join(cmd) for cmd in started))

    def test_run_refuses_outside_unit_missing_invocation_id(self):
        runner = setup_standard_runner()
        runner.env.pop("INVOCATION_ID", None)
        rc = goose_cutover.main(["--run", "prepare-902"], runner=runner)
        self.assertEqual(rc, 2)

    def test_run_refuses_outside_unit_wrong_cgroup(self):
        runner = setup_standard_runner()
        runner.files["/proc/self/cgroup"] = "0::/user.slice/user-1000.slice/session-1.scope\n"
        rc = goose_cutover.main(["--run", "prepare-902"], runner=runner)
        self.assertEqual(rc, 2)

    def test_run_global_lock_busy(self):
        runner = setup_standard_runner()
        runner.flock_busy.add("/var/lib/goose-cutover/run.lock")
        rc = goose_cutover.main(["--run", "prepare-902"], runner=runner)
        self.assertEqual(rc, 1)

    def test_p1_hostname_not_cloudbox_fails(self):
        runner = setup_standard_runner()
        runner.files["/proc/sys/kernel/hostname"] = "devbox\n"
        rc = goose_cutover.main(["--run", "prepare-902"], runner=runner)
        self.assertNotEqual(rc, 0)

    def test_p1_goose_link_status_fails(self):
        runner = setup_standard_runner()
        runner.cmd_handlers.insert(0, (
            lambda a, u, c: a[:2] == ["goose-link", "status"],
            lambda a, u, e, c: RunResult(1, "", "failed")
        ))
        rc = goose_cutover.main(["--run", "prepare-902"], runner=runner)
        self.assertNotEqual(rc, 0)

    def test_p1_state_already_prepared_fails(self):
        runner = setup_standard_runner()
        runner.files["/var/lib/goose-cutover/state.json"] = json.dumps({"phase": "prepared", "pr": 901})
        rc = goose_cutover.main(["--run", "prepare-902"], runner=runner)
        self.assertNotEqual(rc, 0)

    def test_p1_state_already_deploying_fails(self):
        runner = setup_standard_runner()
        runner.files["/var/lib/goose-cutover/state.json"] = json.dumps({"phase": "deploying", "pr": 901})
        rc = goose_cutover.main(["--run", "prepare-902"], runner=runner)
        self.assertNotEqual(rc, 0)

    def test_p1_state_already_failed_refuses(self):
        runner = setup_standard_runner()
        runner.files["/var/lib/goose-cutover/state.json"] = json.dumps({"phase": "failed", "pr": 901, "step": "probe"})
        rc = goose_cutover.main(["--run", "prepare-902"], runner=runner)
        self.assertNotEqual(rc, 0)

    def test_p1_pr_not_open_fails(self):
        runner = setup_standard_runner()
        runner.cmd_handlers.insert(0, (
            lambda a, u, c: a[:3] == ["gh", "pr", "view"],
            lambda a, u, e, c: RunResult(0, json.dumps({
                "state": "CLOSED",
                "baseRefName": "main",
                "labels": [{"name": "goose-upgrade"}],
                "headRefOid": "h",
                "files": [{"path": "pkgs/goose/default.nix"}],
                "statusCheckRollup": [{"name": "ci", "conclusion": "SUCCESS"}],
            }))
        ))
        rc = goose_cutover.main(["--run", "prepare-902"], runner=runner)
        self.assertNotEqual(rc, 0)

    def test_p1_pr_base_not_main_fails(self):
        runner = setup_standard_runner()
        runner.cmd_handlers.insert(0, (
            lambda a, u, c: a[:3] == ["gh", "pr", "view"],
            lambda a, u, e, c: RunResult(0, json.dumps({
                "state": "OPEN",
                "baseRefName": "feature-branch",
                "labels": [{"name": "goose-upgrade"}],
                "headRefOid": "h",
                "files": [{"path": "pkgs/goose/default.nix"}],
                "statusCheckRollup": [{"name": "ci", "conclusion": "SUCCESS"}],
            }))
        ))
        rc = goose_cutover.main(["--run", "prepare-902"], runner=runner)
        self.assertNotEqual(rc, 0)

    def test_p1_pr_missing_goose_upgrade_label_fails(self):
        runner = setup_standard_runner()
        runner.cmd_handlers.insert(0, (
            lambda a, u, c: a[:3] == ["gh", "pr", "view"],
            lambda a, u, e, c: RunResult(0, json.dumps({
                "state": "OPEN",
                "baseRefName": "main",
                "labels": [{"name": "other-label"}],
                "headRefOid": "h",
                "files": [{"path": "pkgs/goose/default.nix"}],
                "statusCheckRollup": [{"name": "ci", "conclusion": "SUCCESS"}],
            }))
        ))
        rc = goose_cutover.main(["--run", "prepare-902"], runner=runner)
        self.assertNotEqual(rc, 0)

    def test_p1_goose_major_without_major_ok_fails(self):
        runner = setup_standard_runner()
        runner.cmd_handlers.insert(0, (
            lambda a, u, c: a[:3] == ["gh", "pr", "view"],
            lambda a, u, e, c: RunResult(0, json.dumps({
                "state": "OPEN",
                "baseRefName": "main",
                "labels": [{"name": "goose-upgrade"}, {"name": "goose-major"}],
                "headRefOid": "h",
                "files": [{"path": "pkgs/goose/default.nix"}],
                "statusCheckRollup": [{"name": "ci", "conclusion": "SUCCESS"}],
            }))
        ))
        rc = goose_cutover.main(["--run", "prepare-902"], runner=runner)
        self.assertNotEqual(rc, 0)

    def test_p1_goose_major_with_major_ok_passes(self):
        runner = setup_standard_runner()
        runner.cmd_handlers.insert(0, (
            lambda a, u, c: a[:3] == ["gh", "pr", "view"],
            lambda a, u, e, c: RunResult(0, json.dumps({
                "state": "OPEN",
                "baseRefName": "main",
                "labels": [{"name": "goose-upgrade"}, {"name": "goose-major"}, {"name": "goose-major-ok"}],
                "headRefOid": "headsha123",
                "mergeable": "MERGEABLE",
                "files": [{"path": "pkgs/goose/default.nix"}],
                "statusCheckRollup": [{"name": "ci", "conclusion": "SUCCESS"}],
                "mergeCommit": {"oid": "mergesha123"},
            }))
        ))
        rc = goose_cutover.main(["--run", "prepare-dry-902"], runner=runner)
        self.assertEqual(rc, 0)

    def test_p1_files_outside_pkgs_goose_without_config_ok_fails(self):
        runner = setup_standard_runner()
        runner.cmd_handlers.insert(0, (
            lambda a, u, c: a[:3] == ["gh", "pr", "view"],
            lambda a, u, e, c: RunResult(0, json.dumps({
                "state": "OPEN",
                "baseRefName": "main",
                "labels": [{"name": "goose-upgrade"}],
                "headRefOid": "h",
                "files": [{"path": "pkgs/goose/default.nix"}, {"path": "modules/goose-cutover.nix"}],
                "statusCheckRollup": [{"name": "ci", "conclusion": "SUCCESS"}],
            }))
        ))
        rc = goose_cutover.main(["--run", "prepare-902"], runner=runner)
        self.assertNotEqual(rc, 0)

    def test_p1_files_outside_pkgs_goose_with_config_ok_passes(self):
        runner = setup_standard_runner()
        runner.cmd_handlers.insert(0, (
            lambda a, u, c: a[:3] == ["gh", "pr", "view"],
            lambda a, u, e, c: RunResult(0, json.dumps({
                "state": "OPEN",
                "baseRefName": "main",
                "labels": [{"name": "goose-upgrade"}, {"name": "goose-config-ok"}],
                "headRefOid": "headsha123",
                "mergeable": "MERGEABLE",
                "files": [{"path": "pkgs/goose/default.nix"}, {"path": "modules/goose-cutover.nix"}],
                "statusCheckRollup": [{"name": "ci", "conclusion": "SUCCESS"}],
                "mergeCommit": {"oid": "mergesha123"},
            }))
        ))
        rc = goose_cutover.main(["--run", "prepare-dry-902"], runner=runner)
        self.assertEqual(rc, 0)

    def test_p1_empty_status_check_rollup_fails(self):
        runner = setup_standard_runner()
        runner.cmd_handlers.insert(0, (
            lambda a, u, c: a[:3] == ["gh", "pr", "view"],
            lambda a, u, e, c: RunResult(0, json.dumps({
                "state": "OPEN",
                "baseRefName": "main",
                "labels": [{"name": "goose-upgrade"}],
                "headRefOid": "h",
                "files": [{"path": "pkgs/goose/default.nix"}],
                "statusCheckRollup": [],
            }))
        ))
        rc = goose_cutover.main(["--run", "prepare-902"], runner=runner)
        self.assertNotEqual(rc, 0)

    def test_p1_checks_pending_or_failed_fails(self):
        runner = setup_standard_runner()
        runner.cmd_handlers.insert(0, (
            lambda a, u, c: a[:3] == ["gh", "pr", "view"],
            lambda a, u, e, c: RunResult(0, json.dumps({
                "state": "OPEN",
                "baseRefName": "main",
                "labels": [{"name": "goose-upgrade"}],
                "headRefOid": "h",
                "files": [{"path": "pkgs/goose/default.nix"}],
                "statusCheckRollup": [{"name": "ci", "conclusion": "FAILURE"}],
            }))
        ))
        rc = goose_cutover.main(["--run", "prepare-902"], runner=runner)
        self.assertNotEqual(rc, 0)

    def test_p1_hosts_ready_missing_report_fails_closed(self):
        runner = setup_standard_runner()
        runner.files.pop("/var/lib/goose-cutover/host-reports/devbox.json")
        rc = goose_cutover.main(["--run", "prepare-902"], runner=runner)
        self.assertNotEqual(rc, 0)

    def test_p1_hosts_ready_stale_report_fails_closed(self):
        runner = setup_standard_runner()
        runner.files["/var/lib/goose-cutover/host-reports/devbox.json"] = json.dumps({
            "host": "devbox",
            "ts": runner.current_time - (27 * 3600),
            "link_current": "/nix/store/devbox-goose",
            "honk_version": "0.5.0",
        })
        rc = goose_cutover.main(["--run", "prepare-902"], runner=runner)
        self.assertNotEqual(rc, 0)

    def test_p1_hosts_ready_old_consumer_report_fails_closed(self):
        runner = setup_standard_runner()
        runner.files["/var/lib/goose-cutover/host-reports/devbox.json"] = json.dumps({
            "host": "devbox",
            "ts": runner.current_time - 1000,
            "link_current": "<none>",
            "honk_version": "0.5.0",
        })
        rc = goose_cutover.main(["--run", "prepare-902"], runner=runner)
        self.assertNotEqual(rc, 0)

    def test_p1_hosts_ready_version_below_min_fails_closed(self):
        runner = setup_standard_runner()
        runner.env["GOOSE_MIN_HONK_VERSION"] = "0.6.0"
        rc = goose_cutover.main(["--run", "prepare-902"], runner=runner)
        self.assertNotEqual(rc, 0)

    def test_p1_hosts_ready_pass_applies_label_in_normal_run(self):
        runner = setup_standard_runner()
        rc = goose_cutover.main(["--run", "prepare-902"], runner=runner)
        self.assertEqual(rc, 0)
        label_calls = [c["argv"] for c in runner.calls if "pr" in c["argv"] and "edit" in c["argv"]]
        self.assertTrue(any("goose-hosts-ready" in cmd for cmd in label_calls))

    def test_p1_hosts_ready_pass_dry_run_does_not_apply_label(self):
        runner = setup_standard_runner()
        rc = goose_cutover.main(["--run", "prepare-dry-902"], runner=runner)
        self.assertEqual(rc, 0)
        label_calls = [c["argv"] for c in runner.calls if "pr" in c["argv"] and "edit" in c["argv"]]
        self.assertEqual(len(label_calls), 0)

    def test_p2_stale_merge_ref_fails(self):
        runner = setup_standard_runner()
        runner.cmd_handlers.insert(0, (
            lambda a, u, c: "refs/remotes/origin/pr/902/merge^1" in a,
            lambda a, u, e, c: RunResult(0, "oldparentsha\n")
        ))
        rc = goose_cutover.main(["--run", "prepare-902"], runner=runner)
        self.assertNotEqual(rc, 0)

    def test_p2_noop_refused_without_allow_noop(self):
        runner = setup_standard_runner()
        runner.current_link_target = "/nix/store/cand-goose-1.54.0-patched.19"
        rc = goose_cutover.main(["--run", "prepare-902"], runner=runner)
        self.assertNotEqual(rc, 0)

    def test_p2_noop_allowed_with_allow_noop(self):
        runner = setup_standard_runner()
        runner.current_link_target = "/nix/store/cand-goose-1.54.0-patched.19"
        rc = goose_cutover.main(["--run", "prepare-dry-noop-902"], runner=runner)
        self.assertEqual(rc, 0)

    def test_p3_probe_fail_stops_before_merge(self):
        runner = setup_standard_runner()
        runner.cmd_handlers.insert(0, (
            lambda a, u, c: "goose-upgrade-probe" in a[0],
            lambda a, u, e, c: RunResult(1, "", "probe failed badly")
        ))
        rc = goose_cutover.main(["--run", "prepare-902"], runner=runner)
        self.assertNotEqual(rc, 0)
        self.assertFalse(any("merge" in c["argv"] for c in runner.calls))

    def test_p4_merged_mismatch_fails(self):
        runner = setup_standard_runner()
        build_count = 0
        def nix_handler(a, u, e, c):
            nonlocal build_count
            if a[:2] == ["nix", "build"]:
                build_count += 1
                for i, arg in enumerate(a):
                    if arg == "--out-link":
                        link = a[i + 1]
                        if "candidate" in link:
                            if build_count > 1:
                                runner.links[link] = "/nix/store/different-candidate"
                            else:
                                runner.links[link] = "/nix/store/cand-goose-1.54.0-patched.19"
                        elif "toplevel" in link:
                            runner.links[link] = "/nix/store/toplevel-123"
                        elif "hm" in link:
                            runner.links[link] = "/nix/store/hm-123"
                return RunResult(0, "")
            raise AssertionError(f"unexpected nix command: {a}")
        runner.cmd_handlers.insert(0, (lambda a, u, c: a[:2] == ["nix", "build"], nix_handler))

        rc = goose_cutover.main(["--run", "prepare-902"], runner=runner)
        self.assertNotEqual(rc, 0)
        state = json.loads(runner.files.get("/var/lib/goose-cutover/state.json", "{}"))
        self.assertEqual(state.get("phase"), "failed")
        self.assertEqual(state.get("step"), "merged-mismatch")

    def test_resume_merged_on_merged_mismatch(self):
        runner = setup_standard_runner()
        runner.pr_state = "MERGED"
        runner.files["/var/lib/goose-cutover/state.json"] = json.dumps({
            "phase": "failed", "step": "merged-mismatch", "pr": 902,
        })
        rc = goose_cutover.main(["--run", "prepare-resume-902"], runner=runner)
        self.assertEqual(rc, 0)
        state = json.loads(runner.files["/var/lib/goose-cutover/state.json"])
        self.assertEqual(state["phase"], "prepared")
        self.assertEqual(state["merge_sha"], "mergesha123")
        self.assertFalse(any("pr" in c["argv"] and "merge" in c["argv"] for c in runner.calls))

    def test_resume_merged_refuses_without_merge_commit(self):
        runner = setup_standard_runner()
        runner.pr_state = "MERGED"
        runner.merge_commit = None
        rc = goose_cutover.main(["--run", "prepare-resume-902"], runner=runner)
        self.assertNotEqual(rc, 0)
        state = json.loads(runner.files.get("/var/lib/goose-cutover/state.json") or "{}")
        self.assertNotEqual(state.get("phase"), "prepared")

    def test_resume_merged_refuses_if_failed_step_not_merged_mismatch(self):
        runner = setup_standard_runner()
        runner.pr_state = "MERGED"
        runner.files["/var/lib/goose-cutover/state.json"] = json.dumps({
            "phase": "failed", "step": "probe", "pr": 902,
        })
        rc = goose_cutover.main(["--run", "prepare-resume-902"], runner=runner)
        self.assertNotEqual(rc, 0)

    def test_prepare_dry_run_issues_no_mutations(self):
        runner = setup_standard_runner()
        rc = goose_cutover.main(["--run", "prepare-dry-902"], runner=runner)
        self.assertEqual(rc, 0)
        for c in runner.calls:
            cmd_str = " ".join(c["argv"])
            self.assertFalse("gh pr merge" in cmd_str)
            self.assertFalse("switch-to-configuration switch" in cmd_str)
            self.assertFalse("nix-env" in cmd_str and "--set" in cmd_str)
            self.assertFalse("goose-link set" in cmd_str)
            self.assertFalse("systemctl restart" in cmd_str)
            self.assertFalse("systemctl stop" in cmd_str)
            self.assertFalse("gh pr edit" in cmd_str)

    def test_prepare_success_persists_state_and_notifies(self):
        runner = setup_standard_runner()
        rc = goose_cutover.main(["--run", "prepare-902"], runner=runner)
        self.assertEqual(rc, 0)
        state_content = runner.files.get("/var/lib/goose-cutover/state.json")
        self.assertIsNotNone(state_content)
        state = json.loads(state_content or "{}")
        self.assertEqual(state["phase"], "prepared")
        self.assertEqual(state["pr"], 902)
        self.assertEqual(state["candidate"], "/nix/store/cand-goose-1.54.0-patched.19")
        self.assertEqual(state["merge_sha"], "mergesha123")
        self.assertEqual(state["built_from"], "mainsha123")

    def test_d1_refuses_if_phase_failed(self):
        runner = setup_standard_runner()
        runner.files["/var/lib/goose-cutover/state.json"] = json.dumps({
            "phase": "failed", "pr": 902,
        })
        rc = goose_cutover.main(["--run", "deploy-1"], runner=runner)
        self.assertNotEqual(rc, 0)

    def test_d3_reconcile_rebuilds_when_main_moved(self):
        runner = setup_standard_runner()
        runner.files["/var/lib/goose-cutover/state.json"] = json.dumps({
            "phase": "prepared", "pr": 902, "candidate": "/nix/store/cand-goose-1.54.0-patched.19",
            "toplevel": "/nix/store/top-old", "hm_package": "/nix/store/hm-old",
            "old_target": "/nix/store/old-goose", "merge_sha": "mergesha123", "built_from": "oldmainsha", "head_sha": "hsha",
        })
        runner.files["/nix/store/cand-goose-1.54.0-patched.19"] = "cand"
        runner.files["/nix/store/top-old"] = "top"
        runner.files["/nix/store/hm-old"] = "hm"

        def git_handler(a, u, e, c):
            if "rev-parse" in a:
                return RunResult(0, "newmainsha\n")
            if "fetch" in a or "worktree" in a:
                return RunResult(0, "")
            raise AssertionError(f"unexpected git command: {a}")
        runner.cmd_handlers.insert(0, (lambda a, u, c: a[0] == "git", git_handler))

        def nix_handler(a, u, e, c):
            if a[:2] == ["nix", "build"]:
                for i, arg in enumerate(a):
                    if arg == "--out-link":
                        link = a[i + 1]
                        if "candidate" in link:
                            runner.links[link] = "/nix/store/cand-goose-1.54.0-patched.19"
                        elif "toplevel" in link:
                            runner.links[link] = "/nix/store/top-new"
                        elif "hm" in link:
                            runner.links[link] = "/nix/store/hm-new"
                return RunResult(0, "")
            raise AssertionError(f"unexpected nix command: {a}")
        runner.cmd_handlers.insert(0, (lambda a, u, c: a[0] == "nix", nix_handler))

        ts_count = 1000
        def sys_handler(a, u, e, c):
            nonlocal ts_count
            if "ExecMainStartTimestampMonotonic" in " ".join(a):
                ts_count += 50
                return RunResult(0, f"ExecMainStartTimestampMonotonic={ts_count}\n")
            if "MainPID" in " ".join(a):
                if "honkd" in " ".join(a):
                    return RunResult(0, "MainPID=777\n")
                return RunResult(0, "MainPID=555\n")
            if "ExecStart" in " ".join(a):
                return RunResult(0, "ExecStart={ path=/nix/store/cand-goose-1.54.0-patched.19/bin/goose ; argv_0=goose }\n")
            if "is-active" in a:
                return RunResult(3, "inactive\n")
            return RunResult(0, "")
        runner.cmd_handlers.insert(0, (lambda a, u, c: a[0] == "systemctl", sys_handler))

        goose_cutover.check_quiet(runner)
        runner.current_time += 650

        rc = goose_cutover.main(["--run", "deploy-1"], runner=runner)
        self.assertEqual(rc, 0)
        state = json.loads(runner.files["/var/lib/goose-cutover/state.json"])
        self.assertEqual(state["built_from"], "newmainsha")
        self.assertEqual(state["merge_sha"], "mergesha123")  # merge_sha never overwritten!
        self.assertEqual(state["toplevel"], "/nix/store/top-new")

    def test_d3_reconcile_fails_if_candidate_changed(self):
        runner = setup_standard_runner()
        runner.files["/var/lib/goose-cutover/state.json"] = json.dumps({
            "phase": "prepared", "pr": 902, "candidate": "/nix/store/cand-goose-1.54.0-patched.19",
            "toplevel": "/nix/store/top-old", "hm_package": "/nix/store/hm-old",
            "old_target": "/nix/store/old-goose", "merge_sha": "mergesha123", "built_from": "oldmainsha", "head_sha": "hsha",
        })
        runner.files["/nix/store/cand-goose-1.54.0-patched.19"] = "cand"
        runner.files["/nix/store/top-old"] = "top"
        runner.files["/nix/store/hm-old"] = "hm"

        def git_handler(a, u, e, c):
            if "rev-parse" in a:
                return RunResult(0, "newmainsha\n")
            if "fetch" in a or "worktree" in a:
                return RunResult(0, "")
            raise AssertionError(f"unexpected git command: {a}")
        runner.cmd_handlers.insert(0, (lambda a, u, c: a[0] == "git", git_handler))

        def nix_handler(a, u, e, c):
            if a[:2] == ["nix", "build"]:
                for i, arg in enumerate(a):
                    if arg == "--out-link":
                        link = a[i + 1]
                        if "candidate" in link:
                            runner.links[link] = "/nix/store/cand-different"
                        elif "toplevel" in link:
                            runner.links[link] = "/nix/store/top-new"
                        elif "hm" in link:
                            runner.links[link] = "/nix/store/hm-new"
                return RunResult(0, "")
            raise AssertionError(f"unexpected nix command: {a}")
        runner.cmd_handlers.insert(0, (lambda a, u, c: a[0] == "nix", nix_handler))

        goose_cutover.check_quiet(runner)
        runner.current_time += 650

        rc = goose_cutover.main(["--run", "deploy-1"], runner=runner)
        self.assertEqual(rc, 1)  # candidate changed is fatal exit 1
        state = json.loads(runner.files["/var/lib/goose-cutover/state.json"])
        self.assertEqual(state["phase"], "failed")
        self.assertEqual(state["step"], "merged-mismatch")

    def test_d2_stall_watch_active_or_activating_blocks(self):
        runner = setup_standard_runner()
        runner.cmd_handlers.insert(0, (
            lambda a, u, c: a[:3] == ["systemctl", "--user", "is-active"],
            lambda a, u, e, c: RunResult(0, "activating\n")
        ))
        quiet, reason = goose_cutover.check_quiet(runner)
        self.assertFalse(quiet)
        self.assertIn("activating", reason)

    def test_d2_missing_stall_watch_tick_blocks(self):
        runner = setup_standard_runner()
        runner.cmd_handlers.insert(0, (
            lambda a, u, c: a[0] == "journalctl",
            lambda a, u, e, c: RunResult(0, "plain text without json\n")
        ))
        quiet, reason = goose_cutover.check_quiet(runner)
        self.assertFalse(quiet)
        self.assertIn("no stall-watch tick found", reason)

    def test_d2_coordinator_runs_blocks(self):
        runner = setup_standard_runner()
        runner.cmd_handlers.insert(0, (
            lambda a, u, c: a[0] == "journalctl",
            lambda a, u, e, c: RunResult(0, json.dumps({"ts": int(runner.current_time * 1000), "coordinator": {"runs": 1}}) + "\n")
        ))
        quiet, reason = goose_cutover.check_quiet(runner)
        self.assertFalse(quiet)
        self.assertIn("runs", reason)

    def test_d2_sessions_db_changing_blocks(self):
        runner = setup_standard_runner()
        val = 100
        def sqlite_handler(a, u, e, c):
            nonlocal val
            val += 1
            return RunResult(0, f"{val}\n")
        runner.cmd_handlers.insert(0, (lambda a, u, c: a[0] == "sqlite3", sqlite_handler))
        quiet, reason = goose_cutover.check_quiet(runner)
        self.assertFalse(quiet)

    def test_d2_cgroup_oom_score_adj_blocks(self):
        runner = setup_standard_runner()
        goose_cutover.check_quiet(runner)
        runner.current_time += 601
        runner.files["/sys/fs/cgroup/system.slice/goose-serve.service/cgroup.procs"] = "1234\n"
        runner.files["/proc/1234/oom_score_adj"] = "600\n"
        quiet, reason = goose_cutover.check_quiet(runner)
        self.assertFalse(quiet)
        self.assertIn("oom_score_adj", reason)

    def test_d2_honk_running_blocks(self):
        runner = setup_standard_runner()
        goose_cutover.check_quiet(runner)
        runner.current_time += 601
        honk_bin = runner.get_env("HONK_BIN") or "/home/dev/.nix-profile/bin/honk"
        runner.cmd_handlers.insert(0, (
            lambda a, u, c: a[:3] == [honk_bin, "list", "--json"],
            lambda a, u, e, c: RunResult(0, json.dumps([{"sessionId": "s1", "running": True, "pendingRequests": 0}]))
        ))
        quiet, reason = goose_cutover.check_quiet(runner)
        self.assertFalse(quiet)
        self.assertIn("busy", reason)

    def test_d2_honk_pending_requests_blocks(self):
        runner = setup_standard_runner()
        goose_cutover.check_quiet(runner)
        runner.current_time += 601
        honk_bin = runner.get_env("HONK_BIN") or "/home/dev/.nix-profile/bin/honk"
        runner.cmd_handlers.insert(0, (
            lambda a, u, c: a[:3] == [honk_bin, "list", "--json"],
            lambda a, u, e, c: RunResult(0, json.dumps([{"sessionId": "s1", "running": False, "pendingRequests": 2}]))
        ))
        quiet, reason = goose_cutover.check_quiet(runner)
        self.assertFalse(quiet)
        self.assertIn("busy", reason)

    def test_d2_honk_unknown_shape_blocks(self):
        runner = setup_standard_runner()
        goose_cutover.check_quiet(runner)
        runner.current_time += 601
        honk_bin = runner.get_env("HONK_BIN") or "/home/dev/.nix-profile/bin/honk"
        runner.cmd_handlers.insert(0, (
            lambda a, u, c: a[:3] == [honk_bin, "list", "--json"],
            lambda a, u, e, c: RunResult(0, "Not JSON at all")
        ))
        quiet, reason = goose_cutover.check_quiet(runner)
        self.assertFalse(quiet)
        self.assertIn("unknown shape", reason)

    def test_d2_all_quiet_passes_after_10min(self):
        runner = setup_standard_runner()
        goose_cutover.check_quiet(runner)
        runner.current_time += 601
        quiet, reason = goose_cutover.check_quiet(runner)
        self.assertTrue(quiet, f"Expected quiet but got: {reason}")

    def test_d2_timeout_2h_keeps_prepared_and_exits_0(self):
        runner = setup_standard_runner()
        runner.files["/var/lib/goose-cutover/state.json"] = json.dumps({
            "phase": "prepared", "pr": 902, "candidate": "/nix/store/cand", "toplevel": "/nix/store/top", "hm_package": "/nix/store/hm",
            "old_target": "/nix/store/old-goose", "merge_sha": "mainsha123", "built_from": "mainsha123", "head_sha": "hsha",
        })
        runner.files["/nix/store/cand"] = "cand"
        runner.files["/nix/store/top"] = "top"
        runner.files["/nix/store/hm"] = "hm"
        runner.cmd_handlers.insert(0, (
            lambda a, u, c: a[:3] == ["systemctl", "--user", "is-active"],
            lambda a, u, e, c: RunResult(0, "active\n")
        ))
        rc = goose_cutover.main(["--run", "deploy-1"], runner=runner)
        self.assertEqual(rc, 0)
        state = json.loads(runner.files["/var/lib/goose-cutover/state.json"])
        self.assertEqual(state["phase"], "prepared")

    def test_d2_refuses_with_less_than_60min_left(self):
        runner = setup_standard_runner()
        runner.files["/var/lib/goose-cutover/state.json"] = json.dumps({
            "phase": "prepared", "pr": 902, "candidate": "/nix/store/cand", "toplevel": "/nix/store/top", "hm_package": "/nix/store/hm",
            "old_target": "/nix/store/old-goose", "merge_sha": "mainsha123", "built_from": "mainsha123", "head_sha": "hsha",
        })
        runner.files["/nix/store/cand"] = "cand"
        runner.files["/nix/store/top"] = "top"
        runner.files["/nix/store/hm"] = "hm"
        runner.env["GOOSE_CUTOVER_START_TIME"] = str(runner.now() - 4.5 * 3600)
        rc = goose_cutover.main(["--run", "deploy-1"], runner=runner)
        self.assertEqual(rc, 0)
        state = json.loads(runner.files["/var/lib/goose-cutover/state.json"])
        self.assertEqual(state["phase"], "prepared")

    def test_d3_lock_busy_returns_to_d2_polling(self):
        runner = setup_standard_runner()
        runner.files["/var/lib/goose-cutover/state.json"] = json.dumps({
            "phase": "prepared", "pr": 902, "candidate": "/nix/store/cand", "toplevel": "/nix/store/top", "hm_package": "/nix/store/hm",
            "old_target": "/nix/store/old-goose", "merge_sha": "mainsha123", "built_from": "mainsha123", "head_sha": "hsha",
        })
        runner.files["/nix/store/cand"] = "cand"
        runner.files["/nix/store/top"] = "top"
        runner.files["/nix/store/hm"] = "hm"
        goose_cutover.check_quiet(runner)
        runner.current_time += 650

        runner.flock_busy.add("/tmp/reset-workspace.lock")
        rc = goose_cutover.main(["--run", "deploy-1"], runner=runner)
        self.assertEqual(rc, 0)
        state = json.loads(runner.files["/var/lib/goose-cutover/state.json"])
        self.assertEqual(state["phase"], "prepared")
        self.assertFalse(any("revert" in c["argv"] for c in runner.calls))

    def test_d3_stall_watch_wait_timeout_is_pre_d5_failure(self):
        runner = setup_standard_runner()
        runner.files["/var/lib/goose-cutover/state.json"] = json.dumps({
            "phase": "prepared", "pr": 902, "candidate": "/nix/store/cand", "toplevel": "/nix/store/top", "hm_package": "/nix/store/hm",
            "old_target": "/nix/store/old-goose", "merge_sha": "mainsha123", "built_from": "mainsha123", "head_sha": "hsha",
        })
        runner.files["/nix/store/cand"] = "cand"
        runner.files["/nix/store/top"] = "top"
        runner.files["/nix/store/hm"] = "hm"
        goose_cutover.check_quiet(runner)
        runner.current_time += 650

        active_calls = 0
        def act_handler(a, u, e, c):
            nonlocal active_calls
            active_calls += 1
            if active_calls > 1:
                return RunResult(0, "activating\n")
            return RunResult(3, "inactive\n")
        runner.cmd_handlers.insert(0, (lambda a, u, c: a[:3] == ["systemctl", "--user", "is-active"], act_handler))

        rc = goose_cutover.main(["--run", "deploy-1"], runner=runner)
        self.assertEqual(rc, 0)
        state = json.loads(runner.files["/var/lib/goose-cutover/state.json"])
        self.assertEqual(state["phase"], "prepared")
        self.assertFalse(any("revert" in c["argv"] for c in runner.calls))

    def test_d4_dry_activate_stderr_parsing(self):
        runner = setup_standard_runner()
        runner.files["/var/lib/goose-cutover/state.json"] = json.dumps({
            "phase": "prepared", "pr": 902, "candidate": "/nix/store/cand", "toplevel": "/nix/store/top", "hm_package": "/nix/store/hm",
            "old_target": "/nix/store/old-goose", "merge_sha": "mainsha123", "built_from": "mainsha123", "head_sha": "hsha",
        })
        runner.files["/nix/store/cand"] = "cand"
        runner.files["/nix/store/top"] = "top"
        runner.files["/nix/store/hm"] = "hm"
        goose_cutover.check_quiet(runner)
        runner.current_time += 650

        runner.cmd_handlers.insert(0, (
            lambda a, u, c: "switch-to-configuration" in a[0] and "dry-activate" in a,
            lambda a, u, e, c: RunResult(0, "", "would stop the following units: rogue.service\n")
        ))
        rc = goose_cutover.main(["--run", "deploy-1"], runner=runner)
        self.assertEqual(rc, 0)
        state = json.loads(runner.files["/var/lib/goose-cutover/state.json"])
        self.assertEqual(state["phase"], "prepared")
        self.assertFalse(any("revert" in c["argv"] for c in runner.calls))

    def test_d4_dry_activate_allowlist_refusal_exits_0_no_rollback(self):
        runner = setup_standard_runner()
        runner.files["/var/lib/goose-cutover/state.json"] = json.dumps({
            "phase": "prepared", "pr": 902, "candidate": "/nix/store/cand", "toplevel": "/nix/store/top", "hm_package": "/nix/store/hm",
            "old_target": "/nix/store/old-goose", "merge_sha": "mainsha123", "built_from": "mainsha123", "head_sha": "hsha",
        })
        runner.files["/nix/store/cand"] = "cand"
        runner.files["/nix/store/top"] = "top"
        runner.files["/nix/store/hm"] = "hm"
        goose_cutover.check_quiet(runner)
        runner.current_time += 650

        runner.cmd_handlers.insert(0, (
            lambda a, u, c: "switch-to-configuration" in a[0] and "dry-activate" in a,
            lambda a, u, e, c: RunResult(0, "would restart the following units: unexpected.service\n", "")
        ))
        rc = goose_cutover.main(["--run", "deploy-1"], runner=runner)
        self.assertEqual(rc, 0)
        state = json.loads(runner.files["/var/lib/goose-cutover/state.json"])
        self.assertEqual(state["phase"], "prepared")
        self.assertFalse(any("revert" in c["argv"] for c in runner.calls))

    def test_d4_backup_failure_is_fatal_pre_d5(self):
        runner = setup_standard_runner()
        runner.files["/var/lib/goose-cutover/state.json"] = json.dumps({
            "phase": "prepared", "pr": 902, "candidate": "/nix/store/cand", "toplevel": "/nix/store/top", "hm_package": "/nix/store/hm",
            "old_target": "/nix/store/old-goose", "merge_sha": "mainsha123", "built_from": "mainsha123", "head_sha": "hsha",
        })
        runner.files["/nix/store/cand"] = "cand"
        runner.files["/nix/store/top"] = "top"
        runner.files["/nix/store/hm"] = "hm"
        goose_cutover.check_quiet(runner)
        runner.current_time += 650

        runner.cmd_handlers.insert(0, (
            lambda a, u, c: a[0] == "sqlite3" and ".backup" in " ".join(a),
            lambda a, u, e, c: RunResult(1, "", "sqlite disk error")
        ))
        rc = goose_cutover.main(["--run", "deploy-1"], runner=runner)
        self.assertEqual(rc, 0)
        state = json.loads(runner.files["/var/lib/goose-cutover/state.json"])
        self.assertEqual(state["phase"], "prepared")
        self.assertFalse(any("revert" in c["argv"] for c in runner.calls))

    def test_deploy_dry_run_issues_no_mutating_commands(self):
        runner = setup_standard_runner()
        runner.files["/var/lib/goose-cutover/state.json"] = json.dumps({
            "phase": "prepared", "pr": 902, "candidate": "/nix/store/cand", "toplevel": "/nix/store/top", "hm_package": "/nix/store/hm",
            "old_target": "/nix/store/old-goose", "merge_sha": "mainsha123", "built_from": "mainsha123", "head_sha": "hsha",
        })
        runner.files["/nix/store/cand"] = "cand"
        runner.files["/nix/store/top"] = "top"
        runner.files["/nix/store/hm"] = "hm"
        rc = goose_cutover.main(["--run", "deploy-dry-1"], runner=runner)
        self.assertEqual(rc, 0)
        for c in runner.calls:
            cmd_str = " ".join(c["argv"])
            self.assertFalse("switch-to-configuration switch" in cmd_str)
            self.assertFalse("nix-env" in cmd_str and "--set" in cmd_str)
            self.assertFalse("goose-link set" in cmd_str)
            self.assertFalse("systemctl restart" in cmd_str)
            self.assertFalse("systemctl stop" in cmd_str)

    def test_deploy_success_writes_deployed_json_and_notifies(self):
        runner = setup_standard_runner()
        runner.files["/var/lib/goose-cutover/state.json"] = json.dumps({
            "phase": "prepared", "pr": 902, "candidate": "/nix/store/cand-goose-1.54.0-patched.19",
            "toplevel": "/nix/store/top", "hm_package": "/nix/store/hm",
            "old_target": "/nix/store/old-goose", "merge_sha": "mainsha123", "built_from": "mainsha123", "head_sha": "hsha",
        })
        runner.files["/nix/store/cand-goose-1.54.0-patched.19"] = "cand"
        runner.files["/nix/store/top"] = "top"
        runner.files["/nix/store/hm"] = "hm"

        goose_cutover.check_quiet(runner)
        runner.current_time += 650

        ts_count = 1000
        def sys_handler(a, u, e, c):
            nonlocal ts_count
            if "ExecMainStartTimestampMonotonic" in " ".join(a):
                ts_count += 50
                return RunResult(0, f"ExecMainStartTimestampMonotonic={ts_count}\n")
            if "MainPID" in " ".join(a):
                if "honkd" in " ".join(a):
                    return RunResult(0, "MainPID=777\n")
                return RunResult(0, "MainPID=555\n")
            if "ExecStart" in " ".join(a):
                return RunResult(0, "ExecStart={ path=/nix/store/cand-goose-1.54.0-patched.19/bin/goose ; argv_0=goose }\n")
            if "is-active" in a:
                return RunResult(3, "inactive\n")
            return RunResult(0, "")
        runner.cmd_handlers.insert(0, (lambda a, u, c: a[0] == "systemctl", sys_handler))

        rc = goose_cutover.main(["--run", "deploy-1"], runner=runner)
        self.assertEqual(rc, 0)
        deployed_content = runner.files.get("/var/lib/goose-cutover/deployed.json")
        self.assertIsNotNone(deployed_content)
        deployed = json.loads(deployed_content or "{}")
        self.assertEqual(deployed["pr"], 902)
        self.assertEqual(deployed["version"], "1.54.0")
        state = json.loads(runner.files["/var/lib/goose-cutover/state.json"])
        self.assertEqual(state["phase"], "deployed")

    def test_honkd_restart_when_binary_changed(self):
        runner = setup_standard_runner()
        runner.files["/var/lib/goose-cutover/state.json"] = json.dumps({
            "phase": "prepared", "pr": 902, "candidate": "/nix/store/cand-goose-1.54.0-patched.19",
            "toplevel": "/nix/store/top", "hm_package": "/nix/store/hm",
            "old_target": "/nix/store/old-goose", "merge_sha": "mainsha123", "built_from": "mainsha123", "head_sha": "hsha",
        })
        runner.files["/nix/store/cand-goose-1.54.0-patched.19"] = "cand"
        runner.files["/nix/store/top"] = "top"
        runner.files["/nix/store/hm"] = "hm"
        goose_cutover.check_quiet(runner)
        runner.current_time += 650

        runner.links["/proc/777/exe"] = "/nix/store/cand-old-goose/bin/goose"

        ts_count = 1000
        def sys_handler(a, u, e, c):
            nonlocal ts_count
            if "ExecMainStartTimestampMonotonic" in " ".join(a):
                ts_count += 50
                return RunResult(0, f"ExecMainStartTimestampMonotonic={ts_count}\n")
            if "MainPID" in " ".join(a):
                if "honkd" in " ".join(a):
                    return RunResult(0, "MainPID=777\n")
                return RunResult(0, "MainPID=555\n")
            if "ExecStart" in " ".join(a):
                return RunResult(0, "ExecStart={ path=/nix/store/cand-goose-1.54.0-patched.19/bin/goose ; argv_0=goose }\n")
            if "is-active" in a:
                return RunResult(3, "inactive\n")
            return RunResult(0, "")
        runner.cmd_handlers.insert(0, (lambda a, u, c: a[0] == "systemctl", sys_handler))

        def j_handler(a, u, e, c):
            if "honkd" in " ".join(a):
                return RunResult(0, "listening on :4081\n")
            if "stall-watch" in " ".join(a):
                return RunResult(0, json.dumps({"ts": int(runner.current_time * 1000), "ok": True, "runs": 0}) + "\n")
            return RunResult(0, "")
        runner.cmd_handlers.insert(0, (lambda a, u, c: a[0] == "journalctl", j_handler))

        rc = goose_cutover.main(["--run", "deploy-1"], runner=runner)
        self.assertEqual(rc, 0)
        honkd_restarts = [c["argv"] for c in runner.calls if "restart" in c["argv"] and "honkd" in c["argv"]]
        self.assertEqual(len(honkd_restarts), 1)

    def test_honkd_no_restart_when_same_binary(self):
        runner = setup_standard_runner()
        runner.files["/var/lib/goose-cutover/state.json"] = json.dumps({
            "phase": "prepared", "pr": 902, "candidate": "/nix/store/cand-goose-1.54.0-patched.19",
            "toplevel": "/nix/store/top", "hm_package": "/nix/store/hm",
            "old_target": "/nix/store/old-goose", "merge_sha": "mainsha123", "built_from": "mainsha123", "head_sha": "hsha",
        })
        runner.files["/nix/store/cand-goose-1.54.0-patched.19"] = "cand"
        runner.files["/nix/store/top"] = "top"
        runner.files["/nix/store/hm"] = "hm"
        goose_cutover.check_quiet(runner)
        runner.current_time += 650

        ts_count = 1000
        def sys_handler(a, u, e, c):
            nonlocal ts_count
            if "ExecMainStartTimestampMonotonic" in " ".join(a):
                ts_count += 50
                return RunResult(0, f"ExecMainStartTimestampMonotonic={ts_count}\n")
            if "MainPID" in " ".join(a):
                if "honkd" in " ".join(a):
                    return RunResult(0, "MainPID=777\n")
                return RunResult(0, "MainPID=555\n")
            if "ExecStart" in " ".join(a):
                return RunResult(0, "ExecStart={ path=/nix/store/cand-goose-1.54.0-patched.19/bin/goose ; argv_0=goose }\n")
            if "is-active" in a:
                return RunResult(3, "inactive\n")
            return RunResult(0, "")
        runner.cmd_handlers.insert(0, (lambda a, u, c: a[0] == "systemctl", sys_handler))

        rc = goose_cutover.main(["--run", "deploy-1"], runner=runner)
        self.assertEqual(rc, 0)
        honkd_restarts = [c["argv"] for c in runner.calls if "restart" in c["argv"] and "honkd" in c["argv"]]
        self.assertEqual(len(honkd_restarts), 0)

    def test_failure_at_d5_runs_rollback_set_to_old(self):
        runner = setup_standard_runner()
        runner.files["/var/lib/goose-cutover/state.json"] = json.dumps({
            "phase": "prepared", "pr": 902, "candidate": "/nix/store/cand-goose-1.54.0-patched.19",
            "toplevel": "/nix/store/top", "hm_package": "/nix/store/hm",
            "old_target": "/nix/store/old-goose", "merge_sha": "mergesha123", "built_from": "mainsha123", "head_sha": "hsha",
        })
        runner.files["/nix/store/cand-goose-1.54.0-patched.19"] = "cand"
        runner.files["/nix/store/top"] = "top"
        runner.files["/nix/store/hm"] = "hm"
        goose_cutover.check_quiet(runner)
        runner.current_time += 650

        runner.cmd_handlers.insert(0, (
            lambda a, u, c: "switch-to-configuration" in a[0] and "switch" in a,
            lambda a, u, e, c: RunResult(1, "", "switch failed")
        ))
        rc = goose_cutover.main(["--run", "deploy-1"], runner=runner)
        self.assertNotEqual(rc, 0)
        goose_link_calls = [c["argv"] for c in runner.calls if c["argv"][:2] == ["goose-link", "set"]]
        self.assertTrue(any("/nix/store/old-goose" in cmd for cmd in goose_link_calls))
        self.assertFalse(any(c["argv"][:2] == ["goose-link", "rollback"] for c in runner.calls))

    def test_failure_at_d6_runs_rollback_set_to_old(self):
        runner = setup_standard_runner()
        runner.files["/var/lib/goose-cutover/state.json"] = json.dumps({
            "phase": "prepared", "pr": 902, "candidate": "/nix/store/cand-goose-1.54.0-patched.19",
            "toplevel": "/nix/store/top", "hm_package": "/nix/store/hm",
            "old_target": "/nix/store/old-goose", "merge_sha": "mergesha123", "built_from": "mainsha123", "head_sha": "hsha",
        })
        runner.files["/nix/store/cand-goose-1.54.0-patched.19"] = "cand"
        runner.files["/nix/store/top"] = "top"
        runner.files["/nix/store/hm"] = "hm"
        goose_cutover.check_quiet(runner)
        runner.current_time += 650

        runner.cmd_handlers.insert(0, (
            lambda a, u, c: a[:2] == ["goose-link", "status"],
            lambda a, u, e, c: RunResult(0, "current=/nix/store/mismatched\nprevious=<none>\npinned=/nix/store/pinned\n")
        ))
        rc = goose_cutover.main(["--run", "deploy-1"], runner=runner)
        self.assertNotEqual(rc, 0)
        self.assertTrue(any(c["argv"][:3] == ["goose-link", "set", "/nix/store/old-goose"] for c in runner.calls))

    def test_failure_at_d7_runs_rollback_restarts_goose_serve_and_polls_status(self):
        runner = setup_standard_runner()
        runner.files["/var/lib/goose-cutover/state.json"] = json.dumps({
            "phase": "prepared", "pr": 902, "candidate": "/nix/store/cand-goose-1.54.0-patched.19",
            "toplevel": "/nix/store/top", "hm_package": "/nix/store/hm",
            "old_target": "/nix/store/old-goose", "merge_sha": "mergesha123", "built_from": "mainsha123", "head_sha": "hsha",
        })
        runner.files["/nix/store/cand-goose-1.54.0-patched.19"] = "cand"
        runner.files["/nix/store/top"] = "top"
        runner.files["/nix/store/hm"] = "hm"
        runner.links["/proc/555/exe"] = "/nix/store/old-goose/bin/goose"
        goose_cutover.check_quiet(runner)
        runner.current_time += 650

        # D7: restart curl fails on candidate, slow bind on rollback (fails twice then ok)
        curl_calls = 0
        def curl_handler(a, u, e, c):
            nonlocal curl_calls
            if "/status" in a[-1]:
                curl_calls += 1
                if curl_calls in (1, 2, 3):
                    return RunResult(1, "", "connection refused")
                return RunResult(0, '{"status":"ok"}\n')
            if any("/acp" in x for x in a):
                return RunResult(0, json.dumps({"id": 1, "jsonrpc": "2.0", "result": {"agentInfo": {"name": "goose", "version": "1.54.0"}}}))
            raise AssertionError(f"unexpected curl command: {a}")
        runner.cmd_handlers.insert(0, (lambda a, u, c: a[0] == "curl", curl_handler))

        rc = goose_cutover.main(["--run", "deploy-1"], runner=runner)
        self.assertNotEqual(rc, 0)
        restarts = [c["argv"] for c in runner.calls if c["argv"][:3] == ["systemctl", "restart", "goose-serve"]]
        self.assertGreaterEqual(len(restarts), 2)
        self.assertGreaterEqual(curl_calls, 4)

    def test_failure_at_d8_control_pong_fails_environmental(self):
        runner = setup_standard_runner()
        runner.files["/var/lib/goose-cutover/state.json"] = json.dumps({
            "phase": "prepared", "pr": 902, "candidate": "/nix/store/cand-goose-1.54.0-patched.19",
            "toplevel": "/nix/store/top", "hm_package": "/nix/store/hm",
            "old_target": "/nix/store/old-goose", "merge_sha": "mergesha123", "built_from": "mainsha123", "head_sha": "hsha",
        })
        runner.files["/nix/store/cand-goose-1.54.0-patched.19"] = "cand"
        runner.files["/nix/store/top"] = "top"
        runner.files["/nix/store/hm"] = "hm"
        runner.links["/proc/555/exe"] = "/nix/store/old-goose/bin/goose"
        goose_cutover.check_quiet(runner)
        runner.current_time += 650

        ts_count = 1000
        def sys_handler(a, u, e, c):
            nonlocal ts_count
            if "ExecMainStartTimestampMonotonic" in " ".join(a):
                ts_count += 50
                return RunResult(0, f"ExecMainStartTimestampMonotonic={ts_count}\n")
            if "MainPID" in " ".join(a):
                if "honkd" in " ".join(a):
                    return RunResult(0, "MainPID=777\n")
                return RunResult(0, "MainPID=555\n")
            if "ExecStart" in " ".join(a):
                return RunResult(0, "ExecStart={ path=/nix/store/cand-goose-1.54.0-patched.19/bin/goose ; argv_0=goose }\n")
            if "is-active" in a:
                return RunResult(3, "inactive\n")
            if "start" in a or "stop" in a or "restart" in a:
                return RunResult(0, "")
            raise AssertionError(f"unexpected systemctl: {a}")
        runner.cmd_handlers.insert(0, (lambda a, u, c: a[0] == "systemctl", sys_handler))

        # PONG always fails
        runner.cmd_handlers.insert(0, (
            lambda a, u, c: a[0] == "timeout" and "tail" in a,
            lambda a, u, e, c: RunResult(0, "ERROR: model timeout\n")
        ))
        rc = goose_cutover.main(["--run", "deploy-1"], runner=runner)
        self.assertNotEqual(rc, 0)
        self.assertFalse(any(c["argv"][:3] == ["gh", "pr", "create"] for c in runner.calls))
        state = json.loads(runner.files["/var/lib/goose-cutover/state.json"])
        self.assertEqual(state["phase"], "prepared")

    def test_merge_sha_never_overwritten_revert_uses_squash_sha(self):
        runner = setup_standard_runner()
        runner.files["/var/lib/goose-cutover/state.json"] = json.dumps({
            "phase": "prepared", "pr": 902, "candidate": "/nix/store/cand-goose-1.54.0-patched.19",
            "toplevel": "/nix/store/top", "hm_package": "/nix/store/hm",
            "old_target": "/nix/store/old-goose", "merge_sha": "pr_squash_commit_sha_999",
            "built_from": "oldmainsha", "head_sha": "hsha",
        })
        runner.files["/nix/store/cand-goose-1.54.0-patched.19"] = "cand"
        runner.files["/nix/store/top"] = "top"
        runner.files["/nix/store/hm"] = "hm"
        runner.links["/proc/555/exe"] = "/nix/store/cand-goose-1.54.0-patched.19/bin/goose"
        goose_cutover.check_quiet(runner)
        runner.current_time += 650

        # Main moved to futuremainsha
        def git_handler(a, u, e, c):
            if "rev-parse" in a:
                return RunResult(0, "futuremainsha\n")
            if "fetch" in a or "worktree" in a or "revert" in a or "push" in a:
                return RunResult(0, "")
            raise AssertionError(f"unexpected git command: {a}")
        runner.cmd_handlers.insert(0, (lambda a, u, c: a[0] == "git", git_handler))

        ts_count = 1000
        def sys_handler(a, u, e, c):
            nonlocal ts_count
            if "ExecMainStartTimestampMonotonic" in " ".join(a):
                ts_count += 50
                return RunResult(0, f"ExecMainStartTimestampMonotonic={ts_count}\n")
            if "MainPID" in " ".join(a):
                if "honkd" in " ".join(a):
                    return RunResult(0, "MainPID=777\n")
                return RunResult(0, "MainPID=555\n")
            if "ExecStart" in " ".join(a):
                return RunResult(0, "ExecStart={ path=/nix/store/cand-goose-1.54.0-patched.19/bin/goose ; argv_0=goose }\n")
            if "is-active" in a:
                return RunResult(3, "inactive\n")
            if a[:3] == ["systemctl", "restart", "goose-serve"]:
                runner.links["/proc/555/exe"] = runner.current_link_target + "/bin/goose"
                return RunResult(0, "")
            if "start" in a or "stop" in a or "restart" in a:
                return RunResult(0, "")
            raise AssertionError(f"unexpected systemctl: {a}")
        runner.cmd_handlers.insert(0, (lambda a, u, c: a[0] == "systemctl", sys_handler))

        # Candidate PONG fails, control PONG passes
        tail_count = 0
        def timeout_handler(a, u, e, c):
            nonlocal tail_count
            tail_count += 1
            if tail_count == 1:
                return RunResult(0, "CRASH\n")
            return RunResult(0, "PONG\n")
        runner.cmd_handlers.insert(0, (lambda a, u, c: a[0] == "timeout" and "tail" in a, timeout_handler))

        rc = goose_cutover.main(["--run", "deploy-1"], runner=runner)
        self.assertNotEqual(rc, 0)
        # Verify revert command specifically reverts the squash SHA, NOT futuremainsha
        revert_calls = [c["argv"] for c in runner.calls if "revert" in c["argv"]]
        self.assertEqual(len(revert_calls), 1)
        self.assertIn("pr_squash_commit_sha_999", revert_calls[0])
        self.assertNotIn("futuremainsha", revert_calls[0])

    def test_revert_pr_created_with_head_and_base_and_cwd(self):
        runner = setup_standard_runner()
        runner.files["/var/lib/goose-cutover/state.json"] = json.dumps({
            "phase": "prepared", "pr": 902, "candidate": "/nix/store/cand-goose-1.54.0-patched.19",
            "toplevel": "/nix/store/top", "hm_package": "/nix/store/hm",
            "old_target": "/nix/store/old-goose", "merge_sha": "mergesha123", "built_from": "mainsha123", "head_sha": "hsha",
        })
        runner.files["/nix/store/cand-goose-1.54.0-patched.19"] = "cand"
        runner.files["/nix/store/top"] = "top"
        runner.files["/nix/store/hm"] = "hm"
        runner.links["/proc/555/exe"] = "/nix/store/cand-goose-1.54.0-patched.19/bin/goose"
        goose_cutover.check_quiet(runner)
        runner.current_time += 650

        ts_count = 1000
        def sys_handler(a, u, e, c):
            nonlocal ts_count
            if "ExecMainStartTimestampMonotonic" in " ".join(a):
                ts_count += 50
                return RunResult(0, f"ExecMainStartTimestampMonotonic={ts_count}\n")
            if "MainPID" in " ".join(a):
                if "honkd" in " ".join(a):
                    return RunResult(0, "MainPID=777\n")
                return RunResult(0, "MainPID=555\n")
            if "ExecStart" in " ".join(a):
                return RunResult(0, "ExecStart={ path=/nix/store/cand-goose-1.54.0-patched.19/bin/goose ; argv_0=goose }\n")
            if "is-active" in a:
                return RunResult(3, "inactive\n")
            if a[:3] == ["systemctl", "restart", "goose-serve"]:
                runner.links["/proc/555/exe"] = runner.current_link_target + "/bin/goose"
                return RunResult(0, "")
            if "start" in a or "stop" in a or "restart" in a:
                return RunResult(0, "")
            raise AssertionError(f"unexpected systemctl: {a}")
        runner.cmd_handlers.insert(0, (lambda a, u, c: a[0] == "systemctl", sys_handler))

        tail_count = 0
        def timeout_handler(a, u, e, c):
            nonlocal tail_count
            tail_count += 1
            if tail_count == 1:
                return RunResult(0, "CRASH\n")
            return RunResult(0, "PONG\n")
        runner.cmd_handlers.insert(0, (lambda a, u, c: a[0] == "timeout" and "tail" in a, timeout_handler))

        rc = goose_cutover.main(["--run", "deploy-1"], runner=runner)
        self.assertNotEqual(rc, 0)
        pr_creates = [c for c in runner.calls if c["argv"][:3] == ["gh", "pr", "create"]]
        self.assertEqual(len(pr_creates), 1)
        pr_call = pr_creates[0]
        argv = pr_call["argv"]
        self.assertIn("--base", argv)
        self.assertIn("main", argv)
        self.assertIn("--head", argv)
        self.assertIn("goose-cutover-revert-902", argv)
        self.assertIsNotNone(pr_call["cwd"])
        self.assertIn("/tmp/goose-revert-worktree-902", pr_call["cwd"])

    def test_rollback_failure_exits_3(self):
        runner = setup_standard_runner()
        runner.files["/var/lib/goose-cutover/state.json"] = json.dumps({
            "phase": "prepared", "pr": 902, "candidate": "/nix/store/cand-goose-1.54.0-patched.19",
            "toplevel": "/nix/store/top", "hm_package": "/nix/store/hm",
            "old_target": "/nix/store/old-goose", "merge_sha": "mergesha123", "built_from": "mainsha123", "head_sha": "hsha",
        })
        runner.files["/nix/store/cand-goose-1.54.0-patched.19"] = "cand"
        runner.files["/nix/store/top"] = "top"
        runner.files["/nix/store/hm"] = "hm"
        goose_cutover.check_quiet(runner)
        runner.current_time += 650

        # D5 switch fails, triggering rollback
        runner.cmd_handlers.insert(0, (
            lambda a, u, c: "switch-to-configuration" in a[0] and "switch" in a,
            lambda a, u, e, c: RunResult(1, "", "switch failed")
        ))
        # Rollback goose-link set ALSO fails
        runner.cmd_handlers.insert(0, (
            lambda a, u, c: a[:2] == ["goose-link", "set"],
            lambda a, u, e, c: RunResult(1, "", "disk error")
        ))
        rc = goose_cutover.main(["--run", "deploy-1"], runner=runner)
        self.assertEqual(rc, 3)
        state = json.loads(runner.files["/var/lib/goose-cutover/state.json"])
        self.assertEqual(state["phase"], "failed")

    def test_deploy_recover_runs_rollback(self):
        runner = setup_standard_runner()
        runner.files["/var/lib/goose-cutover/state.json"] = json.dumps({
            "phase": "deploying", "pr": 902, "candidate": "/nix/store/cand-goose-1.54.0-patched.19",
            "toplevel": "/nix/store/top", "hm_package": "/nix/store/hm",
            "old_target": "/nix/store/old-goose", "merge_sha": "mergesha123", "built_from": "mainsha123", "head_sha": "hsha",
            "step": "restart"
        })
        runner.files["/nix/store/cand-goose-1.54.0-patched.19"] = "cand"
        runner.files["/nix/store/top"] = "top"
        runner.files["/nix/store/hm"] = "hm"
        runner.links["/proc/555/exe"] = "/nix/store/old-goose/bin/goose"

        rc = goose_cutover.main(["--run", "deploy-recover-1"], runner=runner)
        self.assertNotEqual(rc, 0)
        self.assertTrue(any(c["argv"][:3] == ["goose-link", "set", "/nix/store/old-goose"] for c in runner.calls))

    def test_secrets_never_in_argv_and_redacted(self):
        runner = setup_standard_runner()
        planted_token = "PLANTED_SUPER_SECRET_TOKEN_99999"
        runner.files["/run/secrets/github_api_token"] = f"{planted_token}\n"
        runner.files["/run/secrets/pigeon_goose_acp_token"] = f"{planted_token}\n"
        goose_cutover.register_secret(planted_token)

        rc = goose_cutover.main(["--run", "prepare-902"], runner=runner)
        self.assertEqual(rc, 0)

        for call in runner.calls:
            cmd_line = " ".join(call["argv"])
            self.assertNotIn(planted_token, cmd_line)

        state_text = runner.files.get("/var/lib/goose-cutover/state.json", "")
        self.assertNotIn(planted_token, state_text)

    def test_status_command(self):
        runner = setup_standard_runner()
        runner.files["/var/lib/goose-cutover/state.json"] = json.dumps({
            "phase": "prepared", "pr": 902, "candidate": "/nix/store/cand",
        })
        rc = goose_cutover.main(["status"], runner=runner)
        self.assertEqual(rc, 0)


if __name__ == "__main__":
    unittest.main()
