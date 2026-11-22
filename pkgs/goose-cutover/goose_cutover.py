#!/usr/bin/env python3
"""goose-cutover: safe cutover for goose pin updates (workstation-6w7i.27.3)."""

from contextlib import contextmanager
import fcntl
import json
import os
import signal
import subprocess
import sys
import time
from typing import Any, Optional


STATE_PATH = "/var/lib/goose-cutover/state.json"
RUN_LOCK_PATH = "/var/lib/goose-cutover/run.lock"
DEFAULT_HOST_REPORTS_DIR = "/var/lib/goose-cutover/host-reports"
DEFAULT_CUTOVER_HOSTS = "devbox,mac"
BACKUPS_DIR = "/var/lib/goose-cutover/backups"
GCROOTS_DIR = "/var/lib/goose-cutover/gcroots"


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

            full_argv = [
                "runuser",
                "-u",
                "dev",
                "--",
                "env",
                "HOME=/home/dev",
                "XDG_RUNTIME_DIR=/run/user/1000",
                f"GH_TOKEN={gh_token}",
            ] + argv

        proc = subprocess.run(
            full_argv,
            env=run_env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=timeout,
        )
        res = RunResult(proc.returncode, proc.stdout, proc.stderr)
        if check and res.rc != 0:
            raise RuntimeError(
                f"Command failed with rc {res.rc}: {' '.join(full_argv)}\nSTDOUT:\n{res.stdout}\nSTDERR:\n{res.stderr}"
            )
        return res

    def read_file(self, path: str) -> str:
        with open(path, "r", encoding="utf-8") as f:
            return f.read()

    def write_file(self, path: str, content: str) -> None:
        parent = os.path.dirname(os.path.abspath(path))
        os.makedirs(parent, exist_ok=True)
        tmp = f"{path}.tmp.{os.getpid()}"
        with open(tmp, "w", encoding="utf-8") as f:
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

    def get_env(self, key: str, default: Optional[str] = None) -> Optional[str]:
        return os.environ.get(key, default)


def log(step: str, msg: str) -> None:
    print(f"goose-cutover: {step}: {msg}", file=sys.stderr, flush=True)


def notify(runner: Runner, level: str, msg: str) -> None:
    log("notify", f"[{level}] {msg}")
    state_file = f"/var/lib/goose-cutover/alert-{level}.state"
    sig = f"goose-cutover:{level}"
    try:
        runner.run(["opencode-drift-alert", state_file, sig, msg, "0"], check=False)
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
        f"X-Secret-Key: {token}",
        "-d",
        payload,
    ]
    res = runner.run(cmd, check=True, timeout=15)
    data = json.loads(res.stdout)
    return data.get("result", {}).get("agentInfo", {}).get("version", "")


