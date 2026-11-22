#!/usr/bin/env python3
"""goose-cutover: safe cutover for goose pin updates (workstation-6w7i.27.3)."""

from contextlib import contextmanager
import fcntl
import json
import os
import signal
import subprocess
import sys
import tempfile
import time
from typing import Any, Optional


STATE_PATH = "/var/lib/goose-cutover/state.json"
RUN_LOCK_PATH = "/var/lib/goose-cutover/run.lock"

# The environment dev's commands run with, PATH in goose-serve's order. The
# unit's own PATH is only the package's runtimeInputs plus the NixOS service
# default, which has neither node (the probe's pigeon checks) nor bash: goose
# picks its shell by `which bash` (it ignores $SHELL), so without bash on PATH
# it renders "Commands run under `sh`" into the shell tool and the probe's
# rendered-surface check reports a schema change for an unchanged binary.
DEV_ENV = [
    "HOME=/home/dev",
    "USER=dev",
    "LOGNAME=dev",
    "SHELL=/run/current-system/sw/bin/bash",
    "XDG_RUNTIME_DIR=/run/user/1000",
    "PATH=/run/wrappers/bin:/run/current-system/sw/bin:/home/dev/.nix-profile/bin:"
    "/etc/profiles/per-user/dev/bin:/home/dev/.local/bin",
]
DEFAULT_HOST_REPORTS_DIR = "/var/lib/goose-cutover/host-reports"
DEFAULT_CUTOVER_HOSTS = "devbox,mac"
BACKUPS_DIR = "/var/lib/goose-cutover/backups"
GCROOTS_DIR = "/var/lib/goose-cutover/gcroots"
WORKSTATION_PATH = "/home/dev/projects/workstation"
WORKSTATION_REPO = "johnnymo87/workstation"

_SECRETS: set[str] = set()


def register_secret(secret: str) -> None:
    if secret and len(secret) >= 4:
        _SECRETS.add(secret)


def redact(text: str) -> str:
    res = str(text)
    for sec in sorted(_SECRETS, key=len, reverse=True):
        if sec and len(sec) >= 4:
            res = res.replace(sec, "[REDACTED]")
    return res


def format_error(argv: list[str], rc: int, stderr: str) -> str:
    prog = argv[0] if argv else "command"
    clean_err = redact(stderr.strip())
    if len(clean_err) > 1000:
        clean_err = clean_err[-1000:]
    return f"{prog} failed (exit {rc}): {clean_err}"


def parse_version(v: str) -> tuple[int, ...]:
    cleaned = v.strip().split("-")[0].lstrip("v")
    parts = []
    for p in cleaned.split("."):
        num = "".join(c for c in p if c.isdigit())
        parts.append(int(num) if num else 0)
    return tuple(parts)


class SigtermException(Exception):
    pass


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
        user: Optional[str] = None,
        env: Optional[dict[str, str]] = None,
        check: bool = True,
        timeout: Optional[float] = None,
        cwd: Optional[str] = None,
    ) -> RunResult:
        raise NotImplementedError

    def read_file(self, path: str) -> str:
        raise NotImplementedError

    def write_file(self, path: str, content: str) -> None:
        raise NotImplementedError

    def exists(self, path: str) -> bool:
        raise NotImplementedError

    def readlink(self, path: str) -> str:
        raise NotImplementedError

    def listdir(self, path: str) -> list[str]:
        raise NotImplementedError

    def now(self) -> float:
        raise NotImplementedError

    def sleep(self, seconds: float) -> None:
        raise NotImplementedError

    def flock(self, path: str, shared: bool = False, nonblocking: bool = True):
        raise NotImplementedError

    def hold_dev_lock(self, path: str):
        raise NotImplementedError

    def get_env(self, key: str, default: Optional[str] = None) -> Optional[str]:
        raise NotImplementedError


class RealRunner(Runner):
    """Production implementation of Runner using system primitives."""

    def run(
        self,
        argv: list[str],
        user: Optional[str] = None,
        env: Optional[dict[str, str]] = None,
        check: bool = True,
        timeout: Optional[float] = None,
        cwd: Optional[str] = None,
    ) -> RunResult:
        full_argv = list(argv)
        run_env = os.environ.copy()
        if env:
            run_env.update(env)

        if user == "dev":
            gh_token = ""
            token_path = "/run/secrets/github_api_token"
            if os.path.exists(token_path):
                try:
                    with open(token_path, "r", encoding="utf-8") as f:
                        gh_token = f.read().strip()
                except OSError:
                    pass
            if not gh_token:
                gh_token = os.environ.get("GH_TOKEN", "")

            if gh_token:
                register_secret(gh_token)
                run_env["GH_TOKEN"] = gh_token

            full_argv = [
                "runuser",
                "--whitelist-environment=GH_TOKEN",
                "-u",
                "dev",
                "--",
                "env",
            ] + DEV_ENV + argv

        proc = subprocess.run(
            full_argv,
            env=run_env,
            cwd=cwd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=timeout,
        )
        res = RunResult(proc.returncode, proc.stdout, proc.stderr)
        if check and res.rc != 0:
            raise RuntimeError(format_error(argv, res.rc, res.stderr))
        return res

    def read_file(self, path: str) -> str:
        with open(path, "r", encoding="utf-8") as f:
            return f.read()

    def write_file(self, path: str, content: str) -> None:
        parent = os.path.dirname(os.path.abspath(path))
        os.makedirs(parent, exist_ok=True)
        tmp = f"{path}.tmp.{os.getpid()}"
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(content)
        os.replace(tmp, path)

    def exists(self, path: str) -> bool:
        return os.path.exists(path) or os.path.islink(path)

    def readlink(self, path: str) -> str:
        return os.readlink(path)

    def listdir(self, path: str) -> list[str]:
        if not os.path.exists(path):
            return []
        return os.listdir(path)

    def now(self) -> float:
        return time.time()

    def sleep(self, seconds: float) -> None:
        time.sleep(seconds)

    @contextmanager
    def flock(self, path: str, shared: bool = False, nonblocking: bool = True):
        parent = os.path.dirname(os.path.abspath(path))
        os.makedirs(parent, exist_ok=True)
        flags = fcntl.LOCK_SH if shared else fcntl.LOCK_EX
        if nonblocking:
            flags |= fcntl.LOCK_NB
        f = open(path, "r" if shared else "a+")
        try:
            fcntl.flock(f.fileno(), flags)
            yield f
        finally:
            try:
                fcntl.flock(f.fileno(), fcntl.LOCK_UN)
            except OSError:
                pass
            f.close()

    @contextmanager
    def hold_dev_lock(self, path: str):
        cmd = [
            "runuser",
            "-u",
            "dev",
            "--",
            "flock",
            "-n",
            "-o",
            path,
            "sh",
            "-c",
            "echo locked; exec sleep infinity",
        ]
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
        )
        try:
            start = time.time()
            acquired = False
            while time.time() - start < 10:
                if proc.poll() is not None:
                    err = proc.stderr.read() if proc.stderr else ""
                    raise BlockingIOError(f"Dev lock {path} busy (exited rc={proc.returncode}): {err}")
                line = proc.stdout.readline() if proc.stdout else ""
                if "locked" in line:
                    acquired = True
                    break
                time.sleep(0.05)
            if not acquired:
                raise BlockingIOError(f"Dev lock {path} timed out waiting for locked signal")
            yield proc
        finally:
            if proc.poll() is None:
                try:
                    os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
                except OSError:
                    pass
                try:
                    proc.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    try:
                        os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
                    except OSError:
                        pass

    def get_env(self, key: str, default: Optional[str] = None) -> Optional[str]:
        return os.environ.get(key, default)


