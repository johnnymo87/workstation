#!/usr/bin/env python3
"""goose-upgrade-probe: downstream gate for a candidate goose binary.

    goose-upgrade-probe <goose-bin> [--old-bin <bin>] [--keep] [--only CHECK,...]

Read-only to production. Every goose it starts runs with GOOSE_PATH_ROOT under a
fresh work root, on an online-backup COPY of sessions.db, as its own transient
systemd user unit on a random port; honkd likewise, with its own --state-dir and
no swarm/turn-hook/MCP wiring. Prints one PASS/FAIL line per check and exits 0
only if every check passed. A check that could not run is a FAIL, never a skip.

Design and research: docs/plans/2026-11-22-goose-upgrade-probe.md (workstation),
bead workstation-6w7i.27.1.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import os
import pathlib
import re
import secrets
import shutil
import socket
import sqlite3
import subprocess
import sys
import tempfile
import time
import traceback

HOME = pathlib.Path.home()
PROD_SESSIONS_DB = HOME / ".local/share/goose/sessions/sessions.db"
PROD_CONFIG = HOME / ".config/goose/config.yaml"
PIGEON_DIR = pathlib.Path(os.environ.get("GOOSE_PROBE_PIGEON_DIR", HOME / "projects/pigeon"))
EAP_DIR = pathlib.Path(os.environ.get("GOOSE_PROBE_EAP_DIR", HOME / "projects/eng-agent-platform"))
HONK_REPO = pathlib.Path(os.environ.get("GOOSE_PROBE_HONK_REPO", HOME / "projects/honk"))
# Baked in by pkgs/goose-upgrade-probe/default.nix from the workstation flake.lock, so the
# honk suite that runs is the honk that is deployed. Env override for development only.
HONK_REV = os.environ.get("GOOSE_PROBE_HONK_REV", "@honkRev@")
HONKD_BIN = os.environ.get("GOOSE_PROBE_HONKD_BIN", str(HOME / ".nix-profile/bin/honkd"))
CACHE_DIR = HOME / ".cache/goose-upgrade-probe"
LANE_HOME = pathlib.Path(os.environ.get("LANE_HOME", HOME / ".local/state/lane-maven-renovate-home"))
PROBE_MODEL = "claude-haiku-4-5@20251001"

# Production listeners and ports other tools treat specially. A probe never listens here.
# 38910/38999: pigeon probes' default serve and their "dead port".
REFUSED_PORTS = frozenset(
    {4080, 4180, 4181, 4280, 4700, 4731, 4096, 4097, 4098, 4099, 8080, 8789, 38910, 38999}
)
CHECKS = [
    "versions", "migration", "forward-migration", "pigeon", "honk-suite", "honk-live",
    "stall-watch", "rendered-surface", "rollback", "production-untouched",
]
SURFACE_RECIPE, SURFACE_FIXTURE = "maven-renovate.yaml", "fixtures-rendered-surface.json"


class ProbeError(Exception):
    pass


# ---------------------------------------------------------------- pure helpers


def yaml_load(text: str):
    import yaml

    return yaml.safe_load(text)


def yaml_dump(obj) -> str:
    import yaml

    return yaml.safe_dump(obj, sort_keys=False)


def strip_config(text: str) -> str:
    """Config copy with every non-bundled extension and all plugins removed.

    stdio/http/sse extensions and plugins (whose .mcp.json can declare servers) are the
    paths by which a probe session could reach Slack, Atlassian, swarm, ... Bundled
    platform/builtin extensions run in-process and are what the lanes actually use.
    """
    cfg = yaml_load(text) or {}
    exts = cfg.get("extensions")
    if isinstance(exts, dict):
        cfg["extensions"] = {
            k: v for k, v in exts.items() if isinstance(v, dict) and v.get("type") in ("platform", "builtin")
        }
    cfg.pop("plugins", None)
    return yaml_dump(cfg)


_ANSI = re.compile(r"\x1b\[[0-9;]*m")
_SKIP = re.compile(r"(?<![\w])skipping ")


def count_skips(text: str) -> int:
    """honk tests skip by printing `skipping ...` and returning (a pass). Count those.

    Not anchored to line start: with --nocapture, libtest's `test x ... ` and a test's
    eprintln! share a line.
    """
    return len(_SKIP.findall(_ANSI.sub("", text)))


def neutralize_extension_data(raw: str | None) -> str | None:
    """A session's stored extensions minus every non-bundled one.

    session/load starts the extensions a session STORED (acp/server.rs prepare_acp_session),
    whatever the config says: on production rows that is `honk swarm-mcp` with pigeon's
    real token, ro-shell, slack. The copy must not be able to start them.
    """
    if not raw:
        return raw
    d = json.loads(raw)
    ee = d.get("enabled_extensions.v0")
    if isinstance(ee, dict) and isinstance(ee.get("extensions"), list):
        ee["extensions"] = [e for e in ee["extensions"] if isinstance(e, dict) and e.get("type") in ("platform", "builtin")]
    return json.dumps(d)


def is_settled(last_role: str, last_content_json: str) -> bool:
    """A conversation that ended on assistant text: nothing pending for load to resume."""
    if last_role != "assistant":
        return False
    try:
        parts = json.loads(last_content_json)
    except Exception:
        return False
    return bool(parts) and all(p.get("type") in ("text", "thinking", "redactedThinking") for p in parts)


def schema_shape(conn) -> dict:
    """Tables -> set of (column, type, notnull, default, pk), plus index names. Order-free,
    so a migrated DB (ALTER TABLE appends) and a freshly created one compare equal."""
    shape = {}
    for (name,) in conn.execute("select name from sqlite_master where type='table' and name not like 'sqlite_%'"):
        cols = frozenset(tuple(r[1:]) for r in conn.execute(f"pragma table_info('{name}')"))
        idx = frozenset(r[1] for r in conn.execute(f"pragma index_list('{name}')") if not r[1].startswith("sqlite_autoindex"))
        shape[name] = (cols, idx)
    return shape


def diff_shapes(a: dict, b: dict) -> list[str]:
    out = []
    for t in sorted(set(a) | set(b)):
        if t not in a or t not in b:
            out.append(f"table {t} only in {'fresh' if t in b else 'migrated'}")
            continue
        (ca, ia), (cb, ib) = a[t], b[t]
        for c in sorted(ca ^ cb, key=str):
            out.append(f"{t}: column {c} only in {'migrated' if c in ca else 'fresh'}")
        for i in sorted(ia ^ ib):
            out.append(f"{t}: index {i} only in {'migrated' if i in ia else 'fresh'}")
    return out


class Results:
    def __init__(self, names):
        self.names = list(names)
        self.state: dict[str, tuple[str, str]] = {}

    def _set(self, name, status, detail):
        if name not in self.names:
            raise KeyError(name)
        prev = self.state.get(name)
        if prev and prev[0] == "FAIL":
            return  # a failure is sticky
        self.state[name] = (status, detail)

    def passed(self, name, detail=""):
        self._set(name, "PASS", detail)

    def failed(self, name, detail):
        self._set(name, "FAIL", detail)

    def skipped(self, name, why):
        self._set(name, "FAIL", f"SKIPPED: {why}")

    def ok(self) -> bool:
        return all(self.state.get(n, ("FAIL",))[0] == "PASS" for n in self.names)

    def lines(self) -> list[str]:
        out = []
        for n in self.names:
            status, detail = self.state.get(n, ("FAIL", "did not run"))
            out.append(f"{status} {n}" + (f" -- {detail}" if detail else ""))
        return out


def guard_port(port: int) -> None:
    if port in REFUSED_PORTS or port < 1024:
        raise ProbeError(f"refusing to use port {port}: production or reserved")


def free_port() -> int:
    while True:
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            p = s.getsockname()[1]
        if p not in REFUSED_PORTS:
            return p


def assert_isolated_env(env: dict, work_root: pathlib.Path) -> None:
    root = env.get("GOOSE_PATH_ROOT")
    if not root:
        raise ProbeError("GOOSE_PATH_ROOT unset: goose would open the production sessions.db")
    p = pathlib.Path(root)
    if not p.is_absolute() or not work_root.is_absolute():
        raise ProbeError(f"GOOSE_PATH_ROOT must be absolute: {root}")
    if work_root.resolve() not in [p.resolve(), *p.resolve().parents]:
        raise ProbeError(f"GOOSE_PATH_ROOT {root} is not under the work root {work_root}")


def guard_not_production(db: pathlib.Path) -> None:
    if db.resolve() == PROD_SESSIONS_DB.resolve() or db.resolve().parent == PROD_SESSIONS_DB.resolve().parent:
        raise ProbeError(f"refusing to write {db}: that is production's sessions directory")


def write_env_file(path: pathlib.Path, env: dict) -> None:
    lines = []
    for k, v in env.items():
        v = str(v)
        if "\n" in v:
            raise ProbeError(f"env value for {k} contains a newline")
        lines.append(f'{k}="' + v.replace("\\", "\\\\").replace('"', '\\"') + '"')
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write("\n".join(lines) + "\n")
    os.chmod(path, 0o600)


def probe_recipe(text: str, marker: str) -> str:
    """The coordinator recipe with its instructions replaced: same plumbing, no coordinator."""
    r = yaml_load(text)
    r["instructions"] = (
        "This is an automated transport probe, not a real coordinator run. Do not run any "
        f"command and do not call any tool. Reply with exactly: {marker}\n"
    )
    r.pop("prompt", None)
    return yaml_dump(r)


# ---------------------------------------------------------------- processes


def run(cmd, *, env=None, cwd=None, timeout=600, log: pathlib.Path | None = None) -> tuple[int, str]:
    try:
        p = subprocess.run(
            cmd, env=env, cwd=cwd, timeout=timeout, stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace",
        )
        out, rc = p.stdout, p.returncode
    except subprocess.TimeoutExpired as e:
        out = (e.stdout or b"").decode(errors="replace") if isinstance(e.stdout, bytes) else (e.stdout or "")
        out += f"\n[probe] TIMEOUT after {timeout}s"
        rc = 124
    if log:
        with open(log, "a") as f:
            f.write(f"$ {' '.join(map(str, cmd))}\n{out}\n[exit {rc}]\n")
    return rc, out


def tail(text: str, n=15) -> str:
    return " | ".join(l for l in text.strip().splitlines()[-n:] if l.strip())[-1500:]


class Unit:
    """A transient systemd --user service: own cgroup, killed as a whole on stop."""

    def __init__(self, name: str, argv: list[str], env_file: pathlib.Path, cwd: pathlib.Path, log: pathlib.Path):
        self.name, self.argv, self.env_file, self.cwd, self.log = name, argv, env_file, cwd, log

    def start(self):
        env = dict(os.environ, XDG_RUNTIME_DIR=f"/run/user/{os.getuid()}")
        cmd = [
            "systemd-run", "--user", f"--unit={self.name}", "--collect", "--quiet",
            "--expand-environment=no", "-p", "MemoryMax=6G", "-p", "MemorySwapMax=0",
            "-p", f"EnvironmentFile={self.env_file}", "-p", f"WorkingDirectory={self.cwd}",
            "-p", f"StandardOutput=append:{self.log}", "-p", "StandardError=inherit",
            f"--setenv=PATH={os.environ.get('PATH', '')}", "--", *self.argv,
        ]
        rc, out = run(cmd, env=env, timeout=60)
        if rc != 0:
            raise ProbeError(f"systemd-run {self.name} failed: {tail(out)}")

    def active(self) -> bool:
        env = dict(os.environ, XDG_RUNTIME_DIR=f"/run/user/{os.getuid()}")
        rc, _ = run(["systemctl", "--user", "is-active", "--quiet", self.name], env=env, timeout=30)
        return rc == 0

    def stop(self):
        env = dict(os.environ, XDG_RUNTIME_DIR=f"/run/user/{os.getuid()}")
        run(["systemctl", "--user", "stop", self.name], env=env, timeout=60)
        run(["systemctl", "--user", "reset-failed", self.name], env=env, timeout=30)


def wait_port(port: int, unit: Unit, timeout=90):
    end = time.time() + timeout
    while time.time() < end:
        with socket.socket() as s:
            s.settimeout(1)
            if s.connect_ex(("127.0.0.1", port)) == 0:
                return
        if not unit.active():
            raise ProbeError(f"{unit.name} exited before listening: {tail(unit.log.read_text(errors='replace'))}")
        time.sleep(0.5)
    raise ProbeError(f"{unit.name} not listening on {port} after {timeout}s")


# ---------------------------------------------------------------- ACP client


class Acp:
    """Minimal ACP JSON-RPC client over goose serve's WebSocket (/acp?token=)."""

    def __init__(self, port: int, token: str):
        self.url = f"ws://127.0.0.1:{port}/acp?token={token}"
        self.next_id = 0
        self.updates: list[dict] = []

    async def __aenter__(self):
        import websockets

        self.ws = await websockets.connect(self.url, max_size=None, open_timeout=30)
        return self

    async def __aexit__(self, *a):
        await self.ws.close()

    async def req(self, method: str, params: dict, timeout=300):
        self.next_id += 1
        rid = self.next_id
        await self.ws.send(json.dumps({"jsonrpc": "2.0", "id": rid, "method": method, "params": params}))
        end = time.time() + timeout
        while True:
            left = end - time.time()
            if left <= 0:
                raise ProbeError(f"{method}: no response in {timeout}s")
            msg = json.loads(await asyncio.wait_for(self.ws.recv(), left))
            if "method" in msg and "id" in msg:  # server -> client request
                if msg["method"] == "session/request_permission":
                    opts = msg["params"].get("options") or []
                    allow = next((o for o in opts if "allow" in o.get("kind", "")), opts[0] if opts else None)
                    res = {"outcome": {"outcome": "selected", "optionId": allow["optionId"]}} if allow else {"outcome": {"outcome": "cancelled"}}
                    await self.ws.send(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": res}))
                else:
                    await self.ws.send(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "error": {"code": -32601, "message": "probe: unsupported"}}))
                continue
            if "method" in msg:
                self.updates.append(msg.get("params") or {})
                continue
            if msg.get("id") == rid:
                if "error" in msg:
                    raise ProbeError(f"{method}: {json.dumps(msg['error'])[:500]}")
                return msg.get("result")

    async def initialize(self):
        return await self.req("initialize", {"protocolVersion": 1, "clientCapabilities": {}}, timeout=60)

    def updates_for(self, sid: str) -> list[dict]:
        return [u for u in self.updates if u.get("sessionId") == sid]

    async def prompt(self, sid: str, text: str, timeout=300) -> tuple[dict, str, list[str]]:
        start = len(self.updates)
        res = await self.req("session/prompt", {"sessionId": sid, "prompt": [{"type": "text", "text": text}]}, timeout)
        kinds, chunks = [], []
        for u in self.updates[start:]:
            if u.get("sessionId") != sid:
                continue
            up = u.get("update") or {}
            kinds.append(up.get("sessionUpdate", ""))
            if up.get("sessionUpdate") == "agent_message_chunk":
                c = up.get("content") or {}
                chunks.append(c.get("text", ""))
        return res or {}, "".join(chunks), kinds


