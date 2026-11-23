#!/usr/bin/env python3
"""goose-host-report: publish and fetch goose host readiness reports (workstation-6w7i.27.12)."""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from typing import Any, Callable, Optional


DEFAULT_REPO = "johnnymo87/workstation"
DEFAULT_HOST_REPORTS_DIR = "/var/lib/goose-cutover/host-reports"
DEFAULT_CUTOVER_HOSTS = "devbox,mac"


class RunResult:
    def __init__(self, rc: int, stdout: str = "", stderr: str = ""):
        self.rc = rc
        self.stdout = stdout
        self.stderr = stderr

    def __iter__(self):
        return iter((self.rc, self.stdout, self.stderr))


class Runner:
    """Base Runner interface for dependency injection."""

    def run(
        self,
        argv: list[str],
        env: Optional[dict[str, str]] = None,
        check: bool = False,
    ) -> RunResult:
        raise NotImplementedError

    def which(self, cmd: str) -> Optional[str]:
        raise NotImplementedError

    def realpath(self, path: str) -> str:
        raise NotImplementedError

    def now(self) -> float:
        raise NotImplementedError

    def write_file_atomic(self, path: str, content: str) -> None:
        raise NotImplementedError

    def get_env(self, key: str, default: Optional[str] = None) -> Optional[str]:
        raise NotImplementedError


class RealRunner(Runner):
    """Real system execution runner."""

    def run(
        self,
        argv: list[str],
        env: Optional[dict[str, str]] = None,
        check: bool = False,
    ) -> RunResult:
        full_env = os.environ.copy()
        if env:
            full_env.update(env)
        p = subprocess.run(argv, env=full_env, capture_output=True, text=True)
        res = RunResult(p.returncode, p.stdout, p.stderr)
        if check and res.rc != 0:
            raise RuntimeError(f"Command {' '.join(argv)} failed (exit {res.rc}): {res.stderr.strip()}")
        return res

    def which(self, cmd: str) -> Optional[str]:
        return shutil.which(cmd)

    def realpath(self, path: str) -> str:
        return os.path.realpath(path)

    def now(self) -> float:
        return time.time()

    def write_file_atomic(self, path: str, content: str) -> None:
        parent = os.path.dirname(path)
        if parent:
            os.makedirs(parent, exist_ok=True)
        tmp = f"{path}.tmp.{os.getpid()}"
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(content)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)

    def get_env(self, key: str, default: Optional[str] = None) -> Optional[str]:
        return os.environ.get(key, default)


class MockRunner(Runner):
    """In-memory mock runner for unit testing."""

    def __init__(self):
        self.commands: dict[str, RunResult] = {}
        self.command_handlers: dict[str, Callable[[list[str]], RunResult]] = {}
        self.binaries: dict[str, str] = {}
        self.realpaths: dict[str, str] = {}
        self.files: dict[str, str] = {}
        self.history: list[list[str]] = []
        self.current_time: float = 1700000000.0
        self.env: dict[str, str] = {}

    def run(
        self,
        argv: list[str],
        env: Optional[dict[str, str]] = None,
        check: bool = False,
    ) -> RunResult:
        self.history.append(list(argv))
        cmd = argv[0]
        if cmd in self.command_handlers:
            res = self.command_handlers[cmd](argv)
        elif cmd in self.commands:
            res = self.commands[cmd]
        else:
            res = RunResult(0, "")
        if check and res.rc != 0:
            raise RuntimeError(f"Command {' '.join(argv)} failed (exit {res.rc}): {res.stderr.strip()}")
        return res

    def which(self, cmd: str) -> Optional[str]:
        return self.binaries.get(cmd)

    def realpath(self, path: str) -> str:
        return self.realpaths.get(path, path)

    def now(self) -> float:
        return self.current_time

    def write_file_atomic(self, path: str, content: str) -> None:
        self.files[path] = content

    def get_env(self, key: str, default: Optional[str] = None) -> Optional[str]:
        return self.env.get(key, default)


def parse_honk_version(output: str) -> str:
    """Parse version string from `honk --version` output."""
    raw = output.strip()
    if not raw:
        raise ValueError("honk --version produced empty output")
    # honk typically prints "honk X.Y.Z" or "honk vX.Y.Z"
    parts = raw.split()
    ver = parts[-1].lstrip("v")
    if not re.search(r"\d+\.\d+", ver):
        raise ValueError(f"honk --version output not recognized: {raw!r}")
    return ver