def log(step: str, msg: str) -> None:
    print(f"goose-cutover: {step}: {redact(msg)}", file=sys.stderr, flush=True)


def notify(
    runner: Runner,
    level: str,
    msg: str,
    instance: Optional[str] = None,
    event: Optional[str] = None,
) -> None:
    redacted_msg = redact(msg)
    log("notify", f"[{level}] {redacted_msg}")
    state_file = f"/var/lib/goose-cutover/alert-{level}.state"
    inst = instance or "cutover"
    ev = event or level
    sig = f"goose-cutover:{inst}:{ev}:{int(runner.now())}"
    alert_bin = runner.get_env("GOOSE_CUTOVER_ALERT") or "opencode-drift-alert"
    try:
        runner.run([alert_bin, state_file, sig, f"[{level.upper()}] {redacted_msg}", "0"], check=False)
    except Exception as e:
        log("notify", f"opencode-drift-alert could not be run: {e}")


def get_candidate_upstream_version(candidate_path: str) -> str:
    basename = candidate_path.rstrip("/").split("/")[-1]
    if "-goose-" in basename:
        ver = basename.split("-goose-", 1)[1]
    elif basename.startswith("goose-"):
        ver = basename.split("goose-", 1)[1]
    else:
        ver = basename
    upstream = ver.split("-patched")[0]
    return upstream


def get_acp_version(runner: Runner, port: int = 4080, secret_file: str = "/run/secrets/pigeon_goose_acp_token") -> str:
    token = ""
    if runner.exists(secret_file):
        token = runner.read_file(secret_file).strip()
        register_secret(token)

    hdr_file = f"/var/lib/goose-cutover/acp-header-{int(runner.now())}-{os.getpid()}.txt"
    runner.write_file(hdr_file, f"X-Secret-Key: {token}\n")

    try:
        payload = json.dumps({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {"protocolVersion": 1, "clientCapabilities": {}},
        })
        cmd = [
            "curl",
            "-sS",
            "-f",
            "-X",
            "POST",
            f"http://127.0.0.1:{port}/acp",
            "-H",
            "Content-Type: application/json",
            "-H",
            f"@{hdr_file}",
            "-d",
            payload,
        ]
        res = runner.run(cmd, check=True, timeout=15)
        data = json.loads(res.stdout)
        return data.get("result", {}).get("agentInfo", {}).get("version", "")
    finally:
        try:
            runner.run(["rm", "-f", hdr_file], check=False)
        except Exception:
            pass


def check_quiet(runner: Runner, script_start_time: Optional[float] = None) -> tuple[bool, str]:
    if script_start_time is not None:
        if runner.now() - script_start_time > 14400:
            return False, "less than 60 min of TimeoutStartSec remaining"

    if not hasattr(runner, "_observation_state"):
        setattr(runner, "_observation_state", {"last_id": None, "unchanged_since": None})
    obs = getattr(runner, "_observation_state")

    # 1. Stall watch check
    try:
        res = runner.run(
            ["journalctl", "_SYSTEMD_USER_UNIT=stall-watch.service", "_UID=1000", "--since", "-15min", "-o", "cat"],
            check=False,
        )
        last_json = None
        for line in res.stdout.splitlines():
            line = line.strip()
            if line.startswith('{"ts"'):
                try:
                    last_json = json.loads(line)
                except Exception:
                    pass
        if last_json is None:
            return False, "no stall-watch tick found in last 15m"

        runs = last_json.get("coordinator", {}).get("runs", 0)
        if runs == 0:
            runs = last_json.get("runs", 0)
        if runs > 0:
            return False, f"stall-watch coordinator runs > 0: {runs}"
    except Exception as e:
        return False, f"failed checking stall-watch journal: {e}"

    res = runner.run(["systemctl", "--user", "is-active", "stall-watch.service"], user="dev", check=False)
    status = res.stdout.strip()
    if status in ("active", "activating", "reloading"):
        return False, f"stall-watch.service is {status}"

    # 2. Sessions.db max(id) unchanged >= 10 min
    try:
        db_path = "file:/home/dev/.local/share/goose/sessions/sessions.db?mode=ro"
        res = runner.run(["sqlite3", db_path, "SELECT max(id) FROM messages;"], check=False)
        curr_id = res.stdout.strip()
        now = runner.now()
        if obs["last_id"] is None or curr_id != obs["last_id"]:
            obs["last_id"] = curr_id
            obs["unchanged_since"] = now
            return False, f"sessions.db max(id) recorded baseline {curr_id}"
        elapsed = now - obs["unchanged_since"]
        if elapsed < 600:
            return False, f"sessions.db max(id)={curr_id} unchanged for only {elapsed:.0f}s < 600s"
    except Exception as e:
        return False, f"failed querying sessions.db: {e}"

    # 3. goose-serve cgroup oom_score_adj < 500
    cgroup_procs_path = "/sys/fs/cgroup/system.slice/goose-serve.service/cgroup.procs"
    if runner.exists(cgroup_procs_path):
        try:
            procs = runner.read_file(cgroup_procs_path).splitlines()
            for pid_str in procs:
                pid = pid_str.strip()
                if not pid:
                    continue
                score_file = f"/proc/{pid}/oom_score_adj"
                if runner.exists(score_file):
                    score = int(runner.read_file(score_file).strip())
                    if score >= 500:
                        return False, f"goose-serve PID {pid} has oom_score_adj={score} >= 500"
        except Exception as e:
            return False, f"failed checking goose-serve cgroup procs: {e}"

    # 4. honk list --json via HONK_BIN
    honk_bin = runner.get_env("HONK_BIN") or "/home/dev/.nix-profile/bin/honk"
    try:
        res = runner.run([honk_bin, "list", "--json"], user="dev", check=False)
        try:
            sessions = json.loads(res.stdout)
            if not isinstance(sessions, list):
                return False, f"honk list output unknown shape (expected list, got {type(sessions)})"
            for sess in sessions:
                if not isinstance(sess, dict):
                    return False, "honk list item unknown shape (expected dict)"
                if sess.get("running") is True:
                    return False, f"honk session {sess.get('sessionId')} is busy (running=True)"
                if sess.get("pendingRequests", 0) > 0:
                    return False, f"honk session {sess.get('sessionId')} is busy (pendingRequests={sess.get('pendingRequests')})"
        except Exception as e:
            log("quiet", f"honk list output unknown shape: {res.stdout[:200]}")
            return False, f"honk list output unknown shape: {e}"
    except Exception as e:
        return False, f"failed running honk list: {e}"

    return True, "quiet"