def acp(coro_fn):
    return asyncio.run(coro_fn())


# ---------------------------------------------------------------- the probe


class Root:
    """One isolated GOOSE_PATH_ROOT: config copy, optional DB, its own cwd."""

    def __init__(self, base: pathlib.Path, name: str):
        self.name = name
        self.path = base / name
        self.db = self.path / "data/sessions/sessions.db"
        (self.path / "config").mkdir(parents=True)
        self.db.parent.mkdir(parents=True)
        guard_not_production(self.db)
        (self.path / "config/config.yaml").write_text(strip_config(PROD_CONFIG.read_text()))

    def ro(self):
        return sqlite3.connect(f"file:{self.db}?mode=ro", uri=True, timeout=30)

    def exists(self) -> bool:
        return self.db.exists()

    def schema_version(self) -> int:
        with self.ro() as c:
            return c.execute("select max(version) from schema_version").fetchone()[0]

    def shape(self) -> dict:
        with self.ro() as c:
            return schema_shape(c)

    def quick_check(self) -> str:
        with self.ro() as c:
            return c.execute("pragma quick_check").fetchone()[0]

    def message_count(self, sid: str) -> int:
        with self.ro() as c:
            return c.execute("select count(*) from messages where session_id=?", (sid,)).fetchone()[0]

    def contents(self, sid: str) -> tuple[str, list[str]]:
        with self.ro() as c:
            rows = c.execute("select content_json, coalesce(metadata_json,'') from messages where session_id=?", (sid,)).fetchall()
        return "\n".join(r[0] for r in rows), [r[1] for r in rows]

    def session_ids(self) -> set[str]:
        with self.ro() as c:
            return {r[0] for r in c.execute("select id from sessions")}


