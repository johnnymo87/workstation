#!/usr/bin/env python3
"""em-history-shell: the server half of eternal-machinery's sandboxed history shell
(EM bead qpmfc.101.5, phase 2). Stdlib only.

Runs once per connection, as the system user `em-history-shell`, under systemd socket
activation (`Accept=yes`, `StandardInput=socket`): fd 0 is the connected unix socket.
It reads ONE JSON line, validates it, runs the command in a fresh bubblewrap sandbox,
writes ONE JSON line back and exits. Protocol v1 and the design: eternal-machinery
docs/plans/2026-11-03-q101-5-history-shell-phase2-impl.md (Protocol v1, and "Plan review
resolutions" 1, 3, 6, 7, 10). The service shape: hosts/devbox/em-history-shell.nix.

PORTED from eternal-machinery scripts/tec/history_shell.py (phase 1): `_NAME`,
`parse_view`, `view_mounts`, `check_mounts`, `build_argv`, the limits, and `execute`.
That repo is private, so this one cannot import it. The copies MUST stay in step: the
argv is the sandbox, and EM's escape suite tests this server black-box. Change both
together. Differences from phase 1, all on purpose:

- no `systemd-run --user --scope`: the instance's own cgroup carries the memory, task
  and cpu caps (the unit), and `KillMode=control-group` sweeps it when we exit;
- the child gets `oom_score_adj=1000`, so a memory squeeze kills the command and not us;
- the command is killed when the client disconnects;
- `validate_root` (home, checkout, .env) is replaced by a stricter rule: the root must
  be a direct child of the configured base and named `agent-history[-<profile>]`;
- no preflight command: EM's boot gate runs its escape suite through the socket.

FAIL CLOSED: a missing bwrap, seccomp file or tool path, or a bad request, answers
with a refusal before anything runs. There is no path that runs the command outside
bwrap.

Everything the server reads is on fd 0; stdout is the same socket, so nothing else may
print there. Diagnostics go to stderr (the journal).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import select
import signal
import socket
import stat
import struct
import subprocess
import sys
import time
from dataclasses import dataclass, field, replace

PROTOCOL_VERSION = 1

#: Largest request line, in bytes (without the newline).
MAX_REQUEST_BYTES = 256 * 1024
#: How long a client may take to send its request line.
REQUEST_TIMEOUT_S = 10.0
#: How long a client may take to take its answer.
ANSWER_TIMEOUT_S = 10.0

# --- limits, as in phase 1 (history_shell.py) ---------------------------------------
STDOUT_CAP = 64 * 1024
STDERR_CAP = 16 * 1024
#: Output read past the caps is counted and dropped, up to this much in all, and then
#: the command is stopped.
DRAIN_CEILING = 32 * 1024 * 1024
TIMEOUT_S = 30.0
MAX_COMMAND_CHARS = 16_000
SCRATCH_BYTES = 64 * 1024 * 1024
TMP_BYTES = 16 * 1024 * 1024
#: How long a killed command may take to go away, per try (two tries).
REAP_WAIT_S = 10.0
#: Written to the command's /proc/<pid>/oom_score_adj before it starts (the maximum).
OOM_SCORE_ADJ = "1000"

#: A file the history writer puts in the root. A root without it is not bound.
ROOT_MARKER = ".agent-history-root"
SANDBOX_HISTORY = "/history"
SANDBOX_SCRATCH = "/scratch"

# Matched with fullmatch: `$` would let a trailing newline through.
_STORE_PATH = re.compile(r"/nix/store/[0-9a-z]{32}-[A-Za-z0-9+._?=-]+")
_STORE_FILE = re.compile(
    r"(/nix/store/[0-9a-z]{32}-[A-Za-z0-9+._?=-]+)(/[A-Za-z0-9+._?=-]+)+"
)
_NAME = re.compile(r"[A-Za-z0-9_-][A-Za-z0-9_.-]*")
_ROOT_NAME = re.compile(r"agent-history(-[A-Za-z0-9_-]+)?")
_DIGEST = re.compile(r"[0-9a-f]{64}")
_VERSION = re.compile(r"[0-9]+(\.[0-9]+){2}")

RUN_KEYS = frozenset({"v", "op", "root", "view", "agent", "command"})
PING_KEYS = frozenset({"v", "op"})


class Refused(Exception):
    """The request is not acceptable (kind `refused`) or the server cannot serve it
    (kind `unavailable`). The message is a sentence the agent may read."""

    def __init__(self, message: str, kind: str = "refused"):
        super().__init__(message)
        self.kind = kind


class PeerGone(Exception):
    """The client closed the connection while its command ran."""


@dataclass(frozen=True)
class Config:
    """Where the pinned pieces are. Written by default.nix as config.json; shapes are
    checked by `load_config`, the filesystem by `check_installed`."""

    server: str
    bwrap: str
    tools: str
    seccomp: str
    closure: tuple[str, ...]
    #: sha256 (hex) of the unit's settings, from the command line (see `unit_digest_arg`).
    #: Put on every answer, so the client can tell a changed unit from the proven one.
    unit_digest: str | None = None
    #: The libseccomp the blob was built with, and `policy_sha256` of the policy source;
    #: both from default.nix, reported by `ping`.
    libseccomp_version: str = ""
    policy_sha256: str = ""


@dataclass(frozen=True)
class Limits:
    timeout_s: float = TIMEOUT_S
    stdout_cap: int = STDOUT_CAP
    stderr_cap: int = STDERR_CAP
    drain_ceiling: int = DRAIN_CEILING
    reap_wait_s: float = REAP_WAIT_S


@dataclass
class Result:
    exit_code: int | None
    stdout: str
    stderr: str
    timed_out: bool = False
    stdout_dropped: int = 0
    stderr_dropped: int = 0
    flooded: bool = False


@dataclass
class Request:
    root: str
    view: tuple[str, ...]
    agent: str
    command: str
    mounts: list[tuple[str, str]] = field(default_factory=list)


# --- config -------------------------------------------------------------------------


def _store_file(value, name: str) -> str:
    if (
        not isinstance(value, str)
        or not _STORE_FILE.fullmatch(value)
        or ".." in value.split("/")
    ):
        raise ValueError(f"{name} is not a file in the nix store: {value!r}")
    return value


def policy_sha256(text: str) -> str:
    """sha256 (hex) of a seccomp policy source, canonicalised so comments and layout do
    not move it. EXACTLY: split `text` on "\\n"; drop every line whose `.strip()` is empty
    or starts with "#"; `.rstrip()` each remaining line (leading whitespace stays); join
    with "\\n" (no trailing newline); sha256 the UTF-8 bytes. default.nix calls this at
    build time (config.json `policy_sha256`); EM's suite computes the same over its own
    nix/history_shell_seccomp.py. A trailing comment after code is code, and is kept."""
    kept = []
    for line in text.split("\n"):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        kept.append(line.rstrip())
    return hashlib.sha256("\n".join(kept).encode("utf-8")).hexdigest()


def unit_digest_arg(value: str) -> str:
    """argparse type for `--unit-digest`: 64 lowercase hex digits (a sha256)."""
    if not _DIGEST.fullmatch(value):
        raise argparse.ArgumentTypeError("must be 64 lowercase hex digits")
    return value


def load_config(path: str) -> Config:
    """Read config.json (made by default.nix). Raises ValueError/OSError on a bad one."""
    with open(path, encoding="utf-8") as handle:
        raw = json.load(handle)
    if not isinstance(raw, dict):
        raise ValueError("config is not an object")
    server = raw.get("server")
    tools = raw.get("tools")
    for name, value in (("server", server), ("tools", tools)):
        if not isinstance(value, str) or not _STORE_PATH.fullmatch(value):
            raise ValueError(f"config {name} is not a nix store path: {value!r}")
    closure = raw.get("closure")
    if not isinstance(closure, list) or not closure:
        raise ValueError("config closure is empty")
    for entry in closure:
        if not isinstance(entry, str) or not _STORE_PATH.fullmatch(entry):
            raise ValueError(f"config closure holds a non-store path: {entry!r}")
    if tools not in closure:
        raise ValueError("config tools is not part of the closure")
    version = raw.get("libseccomp_version")
    if not isinstance(version, str) or not _VERSION.fullmatch(version):
        raise ValueError(f"config libseccomp_version is not x.y.z: {version!r}")
    policy = raw.get("policy_sha256")
    if not isinstance(policy, str) or not _DIGEST.fullmatch(policy):
        raise ValueError(f"config policy_sha256 is not a sha256: {policy!r}")
    return Config(
        libseccomp_version=version,
        policy_sha256=policy,
        server=server,
        bwrap=_store_file(raw.get("bwrap"), "bwrap"),
        tools=tools,
        seccomp=_store_file(raw.get("seccomp"), "seccomp"),
        closure=tuple(sorted(set(closure))),
    )


def check_installed(config: Config) -> None:
    """The filesystem half of failing closed. Raises `Refused(kind="unavailable")`."""
    for label, path in (("bwrap", config.bwrap), ("seccomp program", config.seccomp)):
        if not os.path.isfile(os.path.realpath(path)):
            raise Refused(
                f"The history shell is broken on this host: the {label} is missing "
                "from the nix store. Nothing was run.",
                "unavailable",
            )
    if not os.access(config.bwrap, os.X_OK):
        raise Refused(
            "The history shell is broken on this host: bwrap cannot be run. "
            "Nothing was run.",
            "unavailable",
        )
    for path in config.closure:
        if not os.path.isdir(path) or os.path.islink(path):
            raise Refused(
                "The history shell is broken on this host: a tool is missing from "
                "the nix store. Nothing was run.",
                "unavailable",
            )
    if not os.path.isdir(os.path.join(config.tools, "bin")):
        raise Refused(
            "The history shell is broken on this host: the tools have no bin "
            "directory. Nothing was run.",
            "unavailable",
        )


def seccomp_sha256(config: Config) -> str:
    with open(config.seccomp, "rb") as handle:
        return hashlib.sha256(handle.read()).hexdigest()


# --- request validation -------------------------------------------------------------


def parse_view(text) -> tuple[str, ...]:
    """`*` (the whole root) or `account/agent,account/agent`. Returns `("*",)` or the
    sorted distinct entries. Raises `Refused` on anything else, so a bad view can never
    widen what is mounted. (Phase 1: history_shell.parse_view.)"""
    if not isinstance(text, str):
        raise Refused("The history view must be a string.")
    value = text.strip()
    if not value:
        raise Refused("This agent has no history view, so it has nothing to read.")
    parts = [p.strip() for p in value.split(",")]
    if "*" in parts:
        if parts != ["*"]:
            raise Refused("A history view of * cannot be mixed with other entries.")
        return ("*",)
    entries = set()
    for part in parts:
        pieces = part.split("/")
        if len(pieces) != 2 or not all(_NAME.fullmatch(p) for p in pieces):
            raise Refused(f"A history view entry must be account/agent: {part!r}.")
        entries.add(part)
    return tuple(sorted(entries))


def check_agent(agent, view: tuple[str, ...]) -> str:
    if not isinstance(agent, str):
        raise Refused("The agent must be a string.")
    pieces = agent.split("/")
    if len(pieces) != 2 or not all(_NAME.fullmatch(p) for p in pieces):
        raise Refused(f"The agent must be account/agent: {agent!r}.")
    if view != ("*",) and agent not in view:
        raise Refused(f"The agent {agent} is not part of its own history view.")
    return agent


def check_command(command) -> str:
    if not isinstance(command, str) or not command.strip():
        raise Refused("The command is empty.")
    if "\x00" in command:
        raise Refused("The command holds a NUL character.")
    if len(command) > MAX_COMMAND_CHARS:
        raise Refused(f"The command is longer than {MAX_COMMAND_CHARS} characters.")
    return command


def check_root(root, base: str) -> str:
    """The real path of the history root, or `Refused`. The root must be a direct child
    of `base`, named `agent-history` or `agent-history-<profile>`, a real directory (not
    a link), and hold the marker file (a regular file, not a link)."""
    if not isinstance(root, str) or not root:
        raise Refused("The history root must be a path.")
    base = os.path.normpath(base)
    if (
        "\x00" in root
        or not os.path.isabs(root)
        or os.path.normpath(root) != root
        or os.path.dirname(root) != base
        or not _ROOT_NAME.fullmatch(os.path.basename(root))
    ):
        raise Refused(
            "The history root is not one this shell serves. It must be "
            f"{base}/agent-history or {base}/agent-history-<profile>."
        )
    try:
        mode = os.lstat(root).st_mode
    except OSError:
        raise Refused(f"The history root {root} does not exist.") from None
    if not stat.S_ISDIR(mode):
        raise Refused(f"The history root {root} is not a directory.")
    real = os.path.realpath(root)
    if real != os.path.join(os.path.realpath(base), os.path.basename(root)):
        raise Refused(f"The history root {root} is not where it claims to be.")
    try:
        marker = os.lstat(os.path.join(real, ROOT_MARKER)).st_mode
    except OSError:
        marker = 0
    if not stat.S_ISREG(marker):
        raise Refused(
            f"The history root {root} has no {ROOT_MARKER} file. "
            "AgentOS creates it when it sets the root up."
        )
    return real


def account_dirs(root: str) -> list[str]:
    """The names of the account directories under the root that the `*` view binds:
    real directories (not links) whose names pass the name rule. A file, a link or an
    odd name at the root is not listed."""
    found = []
    try:
        entries = list(os.scandir(root))
    except OSError:
        raise Refused(
            "The history root cannot be read by the history shell.", "unavailable"
        ) from None
    for entry in entries:
        if not _NAME.fullmatch(entry.name) or entry.name.startswith("."):
            continue
        if entry.is_symlink() or not entry.is_dir(follow_symlinks=False):
            continue
        found.append(entry.name)
    return sorted(found)


def view_mounts(root: str, view: tuple[str, ...]) -> list[tuple[str, str]]:
    """`(host path, sandbox path)` for each part of the view. The `*` view binds each
    account directory (see `account_dirs`), never the root itself."""
    if view == ("*",):
        return [
            (f"{root}/{name}", f"{SANDBOX_HISTORY}/{name}")
            for name in account_dirs(root)
        ]
    return [(f"{root}/{entry}", f"{SANDBOX_HISTORY}/{entry}") for entry in view]


def check_mounts(mounts: list[tuple[str, str]], root: str) -> None:
    """Every host side of the view is a real directory, not a link, and lies under the
    real history root, so no symlink in the middle of the path leads somewhere else."""
    real_root = os.path.realpath(root)
    for host, inside in mounts:
        if os.path.islink(host) or not os.path.isdir(host):
            raise Refused(
                f"The history directory {inside} does not exist (or is a link)."
            )
        real = os.path.realpath(host)
        if real != real_root and not real.startswith(real_root + os.sep):
            raise Refused(f"The history directory {inside} is not under the root.")


def validate_run(msg: dict, base: str) -> Request:
    """Validate a `run` request (the key set is already checked). Touches the file
    system only to check the root and the mounts. Raises `Refused`."""
    view = parse_view(msg["view"])
    agent = check_agent(msg["agent"], view)
    command = check_command(msg["command"])
    root = check_root(msg["root"], base)
    mounts = view_mounts(root, view)
    check_mounts(mounts, root)
    return Request(root=root, view=view, agent=agent, command=command, mounts=mounts)


# --- the sandbox ---------------------------------------------------------------------


def build_argv(
    config: Config, mounts: list[tuple[str, str]], *, seccomp_fd: int, command: str
) -> list[str]:
    """The bwrap command line for one command. Pure: no filesystem access. The same
    argv as phase 1 (history_shell.build_argv)."""
    argv = [
        config.bwrap,
        "--unshare-user",
        "--unshare-pid",
        "--unshare-net",
        "--unshare-ipc",
        "--unshare-uts",
        "--unshare-cgroup",
        "--disable-userns",
        "--die-with-parent",
        "--new-session",
        "--clearenv",
        "--cap-drop",
        "ALL",
        "--seccomp",
        str(seccomp_fd),
    ]
    for path in config.closure:
        argv += ["--ro-bind", path, path]
    argv += [
        "--symlink",
        f"{config.tools}/bin",
        "/bin",
        "--proc",
        "/proc",
        "--dev",
        "/dev",
        "--size",
        str(SCRATCH_BYTES),
        "--tmpfs",
        SANDBOX_SCRATCH,
        "--size",
        str(TMP_BYTES),
        "--tmpfs",
        "/tmp",
        "--dir",
        SANDBOX_HISTORY,
    ]
    for host, inside in mounts:
        argv += ["--ro-bind", host, inside]
    # The root tmpfs (and with it the directories bwrap made above the history
    # mounts) and /dev (a tmpfs of its own, /dev/shm inside it) are read only. Only
    # /scratch and /tmp are writable, each with its own size.
    for path in ("/", "/dev"):
        argv += ["--remount-ro", path]
    for name, value in (
        ("PATH", "/bin"),
        ("HOME", SANDBOX_SCRATCH),
        ("TMPDIR", "/tmp"),
        ("LANG", "C.UTF-8"),
        ("PYTHONNOUSERSITE", "1"),
        ("PYTHONDONTWRITEBYTECODE", "1"),
    ):
        argv += ["--setenv", name, value]
    argv += [
        "--chdir",
        SANDBOX_SCRATCH,
        "--",
        "/bin/bash",
        "--noprofile",
        "--norc",
        "-c",
        command,
    ]
    return argv


def _decode(data: bytes) -> str:
    return data.decode("utf-8", errors="replace")


def _make_oom_child():
    """A `preexec_fn`: the command (and what it forks) is the first thing the kernel's
    OOM killer picks. Failing to set it is logged, not fatal: the unit's memory cap
    and `OOMPolicy=continue` still hold."""

    def preexec() -> None:
        try:
            with open("/proc/self/oom_score_adj", "w") as handle:
                handle.write(OOM_SCORE_ADJ)
        except OSError as err:
            os.write(2, f"oom_score_adj not set: {err}\n".encode())

    return preexec


def _kill(proc: subprocess.Popen) -> None:
    """End the command for good: bwrap's whole process group. `--die-with-parent`
    takes the sandbox's init down with bwrap, and the unit's cgroup sweep is the
    backstop."""
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass
    try:
        proc.kill()
    except (ProcessLookupError, PermissionError):
        pass


def _reap(proc: subprocess.Popen, wait_s: float) -> int:
    """Kill the command and wait for it, with a bound on every wait. A command that is
    still there after two kills raises `Refused(kind="internal")`."""
    for _ in range(2):
        _kill(proc)
        try:
            return proc.wait(timeout=wait_s)
        except subprocess.TimeoutExpired:
            continue
    raise Refused(
        "The command did not stop when it was killed. Nothing more was run.",
        "internal",
    )


def execute(
    config: Config,
    mounts: list[tuple[str, str]],
    command: str,
    *,
    limits: Limits = Limits(),
    peer_fd: int | None = None,
    set_oom: bool = True,
) -> Result:
    """Run `command` once in a sandbox. The checks are the caller's. When `peer_fd`
    (the client's socket) hangs up, the command is killed and `PeerGone` raised. Only
    POLLHUP counts: a client that half-closes its write side after the request has not
    left."""
    seccomp_fd = os.open(config.seccomp, os.O_RDONLY)
    try:
        os.set_inheritable(seccomp_fd, True)
        argv = build_argv(config, mounts, seccomp_fd=seccomp_fd, command=command)
        try:
            proc = subprocess.Popen(  # noqa: S603 -- argv is built here, never from the model
                argv,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env={},
                # close_fds also keeps fd 0/1, the client's socket, out of the sandbox.
                close_fds=True,
                pass_fds=(seccomp_fd,),
                start_new_session=True,
                preexec_fn=_make_oom_child() if set_oom else None,
            )
        except OSError as err:
            raise Refused(
                f"The sandbox could not be started: {err.strerror or err}. "
                "Nothing was run.",
                "unavailable",
            ) from err
    finally:
        os.close(seccomp_fd)

    out, err = bytearray(), bytearray()
    dropped = {"out": 0, "err": 0}
    timed_out = flooded = peer_gone = False
    code: int | None = None
    deadline = time.monotonic() + limits.timeout_s
    poller = select.poll()
    tags: dict[int, str] = {}
    try:
        for stream, tag in ((proc.stdout, "out"), (proc.stderr, "err")):
            os.set_blocking(stream.fileno(), False)
            poller.register(stream.fileno(), select.POLLIN | select.POLLHUP)
            tags[stream.fileno()] = tag
        if peer_fd is not None:
            # POLLHUP is always reported; asking for nothing else keeps a half-close
            # (EOF readable, no hangup) from waking us in a loop.
            poller.register(peer_fd, select.POLLHUP)
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                timed_out = True
                break
            if not tags and proc.poll() is not None:
                break
            for fd, event in poller.poll(min(remaining, 0.2) * 1000):
                if fd == peer_fd:
                    if event & (select.POLLHUP | select.POLLERR | select.POLLNVAL):
                        peer_gone = True
                    continue
                try:
                    chunk = os.read(fd, 65536)
                except BlockingIOError:
                    continue
                if not chunk:
                    poller.unregister(fd)
                    del tags[fd]
                    continue
                tag = tags[fd]
                buf, cap = (
                    (out, limits.stdout_cap)
                    if tag == "out"
                    else (err, limits.stderr_cap)
                )
                room = max(cap - len(buf), 0)
                buf += chunk[:room]
                dropped[tag] += len(chunk) - min(room, len(chunk))
            if peer_gone:
                break
            if dropped["out"] + dropped["err"] > limits.drain_ceiling:
                flooded = True
                break
        if peer_gone:
            _reap(proc, limits.reap_wait_s)
            raise PeerGone()
        if timed_out or flooded:
            code = _reap(proc, limits.reap_wait_s)
        else:
            code = proc.returncode
    finally:
        for stream in (proc.stdout, proc.stderr):
            try:
                stream.close()
            except OSError:
                pass
        if proc.poll() is None:
            # Only on the way out of an error. Bounded, and never raising over it.
            try:
                _reap(proc, limits.reap_wait_s)
            except Refused:
                pass
    return Result(
        exit_code=code,
        stdout=_decode(bytes(out)),
        stderr=_decode(bytes(err)),
        timed_out=timed_out,
        stdout_dropped=dropped["out"],
        stderr_dropped=dropped["err"],
        flooded=flooded,
    )


# --- the protocol --------------------------------------------------------------------


def peer_uid(sock: socket.socket) -> int:
    """The uid of the process that connected (SO_PEERCRED: pid, uid, gid)."""
    raw = sock.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i"))
    return struct.unpack("3i", raw)[1]


def read_line(sock: socket.socket, *, limit: int, timeout_s: float) -> bytes | None:
    """One request line (without its newline). `None` when the peer closed before it
    sent a byte. Raises `Refused` on an oversize, unfinished or too slow request."""
    deadline = time.monotonic() + timeout_s
    data = bytearray()
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise Refused("The request took too long to arrive. Nothing was run.")
        sock.settimeout(remaining)
        try:
            chunk = sock.recv(65536)
        except socket.timeout:
            raise Refused(
                "The request took too long to arrive. Nothing was run."
            ) from None
        if not chunk:
            if not data:
                return None
            raise Refused(
                "The request ended before its closing newline. Nothing was run."
            )
        data += chunk
        newline = data.find(b"\n")
        if newline >= 0:
            if newline > limit:
                break
            return bytes(data[:newline])
        if len(data) > limit:
            break
    raise Refused(
        f"The request is larger than {limit // 1024} KiB. Nothing was run."
    )


def _answer(config: Config, body: dict) -> dict:
    """Every answer, refusals included, names the server and the unit it runs under."""
    answer = {"v": PROTOCOL_VERSION, **body, "server": config.server}
    if config.unit_digest is not None:
        answer["unit_digest"] = config.unit_digest
    return answer


def refusal(config: Config, kind: str, error: str) -> dict:
    # A refusal happens before the sandbox starts, and the agent should not have to
    # wonder whether the command ran (an internal error says what is known instead).
    if kind != "internal" and "Nothing was run" not in error:
        error = f"{error} Nothing was run."
    return _answer(config, {"ok": False, "kind": kind, "error": error})


def run_answer(config: Config, result: Result) -> dict:
    return _answer(
        config,
        {
            "ok": True,
            "exit_code": result.exit_code,
            "stdout": result.stdout,
            "stderr": result.stderr,
            "timed_out": result.timed_out,
            "flooded": result.flooded,
            "stdout_dropped": result.stdout_dropped,
            "stderr_dropped": result.stderr_dropped,
            # Scratch is per command in this phase, so it is never reset behind the
            # agent's back. The field stays so the answer shape is protocol v1's.
            "scratch_reset": False,
        },
    )


def decode_request(line: bytes) -> dict:
    """The request as a dict, with `v` checked first so a newer client hears about the
    version and not about its fields. Raises `Refused` (kind `version` or `refused`)."""
    try:
        msg = json.loads(line.decode("utf-8"))
    except (UnicodeDecodeError, ValueError, RecursionError):
        raise Refused("The request was not valid JSON. Nothing was run.") from None
    if not isinstance(msg, dict):
        raise Refused("The request must be a JSON object. Nothing was run.")
    version = msg.get("v")
    if type(version) is not int or version != PROTOCOL_VERSION:
        raise Refused(
            f"This history shell speaks protocol version {PROTOCOL_VERSION}. "
            f"The request asked for {version!r}. Nothing was run.",
            "version",
        )
    return msg


def check_keys(msg: dict, wanted: frozenset) -> None:
    keys = set(msg)
    if keys == wanted:
        return
    missing = sorted(wanted - keys)
    extra = sorted(keys - wanted)
    parts = []
    if missing:
        parts.append("missing " + ", ".join(missing))
    if extra:
        parts.append("unexpected " + ", ".join(extra))
    raise Refused(
        f"The request has the wrong fields ({' and '.join(parts)}). Nothing was run."
    )


def handle_request(
    msg: dict,
    config: Config,
    *,
    base: str,
    peer_fd: int | None,
    limits: Limits,
    set_oom: bool = True,
) -> dict:
    """The answer for one decoded request. Raises `Refused` and `PeerGone`."""
    op = msg.get("op")
    if op == "ping":
        check_keys(msg, PING_KEYS)
        check_installed(config)
        return _answer(
            config,
            {
                "ok": True,
                "uid": os.getuid(),
                "seccomp_sha256": seccomp_sha256(config),
                "libseccomp_version": config.libseccomp_version,
                "policy_sha256": config.policy_sha256,
            },
        )
    if op != "run":
        raise Refused(f"Unknown operation {op!r}. Nothing was run.")
    check_keys(msg, RUN_KEYS)
    request = validate_run(msg, base)
    check_installed(config)
    result = execute(
        config,
        request.mounts,
        request.command,
        limits=limits,
        peer_fd=peer_fd,
        set_oom=set_oom,
    )
    return run_answer(config, result)


def send_answer(sock: socket.socket, body: dict) -> None:
    payload = (json.dumps(body, separators=(",", ":")) + "\n").encode("utf-8")
    sock.settimeout(ANSWER_TIMEOUT_S)
    try:
        sock.sendall(payload)
    except (OSError, socket.timeout):
        pass  # the client left; nothing to tell it


def _serve(
    sock: socket.socket,
    config: Config,
    allowed_uid: int,
    base: str,
    limits: Limits,
    set_oom: bool,
) -> None:
    try:
        if peer_uid(sock) != allowed_uid:
            send_answer(
                sock,
                refusal(
                    config,
                    "refused",
                    "This history shell only answers the user that runs AgentOS. "
                    "Nothing was run.",
                ),
            )
            return
        line = read_line(sock, limit=MAX_REQUEST_BYTES, timeout_s=REQUEST_TIMEOUT_S)
        if line is None:
            return
        msg = decode_request(line)
        body = handle_request(
            msg,
            config,
            base=base,
            peer_fd=sock.fileno(),
            limits=limits,
            set_oom=set_oom,
        )
    except PeerGone:
        return
    except Refused as err:
        body = refusal(config, err.kind, str(err))
    except Exception as err:  # noqa: BLE001 -- the client must hear something
        print(f"em-history-shell: internal error: {err!r}", file=sys.stderr)
        body = refusal(
            config,
            "internal",
            "The history shell hit an internal error. Nothing more is known.",
        )
    send_answer(sock, body)


def serve(
    sock: socket.socket,
    config: Config,
    *,
    allowed_uid: int,
    base: str,
    limits: Limits = Limits(),
    set_oom: bool = True,
) -> None:
    """One connection, start to finish; the server then closes it (shutdown reaches
    every duplicate of the descriptor, fd 0 and fd 1 included, so the client reads EOF
    at once). Never raises: every failure is an answer (or, when the client has gone,
    nothing)."""
    try:
        _serve(sock, config, allowed_uid, base, limits, set_oom)
    finally:
        try:
            sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        sock.close()


SAY_BROKEN = "The history shell is broken on this host. Nothing was run."


def tell_broken(server: str | None, unit_digest: str | None) -> None:
    """Best effort, on fd 0: an `unavailable` refusal for a server that cannot start, so
    the client reads a sentence and not a bare hangup. Never raises. `server` is left out
    when the config that names it could not be read."""
    body: dict = {"v": PROTOCOL_VERSION, "ok": False, "kind": "unavailable", "error": SAY_BROKEN}
    if server is not None:
        body["server"] = server
    if unit_digest is not None:
        body["unit_digest"] = unit_digest
    payload = (json.dumps(body, separators=(",", ":")) + "\n").encode("utf-8")
    try:
        view = memoryview(payload)
        while view:
            view = view[os.write(0, view) :]
    except OSError:
        return
    try:
        # shutdown reaches every duplicate of the descriptor, so the client reads EOF now
        socket.fromfd(0, socket.AF_UNIX, socket.SOCK_STREAM).shutdown(socket.SHUT_RDWR)
    except OSError:
        pass


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="em-history-shell server (one connection)")
    parser.add_argument("--allowed-uid", type=int, required=True)
    parser.add_argument("--base", required=True, help="directory holding agent-history*")
    parser.add_argument(
        "--unit-digest",
        type=unit_digest_arg,
        required=True,
        help="sha256 of the unit's settings (hosts/devbox/em-history-shell.nix)",
    )
    parser.add_argument(
        "--config",
        default=os.path.join(
            os.path.dirname(os.path.realpath(__file__)),
            "..",
            "share",
            "em-history-shell",
            "config.json",
        ),
    )
    args = parser.parse_args(argv)
    try:
        config = load_config(args.config)
    except (OSError, ValueError) as err:
        print(f"em-history-shell: bad config {args.config}: {err}", file=sys.stderr)
        tell_broken(None, args.unit_digest)
        return 2
    config = replace(config, unit_digest=args.unit_digest)
    try:
        sock = socket.fromfd(0, socket.AF_UNIX, socket.SOCK_STREAM)
        peer_uid(sock)
    except OSError as err:
        print(
            f"em-history-shell: fd 0 is not a connected unix socket ({err}); "
            "run it from em-history-shell.socket",
            file=sys.stderr,
        )
        tell_broken(config.server, config.unit_digest)
        return 2
    serve(sock, config, allowed_uid=args.allowed_uid, base=args.base)
    return 0


if __name__ == "__main__":
    sys.exit(main())
