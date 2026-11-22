"""Tests for goose-cutover (L3a, bead workstation-6w7i.27.3)."""

import json
import os
import sys
import unittest
from typing import Any, Callable, Optional

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
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


class FakeRunner:
    def __init__(self):
        self.files: dict[str, str] = {}
        self.links: dict[str, str] = {}
        self.env: dict[str, str] = {}
        self.calls: list[dict[str, Any]] = []
        self.cmd_handlers: list[tuple[Callable[[list[str]], bool], Callable[[list[str], Optional[str], Optional[dict[str, str]]], RunResult]]] = []
        self.sleep_calls: list[float] = []
        self.current_time: float = 1700000000.0
        self.locks_held: set[str] = set()
        self.flock_busy: set[str] = set()
        self.lock_events: list[tuple[str, str]] = []
        self.current_link_target = "/nix/store/old-goose"
        self.pr_state = "OPEN"

    def run(
        self,
        argv: list[str],
        user: Optional[str] = None,
        env: Optional[dict[str, str]] = None,
        check: bool = True,
        timeout: Optional[float] = None,
    ) -> RunResult:
        self.calls.append({
            "argv": list(argv),
            "user": user,
            "env": dict(env) if env else None,
            "check": check,
            "timeout": timeout,
        })
        for pred, handler in self.cmd_handlers:
            if pred(argv):
                res = handler(argv, user, env)
                if check and res.rc != 0:
                    raise RuntimeError(f"Command failed with rc {res.rc}: {' '.join(argv)}\n{res.stderr}")
                return res
        # Default fallback
        return RunResult(0, "", "")

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

    def get_env(self, key: str, default: Optional[str] = None) -> Optional[str]:
        return self.env.get(key, default)