def run_prepare(
    runner: Runner,
    pr: int,
    dry_run: bool = False,
    allow_noop: bool = False,
    resume_merged: bool = False,
) -> int:
    log("P1", f"Checking preconditions for PR #{pr}")

    # P1.1 Hostname cloudbox from /proc/sys/kernel/hostname
    hostname = runner.read_file("/proc/sys/kernel/hostname").strip()
    if hostname != "cloudbox":
        raise RuntimeError(f"Precondition failed: hostname must be cloudbox, got {hostname}")

    # P1.2 goose-link status exit 0
    res = runner.run(["goose-link", "status"], check=False)
    if res.rc != 0:
        raise RuntimeError(f"Precondition failed: goose-link status exited {res.rc}")
    current_link = "<none>"
    for line in res.stdout.splitlines():
        if line.startswith("current="):
            current_link = line.split("current=", 1)[1].strip()
    if current_link == "<none>":
        raise RuntimeError("Precondition failed: goose-link current is <none>")

    # P1.3 State file check
    if runner.exists(STATE_PATH):
        try:
            st = json.loads(runner.read_file(STATE_PATH))
            phase = st.get("phase")
            step = st.get("step")
            if resume_merged:
                if phase == "failed" and step != "merged-mismatch":
                    raise RuntimeError(f"Precondition failed: state.json is failed at {step}, not merged-mismatch")
                elif phase in ("deploying",):
                    raise RuntimeError(f"Precondition failed: state.json already in phase {phase}")
            else:
                if phase in ("prepared", "deploying", "failed"):
                    raise RuntimeError(f"Precondition failed: state.json already in phase {phase}")
        except json.JSONDecodeError:
            pass

    # P1.4 PR checks
    res = runner.run([
        "gh",
        "pr",
        "view",
        str(pr),
        "-R",
        WORKSTATION_REPO,
        "--json",
        "state,baseRefName,labels,headRefOid,files,statusCheckRollup,mergeable,mergeCommit",
    ], user="dev", check=True)
    pr_data = json.loads(res.stdout)

    pr_state = pr_data.get("state")
    if resume_merged:
        if pr_state != "MERGED":
            raise RuntimeError(f"PR state is {pr_state}, expected MERGED for --resume-merged")
    else:
        if pr_state != "OPEN":
            raise RuntimeError(f"PR state is {pr_state}, expected OPEN")

    if pr_data.get("baseRefName") != "main":
        raise RuntimeError(f"PR base is {pr_data.get('baseRefName')}, expected main")

    labels = [l.get("name") if isinstance(l, dict) else str(l) for l in pr_data.get("labels", [])]
    if "goose-upgrade" not in labels:
        raise RuntimeError("PR missing required label goose-upgrade")

    if "goose-major" in labels and "goose-major-ok" not in labels:
        raise RuntimeError("PR has label goose-major but missing goose-major-ok")

    files = [str(f.get("path") if isinstance(f, dict) else f) for f in pr_data.get("files", [])]
    non_pkgs_goose = [f for f in files if not f.startswith("pkgs/goose/")]
    if non_pkgs_goose and "goose-config-ok" not in labels:
        raise RuntimeError(f"PR changes files outside pkgs/goose/** without goose-config-ok: {non_pkgs_goose}")

    if pr_data.get("mergeable") == "CONFLICTING":
        raise RuntimeError("PR has merge conflicts (mergeable=CONFLICTING)")

    # Status checks: empty statusCheckRollup fails
    checks = pr_data.get("statusCheckRollup", [])
    if not checks:
        raise RuntimeError("PR has no status checks (statusCheckRollup is empty)")
    for check in checks:
        concl = check.get("conclusion") or check.get("state")
        status = check.get("status")
        if status in ("IN_PROGRESS", "QUEUED", "PENDING"):
            raise RuntimeError(f"PR check {check.get('name')} is pending/in-progress")
        if concl not in ("SUCCESS", "NEUTRAL", "SKIPPED"):
            raise RuntimeError(f"PR check {check.get('name')} has conclusion {concl}")

    # P1.5 Mechanical hosts-ready check
    reports_dir = runner.get_env("GOOSE_HOST_REPORTS_DIR") or DEFAULT_HOST_REPORTS_DIR
    hosts_str = runner.get_env("GOOSE_CUTOVER_HOSTS") or DEFAULT_CUTOVER_HOSTS
    hosts = [h.strip() for h in hosts_str.split(",") if h.strip()]

    # Cloudbox local check
    honk_bin = runner.get_env("HONK_BIN") or "/home/dev/.nix-profile/bin/honk"
    if not runner.exists(honk_bin):
        raise RuntimeError(f"honk binary missing at {honk_bin}")
    res = runner.run([honk_bin, "--version"], user="dev", check=False)
    if res.rc != 0:
        raise RuntimeError("cloudbox local honk --version failed")

    # Probe binary check
    probe_bin = runner.get_env("GOOSE_UPGRADE_PROBE") or "/home/dev/.nix-profile/bin/goose-upgrade-probe"
    if not runner.exists(probe_bin):
        raise RuntimeError(f"goose-upgrade-probe missing at {probe_bin}")

    # Remote reports
    now_ts = runner.now()
    min_honk_version = runner.get_env("GOOSE_MIN_HONK_VERSION")
    for host in hosts:
        report_path = f"{reports_dir}/{host}.json"
        if not runner.exists(report_path):
            raise RuntimeError(f"hosts-not-ready: {host} (report missing at {report_path})")
        try:
            rep = json.loads(runner.read_file(report_path))
        except Exception as e:
            raise RuntimeError(f"hosts-not-ready: {host} (malformed json: {e})")

        ts = rep.get("ts", 0)
        age = now_ts - ts
        if age > 26 * 3600:
            raise RuntimeError(f"hosts-not-ready: {host} (stale report: {age / 3600:.1f}h > 26h)")

        link = rep.get("link_current")
        if not link or link == "<none>":
            raise RuntimeError(f"hosts-not-ready: {host} (missing link_current)")

        honk_ver = rep.get("honk_version")
        if not honk_ver:
            raise RuntimeError(f"hosts-not-ready: {host} (missing honk_version)")
        if min_honk_version:
            if parse_version(honk_ver) < parse_version(min_honk_version):
                raise RuntimeError(f"hosts-not-ready: {host} (honk_version {honk_ver} < {min_honk_version})")

    # All hosts ready: apply label (only if not dry_run)
    if not dry_run:
        runner.run(["gh", "pr", "edit", str(pr), "-R", WORKSTATION_REPO, "--add-label", "goose-hosts-ready"], user="dev", check=True)
    else:
        log("P1", "dry-run: would apply label goose-hosts-ready")

    head_sha = pr_data.get("headRefOid", "")
    cand_link = f"{GCROOTS_DIR}/candidate-{pr}"
    top_link = f"{GCROOTS_DIR}/toplevel-{pr}"
    hm_link = f"{GCROOTS_DIR}/hm-{pr}"

    if resume_merged:
        log("P2", "Resuming merged PR: building candidate + toplevel + HM from origin/main")
        runner.run(["git", "-C", WORKSTATION_PATH, "fetch", "origin", "+refs/heads/main:refs/remotes/origin/main"], user="dev", check=True)
        new_main_sha = runner.run(["git", "-C", WORKSTATION_PATH, "rev-parse", "origin/main"], user="dev", check=True).stdout.strip()
        merge_sha = (pr_data.get("mergeCommit") or {}).get("oid") or ""
        if not merge_sha:
            raise RuntimeError("PR has no mergeCommit oid; refusing to guess the pin commit")

        wt_main = f"/tmp/goose-cutover-resume-{pr}-{int(runner.now())}"
        runner.run(["git", "-C", WORKSTATION_PATH, "worktree", "add", "--detach", wt_main, "origin/main"], user="dev", check=True)
        try:
            runner.run([
                "nix",
                "build",
                f"{wt_main}#nixosConfigurations.cloudbox.config.environment.etc.\"goose/pinned\".source",
                "--out-link",
                cand_link,
            ], user="dev", check=True)
            runner.run([
                "nix",
                "build",
                f"{wt_main}#nixosConfigurations.cloudbox.config.system.build.toplevel",
                "--out-link",
                top_link,
            ], user="dev", check=True)
            runner.run([
                "nix",
                "build",
                f"{wt_main}#homeConfigurations.cloudbox.activationPackage",
                "--out-link",
                hm_link,
            ], user="dev", check=True)

            candidate_path = runner.readlink(cand_link)
            toplevel_path = runner.readlink(top_link)
            hm_package = runner.readlink(hm_link)
        finally:
            runner.run(["git", "-C", WORKSTATION_PATH, "worktree", "remove", "--force", wt_main], user="dev", check=False)

        # Probe candidate built from origin/main
        log("P3", "Running goose-upgrade-probe against candidate")
        res = runner.run([
            probe_bin,
            f"{candidate_path}/bin/goose",
            "--old-bin",
            "/var/lib/goose/current/bin/goose",
        ], user="dev", check=False)
        if res.rc != 0:
            lines = (res.stdout + "\n" + res.stderr).splitlines()[-40:]
            log("P3", f"Probe failed (exit {res.rc}):\n" + "\n".join(lines))
            raise RuntimeError(f"probe failed (exit {res.rc})")

        # P5 Persist
        state_data = {
            "phase": "prepared",
            "pr": pr,
            "head_sha": head_sha,
            "merge_sha": merge_sha,
            "built_from": new_main_sha,
            "old_target": current_link,
            "candidate": candidate_path,
            "toplevel": toplevel_path,
            "hm_package": hm_package,
            "old_system": "",
            "started_at": int(runner.now()),
            "step": "prepared",
        }
        runner.write_file(STATE_PATH, json.dumps(state_data))
        notify(runner, "info", f"goose-cutover: PR #{pr} resumed and prepared; deploy pending", instance=f"prepare-{pr}", event="prepared")
        return 0

    # Normal Prepare:
    # P2. Candidate - Build ONLY candidate goose from merge ref for probe
    log("P2", "Fetching candidate from merge ref")
    runner.run([
        "git",
        "-C",
        WORKSTATION_PATH,
        "fetch",
        "origin",
        f"+refs/pull/{pr}/merge:refs/remotes/origin/pr/{pr}/merge",
        "+refs/heads/main:refs/remotes/origin/main",
    ], user="dev", check=True)

    parent1 = runner.run([
        "git",
        "-C",
        WORKSTATION_PATH,
        "rev-parse",
        f"refs/remotes/origin/pr/{pr}/merge^1",
    ], user="dev", check=True).stdout.strip()
    main_sha = runner.run([
        "git",
        "-C",
        WORKSTATION_PATH,
        "rev-parse",
        "origin/main",
    ], user="dev", check=True).stdout.strip()
    if parent1 != main_sha:
        raise RuntimeError(f"stale-merge-ref: merge ref parent {parent1} != origin/main {main_sha}")

    wt_dir = f"/tmp/goose-cutover-worktree-{pr}-{int(runner.now())}"
    runner.run([
        "git",
        "-C",
        WORKSTATION_PATH,
        "worktree",
        "add",
        "--detach",
        wt_dir,
        f"refs/remotes/origin/pr/{pr}/merge",
    ], user="dev", check=True)

    candidate_path = ""
    try:
        runner.run([
            "nix",
            "build",
            f"{wt_dir}#nixosConfigurations.cloudbox.config.environment.etc.\"goose/pinned\".source",
            "--out-link",
            cand_link,
        ], user="dev", check=True)
        candidate_path = runner.readlink(cand_link)
    finally:
        runner.run(["git", "-C", WORKSTATION_PATH, "worktree", "remove", "--force", wt_dir], user="dev", check=False)

    if candidate_path == current_link and not allow_noop:
        raise RuntimeError(f"noop candidate == current ({candidate_path}); use --allow-noop to proceed")

    # P3. Probe
    log("P3", "Running goose-upgrade-probe")
    res = runner.run([
        probe_bin,
        f"{candidate_path}/bin/goose",
        "--old-bin",
        "/var/lib/goose/current/bin/goose",
    ], user="dev", check=False)
    if res.rc != 0:
        lines = (res.stdout + "\n" + res.stderr).splitlines()[-40:]
        log("P3", f"Probe failed (exit {res.rc}):\n" + "\n".join(lines))
        raise RuntimeError(f"probe failed (exit {res.rc})")

    # P4. Merge & Build from origin/main
    if dry_run:
        log("P4", f"dry-run: prepare succeeded up to P3; would merge PR #{pr} and build from origin/main")
        return 0

    log("P4", f"Merging PR #{pr}")
    runner.run(["gh", "pr", "merge", str(pr), "-R", WORKSTATION_REPO, "--squash", "--match-head-commit", head_sha], user="dev", check=True)

    # Poll until MERGED
    merged = False
    for _ in range(60):
        res = runner.run(["gh", "pr", "view", str(pr), "-R", WORKSTATION_REPO, "--json", "state"], user="dev", check=True)
        if json.loads(res.stdout).get("state") == "MERGED":
            merged = True
            break
        runner.sleep(5)
    if not merged:
        raise RuntimeError(f"Timed out waiting for PR #{pr} to be MERGED")

    # Fetch mergeCommit oid
    res = runner.run(["gh", "pr", "view", str(pr), "-R", WORKSTATION_REPO, "--json", "mergeCommit"], user="dev", check=True)
    merge_sha = (json.loads(res.stdout).get("mergeCommit") or {}).get("oid") or ""

    # Fetch origin/main
    runner.run(["git", "-C", WORKSTATION_PATH, "fetch", "origin", "+refs/heads/main:refs/remotes/origin/main"], user="dev", check=True)
    new_main_sha = runner.run(["git", "-C", WORKSTATION_PATH, "rev-parse", "origin/main"], user="dev", check=True).stdout.strip()
    if not merge_sha:
        raise RuntimeError("PR has no mergeCommit oid after merge; refusing to guess the pin commit")

    # Build candidate, toplevel, HM from origin/main
    log("P4", "Building candidate + toplevel + HM from origin/main")
    wt_main = f"/tmp/goose-cutover-main-{pr}-{int(runner.now())}"
    runner.run(["git", "-C", WORKSTATION_PATH, "worktree", "add", "--detach", wt_main, "origin/main"], user="dev", check=True)

    try:
        runner.run([
            "nix",
            "build",
            f"{wt_main}#nixosConfigurations.cloudbox.config.environment.etc.\"goose/pinned\".source",
            "--out-link",
            cand_link,
        ], user="dev", check=True)
        runner.run([
            "nix",
            "build",
            f"{wt_main}#nixosConfigurations.cloudbox.config.system.build.toplevel",
            "--out-link",
            top_link,
        ], user="dev", check=True)
        runner.run([
            "nix",
            "build",
            f"{wt_main}#homeConfigurations.cloudbox.activationPackage",
            "--out-link",
            hm_link,
        ], user="dev", check=True)

        built_candidate = runner.readlink(cand_link)
        toplevel_path = runner.readlink(top_link)
        hm_package = runner.readlink(hm_link)
    finally:
        runner.run(["git", "-C", WORKSTATION_PATH, "worktree", "remove", "--force", wt_main], user="dev", check=False)

    if built_candidate != candidate_path:
        state_data = {
            "phase": "failed",
            "step": "merged-mismatch",
            "pr": pr,
            "candidate": built_candidate,
            "toplevel": toplevel_path,
            "hm_package": hm_package,
        }
        runner.write_file(STATE_PATH, json.dumps(state_data))
        raise RuntimeError("merged-mismatch: rebuilt candidate on origin/main differs from probed candidate")

    # P5. Persist state
    log("P5", "Writing state.json")
    state_data = {
        "phase": "prepared",
        "pr": pr,
        "head_sha": head_sha,
        "merge_sha": merge_sha,
        "built_from": new_main_sha,
        "old_target": current_link,
        "candidate": candidate_path,
        "toplevel": toplevel_path,
        "hm_package": hm_package,
        "old_system": "",
        "started_at": int(runner.now()),
        "step": "prepared",
    }
    runner.write_file(STATE_PATH, json.dumps(state_data))
    notify(runner, "info", f"goose-cutover: PR #{pr} merged and prepared; deploy pending", instance=f"prepare-{pr}", event="prepared")
    return 0