def check_quiet(runner: Runner) -> tuple[bool, str]:
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
        if last_json is not None:
            runs = last_json.get("coordinator", {}).get("runs", 0)
            if runs == 0:
                runs = last_json.get("runs", 0)
            if runs > 0:
                return False, f"stall-watch coordinator runs > 0: {runs}"
    except Exception as e:
        return False, f"failed checking stall-watch journal: {e}"

    res = runner.run(["systemctl", "--user", "is-active", "stall-watch.service"], user="dev", check=False)
    if res.stdout.strip() == "active":
        return False, "stall-watch.service is active"

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

    # 4. honk list --json
    try:
        res = runner.run(["honk", "list", "--json"], user="dev", check=False)
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

    # P1.1 Hostname cloudbox
    res = runner.run(["hostname"], check=True)
    if res.stdout.strip() != "cloudbox":
        raise RuntimeError(f"Precondition failed: hostname must be cloudbox, got {res.stdout.strip()}")

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

    # P1.3 State file not in prepared or deploying
    if runner.exists(STATE_PATH):
        try:
            st = json.loads(runner.read_file(STATE_PATH))
            phase = st.get("phase")
            if phase in ("prepared", "deploying"):
                raise RuntimeError(f"Precondition failed: state.json already in phase {phase}")
        except json.JSONDecodeError:
            pass

    # P1.4 PR checks
    res = runner.run([
        "gh",
        "pr",
        "view",
        str(pr),
        "--json",
        "state,baseRefName,labels,headRefOid,files,statusCheckRollup,mergeable",
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

    # Status checks
    checks = pr_data.get("statusCheckRollup", [])
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
    res = runner.run(["honk", "--version"], user="dev", check=False)
    if res.rc != 0:
        raise RuntimeError("cloudbox local honk --version failed")

    # Remote reports
    now_ts = runner.now()
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

        if not rep.get("honk_version"):
            raise RuntimeError(f"hosts-not-ready: {host} (missing honk_version)")

    # All hosts ready: apply label
    runner.run(["gh", "pr", "edit", str(pr), "--add-label", "goose-hosts-ready"], user="dev", check=True)

    # P2. Candidate
    log("P2", "Fetching candidate and building")
    runner.run(["git", "fetch", "origin", f"refs/pull/{pr}/merge"], user="dev", check=True)
    runner.run(["git", "fetch", "origin", "main"], user="dev", check=True)

    parent1 = runner.run(["git", "rev-parse", f"refs/pull/{pr}/merge^1"], user="dev", check=True).stdout.strip()
    main_sha = runner.run(["git", "rev-parse", "origin/main"], user="dev", check=True).stdout.strip()
    if parent1 != main_sha:
        raise RuntimeError(f"stale-merge-ref: merge ref parent {parent1} != origin/main {main_sha}")

    wt_dir = f"/tmp/goose-cutover-worktree-{pr}-{int(runner.now())}"
    runner.run(["git", "worktree", "add", "--detach", wt_dir, f"refs/pull/{pr}/merge"], user="dev", check=True)

    candidate_path = ""
    toplevel_path = ""
    hm_package = ""
    try:
        cand_link = f"{GCROOTS_DIR}/candidate-{pr}"
        top_link = f"{GCROOTS_DIR}/toplevel-{pr}"
        hm_link = f"{GCROOTS_DIR}/hm-{pr}"

        runner.run([
            "nix",
            "build",
            '.#nixosConfigurations.cloudbox.config.environment.etc."goose/pinned".source',
            "--out-link",
            cand_link,
        ], user="dev", check=True)
        runner.run([
            "nix",
            "build",
            ".#nixosConfigurations.cloudbox.config.system.build.toplevel",
            "--out-link",
            top_link,
        ], user="dev", check=True)
        runner.run([
            "nix",
            "build",
            ".#homeConfigurations.cloudbox.activationPackage",
            "--out-link",
            hm_link,
        ], user="dev", check=True)

        candidate_path = runner.readlink(cand_link)
        toplevel_path = runner.readlink(top_link)
        hm_package = runner.readlink(hm_link)
    finally:
        runner.run(["git", "worktree", "remove", "--force", wt_dir], user="dev", check=False)

    if candidate_path == current_link and not allow_noop:
        raise RuntimeError(f"noop candidate == current ({candidate_path}); use --allow-noop to proceed")

    # P3. Probe
    log("P3", "Running goose-upgrade-probe")
    probe_bin = runner.get_env("GOOSE_UPGRADE_PROBE") or "/home/dev/.nix-profile/bin/goose-upgrade-probe"
    if not runner.exists(probe_bin):
        raise RuntimeError(f"goose-upgrade-probe missing at {probe_bin}")

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

    # P4. Merge
    if dry_run:
        log("P4", f"dry-run: prepare succeeded up to P3; would merge PR #{pr} and write state.json")
        return 0

    log("P4", f"Merging PR #{pr}")
    head_sha = pr_data.get("headRefOid", "")
    runner.run(["gh", "pr", "merge", str(pr), "--squash", "--match-head-commit", head_sha], user="dev", check=True)

    # Poll until MERGED
    merged = False
    for _ in range(60):
        res = runner.run(["gh", "pr", "view", str(pr), "--json", "state"], user="dev", check=True)
        if json.loads(res.stdout).get("state") == "MERGED":
            merged = True
            break
        runner.sleep(5)
    if not merged:
        raise RuntimeError(f"Timed out waiting for PR #{pr} to be MERGED")

    runner.run(["git", "fetch", "origin", "main"], user="dev", check=True)
    new_main_sha = runner.run(["git", "rev-parse", "origin/main"], user="dev", check=True).stdout.strip()
    res = runner.run(["gh", "pr", "view", str(pr), "--json", "mergeCommit"], user="dev", check=True)
    merge_sha = json.loads(res.stdout).get("mergeCommit", {}).get("oid", "")

    if new_main_sha != merge_sha:
        # main moved past it, verify rebuild at origin/main
        log("P4", "origin/main moved past merge commit, rebuilding at origin/main")
        wt_main = f"/tmp/goose-cutover-main-{pr}-{int(runner.now())}"
        runner.run(["git", "worktree", "add", "--detach", wt_main, "origin/main"], user="dev", check=True)
        try:
            cand_link = f"{GCROOTS_DIR}/candidate-{pr}"
            top_link = f"{GCROOTS_DIR}/toplevel-{pr}"
            hm_link = f"{GCROOTS_DIR}/hm-{pr}"
            runner.run([
                "nix",
                "build",
                '.#nixosConfigurations.cloudbox.config.environment.etc."goose/pinned".source',
                "--out-link",
                cand_link,
            ], user="dev", check=True)
            runner.run([
                "nix",
                "build",
                ".#nixosConfigurations.cloudbox.config.system.build.toplevel",
                "--out-link",
                top_link,
            ], user="dev", check=True)
            runner.run([
                "nix",
                "build",
                ".#homeConfigurations.cloudbox.activationPackage",
                "--out-link",
                hm_link,
            ], user="dev", check=True)
            new_cand = runner.readlink(cand_link)
            new_top = runner.readlink(top_link)
            new_hm = runner.readlink(hm_link)
            if (new_cand, new_top, new_hm) != (candidate_path, toplevel_path, hm_package):
                state_data = {
                    "phase": "failed",
                    "step": "merged-mismatch",
                    "pr": pr,
                    "candidate": new_cand,
                    "toplevel": new_top,
                    "hm_package": new_hm,
                }
                runner.write_file(STATE_PATH, json.dumps(state_data))
                raise RuntimeError("merged-mismatch: rebuilt paths on origin/main differ from prepare")
        finally:
            runner.run(["git", "worktree", "remove", "--force", wt_main], user="dev", check=False)

    # P5. Persist state
    log("P5", "Writing state.json")
    state_data = {
        "phase": "prepared",
        "pr": pr,
        "head_sha": head_sha,
        "merge_sha": merge_sha,
        "old_target": current_link,
        "candidate": candidate_path,
        "toplevel": toplevel_path,
        "hm_package": hm_package,
        "old_system": "",
        "started_at": int(runner.now()),
        "step": "prepared",
    }
    runner.write_file(STATE_PATH, json.dumps(state_data))
    notify(runner, "info", f"goose-cutover: PR #{pr} merged and prepared; deploy pending")
    return 0


def run_deploy(runner: Runner, dry_run: bool = False, recover: bool = False) -> int:
    log("D1", "Loading state.json")
    if not runner.exists(STATE_PATH):
        raise RuntimeError(f"State file {STATE_PATH} does not exist")

    state = json.loads(runner.read_file(STATE_PATH))
    phase = state.get("phase")

    if recover:
        if phase != "deploying":
            raise RuntimeError(f"cannot recover: state phase is {phase}, expected deploying")
        log("recover", "Running rollback for recovering deployment")
        return run_rollback(runner, state, "recover", "deploy --recover requested", restarted_goose=True)

    if phase != "prepared":
        raise RuntimeError(f"cannot deploy: state phase is {phase}, expected prepared (crashed run may need --recover)")

    cand = state["candidate"]
    top = state["toplevel"]
    hm = state["hm_package"]
    for p in (cand, top, hm):
        if not p or not runner.exists(p):
            raise RuntimeError(f"GC-rooted path missing: {p}")

    # D2. Quiet window
    log("D2", "Checking quiet window")
    if dry_run:
        q, reason = check_quiet(runner)
        log("D2", f"dry-run quiet check: {q} ({reason})")
        # Run D4 dry-activate gate
        res = runner.run([f"{top}/bin/switch-to-configuration", "dry-activate"], check=False)
        log("D4", f"dry-run dry-activate exit={res.rc}")
        log("deploy", "dry-run: would acquire locks, activate, flip, restart, post-check, and persist")
        return 0

    start_wait = runner.now()
    quiet = False
    while runner.now() - start_wait <= 7200:
        q, reason = check_quiet(runner)
        if q:
            quiet = True
            break
        runner.sleep(30)

    if not quiet:
        notify(runner, "warning", "goose-cutover: quiet window timed out after 2h; deploy remains prepared")
        return 1

    # D3. Locks and holds
    log("D3", "Acquiring locks")
    restarted_goose = False
    restarted_honkd = False

    def handle_sigterm_signal(signum, frame):
        raise SigtermException("SIGTERM received during cutover")

    old_sigterm = signal.signal(signal.SIGTERM, handle_sigterm_signal)

    try:
        with runner.flock("/tmp/reset-workspace.lock", shared=True, nonblocking=True):
            with runner.flock("/run/user/1000/pull-workstation.lock", shared=False, nonblocking=True):
                runner.run(["systemctl", "--user", "stop", "stall-watch.timer"], user="dev", check=True)
                # Wait until inactive
                for _ in range(300):
                    res = runner.run(["systemctl", "--user", "is-active", "stall-watch.service"], user="dev", check=False)
                    if res.stdout.strip() != "active":
                        break
                    runner.sleep(2)

                q, reason = check_quiet(runner)
                if not q:
                    raise RuntimeError(f"Quiet check failed after locking: {reason}")

                state["phase"] = "deploying"
                state["step"] = "deploying"
                runner.write_file(STATE_PATH, json.dumps(state))

                # D4. Gate + backup
                log("D4", "Gate + backup")
                res = runner.run([f"{top}/bin/switch-to-configuration", "dry-activate"], check=True)
                for line in res.stdout.splitlines():
                    if "would stop" in line or "would restart" in line:
                        for unit in line.split()[5:]:
                            u = unit.strip(",.")
                            if u and u not in ("systemd-tmpfiles-resetup.service", "systemd-tmpfiles-setup.service"):
                                if u == "lgtm-run.service":
                                    for _ in range(150):
                                        c = runner.run(["systemctl", "is-active", "lgtm-run.service"], check=False)
                                        if c.stdout.strip() != "active":
                                            break
                                        runner.sleep(2)
                                else:
                                    raise RuntimeError(f"dry-activate would stop/restart unallowed unit: {u}")

                # Backup sessions.db
                utc_ts = int(runner.now())
                pr_num = state["pr"]
                backup_file = f"{BACKUPS_DIR}/sessions-{utc_ts}-pr{pr_num}.db"
                runner.run(["sqlite3", "/home/dev/.local/share/goose/sessions/sessions.db", f".backup {backup_file}"], check=False)

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

                runner.run(["systemctl", "restart", "goose-serve"], check=True)
                restarted_goose = True

                # Poll curl /status
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

                # honkd check
                res = runner.run(["systemctl", "--user", "show", "-p", "ExecStart", "honkd.service"], user="dev", check=False)
                if exe not in res.stdout:
                    runner.run(["systemctl", "--user", "restart", "honkd"], user="dev", check=True)
                    restarted_honkd = True

                # D8. Post-checks
                log("D8", "Running post-checks")
                state["step"] = "post-checks"
                runner.write_file(STATE_PATH, json.dumps(state))

                # (a) honk headless PONG
                res = runner.run([
                    "honk",
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

                res = runner.run(["honk", "tail", "--text-only", "--exit-on-turn-end", sess_id], user="dev", check=True, timeout=300)
                if "PONG" not in res.stdout:
                    raise RuntimeError(f"PONG not in honk output: {res.stdout}")

                runner.run(["honk", "archive", sess_id], user="dev", check=False)

                # (b) restart stall-watch.timer
                runner.run(["systemctl", "--user", "start", "stall-watch.timer"], user="dev", check=True)

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
                notify(runner, "info", f"goose-cutover: PR #{state['pr']} live: {state['old_target']} -> {cand}")
                return 0

    except (Exception, SigtermException) as e:
        log("deploy", f"Deploy failed during {state.get('step')}: {e}")
        return run_rollback(runner, state, state.get("step", "unknown"), str(e), restarted_goose, restarted_honkd)
    finally:
        signal.signal(signal.SIGTERM, old_sigterm)
        try:
            runner.run(["systemctl", "--user", "start", "stall-watch.timer"], user="dev", check=False)
        except Exception:
            pass


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
            runner.run(["systemctl", "restart", "goose-serve"], check=True)
            runner.run(["curl", "-sf", "http://127.0.0.1:4080/status"], check=True)

        if restarted_honkd:
            runner.run(["systemctl", "--user", "restart", "honkd"], user="dev", check=False)

        # 4. Control check: run D8(a) PONG against old binary
        control_passed = False
        try:
            res = runner.run([
                "honk",
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
                res = runner.run(["honk", "tail", "--text-only", "--exit-on-turn-end", sess_id], user="dev", check=True, timeout=300)
                if "PONG" in res.stdout:
                    control_passed = True
                runner.run(["honk", "archive", sess_id], user="dev", check=False)
        except Exception as e:
            log("rollback", f"Control check failed: {e}")

        if not control_passed:
            log("rollback", "Control check failed; failure appears environmental")
            notify(
                runner,
                "warning",
                f"goose-cutover: rolled back, failure looks environmental ({failing_step}: {detail}); pin left merged; rerun deploy",
            )
            state["phase"] = "prepared"
            state["step"] = "prepared"
            runner.write_file(STATE_PATH, json.dumps(state))
            return 1

        # 5. Control passed -> open revert PR
        log("rollback", "Control check passed; opening revert PR")
        wt_dir = f"/tmp/goose-revert-worktree-{pr}-{int(runner.now())}"
        runner.run(["git", "worktree", "add", "--detach", wt_dir, "origin/main"], user="dev", check=True)
        revert_url = ""
        try:
            runner.run(["git", "revert", "--no-edit", str(merge_sha)], user="dev", check=True)
            branch = f"goose-cutover-revert-{pr}"
            runner.run(["git", "push", "origin", f"HEAD:refs/heads/{branch}"], user="dev", check=True)
            body = f"Failing step: {failing_step}\nDetail: {detail}"
            res = runner.run([
                "gh",
                "pr",
                "create",
                "--label",
                "goose-revert",
                "--title",
                f"Revert PR #{pr}",
                "--body",
                body,
            ], user="dev", check=True)
            revert_url = res.stdout.strip()
        finally:
            runner.run(["git", "worktree", "remove", "--force", wt_dir], user="dev", check=False)

        state["phase"] = "rolled-back"
        state["step"] = "rolled-back"
        runner.write_file(STATE_PATH, json.dumps(state))
        notify(
            runner,
            "error",
            f"goose-cutover: deploy failed at {failing_step}; rolled back and opened revert PR: {revert_url}",
        )
        return 1

    except Exception as e:
        log("rollback", f"Rollback step failed: {e}")
        notify(runner, "error", f"ROLLBACK FAILED at {failing_step}; goose-serve state unknown")
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
            notify(runner, "warning", "goose-cutover: global lock busy; another cutover is running")
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