def prod_schema_version() -> int:
    c = sqlite3.connect(f"file:{PROD_SESSIONS_DB}?mode=ro", uri=True, timeout=30)
    try:
        return c.execute("select max(version) from schema_version").fetchone()[0]
    finally:
        c.close()


def bin_version(binary: str) -> str:
    rc, out = run([binary, "--version"], env=dict(os.environ, GOOSE_PATH_ROOT="/nonexistent-probe-root"), timeout=30)
    if rc != 0:
        raise ProbeError(f"{binary} --version exit {rc}: {tail(out)}")
    return out.strip().split()[-1]


def unit_pids(unit: str) -> list[int]:
    env = dict(os.environ, XDG_RUNTIME_DIR=f"/run/user/{os.getuid()}")
    _, cg = run(["systemctl", "--user", "show", "-p", "ControlGroup", "--value", unit], env=env, timeout=30)
    f = pathlib.Path("/sys/fs/cgroup") / cg.strip().lstrip("/") / "cgroup.procs"
    try:
        return [int(x) for x in f.read_text().split()]
    except OSError:
        return []


class Probe:
    def __init__(self, cand: str, old: str, keep: bool, only: list[str] | None):
        self.cand, self.old, self.keep = cand, old, keep
        self.only = only or CHECKS
        self.results = Results(self.only)
        self.root = pathlib.Path(tempfile.mkdtemp(prefix="goose-probe.", dir="/var/tmp"))
        self.id = re.sub(r"[^a-z0-9]", "", self.root.name.split(".", 1)[1].lower())
        self.logs = self.root / "logs"
        self.logs.mkdir()
        self.cwd = self.root / "cwd"
        self.cwd.mkdir()
        self.secret = secrets.token_hex(24)
        (self.root / "secret").write_text(self.secret)
        os.chmod(self.root / "secret", 0o600)
        self.units: list[Unit] = []
        self.serve: Unit | None = None
        self.serve_bin = ""
        self.port = free_port()  # ONE serve port per run: honkd follows the candidate -> old switch
        guard_port(self.port)
        self.honkd: Unit | None = None
        self.hport = 0
        self.honk_token: pathlib.Path | None = None
        self.versions: dict[str, str] = {}
        self.goose_shell = ""

    def say(self, msg):
        print(f"[probe] {msg}", file=sys.stderr, flush=True)

    def want(self, *names) -> bool:
        return any(n in self.only for n in names)

    # ------------------------------------------------ setup

    def prepare(self):
        need = PROD_SESSIONS_DB.stat().st_size * 3
        free = shutil.disk_usage(self.root).free
        if free < need:
            raise ProbeError(f"need {need >> 20} MiB free in /var/tmp, have {free >> 20}")
        self.prod_version_before = prod_schema_version()
        self.goose_shell = production_goose_shell()
        self.copy = Root(self.root, "copy")       # production backup: migration, rollback
        self.synth = Root(self.root, "synth")     # written by OLD from empty: forward migration
        self.fresh = Root(self.root, "fresh")     # created by CANDIDATE from empty: reference schema
        self.say(f"backing up sessions.db to {self.copy.db}")
        src = sqlite3.connect(f"file:{PROD_SESSIONS_DB}?mode=ro", uri=True, timeout=30)
        dst = sqlite3.connect(self.copy.db)
        with dst:
            src.backup(dst)
        src.close()
        # The copy must not be able to start any session's stored MCP servers.
        with dst:
            rows = dst.execute("select id, extension_data from sessions").fetchall()
            dst.executemany("update sessions set extension_data=? where id=?",
                            [(neutralize_extension_data(e), i) for i, e in rows])
        dst.close()

    def serve_env(self, root: Root) -> dict:
        project = pathlib.Path("/run/secrets/google_cloud_project").read_text().strip()
        env = {
            "HOME": str(HOME),
            "GOOSE_PATH_ROOT": str(root.path),
            "GOOSE_SERVER__SECRET_KEY": self.secret,
            "GOOSE_MODE": "auto",
            "GOOSE_DISABLE_KEYRING": "true",
            "GOOSE_TELEMETRY_ENABLED": "false",
            "GOOSE_PROVIDER": "gcp_vertex_ai",
            "GOOSE_MODEL": PROBE_MODEL,
            "GCP_PROJECT_ID": project,
            "GCP_LOCATION": "global",
            "GOOGLE_APPLICATION_CREDENTIALS": str(HOME / ".config/gcloud/application_default_credentials.json"),
            "GCP_VERTEX_HOST": "http://127.0.0.1:8789",
            "GCP_VERTEX_SESSION_HEADER": "x-opencode-session,x-session-id",
            "GCP_VERTEX_PARENT_SESSION_HEADER": "x-parent-session-id",
            "GCP_VERTEX_GEMINI_HOST": "https://aiplatform.googleapis.com",
            "GCP_AUTH_SCOPES": "https://www.googleapis.com/auth/cloud-platform https://www.googleapis.com/auth/userinfo.email",
            "GOOSE_THINKING_EFFORT": "high",
            "GIT_EDITOR": ":",
            "GIT_SEQUENCE_EDITOR": ":",
            "GIT_PAGER": "cat",
            "EDITOR": ":",
        }
        if self.goose_shell:
            env["GOOSE_SHELL"] = self.goose_shell
        assert_isolated_env(env, self.root)
        return env

    def start_serve(self, binary: str, root: Root, label: str):
        self.stop_serve()
        envf = self.root / f"{label}.env"
        write_env_file(envf, self.serve_env(root))
        u = Unit(f"goose-probe-{self.id}-{label}", [binary, "serve", "--host", "127.0.0.1", "--port", str(self.port)],
                 envf, self.cwd, self.logs / f"{label}-serve.log")
        self.units.append(u)
        u.start()
        self.serve, self.serve_bin = u, binary
        wait_port(self.port, u)
        self.say(f"{label}: {binary} on :{self.port} root={root.name} ({u.name})")

        async def init():
            async with Acp(self.port, self.secret) as a:
                return await a.initialize()

        info = acp(init) or {}
        got = ((info.get("agentInfo") or {}).get("version")) or ""
        want = self.versions.get(binary) or bin_version(binary)
        self.versions[binary] = want
        if got != want:
            raise ProbeError(f"{label}: serve reports version {got!r}, {binary} --version says {want!r}")

    def stop_serve(self):
        if self.serve:
            self.serve.stop()
            self.serve = None

    def foreign_children(self) -> list[str]:
        """Processes in the serve's cgroup that are not the serve itself (MCP servers, shells)."""
        if not self.serve:
            return []
        out = []
        me = os.path.realpath(self.serve_bin)
        for pid in unit_pids(self.serve.name):
            try:
                exe = os.path.realpath(f"/proc/{pid}/exe")
                cmd = pathlib.Path(f"/proc/{pid}/cmdline").read_bytes().replace(b"\0", b" ").decode(errors="replace")
            except OSError:
                continue
            if exe != me:
                out.append(f"{pid}:{cmd[:120]}")
        return out

    def teardown(self):
        for u in reversed(self.units):
            u.stop()
        if self.keep:
            self.say(f"--keep: work root left at {self.root}")
            return
        for p in self.root.rglob("sessions.db*"):
            p.unlink(missing_ok=True)
        self.say(f"DB copies deleted; logs kept at {self.logs}")

    # ------------------------------------------------ ACP helpers

    async def _load(self, a: Acp, sid: str, cwd: str | None = None) -> int:
        before = len(a.updates_for(sid))
        cwd = cwd if cwd and os.path.isdir(cwd) else str(self.cwd)
        await a.req("session/load", {"sessionId": sid, "cwd": cwd, "mcpServers": []}, timeout=180)
        return len(a.updates_for(sid)) - before

    def load_all(self, sids: list[tuple[str, str | None]]) -> dict:
        async def go():
            out = {}
            async with Acp(self.port, self.secret) as a:
                await a.initialize()
                for sid, wd in sids:
                    try:
                        out[sid] = await self._load(a, sid, wd)
                    except ProbeError as e:
                        out[sid] = f"error: {e}"
            return out

        return acp(go)

    def make_rich_session(self, root: Root) -> str:
        """A session with a tool call, stored thinking and a compaction, on the running serve."""

        async def go():
            async with Acp(self.port, self.secret) as a:
                await a.initialize()
                s = await a.req("session/new", {"cwd": str(self.cwd), "mcpServers": []}, timeout=120)
                sid = s["sessionId"]
                _, _, kinds = await a.prompt(
                    sid, "Use your shell tool to run exactly `echo PROBE_TOOL_OK`, then reply with the single word DONE.")
                if "tool_call" not in kinds:
                    raise ProbeError(f"no tool call (updates: {sorted(set(kinds))})")
                await a.prompt(sid, "Think step by step about whether 91 is prime, then reply YES or NO.")
                await a.prompt(sid, "/compact")
                _, text, _ = await a.prompt(sid, "Reply with the single word AFTER.")
                return sid

        sid = acp(go)
        blob, meta = root.contents(sid)
        missing = [k for k in ("toolRequest", "toolResponse", "thinking") if f'"type":"{k}"' not in blob.replace(" ", "")]
        if not any('"userVisible":false' in m.replace(" ", "") for m in meta):
            missing.append("compaction (no userVisible:false message)")
        if missing:
            raise ProbeError(f"rich session {sid} lacks {missing}")
        return sid

    def prompt_new(self, text: str) -> tuple[str, str]:
        async def go():
            async with Acp(self.port, self.secret) as a:
                await a.initialize()
                s = await a.req("session/new", {"cwd": str(self.cwd), "mcpServers": []}, timeout=120)
                _, out, _ = await a.prompt(s["sessionId"], text)
                return s["sessionId"], out

        return acp(go)

    # ------------------------------------------------ checks

    def phase_old_synth(self):
        """OLD binary writes a rich session into an empty root (forward-migration input)."""
        self.start_serve(self.old, self.synth, "old-synth")
        self.synth_sid = self.make_rich_session(self.synth)
        self.synth_version = self.synth.schema_version()
        self.stop_serve()

    def phase_fresh(self):
        self.start_serve(self.cand, self.fresh, "cand-fresh")
        self.prompt_new("Reply with the single word FRESH.")  # make sure the DB is materialised
        self.stop_serve()
        if not self.fresh.exists():
            raise ProbeError("candidate created no sessions.db on an empty root")
        self.fresh_shape = self.fresh.shape()

    def check_migration(self):
        before = self.copy.schema_version()
        with self.copy.ro() as c:
            cands = c.execute(
                """select s.id, s.working_dir from sessions s
                   join (select session_id, max(id) m from messages where content_json like '%"toolRequest"%'
                         group by session_id) t on t.session_id = s.id
                   order by t.m desc limit 40""").fetchall()
            settled = []
            for sid, wd in cands:
                last = c.execute("select role, content_json from messages where session_id=? order by id desc limit 1",
                                 (sid,)).fetchone()
                if last and is_settled(*last):
                    settled.append((sid, wd))
                if len(settled) == 3:
                    break
        if len(settled) < 3:
            return self.results.failed("migration", f"only {len(settled)} settled production sessions with tool calls")
        self.copy_ids_before = self.copy.session_ids()
        self.start_serve(self.cand, self.copy, "cand")
        loaded = self.load_all(settled)
        foreign = self.foreign_children()
        problems = []
        after = self.copy.schema_version()
        if after < before:
            problems.append(f"schema went backwards {before}->{after}")
        # Missing = the candidate's own schema is not all there: FAIL. Extra = left by a NEWER
        # writer (production ran a 1.60 goose on 2026-11-22): additive, reported only.
        d = diff_shapes(self.copy.shape(), self.fresh_shape)
        missing = [x for x in d if x.endswith("only in fresh")]
        extra = [x for x in d if not x.endswith("only in fresh")]
        if missing:
            problems.append(f"migrated schema lacks what the candidate creates fresh: {missing[:6]}")
        qc = self.copy.quick_check()
        if qc != "ok":
            problems.append(f"quick_check: {qc}")
        bad = {k: v for k, v in loaded.items() if not (isinstance(v, int) and v >= 1)}
        if bad:
            problems.append(f"session/load failed or replayed nothing: {bad}")
        if foreign:
            problems.append(f"loading started processes in the serve cgroup: {foreign}")
        if problems:
            return self.results.failed("migration", "; ".join(problems))
        self.results.passed("migration", f"schema v{before}->v{after} has the candidate's fresh schema"
                            + (f" (+{len(extra)} extra from a newer writer)" if extra else "")
                            + f"; loaded {len(loaded)} production sessions")

    def check_forward_migration(self):
        """Candidate opens the DB the OLD binary created: a real migration from old's schema."""
        self.start_serve(self.cand, self.synth, "cand-synth")
        loaded = self.load_all([(self.synth_sid, None)])
        self.stop_serve()
        problems = []
        d = diff_shapes(self.synth.shape(), self.fresh_shape)
        if d:  # old binary's own DB, migrated: must equal the candidate's fresh schema exactly
            problems.append(f"migrated schema != fresh schema: {d[:6]}")
        if not (isinstance(loaded.get(self.synth_sid), int) and loaded[self.synth_sid] >= 1):
            problems.append(f"candidate could not load the old binary's rich session: {loaded}")
        if self.synth.quick_check() != "ok":
            problems.append("quick_check failed")
        if problems:
            return self.results.failed("forward-migration", "; ".join(problems))
        self.results.passed("forward-migration",
                            f"v{self.synth_version}->v{self.synth.schema_version()}, old binary's rich session loads")

    def ensure_cand_on_copy(self):
        if not (self.serve and self.serve_bin == self.cand and self.serve.name.endswith("-cand")):
            self.start_serve(self.cand, self.copy, "cand")

    def check_pigeon(self):
        scripts = ["goose-launch-probe.ts", "goose-runner-probe.ts", "goose-id-split-probe.ts"]
        d = PIGEON_DIR / "packages/daemon"
        tsx = PIGEON_DIR / "node_modules/.bin/tsx"
        if not tsx.exists():
            return self.results.failed("pigeon", f"{tsx} missing (run npm ci in {PIGEON_DIR})")
        env = dict(os.environ, GOOSE_ACP_URL=f"ws://127.0.0.1:{self.port}/acp",
                   PIGEON_GOOSE_PROBE_TOKEN=self.secret, GOOSE_ACP_CWD=str(self.cwd))
        env.pop("PIGEON_DAEMON_URL", None)
        fails = []
        for s in scripts:
            if not (d / "scripts" / s).exists():
                fails.append(f"{s}: missing")
                continue
            rc, out = run([str(tsx), f"scripts/{s}"], env=env, cwd=d, timeout=600, log=self.logs / "pigeon.log")
            nfail = len(re.findall(r"^\s*FAIL\b", out, re.M))
            npass = len(re.findall(r"^\s*PASS\b", out, re.M))
            if rc != 0 or nfail or npass == 0:
                fails.append(f"{s}: exit {rc}, {npass} PASS {nfail} FAIL: {tail(out, 6)}")
        if fails:
            return self.results.failed("pigeon", "; ".join(fails))
        self.results.passed("pigeon", f"{len(scripts)} probes")

    def _cargo(self, wt, args, env_extra, timeout, log):
        env = dict(os.environ, CARGO_TARGET_DIR=str(CACHE_DIR / "honk-target"), **env_extra)
        return run(["nix", "develop", str(wt), "-c", "cargo", *args], env=env, cwd=wt, timeout=timeout, log=log)

    def check_honk(self):
        names = [n for n in ("honk-suite", "honk-live") if n in self.only]
        if HONK_REV.startswith("@"):
            for n in names:
                self.results.failed(n, "honk rev not baked in (GOOSE_PROBE_HONK_REV unset)")
            return
        wt = self.root / "honk"
        run(["git", "-C", str(HONK_REPO), "fetch", "-q", "origin"], timeout=120)
        rc, out = run(["git", "-C", str(HONK_REPO), "worktree", "add", "--detach", str(wt), HONK_REV], timeout=120)
        if rc != 0:
            for n in names:
                self.results.failed(n, f"honk worktree at {HONK_REV}: {tail(out)}")
            return
        try:
            CACHE_DIR.mkdir(parents=True, exist_ok=True)
            log = self.logs / "honk.log"
            rc, out = self._cargo(wt, ["build", "-p", "honkd"], {}, 3600, log)
            if rc != 0:
                raise ProbeError(f"cargo build -p honkd: {tail(out)}")
            honkd = CACHE_DIR / "honk-target/debug/honkd"
            if "honk-suite" in self.only:
                rc, out = self._cargo(wt, ["test", "--workspace", "--", "--nocapture"],
                                      {"HONK_GOOSE_BIN": self.cand, "HONKD_BIN": str(honkd)}, 3600, log)
                skips = count_skips(out)
                ran = sum(int(n) for n in re.findall(r"test result: \w+\. (\d+) passed", out))
                if rc != 0:
                    self.results.failed("honk-suite", f"cargo test exit {rc}: {tail(out)}")
                elif skips:
                    self.results.failed("honk-suite", f"{skips} tests skipped (see {log})")
                elif ran == 0:
                    self.results.failed("honk-suite", "no tests ran")
                else:
                    self.results.passed("honk-suite", f"{ran} passed, 0 skipped")
            if "honk-live" in self.only:
                self.ensure_cand_on_copy()
                fails, ran = [], 0
                for t in ("p2_patched", "p4_patched"):
                    rc, out = self._cargo(
                        wt, ["test", "-p", "honk-upstream", "--test", t, "--", "--ignored", "--test-threads=1", "--nocapture"],
                        {"HONK_GOOSE_URL": f"http://127.0.0.1:{self.port}/acp", "HONK_GOOSE_SECRET": self.secret,
                         "HONK_SANDBOX_UNIT": self.serve.name, "HONK_FIXTURES_ROOT": str(self.root / "honk-fixtures")},
                        1800, log)
                    n = sum(int(x) for x in re.findall(r"test result: \w+\. (\d+) passed", out))
                    ran += n
                    if rc != 0 or count_skips(out) or n == 0:
                        fails.append(f"{t}: exit {rc}, {n} passed, {count_skips(out)} skipped: {tail(out, 6)}")
                if fails:
                    self.results.failed("honk-live", "; ".join(fails))
                else:
                    self.results.passed("honk-live", f"p2_patched+p4_patched {ran} passed")
        except ProbeError as e:
            for n in names:
                self.results.failed(n, str(e))
        finally:
            run(["git", "-C", str(HONK_REPO), "worktree", "remove", "--force", str(wt)], timeout=120)

    def start_honkd(self):
        """The deployed honkd, isolated: own port and state dir, no swarm/hook/MCP wiring, and
        WITHOUT --allow-unpatched-upstream, so a candidate that lost takeover/replay is refused."""
        self.hport = free_port()
        guard_port(self.hport)
        state = self.root / "honk-state"
        state.mkdir()
        envf = self.root / "honkd.env"
        write_env_file(envf, {"HOME": str(HOME), "RUST_LOG": "info"})
        u = Unit(f"goose-probe-{self.id}-honkd",
                 [HONKD_BIN, "--listen", f"127.0.0.1:{self.hport}", "--upstream", f"http://127.0.0.1:{self.port}/acp",
                  "--upstream-secret-file", str(self.root / "secret"), "--state-dir", str(state)],
                 envf, self.cwd, self.logs / "honkd.log")
        self.units.append(u)
        u.start()
        self.honkd = u
        wait_port(self.hport, u, timeout=60)
        tok = state / "secret"
        for _ in range(20):
            if tok.exists():
                break
            time.sleep(0.5)
        if not tok.exists():
            raise ProbeError(f"isolated honkd wrote no {tok}")
        self.honk_token = tok

    def sw_turn(self, db: Root, label: str) -> dict:
        """One stall-watch coordinator turn (run_honk, the production code path) on a scratch session."""
        recipe = self.root / "sw-probe-recipe.yaml"
        if not recipe.exists():
            recipe.write_text(probe_recipe((EAP_DIR / "stallwatch/coordinator_tools.yaml").read_text(), "SWPROBEOK"))
        swhome = self.root / f"swhome-{label}"
        (swhome / ".local/state").mkdir(parents=True)
        ghome = self.root / f"sw-coord-home-{label}"
        ghome.mkdir()
        driver = self.root / "sw_driver.py"
        driver.write_text(SW_DRIVER)
        env = dict(os.environ, HOME=str(swhome), STALLWATCH_MESSAGES="0", STALLWATCH_DELEGATE="0",
                   STALLWATCH_LOCK_PATH=str(self.root / "sw.lock"), PYTHONPATH=str(EAP_DIR),
                   SW_URL=f"ws://127.0.0.1:{self.hport}/acp", SW_TOKEN=str(self.honk_token), SW_DB=str(db.db),
                   SW_RECIPE=str(recipe), SW_HOME=str(ghome))
        env.pop("PIGEON_DAEMON_URL", None)
        rc, out = run(["uv", "run", "--no-project", "--with", "websockets>=14,<18", "--with", "pyyaml",
                       "python3", str(driver)], env=env, cwd=EAP_DIR, timeout=600, log=self.logs / f"stall-watch-{label}.log")
        m = re.search(r"^SWRESULT (.*)$", out, re.M)
        if rc != 0 or not m:
            raise ProbeError(f"driver exit {rc}: {tail(out)}")
        res = json.loads(m.group(1))
        if "SWPROBEOK" not in res.get("text", ""):
            raise ProbeError(f"coordinator turn did not answer SWPROBEOK: {str(res)[:400]}")
        return res

    def check_stall_watch(self):
        self.ensure_cand_on_copy()
        self.start_honkd()
        res = self.sw_turn(self.copy, "cand")
        self.results.passed("stall-watch", "isolated honkd accepted the candidate; run_honk turn answered SWPROBEOK")

    def check_surface(self):
        bindir = self.root / "surface-bin"
        bindir.mkdir()
        (bindir / "goose").symlink_to(os.path.realpath(self.cand))
        env = dict(os.environ, PATH=f"{bindir}:{os.environ.get('PATH', '')}",
                   GOOSE_GLOBAL_SKILLS="false", CONTEXT_FILE_NAMES="[]")  # lanes/lane-home.sh exports
        env.pop("GOOSE_PATH_ROOT", None)
        lanes = EAP_DIR / "lanes"
        if not LANE_HOME.is_dir():
            return self.results.failed("rendered-surface", f"lane home {LANE_HOME} missing")
        want = bin_version(self.cand)
        fixture = json.loads((lanes / SURFACE_FIXTURE).read_text())
        surf = self.root / "surface.json"
        rc, out = run(["python3", str(lanes / "capture-rendered-surface.py"), "--recipe", str(lanes / SURFACE_RECIPE),
                       "--cwd", str(LANE_HOME), "--params", "repo=food-truck/mono", "--params", "tracker_issue=probe-000"],
                      env=env, cwd=LANE_HOME, timeout=180, log=self.logs / "surface.log")
        if rc != 0:
            return self.results.failed("rendered-surface", f"capture exit {rc}: {tail(out, 4)}")
        try:
            data = json.loads(out[out.find("{"):out.rfind("}") + 1])
        except Exception:
            return self.results.failed("rendered-surface", "capture output not JSON")
        if not data.get("system_prompt"):
            return self.results.failed("rendered-surface", "capture produced no system prompt")
        if data.get("goose_version") != want:
            return self.results.failed("rendered-surface", f"capture ran goose {data.get('goose_version')!r}, not the candidate {want!r}")
        surf.write_text(json.dumps(data))
        # --param makes --bless impossible (the checker refuses the combination).
        rc, out = run(["python3", str(lanes / "check-rendered-surface.py"), "--surface", str(surf),
                       "--param", "repo=food-truck/mono", "--fixture", str(lanes / SURFACE_FIXTURE)],
                      env=env, cwd=EAP_DIR, timeout=120, log=self.logs / "surface.log")
        if rc != 0:
            return self.results.failed("rendered-surface", f"MISMATCH: {tail(out, 8)} (full report {self.logs}/surface.log)")
        if fixture.get("goose_version") != want:
            # The checker only NOTES a version change; for a gate, an unreviewed version is a FAIL.
            return self.results.failed("rendered-surface",
                                       f"content matches but the fixture is approved for goose {fixture.get('goose_version')!r}, "
                                       f"not {want!r}: re-approve it in eng-agent-platform (C3/L8) first")
        self.results.passed("rendered-surface", f"maven-renovate surface matches the fixture approved for {want}")

    def check_rollback(self):
        self.ensure_cand_on_copy()
        try:
            rich = self.make_rich_session(self.copy)
        except ProbeError as e:
            return self.results.failed("rollback", f"could not build a rich session on the candidate: {e}")
        created = sorted(self.copy.session_ids() - self.copy_ids_before) if hasattr(self, "copy_ids_before") else [rich]
        self.start_serve(self.old, self.copy, "old")
        problems = []
        sid, text = self.prompt_new("Reply with the single word ROLLBACKOK.")
        if self.copy.message_count(sid) < 2:
            problems.append(f"old binary wrote {self.copy.message_count(sid)} messages for its new session")
        if "ROLLBACKOK" not in text:
            problems.append(f"old binary's turn answered {text[:100]!r}")
        loaded = self.load_all([(c, None) for c in created])
        # A session with messages must replay something; an empty one (a probe that only
        # minted a session) must merely load.
        bad = {k: v for k, v in loaded.items()
               if not (isinstance(v, int) and (v >= 1 or self.copy.message_count(k) == 0))}
        if rich not in loaded:
            problems.append("rich session was not loaded")
        if bad:
            problems.append(f"session/load failed or replayed nothing on old: {bad}")
        if self.honkd:
            try:
                self.sw_turn(self.copy, "old")
            except ProbeError as e:
                problems.append(f"honkd across the candidate->old switch: {e}")
        qc = self.copy.quick_check()
        if qc != "ok":
            problems.append(f"quick_check: {qc}")
        if problems:
            return self.results.failed("rollback", "; ".join(problems))
        self.results.passed("rollback", f"old binary wrote a turn and loaded {len(loaded)} candidate-written sessions"
                            + ("; honkd turn ok after the switch" if self.honkd else ""))

    # ------------------------------------------------ driver

    def guarded(self, names, fn, *, required=False):
        names = [names] if isinstance(names, str) else names
        if not required and not self.want(*names):
            return True
        self.say(f"check {'/'.join(names)}")
        try:
            fn()
            return True
        except Exception as e:  # any crash in a check is that check's FAIL
            traceback.print_exc(file=sys.stderr)
            for n in names:
                if n in self.only:
                    self.results.failed(n, f"{type(e).__name__}: {e}")
            return False

    def main(self) -> int:
        try:
            self.prepare()
            if self.want("versions"):
                self.results.passed("versions", f"candidate {bin_version(self.cand)} ({self.cand}), old {bin_version(self.old)} ({self.old})")
            synth_ok = self.guarded(["forward-migration"], self.phase_old_synth)
            fresh_ok = self.guarded(["migration", "forward-migration"], self.phase_fresh)
            if fresh_ok:
                self.guarded("migration", self.check_migration)
                if synth_ok:
                    self.guarded("forward-migration", self.check_forward_migration)
            self.guarded("pigeon", lambda: (self.ensure_cand_on_copy(), self.check_pigeon()))
            self.guarded(["honk-suite", "honk-live"], self.check_honk)
            self.guarded("stall-watch", self.check_stall_watch)
            self.guarded("rendered-surface", self.check_surface)
            self.guarded("rollback", self.check_rollback)
        except Exception as e:
            traceback.print_exc(file=sys.stderr)
            self.say(f"aborted: {e}")
        finally:
            self.teardown()
        if self.want("production-untouched"):
            try:
                after = prod_schema_version()
                if after != getattr(self, "prod_version_before", None):
                    self.results.failed("production-untouched",
                                        f"production schema_version changed during the run: {getattr(self, 'prod_version_before', None)} -> {after}")
                else:
                    self.results.passed("production-untouched", f"production schema v{after} unchanged")
            except Exception as e:
                self.results.failed("production-untouched", str(e))
        print(f"goose-upgrade-probe candidate={self.cand} old={self.old} root={self.root}")
        for line in self.results.lines():
            print(line)
        ok = self.results.ok()
        print("RESULT PASS" if ok else "RESULT FAIL")
        return 0 if ok else 1