def run_deploy(runner: Runner, dry_run: bool = False, recover: bool = False) -> int:
    unit_start = float(runner.get_env("GOOSE_CUTOVER_START_TIME") or runner.now())
    log("D1", "Loading state.json")
    if not runner.exists(STATE_PATH):
        raise RuntimeError(f"State file {STATE_PATH} does not exist")

    state = json.loads(runner.read_file(STATE_PATH))
    phase = state.get("phase")

    if phase == "failed":
        log("D1", f"refusing deploy: state phase is failed (requires --recover or human intervention)")
        return 1

    if recover:
        if phase != "deploying":
            raise RuntimeError(f"cannot recover: state phase is {phase}, expected deploying")
        log("recover", "Running rollback for recovering deployment")
        with runner.flock("/tmp/reset-workspace.lock", shared=True, nonblocking=True):
            return run_rollback(runner, state, "recover", "deploy --recover requested", restarted_goose=True)

    if phase != "prepared":
        raise RuntimeError(f"cannot deploy: state phase is {phase}, expected prepared (crashed run may need --recover)")

    cand = state["candidate"]
    top = state["toplevel"]
    hm = state["hm_package"]
    pr_num = state["pr"]
    for p in (cand, top, hm):
        if not p or not runner.exists(p):
            raise RuntimeError(f"GC-rooted path missing: {p}")

    # D2. Quiet window
    log("D2", "Checking quiet window")
    if dry_run:
        q, reason = check_quiet(runner, unit_start)
        log("D2", f"dry-run quiet check: {q} ({reason})")
        res = runner.run([f"{top}/bin/switch-to-configuration", "dry-activate"], check=False)
        log("D4", f"dry-run dry-activate exit={res.rc}")
        log("deploy", "dry-run: would acquire locks, activate, flip, restart, post-check, and persist")
        return 0

    start_wait = runner.now()
    restarted_goose = False
    restarted_honkd = False

    def handle_sigterm_signal(signum, frame):
        raise SigtermException("SIGTERM received during cutover")

    old_sigterm = signal.signal(signal.SIGTERM, handle_sigterm_signal)

    # Main quiet & lock acquisition loop
    try:
        while True:
            if runner.now() - start_wait > 7200:
                log("D2", "quiet window timed out after 2h")
                notify(runner, "warning", "goose-cutover: quiet window timed out after 2h; deploy remains prepared", instance="deploy-1", event="quiet-timeout")
                return 0

            q, reason = check_quiet(runner, unit_start)
            if not q:
                if "less than 60 min of TimeoutStartSec remaining" in reason:
                    log("D2", f"refusing deploy: {reason}")
                    notify(runner, "warning", f"goose-cutover: {reason}; deploy remains prepared", instance="deploy-1", event="timeout-refusal")
                    return 0
                runner.sleep(30)
                continue

            # Attempt D3 locks
            try:
                with runner.flock("/tmp/reset-workspace.lock", shared=True, nonblocking=True):
                    try:
                        with runner.hold_dev_lock("/run/user/1000/pull-workstation.lock"):
                            try:
                                runner.run(["systemctl", "--user", "stop", "stall-watch.timer", "stall-watch-wake.path"], user="dev", check=True)

                                # Wait until inactive (fails if active/activating/reloading after 10 min)
                                stopped = False
                                for _ in range(300):
                                    res = runner.run(["systemctl", "--user", "is-active", "stall-watch.service"], user="dev", check=False)
                                    if res.stdout.strip() not in ("active", "activating", "reloading"):
                                        stopped = True
                                        break
                                    runner.sleep(2)

                                if not stopped:
                                    log("D3", "stall-watch.service failed to stop within 10 min; pre-D5 clean refusal")
                                    notify(runner, "warning", "goose-cutover: stall-watch failed to stop; deploy remains prepared", instance="deploy-1", event="stall-watch-timeout")
                                    return 0

                                # D3 Reconcile main
                                runner.run([
                                    "git",
                                    "-C",
                                    WORKSTATION_PATH,
                                    "fetch",
                                    "origin",
                                    "+refs/heads/main:refs/remotes/origin/main",
                                ], user="dev", check=True)
                                current_main = runner.run(["git", "-C", WORKSTATION_PATH, "rev-parse", "origin/main"], user="dev", check=True).stdout.strip()
                                built_from = state.get("built_from") or state.get("merge_sha")
                                if current_main != built_from:
                                    log("D3", f"origin/main moved ({built_from} -> {current_main}), rebuilding at origin/main")
                                    wt_main = f"/tmp/goose-cutover-deploy-{pr_num}-{int(runner.now())}"
                                    runner.run(["git", "-C", WORKSTATION_PATH, "worktree", "add", "--detach", wt_main, "origin/main"], user="dev", check=True)
                                    cand_link = f"{GCROOTS_DIR}/candidate-{pr_num}"
                                    top_link = f"{GCROOTS_DIR}/toplevel-{pr_num}"
                                    hm_link = f"{GCROOTS_DIR}/hm-{pr_num}"
                                    try:
                                        runner.run([
                                            "nix",
                                            "build",
                                            f"{wt_main}#nixosConfigurations.cloudbox.config.environment.etc.\"goose/pinned\".source",
                                            "--out-link",
                                            cand_link,
                                        ], user="dev", check=True)
                                        runner.run([
                                            "nix",
                                            "build",
                                            f"{wt_main}#nixosConfigurations.cloudbox.config.system.build.toplevel",
                                            "--out-link",
                                            top_link,
                                        ], user="dev", check=True)
                                        runner.run([
                                            "nix",
                                            "build",
                                            f"{wt_main}#homeConfigurations.cloudbox.activationPackage",
                                            "--out-link",
                                            hm_link,
                                        ], user="dev", check=True)
                                        new_cand = runner.readlink(cand_link)
                                        new_top = runner.readlink(top_link)
                                        new_hm = runner.readlink(hm_link)
                                        if new_cand != cand:
                                            log("D3", f"origin/main candidate changed ({cand} -> {new_cand}); setting phase=failed step=merged-mismatch")
                                            state["phase"] = "failed"
                                            state["step"] = "merged-mismatch"
                                            runner.write_file(STATE_PATH, json.dumps(state))
                                            notify(runner, "error", f"goose-cutover: candidate changed on origin/main; deploy aborted (use prepare --resume-merged)", instance="deploy-1", event="merged-mismatch")
                                            return 1
                                        state["toplevel"] = new_top
                                        state["hm_package"] = new_hm
                                        state["built_from"] = current_main
                                        top = new_top
                                        hm = new_hm
                                        runner.write_file(STATE_PATH, json.dumps(state))
                                    finally:
                                        runner.run(["git", "-C", WORKSTATION_PATH, "worktree", "remove", "--force", wt_main], user="dev", check=False)

                                q, reason = check_quiet(runner, unit_start)
                                if not q:
                                    log("D3", f"quiet re-check failed after locking ({reason}); returning to D2 polling")
                                    runner.sleep(30)
                                    continue

                                # D4. Gate + backup
                                log("D4", "Gate + backup")
                                res = runner.run([f"{top}/bin/switch-to-configuration", "dry-activate"], check=True)
                                out_text = f"{res.stdout}\n{res.stderr}"
                                for line in out_text.splitlines():
                                    if "would stop" in line or "would restart" in line:
                                        for unit in line.split()[5:]:
                                            u = unit.strip(",.")
                                            if u and u not in ("systemd-tmpfiles-resetup.service", "systemd-tmpfiles-setup.service"):
                                                if u == "lgtm-run.service":
                                                    for _ in range(150):
                                                        c = runner.run(["systemctl", "is-active", "lgtm-run.service"], check=False)
                                                        if c.stdout.strip() not in ("active", "activating", "reloading"):
                                                            break
                                                        runner.sleep(2)
                                                else:
                                                    log("D4", f"dry-activate would stop/restart unallowed unit: {u}; pre-D5 refusal")
                                                    notify(runner, "warning", f"goose-cutover: dry-activate refused unit {u}; deploy remains prepared", instance="deploy-1", event="gate-refusal")
                                                    return 0

                                # Backup sessions.db
                                utc_ts = int(runner.now())
                                backup_file = f"{BACKUPS_DIR}/sessions-{utc_ts}-pr{pr_num}.db"
                                try:
                                    runner.run(["sqlite3", "/home/dev/.local/share/goose/sessions/sessions.db", f".backup {backup_file}"], check=True)
                                except Exception as e:
                                    log("D4", f"backup failed: {e}; pre-D5 refusal")
                                    notify(runner, "warning", "goose-cutover: sessions.db backup failed; deploy remains prepared", instance="deploy-1", event="backup-failed")
                                    return 0

                                # Keep newest 5
                                existing = runner.listdir(BACKUPS_DIR)
                                db_backups = sorted([f for f in existing if f.startswith("sessions-") and f.endswith(".db")])
                                if len(db_backups) > 5:
                                    for old_b in db_backups[:-5]:
                                        try:
                                            runner.run(["rm", "-f", f"{BACKUPS_DIR}/{old_b}"], check=False)
                                        except Exception:
                                            pass

                                old_sys = runner.run(["readlink", "-f", "/nix/var/nix/profiles/system"], check=True).stdout.strip()
                                state["old_system"] = old_sys
                                runner.write_file(STATE_PATH, json.dumps(state))

                            except (Exception, SigtermException) as e:
                                log("D3/D4", f"pre-D5 failure: {e}; restoring prepared state")
                                state["phase"] = "prepared"
                                runner.write_file(STATE_PATH, json.dumps(state))
                                notify(runner, "warning", f"goose-cutover: pre-D5 failure ({e}); deploy remains prepared", instance="deploy-1", event="pre-d5-failure")
                                return 0

                            # Immediately before D5: write phase=deploying
                            state["phase"] = "deploying"
                            state["step"] = "deploying"
                            runner.write_file(STATE_PATH, json.dumps(state))

                            # Execution D5-D8 (any failure past this point triggers rollback)
                            try:
                                # D5. Activate
                                log("D5", "Activating new system and home-manager")
                                state["step"] = "activate"
                                runner.write_file(STATE_PATH, json.dumps(state))
                                runner.run(["nix-env", "-p", "/nix/var/nix/profiles/system", "--set", top], check=True)
                                runner.run([f"{top}/bin/switch-to-configuration", "switch"], check=True)
                                runner.run([f"{hm}/activate"], user="dev", check=True)

                                # D6. Flip
                                log("D6", "Flipping goose-link")
                                state["step"] = "flip"
                                runner.write_file(STATE_PATH, json.dumps(state))
                                runner.run(["goose-link", "set", cand], check=True)
                                res = runner.run(["goose-link", "status"], check=True)
                                cur = ""
                                for line in res.stdout.splitlines():
                                    if line.startswith("current="):
                                        cur = line.split("current=", 1)[1].strip()
                                if cur != cand:
                                    raise RuntimeError(f"goose-link flip failed: current={cur} != {cand}")

                                # D7. Restart
                                log("D7", "Restarting goose-serve")
                                state["step"] = "restart"
                                runner.write_file(STATE_PATH, json.dumps(state))

                                res = runner.run(["systemctl", "show", "-p", "ExecMainStartTimestampMonotonic", "goose-serve"], check=True)
                                old_mono = 0
                                for line in res.stdout.splitlines():
                                    if "ExecMainStartTimestampMonotonic=" in line:
                                        old_mono = int(line.split("=", 1)[1].strip())

                                restarted_goose_time = runner.now()
                                restarted_goose = True
                                runner.run(["systemctl", "restart", "goose-serve"], check=True)

                                # Poll curl /status up to 60s
                                ok_status = False
                                for _ in range(60):
                                    res = runner.run(["curl", "-sf", "http://127.0.0.1:4080/status"], check=False)
                                    if res.rc == 0:
                                        ok_status = True
                                        break
                                    runner.sleep(1)
                                if not ok_status:
                                    raise RuntimeError("goose-serve failed to answer /status after restart")

                                res = runner.run(["systemctl", "show", "-p", "ExecMainStartTimestampMonotonic", "goose-serve"], check=True)
                                new_mono = 0
                                for line in res.stdout.splitlines():
                                    if "ExecMainStartTimestampMonotonic=" in line:
                                        new_mono = int(line.split("=", 1)[1].strip())
                                if new_mono <= old_mono:
                                    raise RuntimeError(f"goose-serve ExecMainStartTimestampMonotonic did not increase ({new_mono} <= {old_mono})")

                                res = runner.run(["systemctl", "show", "-p", "MainPID", "goose-serve"], check=True)
                                main_pid = res.stdout.split("=", 1)[1].strip()

                                cmdline = runner.read_file(f"/proc/{main_pid}/cmdline")
                                argv0 = cmdline.split("\0")[0]
                                if argv0 != "/var/lib/goose/current/bin/goose":
                                    raise RuntimeError(f"MainPID {main_pid} argv0={argv0} != /var/lib/goose/current/bin/goose")

                                exe = runner.readlink(f"/proc/{main_pid}/exe")
                                if exe != f"{cand}/bin/goose":
                                    raise RuntimeError(f"MainPID {main_pid} exe={exe} != {cand}/bin/goose")

                                acp_ver = get_acp_version(runner)
                                expected_ver = get_candidate_upstream_version(cand)
                                if acp_ver != expected_ver:
                                    raise RuntimeError(f"ACP version {acp_ver} != expected upstream version {expected_ver}")

                                # honkd check: restart only if unit's ExecStart differs from running exe
                                res = runner.run(["systemctl", "--user", "show", "-p", "ExecStart", "honkd"], user="dev", check=False)
                                exec_path = ""
                                for part in res.stdout.split():
                                    if part.startswith("path="):
                                        exec_path = part.split("path=", 1)[1]
                                res_pid = runner.run(["systemctl", "--user", "show", "-p", "MainPID", "honkd"], user="dev", check=False)
                                honkd_pid = res_pid.stdout.split("=", 1)[1].strip() if "=" in res_pid.stdout else ""
                                running_honkd_exe = runner.readlink(f"/proc/{honkd_pid}/exe") if honkd_pid and runner.exists(f"/proc/{honkd_pid}/exe") else ""

                                if exec_path and running_honkd_exe and exec_path != running_honkd_exe:
                                    restarted_honkd = True
                                    runner.run(["systemctl", "--user", "restart", "honkd"], user="dev", check=True)
                                    # Wait up to 30s for listening in journal
                                    for _ in range(15):
                                        res_j = runner.run(["journalctl", "--user-unit=honkd.service", "--since", "-30s", "-n", "20"], user="dev", check=False)
                                        if "listening" in res_j.stdout:
                                            break
                                        runner.sleep(2)
                                else:
                                    # Wait up to 30s for upstream control connection re-initialized
                                    for _ in range(15):
                                        res_j = runner.run(["journalctl", "--user-unit=honkd.service", "--since", "-30s", "-n", "20"], user="dev", check=False)
                                        if "Upstream control connection re-initialized successfully" in res_j.stdout:
                                            break
                                        runner.sleep(2)

                                # D8. Post-checks
                                log("D8", "Running post-checks")
                                state["step"] = "post-checks"
                                runner.write_file(STATE_PATH, json.dumps(state))

                                honk_bin = runner.get_env("HONK_BIN") or "/home/dev/.nix-profile/bin/honk"
                                res = runner.run([
                                    honk_bin,
                                    "launch",
                                    "--tag",
                                    "goose-upgrade",
                                    "--no-attach",
                                    "--title",
                                    "goose-cutover-probe",
                                    "--model",
                                    "claude-haiku-4-5@20251001",
                                    "--effort",
                                    "off",
                                    "/tmp",
                                    "Reply with exactly: PONG",
                                ], user="dev", check=True)

                                sess_id = ""
                                for part in res.stdout.split():
                                    if part.startswith("native="):
                                        sess_id = part.split("native=", 1)[1]
                                if not sess_id:
                                    raise RuntimeError(f"Could not parse native=<id> from honk launch: {res.stdout}")

                                log("D8", f"Launched probe session {sess_id}, polling for turn completion")
                                completed = False
                                for _ in range(100):
                                    res_l = runner.run([honk_bin, "list", "--json"], user="dev", check=False)
                                    try:
                                        s_list = json.loads(res_l.stdout)
                                        target_sess = next((s for s in s_list if s.get("sessionId") == sess_id), None)
                                        if target_sess and not target_sess.get("running") and target_sess.get("pendingRequests", 0) == 0:
                                            completed = True
                                            break
                                    except Exception:
                                        pass
                                    runner.sleep(3)

                                res_t = runner.run(["timeout", "30", honk_bin, "tail", "--text-only", sess_id], user="dev", check=False)
                                if "PONG" not in res_t.stdout:
                                    raise RuntimeError(f"PONG not in honk output: {res_t.stdout}")

                                # (b) restart stall-watch.timer and stall-watch-wake.path
                                runner.run(["systemctl", "--user", "start", "stall-watch.timer", "stall-watch-wake.path"], user="dev", check=True)

                                # Wait <= 10 min for first tick JSON line with ts (ms epoch) > goose_restart_time
                                goose_restart_ms = int(restarted_goose_time * 1000)
                                tick_found = False
                                start_sw_wait = runner.now()
                                while runner.now() - start_sw_wait <= 600:
                                    res_j = runner.run(
                                        ["journalctl", "_SYSTEMD_USER_UNIT=stall-watch.service", "_UID=1000", "--since", "-10min", "-o", "cat"],
                                        check=False,
                                    )
                                    for line in res_j.stdout.splitlines():
                                        line = line.strip()
                                        if line.startswith('{"ts"'):
                                            try:
                                                data = json.loads(line)
                                                ts = data.get("ts", 0)
                                                if ts > goose_restart_ms:
                                                    if not data.get("ok"):
                                                        raise RuntimeError(f"stall-watch tick after restart reported ok=false: {line}")
                                                    coord_runs = data.get("coordinator", {}).get("runs", 0)
                                                    log("D8", f"stall-watch post-restart tick ok=true (coordinator.runs={coord_runs})")
                                                    tick_found = True
                                                    break
                                            except json.JSONDecodeError:
                                                pass
                                    if tick_found:
                                        break
                                    runner.sleep(3)

                                if not tick_found:
                                    raise RuntimeError("timed out waiting for stall-watch tick after goose restart")

                                # D9. Success
                                log("D9", "Cutover successful")
                                state["phase"] = "deployed"
                                state["step"] = "deployed"
                                runner.write_file(STATE_PATH, json.dumps(state))

                                deployed_data = {
                                    "pr": state["pr"],
                                    "merge_sha": state["merge_sha"],
                                    "store_path": cand,
                                    "version": expected_ver,
                                    "ts": int(runner.now()),
                                }
                                runner.write_file("/var/lib/goose-cutover/deployed.json", json.dumps(deployed_data))
                                notify(runner, "info", f"goose-cutover: PR #{state['pr']} live: {state['old_target']} -> {cand}", instance="deploy-1", event="deployed")
                                return 0

                            except (Exception, SigtermException) as e:
                                log("deploy", f"Deploy failed during {state.get('step')}: {e}")
                                return run_rollback(runner, state, state.get("step", "unknown"), str(e), restarted_goose, restarted_honkd)

                    except BlockingIOError:
                        log("D3", "pull-workstation.lock busy; returning to D2 polling loop")
                        runner.run(["systemctl", "--user", "start", "stall-watch.timer", "stall-watch-wake.path"], user="dev", check=False)
                        runner.sleep(30)
                        continue
                    finally:
                        runner.run(["systemctl", "--user", "start", "stall-watch.timer", "stall-watch-wake.path"], user="dev", check=False)

            except BlockingIOError:
                log("D3", "reset-workspace.lock busy; returning to D2 polling loop")
                runner.sleep(30)
                continue

    finally:
        signal.signal(signal.SIGTERM, old_sigterm)