def generate_report(
    runner: Runner,
    host: str,
    goose_link_bin: Optional[str] = None,
    honk_bin: Optional[str] = None,
    goose_bin: Optional[str] = None,
) -> dict[str, Any]:
    """Generate the readiness report dictionary for the specified host.

    Structure:
        host: str (e.g. 'devbox', 'mac')
        ts: int (unix seconds timestamp)
        link_current: str (resolved store path of the approved/running goose binary)
        honk_version: str (e.g. '0.5.0')
    """
    link_current: Optional[str] = None

    # On macOS (host == 'mac' or platform darwin), there is no /var/lib/goose/current
    # and modules/goose-current.nix is not deployed. Both goose-serve (launchd agent in
    # users/dev/home.darwin.nix) and the user CLI (users/dev/goose-config.nix) run the same
    # packaged binary directly (pkgs/goose, pinned on macOS to patched-1.54.0.18).
    # Therefore, link_current on the Mac is reported as the resolved path of the goose
    # binary on PATH / in the nix profile (via os.path.realpath(shutil.which("goose"))),
    # which points directly to the active Nix store path.
    is_mac = host == "mac" or sys.platform == "darwin"

    if not is_mac:
        # On Linux / devbox: goose-link status is the authoritative source.
        gl_bin = goose_link_bin or runner.which("goose-link") or "goose-link"
        res = runner.run([gl_bin, "status"])
        if res.rc != 0:
            raise RuntimeError(f"goose-link status failed (exit {res.rc}): {res.stderr.strip()}")
        for line in res.stdout.splitlines():
            if line.startswith("current="):
                link_current = line.split("=", 1)[1].strip()
                break
        if not link_current or link_current == "<none>":
            raise RuntimeError(f"goose-link status: link_current is <none> or missing in output: {res.stdout.strip()}")
    else:
        # On Mac: resolve the goose binary that runs CLI and serve.
        g_bin = goose_bin or runner.which("goose")
        if not g_bin:
            # Fall back to standard profile locations if which() fails in non-interactive environment
            for candidate in [
                "/Users/dev/.nix-profile/bin/goose",
                "/etc/profiles/per-user/dev/bin/goose",
                "/run/current-system/sw/bin/goose",
            ]:
                if runner.which(candidate) or candidate in getattr(runner, "binaries", {}):
                    g_bin = candidate
                    break
        if not g_bin:
            raise RuntimeError("mac: goose binary not found on PATH or profile")
        resolved = runner.realpath(g_bin)
        if not resolved or resolved == "<none>":
            raise RuntimeError(f"mac: could not resolve realpath for goose binary {g_bin}")
        link_current = resolved

    # Detect honk version
    h_bin = honk_bin or runner.which("honk") or "honk"
    res_honk = runner.run([h_bin, "--version"])
    if res_honk.rc != 0:
        raise RuntimeError(f"honk --version failed (exit {res_honk.rc}): {res_honk.stderr.strip()}")
    honk_version = parse_honk_version(res_honk.stdout)

    return {
        "host": host,
        "ts": int(runner.now()),
        "link_current": link_current,
        "honk_version": honk_version,
    }


def publish_report(
    runner: Runner,
    host: str,
    repo: str = DEFAULT_REPO,
    goose_link_bin: Optional[str] = None,
    honk_bin: Optional[str] = None,
    goose_bin: Optional[str] = None,
) -> None:
    """Publish the readiness report to GitHub Actions repo variable."""
    rep = generate_report(
        runner,
        host=host,
        goose_link_bin=goose_link_bin,
        honk_bin=honk_bin,
        goose_bin=goose_bin,
    )
    json_payload = json.dumps(rep)
    var_name = f"GOOSE_HOST_REPORT_{host.upper()}"

    res = runner.run(["gh", "variable", "set", var_name, "--body", json_payload, "-R", repo])
    if res.rc != 0:
        err_msg = res.stderr.strip() or f"exit code {res.rc}"
        sys.stderr.write(f"goose-host-report: failed to set gh variable {var_name} on {repo}: {err_msg}\n")
        raise RuntimeError(f"failed to set gh variable {var_name}: {err_msg}")

    sys.stdout.write(f"goose-host-report: successfully published {var_name} for host {host}: {json_payload}\n")