SW_DRIVER = r'''
import json, os, pathlib, sys
from stallwatch import config, coordinator, honk_transport
config.HONK_URL = os.environ["SW_URL"]
config.HONK_TOKEN_FILE = pathlib.Path(os.environ["SW_TOKEN"])
config.GOOSE_SESSIONS_DB = pathlib.Path(os.environ["SW_DB"])
home = pathlib.Path(os.environ["SW_HOME"])
run_id = "probe" + os.urandom(4).hex()
payload = f"[sw wake run={run_id}] transport probe. Reply with exactly SWPROBEOK."
ctx = coordinator.SessionCtx(mode="new", tag="goose-upgrade-probe", home=home, swarm_tools=False, rolling_memory=False)
res = honk_transport.run_honk(
    payload, ctx, home, url=config.HONK_URL, token_file=config.HONK_TOKEN_FILE,
    db_path=config.GOOSE_SESSIONS_DB, recipe_file=os.environ["SW_RECIPE"], run_id=run_id,
    rolling_memory=False, swarm_tools=False, timeout_s=300)
print("SWRESULT " + json.dumps({"text": json.dumps(res, default=str)}))
'''


def production_goose_shell() -> str:
    try:
        pid = int(subprocess.run(["systemctl", "show", "goose-serve", "-p", "MainPID", "--value"],
                                 capture_output=True, text=True, timeout=30).stdout.strip() or 0)
        if pid:
            for kv in pathlib.Path(f"/proc/{pid}/environ").read_bytes().split(b"\0"):
                if kv.startswith(b"GOOSE_SHELL="):
                    return kv.split(b"=", 1)[1].decode()
    except Exception:
        pass
    return ""