def setup_standard_runner() -> FakeRunner:
    runner = FakeRunner()
    runner.files["/proc/self/cgroup"] = "0::/system.slice/goose-cutover@prepare-902.service\n"
    runner.env["INVOCATION_ID"] = "test-invocation-123"
    runner.env["GOOSE_HOST_REPORTS_DIR"] = "/var/lib/goose-cutover/host-reports"
    runner.env["GOOSE_CUTOVER_HOSTS"] = "devbox,mac"
    runner.files["/run/secrets/github_api_token"] = "gh-secret-token\n"
    runner.files["/run/secrets/pigeon_goose_acp_token"] = "acp-secret-token\n"
    runner.files["/home/dev/.nix-profile/bin/goose-upgrade-probe"] = "binary"
    runner.files["/home/dev/.nix-profile/bin/honk"] = "binary"

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

    # Default handlers
    def handler(argv, user, env):
        cmd = argv[0]
        if cmd == "hostname":
            return RunResult(0, "cloudbox\n")
        if cmd == "goose-link":
            if argv[1] == "status":
                return RunResult(0, f"current={runner.current_link_target}\nprevious=<none>\npinned=/nix/store/old-goose\npinned_is_current=yes\n")
            if argv[1] == "set":
                runner.current_link_target = argv[2]
                return RunResult(0, f"goose-link: current={runner.current_link_target}\n")
        if cmd == "gh":
            if argv[1:3] == ["pr", "view"]:
                # PR view json
                return RunResult(0, json.dumps({
                    "state": runner.pr_state,
                    "baseRefName": "main",
                    "labels": [{"name": "goose-upgrade"}],
                    "headRefOid": "headsha123",
                    "mergeable": "MERGEABLE",
                    "files": [{"path": "pkgs/goose/default.nix"}],
                    "statusCheckRollup": [{"name": "ci", "conclusion": "SUCCESS"}],
                    "mergeCommit": {"oid": "mergesha123"},
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
                if "refs/pull/902/merge^1" in argv:
                    return RunResult(0, "mainsha123\n")
                if "origin/main" in argv:
                    return RunResult(0, "mainsha123\n")
            if "worktree" in argv:
                return RunResult(0, "")
            if "fetch" in argv:
                return RunResult(0, "")
            if "revert" in argv or "push" in argv:
                return RunResult(0, "")
        if cmd == "nix":
            if argv[1] == "build":
                # find out-link
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
        if cmd == "honk":
            if argv[1:3] == ["list", "--json"]:
                return RunResult(0, json.dumps([]))
            if argv[1] == "launch":
                return RunResult(0, "native=sess_123 gse=123 tag=goose-upgrade prompt=PONG\n")
            if argv[1] == "tail":
                return RunResult(0, "PONG\n")
            if argv[1] == "--version":
                return RunResult(0, "honk 0.5.0\n")
        if cmd == "curl":
            if "/status" in argv[-1]:
                return RunResult(0, '{"status":"ok"}\n')
            if any("/acp" in a for a in argv):
                return RunResult(0, json.dumps({
                    "id": 1,
                    "jsonrpc": "2.0",
                    "result": {
                        "agentInfo": {"name": "goose", "version": "1.54.0"}
                    }
                }))
        if cmd == "systemctl":
            if "show" in argv:
                if "ExecMainStartTimestampMonotonic" in " ".join(argv):
                    return RunResult(0, "ExecMainStartTimestampMonotonic=1000\n")
                if "MainPID" in " ".join(argv):
                    return RunResult(0, "MainPID=555\n")
                if "ExecStart" in " ".join(argv):
                    return RunResult(0, "ExecStart={ path=/nix/store/cand-goose-1.54.0-patched.19/bin/goose ; argv_0=goose }\n")
            if "is-active" in argv:
                return RunResult(3, "inactive\n")
            return RunResult(0, "")
        if cmd == "journalctl":
            return RunResult(0, json.dumps({"ts": runner.current_time, "ok": True, "runs": 0, "coordinator": {"runs": 0}}) + "\n")
        if cmd == "readlink":
            if argv[-1] == "/nix/var/nix/profiles/system":
                return RunResult(0, "/nix/store/old-system-toplevel\n")
            if argv[-1] == "/proc/555/exe":
                return RunResult(0, "/nix/store/cand-goose-1.54.0-patched.19/bin/goose\n")
        if "switch-to-configuration" in cmd:
            return RunResult(0, "")
        if cmd == "nix-env":
            return RunResult(0, "")
        if "goose-upgrade-probe" in cmd:
            return RunResult(0, "All tests passed\n")
        return RunResult(0, "", "")

    runner.cmd_handlers.append((lambda argv: True, handler))
    return runner


class TestGooseCutover(unittest.TestCase):
    def test_launcher_refuses_in_goose_serve_cgroup(self):
        runner = setup_standard_runner()
        runner.files["/proc/self/cgroup"] = "0::/system.slice/goose-serve.service\n"
        rc = goose_cutover.main(["prepare", "902"], runner=runner)
        self.assertEqual(rc, 2)
        # Check no systemctl was started
        self.assertFalse(any("systemctl" in c["argv"] for c in runner.calls))

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
        runner.cmd_handlers.insert(0, (lambda a: a[0] == "hostname", lambda a, u, e: RunResult(0, "devbox\n")))
        rc = goose_cutover.main(["--run", "prepare-902"], runner=runner)
        self.assertNotEqual(rc, 0)

    def test_p1_goose_link_status_fails(self):
        runner = setup_standard_runner()
        runner.cmd_handlers.insert(0, (lambda a: a[:2] == ["goose-link", "status"], lambda a, u, e: RunResult(1, "", "failed")))
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

    def test_p1_pr_not_open_fails(self):
        runner = setup_standard_runner()
        runner.cmd_handlers.insert(0, (
            lambda a: a[:3] == ["gh", "pr", "view"],
            lambda a, u, e: RunResult(0, json.dumps({
                "state": "CLOSED",
                "baseRefName": "main",
                "labels": [{"name": "goose-upgrade"}],
                "headRefOid": "h",
                "files": [{"path": "pkgs/goose/default.nix"}],
                "statusCheckRollup": [],
            }))
        ))
        rc = goose_cutover.main(["--run", "prepare-902"], runner=runner)
        self.assertNotEqual(rc, 0)

    def test_p1_pr_base_not_main_fails(self):
        runner = setup_standard_runner()
        runner.cmd_handlers.insert(0, (
            lambda a: a[:3] == ["gh", "pr", "view"],
            lambda a, u, e: RunResult(0, json.dumps({
                "state": "OPEN",
                "baseRefName": "feature-branch",
                "labels": [{"name": "goose-upgrade"}],
                "headRefOid": "h",
                "files": [{"path": "pkgs/goose/default.nix"}],
                "statusCheckRollup": [],
            }))
        ))
        rc = goose_cutover.main(["--run", "prepare-902"], runner=runner)
        self.assertNotEqual(rc, 0)

    def test_p1_pr_missing_goose_upgrade_label_fails(self):
        runner = setup_standard_runner()
        runner.cmd_handlers.insert(0, (
            lambda a: a[:3] == ["gh", "pr", "view"],
            lambda a, u, e: RunResult(0, json.dumps({
                "state": "OPEN",
                "baseRefName": "main",
                "labels": [{"name": "other-label"}],
                "headRefOid": "h",
                "files": [{"path": "pkgs/goose/default.nix"}],
                "statusCheckRollup": [],
            }))
        ))
        rc = goose_cutover.main(["--run", "prepare-902"], runner=runner)
        self.assertNotEqual(rc, 0)

    def test_p1_goose_major_without_major_ok_fails(self):
        runner = setup_standard_runner()
        runner.cmd_handlers.insert(0, (
            lambda a: a[:3] == ["gh", "pr", "view"],
            lambda a, u, e: RunResult(0, json.dumps({
                "state": "OPEN",
                "baseRefName": "main",
                "labels": [{"name": "goose-upgrade"}, {"name": "goose-major"}],
                "headRefOid": "h",
                "files": [{"path": "pkgs/goose/default.nix"}],
                "statusCheckRollup": [],
            }))
        ))
        rc = goose_cutover.main(["--run", "prepare-902"], runner=runner)
        self.assertNotEqual(rc, 0)

    def test_p1_goose_major_with_major_ok_passes(self):
        runner = setup_standard_runner()
        runner.cmd_handlers.insert(0, (
            lambda a: a[:3] == ["gh", "pr", "view"],
            lambda a, u, e: RunResult(0, json.dumps({
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
            lambda a: a[:3] == ["gh", "pr", "view"],
            lambda a, u, e: RunResult(0, json.dumps({
                "state": "OPEN",
                "baseRefName": "main",
                "labels": [{"name": "goose-upgrade"}],
                "headRefOid": "h",
                "files": [{"path": "pkgs/goose/default.nix"}, {"path": "modules/goose-cutover.nix"}],
                "statusCheckRollup": [],
            }))
        ))
        rc = goose_cutover.main(["--run", "prepare-902"], runner=runner)
        self.assertNotEqual(rc, 0)

    def test_p1_files_outside_pkgs_goose_with_config_ok_passes(self):
        runner = setup_standard_runner()
        runner.cmd_handlers.insert(0, (
            lambda a: a[:3] == ["gh", "pr", "view"],
            lambda a, u, e: RunResult(0, json.dumps({
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

    def test_p1_checks_pending_or_failed_fails(self):
        runner = setup_standard_runner()
        runner.cmd_handlers.insert(0, (
            lambda a: a[:3] == ["gh", "pr", "view"],
            lambda a, u, e: RunResult(0, json.dumps({
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

    def test_p1_hosts_ready_pass_applies_label(self):
        runner = setup_standard_runner()
        rc = goose_cutover.main(["--run", "prepare-902"], runner=runner)
        self.assertEqual(rc, 0)
        # Check that gh pr edit was called with --add-label goose-hosts-ready
        label_calls = [c["argv"] for c in runner.calls if "pr" in c["argv"] and "edit" in c["argv"]]
        self.assertTrue(any("goose-hosts-ready" in cmd for cmd in label_calls))

    def test_p2_stale_merge_ref_fails(self):
        runner = setup_standard_runner()
        runner.cmd_handlers.insert(0, (
            lambda a: a[:3] == ["git", "rev-parse", "refs/pull/902/merge^1"],
            lambda a, u, e: RunResult(0, "oldparentsha\n")
        ))
        rc = goose_cutover.main(["--run", "prepare-902"], runner=runner)
        self.assertNotEqual(rc, 0)

    def test_p2_noop_refused_without_allow_noop(self):
        runner = setup_standard_runner()
        # Candidate == current target
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
            lambda a: "goose-upgrade-probe" in a[0],
            lambda a, u, e: RunResult(1, "", "probe failed badly")
        ))
        rc = goose_cutover.main(["--run", "prepare-902"], runner=runner)
        self.assertNotEqual(rc, 0)
        # Ensure merge was not attempted
        self.assertFalse(any("merge" in c["argv"] for c in runner.calls))

    def test_p4_merged_mismatch_fails(self):
        runner = setup_standard_runner()
        # In P4, after merge, origin/main moved past merge commit
        merge_called = False
        def git_handler(a, u, e):
            nonlocal merge_called
            if a[:3] == ["git", "rev-parse", "origin/main"]:
                if merge_called:
                    return RunResult(0, "futuremainsha\n")
                return RunResult(0, "mainsha123\n")
            if a[:3] == ["git", "rev-parse", "refs/pull/902/merge^1"]:
                return RunResult(0, "mainsha123\n")
            return RunResult(0, "")
        runner.cmd_handlers.insert(0, (lambda a: a[0] == "git", git_handler))

        def gh_handler(a, u, e):
            nonlocal merge_called
            if a[1:3] == ["pr", "merge"]:
                merge_called = True
                runner.pr_state = "MERGED"
                return RunResult(0, "Merged\n")
            if a[1:3] == ["pr", "view"]:
                return RunResult(0, json.dumps({
                    "state": runner.pr_state,
                    "baseRefName": "main",
                    "labels": [{"name": "goose-upgrade"}],
                    "headRefOid": "headsha123",
                    "mergeable": "MERGEABLE",
                    "files": [{"path": "pkgs/goose/default.nix"}],
                    "statusCheckRollup": [{"name": "ci", "conclusion": "SUCCESS"}],
                    "mergeCommit": {"oid": "mergesha123"},
                }))
            return RunResult(0, "")
        runner.cmd_handlers.insert(0, (lambda a: a[0] == "gh", gh_handler))

        # Rebuilt candidate differs
        build_count = 0
        def nix_handler(a, u, e):
            nonlocal build_count
            if a[:2] == ["nix", "build"]:
                build_count += 1
                for i, arg in enumerate(a):
                    if arg == "--out-link":
                        link = a[i + 1]
                        if "candidate" in link:
                            if build_count > 3:
                                runner.links[link] = "/nix/store/different-candidate"
                            else:
                                runner.links[link] = "/nix/store/cand-goose-1.54.0-patched.19"
                        elif "toplevel" in link:
                            runner.links[link] = "/nix/store/toplevel-123"
                        elif "hm" in link:
                            runner.links[link] = "/nix/store/hm-123"
            return RunResult(0, "")
        runner.cmd_handlers.insert(0, (lambda a: a[0] == "nix", nix_handler))

        rc = goose_cutover.main(["--run", "prepare-902"], runner=runner)
        self.assertNotEqual(rc, 0)
        state = json.loads(runner.files.get("/var/lib/goose-cutover/state.json", "{}"))
        self.assertEqual(state.get("phase"), "failed")
        self.assertEqual(state.get("step"), "merged-mismatch")

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

    def test_d2_stall_watch_active_blocks(self):
        runner = setup_standard_runner()
        runner.files["/var/lib/goose-cutover/state.json"] = json.dumps({
            "phase": "prepared", "pr": 902, "candidate": "/nix/store/cand", "toplevel": "/nix/store/top", "hm_package": "/nix/store/hm",
            "old_target": "/nix/store/old-goose", "merge_sha": "msha", "head_sha": "hsha",
        })
        runner.files["/nix/store/cand"] = "cand"
        runner.files["/nix/store/top"] = "top"
        runner.files["/nix/store/hm"] = "hm"
        runner.cmd_handlers.insert(0, (
            lambda a: a[:3] == ["systemctl", "--user", "is-active"],
            lambda a, u, e: RunResult(0, "active\n")
        ))
        quiet, reason = goose_cutover.check_quiet(runner)
        self.assertFalse(quiet)
        self.assertIn("stall-watch", reason)

    def test_d2_coordinator_runs_blocks(self):
        runner = setup_standard_runner()
        runner.cmd_handlers.insert(0, (
            lambda a: a[0] == "journalctl",
            lambda a, u, e: RunResult(0, json.dumps({"ts": runner.current_time, "coordinator": {"runs": 1}}) + "\n")
        ))
        quiet, reason = goose_cutover.check_quiet(runner)
        self.assertFalse(quiet)
        self.assertIn("runs", reason)

    def test_d2_sessions_db_changing_blocks(self):
        runner = setup_standard_runner()
        val = 100
        def sqlite_handler(a, u, e):
            nonlocal val
            val += 1
            return RunResult(0, f"{val}\n")
        runner.cmd_handlers.insert(0, (lambda a: a[0] == "sqlite3", sqlite_handler))
        quiet, reason = goose_cutover.check_quiet(runner)
        self.assertFalse(quiet)

    def test_d2_cgroup_oom_score_adj_blocks(self):
        runner = setup_standard_runner()
        runner.cmd_handlers.insert(0, (lambda a: a[0] == "sqlite3", lambda a, u, e: RunResult(0, "50\n")))
        goose_cutover.check_quiet(runner)
        runner.current_time += 601

        runner.files["/sys/fs/cgroup/system.slice/goose-serve.service/cgroup.procs"] = "1234\n"
        runner.files["/proc/1234/oom_score_adj"] = "600\n"
        quiet, reason = goose_cutover.check_quiet(runner)
        self.assertFalse(quiet)
        self.assertIn("oom_score_adj", reason)

    def test_d2_honk_running_blocks(self):
        runner = setup_standard_runner()
        runner.cmd_handlers.insert(0, (lambda a: a[0] == "sqlite3", lambda a, u, e: RunResult(0, "50\n")))
        goose_cutover.check_quiet(runner)
        runner.current_time += 601

        runner.cmd_handlers.insert(0, (
            lambda a: a[:3] == ["honk", "list", "--json"],
            lambda a, u, e: RunResult(0, json.dumps([{"sessionId": "s1", "running": True, "pendingRequests": 0}]))
        ))
        quiet, reason = goose_cutover.check_quiet(runner)
        self.assertFalse(quiet)
        self.assertIn("busy", reason)

    def test_d2_honk_pending_requests_blocks(self):
        runner = setup_standard_runner()
        runner.cmd_handlers.insert(0, (lambda a: a[0] == "sqlite3", lambda a, u, e: RunResult(0, "50\n")))
        goose_cutover.check_quiet(runner)
        runner.current_time += 601

        runner.cmd_handlers.insert(0, (
            lambda a: a[:3] == ["honk", "list", "--json"],
            lambda a, u, e: RunResult(0, json.dumps([{"sessionId": "s1", "running": False, "pendingRequests": 2}]))
        ))
        quiet, reason = goose_cutover.check_quiet(runner)
        self.assertFalse(quiet)
        self.assertIn("busy", reason)

    def test_d2_honk_unknown_shape_blocks(self):
        runner = setup_standard_runner()
        runner.cmd_handlers.insert(0, (lambda a: a[0] == "sqlite3", lambda a, u, e: RunResult(0, "50\n")))
        goose_cutover.check_quiet(runner)
        runner.current_time += 601

        runner.cmd_handlers.insert(0, (
            lambda a: a[:3] == ["honk", "list", "--json"],
            lambda a, u, e: RunResult(0, "Not JSON at all")
        ))
        quiet, reason = goose_cutover.check_quiet(runner)
        self.assertFalse(quiet)
        self.assertIn("unknown shape", reason)

    def test_d2_all_quiet_passes_after_10min(self):
        runner = setup_standard_runner()
        runner.cmd_handlers.insert(0, (lambda a: a[0] == "sqlite3", lambda a, u, e: RunResult(0, "50\n")))
        # First observation sets baseline
        goose_cutover.check_quiet(runner)
        runner.current_time += 601
        quiet, reason = goose_cutover.check_quiet(runner)
        self.assertTrue(quiet, f"Expected quiet but got: {reason}")

    def test_d2_timeout_2h_keeps_prepared(self):
        runner = setup_standard_runner()
        runner.files["/var/lib/goose-cutover/state.json"] = json.dumps({
            "phase": "prepared", "pr": 902, "candidate": "/nix/store/cand", "toplevel": "/nix/store/top", "hm_package": "/nix/store/hm",
            "old_target": "/nix/store/old-goose", "merge_sha": "msha", "head_sha": "hsha",
        })
        runner.files["/nix/store/cand"] = "cand"
        runner.files["/nix/store/top"] = "top"
        runner.files["/nix/store/hm"] = "hm"
        # Always not quiet
        runner.cmd_handlers.insert(0, (
            lambda a: a[:3] == ["systemctl", "--user", "is-active"],
            lambda a, u, e: RunResult(0, "active\n")
        ))
        rc = goose_cutover.main(["--run", "deploy-1"], runner=runner)
        self.assertEqual(rc, 1)
        state = json.loads(runner.files["/var/lib/goose-cutover/state.json"])
        self.assertEqual(state["phase"], "prepared")

    def test_d3_locks_order_and_finally_release_on_failure(self):
        runner = setup_standard_runner()
        runner.files["/var/lib/goose-cutover/state.json"] = json.dumps({
            "phase": "prepared", "pr": 902, "candidate": "/nix/store/cand", "toplevel": "/nix/store/top", "hm_package": "/nix/store/hm",
            "old_target": "/nix/store/old-goose", "merge_sha": "msha", "head_sha": "hsha",
        })
        runner.files["/nix/store/cand"] = "cand"
        runner.files["/nix/store/top"] = "top"
        runner.files["/nix/store/hm"] = "hm"
        runner.cmd_handlers.insert(0, (lambda a: a[0] == "sqlite3", lambda a, u, e: RunResult(0, "50\n")))
        goose_cutover.check_quiet(runner)
        runner.current_time += 650

        # Simulate failure in D4 dry-activate
        runner.cmd_handlers.insert(0, (
            lambda a: "switch-to-configuration" in a[0] and "dry-activate" in a,
            lambda a, u, e: RunResult(1, "error", "error")
        ))
        rc = goose_cutover.main(["--run", "deploy-1"], runner=runner)
        self.assertNotEqual(rc, 0)
        # Check locks were released
        self.assertEqual(len(runner.locks_held), 0)
        # Check stall-watch.timer was restored
        timer_started = any("start" in c["argv"] and "stall-watch.timer" in c["argv"] for c in runner.calls)
        self.assertTrue(timer_started)

    def test_d4_dry_activate_allowlist_refusal(self):
        runner = setup_standard_runner()
        runner.files["/var/lib/goose-cutover/state.json"] = json.dumps({
            "phase": "prepared", "pr": 902, "candidate": "/nix/store/cand", "toplevel": "/nix/store/top", "hm_package": "/nix/store/hm",
            "old_target": "/nix/store/old-goose", "merge_sha": "msha", "head_sha": "hsha",
        })
        runner.files["/nix/store/cand"] = "cand"
        runner.files["/nix/store/top"] = "top"
        runner.files["/nix/store/hm"] = "hm"
        runner.cmd_handlers.insert(0, (lambda a: a[0] == "sqlite3", lambda a, u, e: RunResult(0, "50\n")))
        goose_cutover.check_quiet(runner)
        runner.current_time += 650

        # dry-activate says it would stop unallowed unit
        runner.cmd_handlers.insert(0, (
            lambda a: "switch-to-configuration" in a[0] and "dry-activate" in a,
            lambda a, u, e: RunResult(0, "would stop the following units: unexpected.service\n")
        ))
        rc = goose_cutover.main(["--run", "deploy-1"], runner=runner)
        self.assertNotEqual(rc, 0)

    def test_deploy_dry_run_issues_no_mutating_commands(self):
        runner = setup_standard_runner()
        runner.files["/var/lib/goose-cutover/state.json"] = json.dumps({
            "phase": "prepared", "pr": 902, "candidate": "/nix/store/cand", "toplevel": "/nix/store/top", "hm_package": "/nix/store/hm",
            "old_target": "/nix/store/old-goose", "merge_sha": "msha", "head_sha": "hsha",
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
            "old_target": "/nix/store/old-goose", "merge_sha": "msha", "head_sha": "hsha",
        })
        runner.files["/nix/store/cand-goose-1.54.0-patched.19"] = "cand"
        runner.files["/nix/store/top"] = "top"
        runner.files["/nix/store/hm"] = "hm"
        runner.files["/proc/555/cmdline"] = "/var/lib/goose/current/bin/goose\0"
        runner.links["/proc/555/exe"] = "/nix/store/cand-goose-1.54.0-patched.19/bin/goose"

        # Advance quiet window
        runner.cmd_handlers.insert(0, (lambda a: a[0] == "sqlite3", lambda a, u, e: RunResult(0, "50\n")))
        goose_cutover.check_quiet(runner)
        runner.current_time += 650

        # Monotonic timestamp increases on restart
        ts_count = 1000
        def sys_handler(a, u, e):
            nonlocal ts_count
            if "ExecMainStartTimestampMonotonic" in " ".join(a):
                ts_count += 50
                return RunResult(0, f"ExecMainStartTimestampMonotonic={ts_count}\n")
            if "MainPID" in " ".join(a):
                return RunResult(0, "MainPID=555\n")
            if "ExecStart" in " ".join(a):
                return RunResult(0, "ExecStart={ path=/nix/store/cand-goose-1.54.0-patched.19/bin/goose }\n")
            if "is-active" in a:
                return RunResult(3, "inactive\n")
            return RunResult(0, "")
        runner.cmd_handlers.insert(0, (lambda a: a[0] == "systemctl", sys_handler))

        rc = goose_cutover.main(["--run", "deploy-1"], runner=runner)
        self.assertEqual(rc, 0)
        deployed_content = runner.files.get("/var/lib/goose-cutover/deployed.json")
        self.assertIsNotNone(deployed_content)
        deployed = json.loads(deployed_content or "{}")
        self.assertEqual(deployed["pr"], 902)
        self.assertEqual(deployed["version"], "1.54.0")
        state = json.loads(runner.files["/var/lib/goose-cutover/state.json"])
        self.assertEqual(state["phase"], "deployed")

    def test_failure_at_d5_runs_rollback_set_to_old(self):
        runner = setup_standard_runner()
        runner.files["/var/lib/goose-cutover/state.json"] = json.dumps({
            "phase": "prepared", "pr": 902, "candidate": "/nix/store/cand-goose-1.54.0-patched.19",
            "toplevel": "/nix/store/top", "hm_package": "/nix/store/hm",
            "old_target": "/nix/store/old-goose", "merge_sha": "msha", "head_sha": "hsha",
        })
        runner.files["/nix/store/cand-goose-1.54.0-patched.19"] = "cand"
        runner.files["/nix/store/top"] = "top"
        runner.files["/nix/store/hm"] = "hm"
        runner.cmd_handlers.insert(0, (lambda a: a[0] == "sqlite3", lambda a, u, e: RunResult(0, "50\n")))
        goose_cutover.check_quiet(runner)
        runner.current_time += 650

        # D5 failure: switch-to-configuration switch fails
        runner.cmd_handlers.insert(0, (
            lambda a: "switch-to-configuration" in a[0] and "switch" in a,
            lambda a, u, e: RunResult(1, "", "switch failed")
        ))
        rc = goose_cutover.main(["--run", "deploy-1"], runner=runner)
        self.assertNotEqual(rc, 0)
        # Rollback sets old target
        goose_link_calls = [c["argv"] for c in runner.calls if c["argv"][:2] == ["goose-link", "set"]]
        self.assertTrue(any("/nix/store/old-goose" in cmd for cmd in goose_link_calls))
        # Never calls `goose-link rollback`
        self.assertFalse(any(c["argv"][:2] == ["goose-link", "rollback"] for c in runner.calls))

    def test_failure_at_d6_runs_rollback_set_to_old(self):
        runner = setup_standard_runner()
        runner.files["/var/lib/goose-cutover/state.json"] = json.dumps({
            "phase": "prepared", "pr": 902, "candidate": "/nix/store/cand-goose-1.54.0-patched.19",
            "toplevel": "/nix/store/top", "hm_package": "/nix/store/hm",
            "old_target": "/nix/store/old-goose", "merge_sha": "msha", "head_sha": "hsha",
        })
        runner.files["/nix/store/cand-goose-1.54.0-patched.19"] = "cand"
        runner.files["/nix/store/top"] = "top"
        runner.files["/nix/store/hm"] = "hm"
        runner.cmd_handlers.insert(0, (lambda a: a[0] == "sqlite3", lambda a, u, e: RunResult(0, "50\n")))
        goose_cutover.check_quiet(runner)
        runner.current_time += 650

        # D6 failure: goose-link status does not match candidate
        runner.cmd_handlers.insert(0, (
            lambda a: a[:2] == ["goose-link", "status"],
            lambda a, u, e: RunResult(0, "current=/nix/store/mismatched\nprevious=<none>\npinned=/nix/store/pinned\n")
        ))
        rc = goose_cutover.main(["--run", "deploy-1"], runner=runner)
        self.assertNotEqual(rc, 0)
        # Rollback sets old target
        self.assertTrue(any(c["argv"][:3] == ["goose-link", "set", "/nix/store/old-goose"] for c in runner.calls))

    def test_failure_at_d7_runs_rollback_restarts_goose_serve(self):
        runner = setup_standard_runner()
        runner.files["/var/lib/goose-cutover/state.json"] = json.dumps({
            "phase": "prepared", "pr": 902, "candidate": "/nix/store/cand-goose-1.54.0-patched.19",
            "toplevel": "/nix/store/top", "hm_package": "/nix/store/hm",
            "old_target": "/nix/store/old-goose", "merge_sha": "msha", "head_sha": "hsha",
        })
        runner.files["/nix/store/cand-goose-1.54.0-patched.19"] = "cand"
        runner.files["/nix/store/top"] = "top"
        runner.files["/nix/store/hm"] = "hm"
        runner.cmd_handlers.insert(0, (lambda a: a[0] == "sqlite3", lambda a, u, e: RunResult(0, "50\n")))
        goose_cutover.check_quiet(runner)
        runner.current_time += 650

        # D7: goose restart curl status fails on first attempt, but succeeds during rollback restart
        curl_calls = 0
        def curl_handler(a, u, e):
            nonlocal curl_calls
            if "/status" in a[-1]:
                curl_calls += 1
                if curl_calls == 1:
                    return RunResult(1, "", "connection refused")
                return RunResult(0, '{"status":"ok"}\n')
            if any("/acp" in x for x in a):
                return RunResult(0, json.dumps({"id": 1, "jsonrpc": "2.0", "result": {"agentInfo": {"name": "goose", "version": "1.54.0"}}}))
            return RunResult(0, "")
        runner.cmd_handlers.insert(0, (lambda a: a[0] == "curl", curl_handler))

        rc = goose_cutover.main(["--run", "deploy-1"], runner=runner)
        self.assertNotEqual(rc, 0)
        # Rollback restarted goose-serve
        restarts = [c["argv"] for c in runner.calls if c["argv"][:3] == ["systemctl", "restart", "goose-serve"]]
        self.assertGreaterEqual(len(restarts), 2)

    def test_failure_at_d8_control_pong_fails_environmental(self):
        runner = setup_standard_runner()
        runner.files["/var/lib/goose-cutover/state.json"] = json.dumps({
            "phase": "prepared", "pr": 902, "candidate": "/nix/store/cand-goose-1.54.0-patched.19",
            "toplevel": "/nix/store/top", "hm_package": "/nix/store/hm",
            "old_target": "/nix/store/old-goose", "merge_sha": "msha", "head_sha": "hsha",
        })
        runner.files["/nix/store/cand-goose-1.54.0-patched.19"] = "cand"
        runner.files["/nix/store/top"] = "top"
        runner.files["/nix/store/hm"] = "hm"
        runner.files["/proc/555/cmdline"] = "/var/lib/goose/current/bin/goose\0"
        runner.links["/proc/555/exe"] = "/nix/store/cand-goose-1.54.0-patched.19/bin/goose"
        runner.cmd_handlers.insert(0, (lambda a: a[0] == "sqlite3", lambda a, u, e: RunResult(0, "50\n")))
        goose_cutover.check_quiet(runner)
        runner.current_time += 650

        ts_count = 1000
        def sys_handler(a, u, e):
            nonlocal ts_count
            if "ExecMainStartTimestampMonotonic" in " ".join(a):
                ts_count += 50
                return RunResult(0, f"ExecMainStartTimestampMonotonic={ts_count}\n")
            if "MainPID" in " ".join(a):
                return RunResult(0, "MainPID=555\n")
            if "ExecStart" in " ".join(a):
                return RunResult(0, "ExecStart={ path=/nix/store/cand-goose-1.54.0-patched.19/bin/goose }\n")
            if "is-active" in a:
                return RunResult(3, "inactive\n")
            return RunResult(0, "")
        runner.cmd_handlers.insert(0, (lambda a: a[0] == "systemctl", sys_handler))

        # PONG always fails (both candidate and control)
        runner.cmd_handlers.insert(0, (
            lambda a: a[0] == "honk" and a[1] == "tail",
            lambda a, u, e: RunResult(0, "ERROR: model timeout\n")
        ))
        rc = goose_cutover.main(["--run", "deploy-1"], runner=runner)
        self.assertNotEqual(rc, 0)
        # No revert PR created
        self.assertFalse(any(c["argv"][:3] == ["gh", "pr", "create"] for c in runner.calls))
        # State stays prepared
        state = json.loads(runner.files["/var/lib/goose-cutover/state.json"])
        self.assertEqual(state["phase"], "prepared")

    def test_failure_at_d8_control_pong_passes_creates_revert_pr(self):
        runner = setup_standard_runner()
        runner.files["/var/lib/goose-cutover/state.json"] = json.dumps({
            "phase": "prepared", "pr": 902, "candidate": "/nix/store/cand-goose-1.54.0-patched.19",
            "toplevel": "/nix/store/top", "hm_package": "/nix/store/hm",
            "old_target": "/nix/store/old-goose", "merge_sha": "msha", "head_sha": "hsha",
        })
        runner.files["/nix/store/cand-goose-1.54.0-patched.19"] = "cand"
        runner.files["/nix/store/top"] = "top"
        runner.files["/nix/store/hm"] = "hm"
        runner.files["/proc/555/cmdline"] = "/var/lib/goose/current/bin/goose\0"
        runner.links["/proc/555/exe"] = "/nix/store/cand-goose-1.54.0-patched.19/bin/goose"
        runner.cmd_handlers.insert(0, (lambda a: a[0] == "sqlite3", lambda a, u, e: RunResult(0, "50\n")))
        goose_cutover.check_quiet(runner)
        runner.current_time += 650

        ts_count = 1000
        def sys_handler(a, u, e):
            nonlocal ts_count
            if "ExecMainStartTimestampMonotonic" in " ".join(a):
                ts_count += 50
                return RunResult(0, f"ExecMainStartTimestampMonotonic={ts_count}\n")
            if "MainPID" in " ".join(a):
                return RunResult(0, "MainPID=555\n")
            if "ExecStart" in " ".join(a):
                return RunResult(0, "ExecStart={ path=/nix/store/cand-goose-1.54.0-patched.19/bin/goose }\n")
            if "is-active" in a:
                return RunResult(3, "inactive\n")
            return RunResult(0, "")
        runner.cmd_handlers.insert(0, (lambda a: a[0] == "systemctl", sys_handler))

        # Candidate PONG fails, control PONG passes
        tail_count = 0
        def honk_handler(a, u, e):
            nonlocal tail_count
            if a[1:3] == ["list", "--json"]:
                return RunResult(0, "[]")
            if a[1] == "tail":
                tail_count += 1
                if tail_count == 1:
                    return RunResult(0, "CRASH\n")
                return RunResult(0, "PONG\n")
            if a[1] == "launch":
                return RunResult(0, "native=sess_123 gse=123 tag=goose-upgrade prompt=PONG\n")
            return RunResult(0, "")
        runner.cmd_handlers.insert(0, (lambda a: a[0] == "honk", honk_handler))

        rc = goose_cutover.main(["--run", "deploy-1"], runner=runner)
        self.assertNotEqual(rc, 0)
        # Revert PR created
        pr_creates = [c["argv"] for c in runner.calls if c["argv"][:3] == ["gh", "pr", "create"]]
        self.assertEqual(len(pr_creates), 1)
        self.assertTrue(any("goose-revert" in cmd for cmd in pr_creates))
        state = json.loads(runner.files["/var/lib/goose-cutover/state.json"])
        self.assertEqual(state["phase"], "rolled-back")

    def test_rollback_failure_exits_3(self):
        runner = setup_standard_runner()
        runner.files["/var/lib/goose-cutover/state.json"] = json.dumps({
            "phase": "prepared", "pr": 902, "candidate": "/nix/store/cand-goose-1.54.0-patched.19",
            "toplevel": "/nix/store/top", "hm_package": "/nix/store/hm",
            "old_target": "/nix/store/old-goose", "merge_sha": "msha", "head_sha": "hsha",
        })
        runner.files["/nix/store/cand-goose-1.54.0-patched.19"] = "cand"
        runner.files["/nix/store/top"] = "top"
        runner.files["/nix/store/hm"] = "hm"
        runner.cmd_handlers.insert(0, (lambda a: a[0] == "sqlite3", lambda a, u, e: RunResult(0, "50\n")))
        goose_cutover.check_quiet(runner)
        runner.current_time += 650

        # D5 switch fails, triggering rollback
        runner.cmd_handlers.insert(0, (
            lambda a: "switch-to-configuration" in a[0] and "switch" in a,
            lambda a, u, e: RunResult(1, "", "switch failed")
        ))
        # Rollback goose-link set ALSO fails
        runner.cmd_handlers.insert(0, (
            lambda a: a[:2] == ["goose-link", "set"],
            lambda a, u, e: RunResult(1, "", "disk error")
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
            "old_target": "/nix/store/old-goose", "merge_sha": "msha", "head_sha": "hsha",
            "step": "restart"
        })
        runner.files["/nix/store/cand-goose-1.54.0-patched.19"] = "cand"
        runner.files["/nix/store/top"] = "top"
        runner.files["/nix/store/hm"] = "hm"
        runner.files["/proc/555/cmdline"] = "/var/lib/goose/current/bin/goose\0"
        runner.links["/proc/555/exe"] = "/nix/store/old-goose/bin/goose"

        rc = goose_cutover.main(["--run", "deploy-recover-1"], runner=runner)
        self.assertNotEqual(rc, 0)
        # goose-link set old-target called
        self.assertTrue(any(c["argv"][:3] == ["goose-link", "set", "/nix/store/old-goose"] for c in runner.calls))

    def test_status_command(self):
        runner = setup_standard_runner()
        runner.files["/var/lib/goose-cutover/state.json"] = json.dumps({
            "phase": "prepared", "pr": 902, "candidate": "/nix/store/cand",
        })
        rc = goose_cutover.main(["status"], runner=runner)
        self.assertEqual(rc, 0)


if __name__ == "__main__":
    unittest.main()