def run_rollback(
    runner: Runner,
    state: dict[str, Any],
    failing_step: str,
    detail: str,
    restarted_goose: bool = False,
    restarted_honkd: bool = False,
) -> int:
    log("rollback", f"Rolling back to old target {state.get('old_target')}")
    old_target = state.get("old_target")
    pr = state.get("pr")
    merge_sha = state.get("merge_sha")

    try:
        # 1. goose-link set <old_target>
        if not old_target:
            raise RuntimeError("old_target missing from state")
        runner.run(["goose-link", "set", old_target], check=True)

        # 2. Restart goose-serve if needed
        if restarted_goose:
            restarted_goose = True
            runner.run(["systemctl", "restart", "goose-serve"], check=True)
            # Poll /status up to 60s
            ok_status = False
            for _ in range(60):
                res = runner.run(["curl", "-sf", "http://127.0.0.1:4080/status"], check=False)
                if res.rc == 0:
                    ok_status = True
                    break
                runner.sleep(1)
            if not ok_status:
                raise RuntimeError("goose-serve failed to answer /status after rollback restart")

            # Verify MainPID argv0 and exe link
            res_pid = runner.run(["systemctl", "show", "-p", "MainPID", "goose-serve"], check=True)
            main_pid = res_pid.stdout.split("=", 1)[1].strip()
            cmdline = runner.read_file(f"/proc/{main_pid}/cmdline")
            argv0 = cmdline.split("\0")[0]
            if argv0 != "/var/lib/goose/current/bin/goose":
                raise RuntimeError(f"MainPID {main_pid} argv0={argv0} != /var/lib/goose/current/bin/goose")
            exe = runner.readlink(f"/proc/{main_pid}/exe")
            if exe != f"{old_target}/bin/goose":
                raise RuntimeError(f"MainPID {main_pid} exe={exe} != {old_target}/bin/goose")

        if restarted_honkd:
            runner.run(["systemctl", "--user", "restart", "honkd"], user="dev", check=False)

        # 4. Control check: run D8(a) PONG against old binary
        control_passed = False
        try:
            honk_bin = runner.get_env("HONK_BIN") or "/home/dev/.nix-profile/bin/honk"
            res = runner.run([
                honk_bin,
                "launch",
                "--tag",
                "goose-upgrade",
                "--no-attach",
                "--title",
                "goose-cutover-probe",
                "--model",
                "claude-haiku-4-5@20251001",
                "--effort",
                "off",
                "/tmp",
                "Reply with exactly: PONG",
            ], user="dev", check=True)
            sess_id = ""
            for part in res.stdout.split():
                if part.startswith("native="):
                    sess_id = part.split("native=", 1)[1]
            if sess_id:
                res_t = runner.run(["timeout", "30", honk_bin, "tail", "--text-only", sess_id], user="dev", check=False)
                if "PONG" in res_t.stdout:
                    control_passed = True
        except Exception as e:
            log("rollback", f"Control check failed: {e}")

        if not control_passed:
            log("rollback", "Control check failed; failure appears environmental")
            notify(
                runner,
                "warning",
                f"goose-cutover: rolled back, failure looks environmental ({failing_step}: {detail}); pin left merged; rerun deploy",
                instance=f"deploy-{pr}",
                event="environmental-rollback",
            )
            state["phase"] = "prepared"
            state["step"] = "prepared"
            runner.write_file(STATE_PATH, json.dumps(state))
            return 1

        # 5. Control passed -> open revert PR
        log("rollback", "Control check passed; opening revert PR")
        wt_dir = f"/tmp/goose-revert-worktree-{pr}-{int(runner.now())}"
        runner.run(["git", "-C", WORKSTATION_PATH, "worktree", "add", "--detach", wt_dir, "origin/main"], user="dev", check=True)
        revert_url = ""
        try:
            runner.run(["git", "-C", wt_dir, "revert", "--no-edit", str(merge_sha)], user="dev", check=True)
            branch = f"goose-cutover-revert-{pr}"
            runner.run(["git", "-C", wt_dir, "push", "origin", f"HEAD:refs/heads/{branch}"], user="dev", check=True)
            body = f"Failing step: {failing_step}\nDetail: {redact(detail)}"
            res = runner.run([
                "gh",
                "pr",
                "create",
                "-R",
                WORKSTATION_REPO,
                "--base",
                "main",
                "--head",
                branch,
                "--label",
                "goose-revert",
                "--title",
                f"Revert PR #{pr}",
                "--body",
                body,
            ], user="dev", check=True, cwd=wt_dir)
            revert_url = res.stdout.strip()
        finally:
            runner.run(["git", "-C", WORKSTATION_PATH, "worktree", "remove", "--force", wt_dir], user="dev", check=False)

        state["phase"] = "rolled-back"
        state["step"] = "rolled-back"
        runner.write_file(STATE_PATH, json.dumps(state))
        notify(
            runner,
            "error",
            f"goose-cutover: deploy failed at {failing_step}; rolled back and opened revert PR: {revert_url}",
            instance=f"deploy-{pr}",
            event="rolled-back",
        )
        return 1

    except Exception as e:
        log("rollback", f"Rollback step failed: {e}")
        notify(runner, "error", f"ROLLBACK FAILED at {failing_step}; goose-serve state unknown", instance=f"deploy-{pr}", event="rollback-failed")
        state["phase"] = "failed"
        state["step"] = f"rollback-failed-{failing_step}"
        runner.write_file(STATE_PATH, json.dumps(state))
        return 3