def fetch_reports(
    runner: Runner,
    reports_dir: str = DEFAULT_HOST_REPORTS_DIR,
    hosts: Optional[list[str]] = None,
    repo: str = DEFAULT_REPO,
) -> bool:
    """Fetch reports from GitHub Actions repo variables and write atomically to disk.

    Returns True if all requested host reports were successfully fetched and written.
    """
    if hosts is None:
        hosts = [h.strip() for h in DEFAULT_CUTOVER_HOSTS.split(",") if h.strip()]

    all_ok = True
    for host in hosts:
        var_name = f"GOOSE_HOST_REPORT_{host.upper()}"
        res = runner.run(["gh", "variable", "get", var_name, "-R", repo])
        if res.rc != 0:
            sys.stderr.write(f"goose-host-report: failed to get gh variable {var_name} on {repo}: {res.stderr.strip()}\n")
            all_ok = False
            continue

        raw = res.stdout.strip()
        try:
            data = json.loads(raw)
        except Exception as e:
            sys.stderr.write(f"goose-host-report: invalid JSON in {var_name}: {e} (raw: {raw!r})\n")
            all_ok = False
            continue

        # Validate schema
        ts = data.get("ts")
        link = data.get("link_current")
        ver = data.get("honk_version")
        if not isinstance(ts, (int, float)) or ts <= 0:
            sys.stderr.write(f"goose-host-report: invalid ts in {var_name}: {ts!r}\n")
            all_ok = False
            continue
        if not link or link == "<none>":
            sys.stderr.write(f"goose-host-report: invalid link_current in {var_name}: {link!r}\n")
            all_ok = False
            continue
        if not ver:
            sys.stderr.write(f"goose-host-report: invalid honk_version in {var_name}: {ver!r}\n")
            all_ok = False
            continue

        dest = os.path.join(reports_dir, f"{host}.json")
        try:
            runner.write_file_atomic(dest, json.dumps(data, indent=2) + "\n")
            sys.stdout.write(f"goose-host-report: wrote {dest} for host {host} (ts={ts}, honk={ver})\n")
        except Exception as e:
            sys.stderr.write(f"goose-host-report: failed to write {dest}: {e}\n")
            all_ok = False

    return all_ok


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="goose-host-report: publish or fetch host readiness reports")
    subparsers = parser.add_subparsers(dest="command", required=True)

    # publish subcommand
    pub_parser = subparsers.add_parser("publish", help="Publish local host report to GitHub repo variable")
    pub_parser.add_argument("--host", default=None, help="Host name (devbox or mac). Autodetected if omitted.")
    pub_parser.add_argument("--repo", default=DEFAULT_REPO, help=f"GitHub repository (default: {DEFAULT_REPO})")
    pub_parser.add_argument("--goose-link-bin", default=None, help="Path to goose-link binary")
    pub_parser.add_argument("--honk-bin", default=None, help="Path to honk binary")
    pub_parser.add_argument("--goose-bin", default=None, help="Path to goose binary")

    # fetch subcommand
    fetch_parser = subparsers.add_parser("fetch", help="Fetch remote host reports and write atomically")
    fetch_parser.add_argument(
        "--dir",
        default=os.environ.get("GOOSE_HOST_REPORTS_DIR", DEFAULT_HOST_REPORTS_DIR),
        help=f"Directory for host reports (default: {DEFAULT_HOST_REPORTS_DIR})",
    )
    fetch_parser.add_argument(
        "--hosts",
        default=os.environ.get("GOOSE_CUTOVER_HOSTS", DEFAULT_CUTOVER_HOSTS),
        help=f"Comma-separated host list (default: {DEFAULT_CUTOVER_HOSTS})",
    )
    fetch_parser.add_argument("--repo", default=DEFAULT_REPO, help=f"GitHub repository (default: {DEFAULT_REPO})")

    args = parser.parse_args(argv)
    runner = RealRunner()

    if args.command == "publish":
        host = args.host
        if not host:
            # Autodetect from hostname or environment
            hname = os.uname().nodename.lower()
            if "devbox" in hname:
                host = "devbox"
            elif sys.platform == "darwin" or "mac" in hname or "y0fmqx93rr" in hname:
                host = "mac"
            else:
                host = hname
        try:
            publish_report(
                runner,
                host=host,
                repo=args.repo,
                goose_link_bin=args.goose_link_bin,
                honk_bin=args.honk_bin,
                goose_bin=args.goose_bin,
            )
            return 0
        except Exception as e:
            sys.stderr.write(f"goose-host-report publish failed: {e}\n")
            return 1

    elif args.command == "fetch":
        hosts_list = [h.strip() for h in args.hosts.split(",") if h.strip()]
        ok = fetch_reports(runner, reports_dir=args.dir, hosts=hosts_list, repo=args.repo)
        return 0 if ok else 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