def default_old_bin() -> str:
    """The goose that writes production's sessions.db: L6's approved link, else the running
    goose-serve's executable, else PATH (a host without goose-serve)."""
    current = pathlib.Path("/var/lib/goose/current/bin/goose")
    if current.exists():
        return str(current.resolve())
    try:
        pid = int(subprocess.run(["systemctl", "show", "goose-serve", "-p", "MainPID", "--value"],
                                 capture_output=True, text=True, timeout=30).stdout.strip() or 0)
        if pid:
            return os.path.realpath(f"/proc/{pid}/exe")
    except Exception:
        pass
    g = shutil.which("goose")
    if not g:
        raise ProbeError("no deployed goose found; pass --old-bin")
    return os.path.realpath(g)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="goose-upgrade-probe", description=__doc__.split("\n\n")[0])
    ap.add_argument("goose_bin")
    ap.add_argument("--old-bin")
    ap.add_argument("--keep", action="store_true", help="keep the work root (DB copies) for forensics")
    ap.add_argument("--only", help=f"comma-separated subset of {','.join(CHECKS)} (development only)")
    a = ap.parse_args(argv)
    cand = os.path.realpath(a.goose_bin)
    if not os.access(cand, os.X_OK):
        print(f"FAIL setup -- {a.goose_bin} is not an executable", flush=True)
        return 1
    try:
        old = os.path.realpath(a.old_bin) if a.old_bin else default_old_bin()
    except ProbeError as e:
        print(f"FAIL setup -- {e}")
        return 1
    only = [c.strip() for c in a.only.split(",")] if a.only else None
    if only and set(only) - set(CHECKS):
        print(f"FAIL setup -- unknown checks {set(only) - set(CHECKS)}")
        return 1
    return Probe(cand, old, a.keep, only).main()


if __name__ == "__main__":
    sys.exit(main())