def main(argv: Optional[list[str]] = None, runner: Optional[Runner] = None) -> int:
    if argv is None:
        argv = sys.argv[1:]
    if runner is None:
        runner = RealRunner()

    if not argv:
        print("usage: goose-cutover prepare <pr> [--dry-run] [--allow-noop] [--resume-merged] | deploy [--dry-run] [--recover] | status | --run <instance>", file=sys.stderr)
        return 2

    cmd = argv[0]

    if cmd == "status":
        if not runner.exists(STATE_PATH):
            print(f"no state file ({STATE_PATH})")
            return 0
        try:
            st = json.loads(runner.read_file(STATE_PATH))
            print(json.dumps(st, indent=2))
            return 0
        except Exception as e:
            print(f"failed reading state file: {e}", file=sys.stderr)
            return 1

    if cmd == "--run":
        if len(argv) < 2:
            print("usage: goose-cutover --run <instance>", file=sys.stderr)
            return 2
        instance = argv[1]

        # Guard: INVOCATION_ID must be set
        if not runner.get_env("INVOCATION_ID"):
            print("refusing: --run must be executed by systemd inside goose-cutover@ ($INVOCATION_ID missing)", file=sys.stderr)
            return 2

        # Guard: cgroup must name goose-cutover@
        try:
            cgroup = runner.read_file("/proc/self/cgroup")
            if "goose-cutover@" not in cgroup:
                print("refusing: --run must be executed by systemd inside goose-cutover@ (cgroup mismatch)", file=sys.stderr)
                return 2
        except Exception as e:
            print(f"refusing: could not read /proc/self/cgroup: {e}", file=sys.stderr)
            return 2

        tokens = instance.split("-")
        phase = tokens[0]

        try:
            with runner.flock(RUN_LOCK_PATH, shared=False, nonblocking=True):
                if phase == "prepare":
                    pr = int(tokens[-1])
                    dry_run = "dry" in tokens
                    allow_noop = "noop" in tokens
                    resume_merged = "resume" in tokens
                    return run_prepare(runner, pr, dry_run=dry_run, allow_noop=allow_noop, resume_merged=resume_merged)
                elif phase == "deploy":
                    dry_run = "dry" in tokens
                    recover = "recover" in tokens
                    return run_deploy(runner, dry_run=dry_run, recover=recover)
                else:
                    print(f"unknown phase in instance: {phase}", file=sys.stderr)
                    return 2
        except BlockingIOError:
            log("lock", f"Global lock {RUN_LOCK_PATH} busy; cutover already running")
            notify(runner, "warning", "goose-cutover: global lock busy; another cutover is running", instance=instance, event="lock-busy")
            return 1
        except Exception as e:
            log("error", f"Cutover failed: {e}")
            return 1

    # Launcher commands: prepare and deploy without --run
    if cmd in ("prepare", "deploy"):
        try:
            cgroup = runner.read_file("/proc/self/cgroup")
            if "goose-serve" in cgroup:
                print("refusing: goose-cutover launcher cannot run inside goose-serve cgroup", file=sys.stderr)
                return 2
        except Exception as e:
            log("launcher", f"Note: could not read /proc/self/cgroup: {e}")

        # Check run.lock before starting unit
        # flock -n exits 1 only when the lock is held; any other non-zero
        # (e.g. the lock file cannot be opened yet) is not "a cutover is running".
        res_lock = runner.run(["flock", "-n", RUN_LOCK_PATH, "true"], check=False)
        if res_lock.rc == 1:
            print("refusing: a cutover is running (/var/lib/goose-cutover/run.lock busy)", file=sys.stderr)
            return 2
        if res_lock.rc != 0:
            log("launcher", f"Note: run.lock probe rc={res_lock.rc}; the unit takes the lock itself")

        if cmd == "prepare":
            if len(argv) < 2:
                print("usage: goose-cutover prepare <pr> [--dry-run] [--allow-noop] [--resume-merged]", file=sys.stderr)
                return 2
            pr = argv[1]
            dry_run = "--dry-run" in argv
            allow_noop = "--allow-noop" in argv
            resume_merged = "--resume-merged" in argv

            parts = ["prepare"]
            if dry_run:
                parts.append("dry")
            if allow_noop:
                parts.append("noop")
            if resume_merged:
                parts.append("resume")
            parts.append(str(pr))
            instance = "-".join(parts)

        else:  # deploy
            dry_run = "--dry-run" in argv
            recover = "--recover" in argv

            parts = ["deploy"]
            if dry_run:
                parts.append("dry")
            if recover:
                parts.append("recover")
            parts.append("1")
            instance = "-".join(parts)

        unit = f"goose-cutover@{instance}.service"
        runner.run(["sudo", "systemctl", "start", "--no-block", unit], check=True)
        print(f"Started {unit}")
        print(f"Follow logs with: journalctl -fu {unit}")
        return 0

    print(f"unknown command: {cmd}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
