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

PROTOCOL v2 (EM bead qpmfc.18.16.49.2.14, character memory spec section 3.5) adds her
skills folder. A `run` names a `character` (or null) and how she may use her folder,
`own` ("edit", "read", or null with no character):

- /skills/own, "edit": COPY IN, COPY OUT. The service copies her folder
  (<base>/skills-own/<history root name>/<key>/) into a fresh size-limited tmpfs (the
  unit's TemporaryFileSystem, `--skills-work`) and binds that copy read-write. After
  the command it reads the copy once, checking it as it reads (`read_tree`: folders
  and plain files only, no links or second names, the name grammar, depth and the
  runaway caps), writes what it read to a staging folder and swaps it in with an
  atomic rename. A killed command, a failed check, a full tmpfs or a folder that
  changed on disk meanwhile keeps nothing, and the answer says why in one sentence.
- /skills/own, "read": her folder bound read only (a player reads its character's).
- /skills/shared: the shared skills AgentOS publishes at boot
  (<base>/skills-shared[-<profile>]/, marker `.agent-skills-shared-root`), read only.
  Missing or unmarked: not mounted.
- /skills/characters: the view `*` (the Coordinator) also reads every character's
  folder of the profile, read only.

The skills roots are the service's own (<base>/skills-own/ is made by tmpfiles, owned
by this user, with an ACL that lets dev read): dev never writes there. A reviewed skill
reaches her folder through the `sync` op, and leaves it through `remove`, each guarded
by the folder's `files_sha256` as the caller last saw it.

Everything the server reads is on fd 0; stdout is the same socket, so nothing else may
print there. Diagnostics go to stderr (the journal).
"""

from __future__ import annotations

import argparse
import ctypes
import errno
import fcntl
import hashlib
import json
import os
import re
import secrets
import select
import shutil
import signal
import socket
import stat
import struct
import subprocess
import sys
import time
from dataclasses import dataclass, field, replace

PROTOCOL_VERSION = 2

#: Largest request line, in bytes (without the newline). Big enough for a `sync` of a
#: skill up to the folder caps after JSON escaping (only dev can connect).
MAX_REQUEST_BYTES = 16 * 1024 * 1024
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

# --- her skills folder (protocol v2) -------------------------------------------------
#: Under the base: the service's own folder (tmpfiles makes it). One profile root per
#: history root inside it, named as the history root is, then one folder per name key.
SKILLS_OWN = "skills-own"
#: Inside SKILLS_OWN: where new trees are written before they are swapped in, and where
#: old ones wait to be deleted. Same filesystem, so a rename moves them.
STAGING = ".staging"
#: Staging entries older than this are deleted by the next change. A tree being written
#: lives less than the unit's RuntimeMaxSec (60 s). A replaced folder is NOT deleted at
#: once (its mtime is set to the swap): a reader that walked into it just before the
#: swap (another instance's copy in, or AgentOS building her index) can finish.
STAGING_STALE_S = 120
#: The shared root AgentOS publishes is marked with this file.
SHARED_MARKER = ".agent-skills-shared-root"
SANDBOX_SKILLS = "/skills"
SANDBOX_OWN = "/skills/own"
SANDBOX_SHARED = "/skills/shared"
SANDBOX_CHARACTERS = "/skills/characters"
#: The folder inside `--skills-work` (a tmpfs) that is bound at /skills/own.
WORK_OWN = "own"
#: Runaway guards, not style rules: files in her whole folder, bytes per file, bytes in
#: all, folders below /skills/own (a file in /skills/own/a/b/c/ is at depth 4).
MAX_SKILL_FILES = 2000
MAX_FILE_BYTES = 1024 * 1024
MAX_TOTAL_BYTES = 8 * 1024 * 1024
MAX_DEPTH = 4
#: Below this much free space or these many free inodes, the work tmpfs counts as full:
#: a write cut short there can still exit 0.
WORK_LOW_BYTES = 256 * 1024
WORK_LOW_INODES = 8
#: Kept files and folders get these modes (no exec bits). The ACL gives dev r-X.
FILE_MODE = 0o640
DIR_MODE = 0o750

#: Capitalised words separated by single spaces (and at most 64 characters).
_CHARACTER = re.compile(r"[A-Z][a-z]+( [A-Z][a-z]+)*")
MAX_CHARACTER_CHARS = 64
#: A skill folder's name: skill-check's name rule (and at most 64 characters).
_SKILL_NAME = re.compile(r"[a-z0-9]+(-[a-z0-9]+)*")
#: Every other path component below /skills/own.
_COMPONENT = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}")
_SHARED_NAME = re.compile(r"skills-shared(-[A-Za-z0-9_-]+)?")

RUN_KEYS = frozenset(
    {"v", "op", "root", "view", "agent", "command", "character", "own"}
)
PING_KEYS = frozenset({"v", "op"})
SYNC_KEYS = frozenset({"v", "op", "root", "character", "skill", "expect_sha256", "files"})
REMOVE_KEYS = frozenset({"v", "op", "root", "character", "skill", "expect_sha256"})


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
    #: The tmpfs (the unit's TemporaryFileSystem) where her folder is copied in for an
    #: "edit" run, from `--skills-work`. None: "edit" runs are refused.
    skills_work: str | None = None


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
    #: Her name key, or None when the run has no character.
    key: str | None = None
    #: "edit", "read" or None.
    own: str | None = None
    #: The history root's name, which names its profile root under SKILLS_OWN.
    profile: str = ""
    #: The validated shared root, or None (not mounted).
    shared: str | None = None


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
    key = character_key(msg["character"])
    own = check_own(msg["own"], key)
    root = check_root(msg["root"], base)
    mounts = view_mounts(root, view)
    check_mounts(mounts, root)
    return Request(
        root=root,
        view=view,
        agent=agent,
        command=command,
        mounts=mounts,
        key=key,
        own=own,
        profile=os.path.basename(root),
        shared=shared_root(root, base),
    )


# --- her skills folder: names and roots -----------------------------------------------


def character_key(character) -> str | None:
    """The folder key for a character name: casefolded, each space a hyphen ("Aelinthia
    Corvella" is "aelinthia-corvella"). One-to-one under the grammar, which has no
    hyphens. None for no character. Raises `Refused`."""
    if character is None:
        return None
    if (
        not isinstance(character, str)
        or len(character) > MAX_CHARACTER_CHARS
        or not _CHARACTER.fullmatch(character)
    ):
        raise Refused(
            "The character must be a name of capitalised words with single spaces, "
            f"at most {MAX_CHARACTER_CHARS} characters."
        )
    return character.casefold().replace(" ", "-")


def check_own(own, key: str | None) -> str | None:
    if key is None:
        if own is not None:
            raise Refused("A run with no character has no skills folder to use.")
        return None
    if own not in ("edit", "read"):
        raise Refused('With a character, own must be "edit" or "read".')
    return own


def check_skill_name(skill) -> str:
    if not isinstance(skill, str) or len(skill) > 64 or not _SKILL_NAME.fullmatch(skill):
        raise Refused(
            "The skill must be named with lowercase letters, digits and single "
            "hyphens, at most 64 characters."
        )
    return skill


def shared_root(root: str, base: str) -> str | None:
    """The shared skills root that pairs with the history root (agent-history goes with
    skills-shared, agent-history-<p> with skills-shared-<p>) when it is a real directory
    (not a link) holding its marker as a regular file. Anything else: None, and nothing
    is mounted at /skills/shared. Never raises."""
    suffix = os.path.basename(root)[len("agent-history") :]
    name = "skills-shared" + suffix
    if not _SHARED_NAME.fullmatch(name):
        return None
    path = os.path.join(os.path.realpath(base), name)
    try:
        if not stat.S_ISDIR(os.lstat(path).st_mode):
            return None
        if not stat.S_ISREG(os.lstat(os.path.join(path, SHARED_MARKER)).st_mode):
            return None
    except OSError:
        return None
    return path


def _open_dir(name: str, dir_fd: int | None = None) -> int:
    """A directory fd, never through a symlink at the last component."""
    return os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=dir_fd)


def open_skills_own(base: str) -> int:
    """The fd of <base>/skills-own when it is this user's real directory and nobody else
    can write it. Raises `Refused(kind="unavailable")`."""
    say = (
        "Her skills folder is not set up on this host (the service's skills-own "
        "folder is missing or not its own)."
    )
    try:
        fd = _open_dir(os.path.join(os.path.realpath(base), SKILLS_OWN))
    except OSError:
        raise Refused(say, "unavailable") from None
    info = os.fstat(fd)
    if info.st_uid != os.geteuid() or info.st_mode & 0o022:
        os.close(fd)
        raise Refused(say, "unavailable")
    return fd


def _open_child(parent_fd: int, name: str) -> int | None:
    """A real directory below `parent_fd` (no link), or None when there is none."""
    try:
        return _open_dir(name, parent_fd)
    except FileNotFoundError:
        return None
    except OSError as err:
        if err.errno in (errno.ENOTDIR, errno.ELOOP):
            raise Refused(
                "Her skills folder holds something that is not a folder where a "
                "folder belongs.",
                "internal",
            ) from None
        raise


# --- her skills folder: the tree check -------------------------------------------------


class TreeRefused(Exception):
    """The folder does not pass the check. The message is the reason, a clause the
    answer puts after "Your skills were not saved because"."""


@dataclass(frozen=True)
class Tree:
    """A folder as read: every directory and file by its path below the folder, with
    the files' bytes. Paths use "/" and have no leading slash."""

    dirs: tuple[str, ...]
    files: tuple[tuple[str, bytes], ...]

    def digest(self) -> str:
        """Changes when any path, folder or file content changes (empty folders count,
        unlike `files_sha256`)."""
        h = hashlib.sha256()
        for path in self.dirs:
            h.update(b"d " + path.encode("utf-8", "surrogateescape") + b"\n")
        for path, data in self.files:
            h.update(b"f " + path.encode("utf-8", "surrogateescape") + b"\0")
            h.update(hashlib.sha256(data).hexdigest().encode() + b"\n")
        return h.hexdigest()

    def total(self) -> int:
        return sum(len(data) for _, data in self.files)

    def skill(self, name: str) -> Tree | None:
        """The part of the tree below one top-level folder, or None."""
        if name not in self.dirs:
            return None
        prefix = name + "/"
        return Tree(
            dirs=tuple(d[len(prefix) :] for d in self.dirs if d.startswith(prefix)),
            files=tuple((p[len(prefix) :], b) for p, b in self.files if p.startswith(prefix)),
        )

    def without(self, name: str) -> Tree:
        prefix = name + "/"
        return Tree(
            dirs=tuple(d for d in self.dirs if d != name and not d.startswith(prefix)),
            files=tuple((p, b) for p, b in self.files if not p.startswith(prefix)),
        )


EMPTY_TREE = Tree(dirs=(), files=())


def files_sha256(tree: Tree | None) -> str | None:
    """The hash the review ledger keys on, for one skill folder (None: no folder).
    EXACTLY: for each regular file, in the order of its "/"-joined path below the skill
    folder sorted by UTF-8 bytes, the bytes `path + "\\0" + sha256hex(content) + "\\n"`,
    all concatenated and hashed with sha256 (hex). Folders do not count. AgentOS
    computes the same host-side."""
    if tree is None:
        return None
    h = hashlib.sha256()
    for path, data in sorted(tree.files, key=lambda item: item[0].encode("utf-8", "surrogateescape")):
        h.update(path.encode("utf-8", "surrogateescape") + b"\0")
        h.update(hashlib.sha256(data).hexdigest().encode() + b"\n")
    return h.hexdigest()


def _show(path: str) -> str:
    """A path as she sees it, safe to put in a sentence."""
    text = os.fsencode(SANDBOX_OWN + "/" + path).decode("ascii", "backslashreplace")
    return text if len(text) <= 200 else text[:200] + "..."


def check_name(path: str, depth: int) -> None:
    """One path component's rule: a skill folder's at depth 1, the general one below."""
    name = path.rsplit("/", 1)[-1]
    if depth == 1:
        if len(name) > 64 or not _SKILL_NAME.fullmatch(name):
            raise TreeRefused(
                f"{_show(path)} is not a skill name. Name a skill folder with lowercase "
                "letters, digits and single hyphens, at most 64 characters"
            )
    elif not _COMPONENT.fullmatch(name):
        raise TreeRefused(
            f"{_show(path)} has a name that is not allowed. Use letters, digits, dots, "
            "hyphens and underscores, not starting with a dot, at most 64 characters"
        )


def check_tree(tree: Tree) -> None:
    """The rules a whole folder must pass (names, depth, caps), on a tree already read.
    Used for a `sync`, whose files never went through `read_tree`."""
    for path in tree.dirs:
        depth = path.count("/") + 1
        check_name(path, depth)
        if depth > MAX_DEPTH:
            raise TreeRefused(f"{_show(path)} is nested too deep. Keep files at most {MAX_DEPTH} folders down")
    dirs = set(tree.dirs)
    for path, _ in tree.files:
        if path in dirs:
            raise TreeRefused(f"{_show(path)} is both a file and a folder")
    for path, data in tree.files:
        parts = path.split("/")
        if len(parts) == 1:
            raise TreeRefused(
                f"{_show(path)} is a file at the top of your skills folder. Each skill is a folder"
            )
        for i in range(1, len(parts)):
            if "/".join(parts[:i]) not in dirs:
                raise TreeRefused(f"{_show(path)} has no folder above it")
        check_name(path, len(parts))
        if len(parts) - 1 > MAX_DEPTH:
            raise TreeRefused(f"{_show(path)} is nested too deep. Keep files at most {MAX_DEPTH} folders down")
        if len(data) > MAX_FILE_BYTES:
            raise TreeRefused(f"{_show(path)} is larger than {MAX_FILE_BYTES // (1024 * 1024)} MiB")
    if len(tree.files) > MAX_SKILL_FILES:
        raise TreeRefused(f"your skills folder holds more than {MAX_SKILL_FILES} files")
    if tree.total() > MAX_TOTAL_BYTES:
        raise TreeRefused(
            f"your skills folder holds more than {MAX_TOTAL_BYTES // (1024 * 1024)} MiB"
        )


def read_tree(dir_fd: int, _prefix: str = "") -> Tree:
    """Read the folder at `dir_fd` once, checking it as it is read: folders and regular
    files only (a link, a device, a fifo or a socket is refused, and so is a file with a
    second name), every name, the depth and the caps. What is returned is what was
    checked, so a change made after a file was read cannot slip in. Raises
    `TreeRefused`."""
    dirs: list[str] = []
    files: list[tuple[str, bytes]] = []
    total = 0

    def walk(fd: int, prefix: str, depth: int) -> None:
        nonlocal total
        try:
            names = sorted(os.listdir(fd))
        except OSError:
            raise TreeRefused(f"{_show(prefix.rstrip('/')) if prefix else SANDBOX_OWN} cannot be read") from None
        for name in names:
            path = prefix + name
            try:
                info = os.stat(name, dir_fd=fd, follow_symlinks=False)
            except OSError:
                raise TreeRefused(f"{_show(path)} cannot be read") from None
            if stat.S_ISLNK(info.st_mode):
                raise TreeRefused(f"{_show(path)} is a link. Only plain files and folders are kept")
            if stat.S_ISREG(info.st_mode) and depth == 1:
                raise TreeRefused(
                    f"{_show(path)} is a file at the top of your skills folder. Each skill is a folder"
                )
            check_name(path, depth)
            if stat.S_ISDIR(info.st_mode):
                if depth > MAX_DEPTH:
                    raise TreeRefused(f"{_show(path)} is nested too deep. Keep files at most {MAX_DEPTH} folders down")
                try:
                    child = _open_dir(name, fd)
                except OSError:
                    raise TreeRefused(f"{_show(path)} cannot be read") from None
                try:
                    dirs.append(path)
                    walk(child, path + "/", depth + 1)
                finally:
                    os.close(child)
                continue
            if not stat.S_ISREG(info.st_mode):
                raise TreeRefused(f"{_show(path)} is not a plain file or folder. Only plain files and folders are kept")
            try:
                ffd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=fd)
            except OSError:
                raise TreeRefused(f"{_show(path)} cannot be read") from None
            try:
                opened = os.fstat(ffd)
                if not stat.S_ISREG(opened.st_mode):
                    raise TreeRefused(f"{_show(path)} is not a plain file or folder. Only plain files and folders are kept")
                if opened.st_nlink != 1:
                    raise TreeRefused(f"{_show(path)} has a second name (a hard link). Only plain files and folders are kept")
                chunks = []
                size = 0
                while size <= MAX_FILE_BYTES:
                    chunk = os.read(ffd, 65536)
                    if not chunk:
                        break
                    chunks.append(chunk)
                    size += len(chunk)
            finally:
                os.close(ffd)
            if size > MAX_FILE_BYTES:
                raise TreeRefused(f"{_show(path)} is larger than {MAX_FILE_BYTES // (1024 * 1024)} MiB")
            files.append((path, b"".join(chunks)))
            total += size
            if len(files) > MAX_SKILL_FILES:
                raise TreeRefused(f"your skills folder holds more than {MAX_SKILL_FILES} files")
            if total > MAX_TOTAL_BYTES:
                raise TreeRefused(
                    f"your skills folder holds more than {MAX_TOTAL_BYTES // (1024 * 1024)} MiB"
                )

    if _prefix:
        dirs.append(_prefix)
        walk(dir_fd, _prefix + "/", 2)
    else:
        walk(dir_fd, "", 1)
    return Tree(dirs=tuple(dirs), files=tuple(files))


def read_tree_below(skill_fd: int, skill: str) -> Tree:
    """`read_tree` of one skill folder, with paths as below her folder."""
    return read_tree(skill_fd, skill)


def write_tree(dir_fd: int, tree: Tree) -> None:
    """Write `tree` into the empty folder at `dir_fd`: folders DIR_MODE, files
    FILE_MODE, every file and folder synced. Never follows a link."""
    fds = {"": dir_fd}
    try:
        for path in tree.dirs:
            parent, _, name = path.rpartition("/")
            os.mkdir(name, DIR_MODE, dir_fd=fds[parent])
            fds[path] = _open_dir(name, fds[parent])
        for path, data in tree.files:
            parent, _, name = path.rpartition("/")
            ffd = os.open(
                name,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                FILE_MODE,
                dir_fd=fds[parent],
            )
            try:
                view = memoryview(data)
                while view:
                    view = view[os.write(ffd, view) :]
                os.fsync(ffd)
            finally:
                os.close(ffd)
        for path in sorted(tree.dirs, key=len, reverse=True):
            os.fsync(fds[path])
        os.fsync(dir_fd)
    finally:
        for path, fd in fds.items():
            if path:
                os.close(fd)


# --- her skills folder: swapping a tree in ---------------------------------------------

_RENAME_NOREPLACE = 1
_RENAME_EXCHANGE = 2
_libc = None


def _renameat2(old_fd: int, old: str, new_fd: int, new: str, flags: int) -> None:
    global _libc
    if _libc is None:
        _libc = ctypes.CDLL(None, use_errno=True)
    if _libc.renameat2(old_fd, os.fsencode(old), new_fd, os.fsencode(new), flags) != 0:
        err = ctypes.get_errno()
        raise OSError(err, os.strerror(err))


class Store:
    """<base>/skills-own, held open, with its lock. Every change to a character's
    folder happens under the lock, so a copy out and a sync never interleave."""

    def __init__(self, base: str):
        self.fd = open_skills_own(base)
        self.staging_fd: int | None = None

    def close(self) -> None:
        if self.staging_fd is not None:
            os.close(self.staging_fd)
            self.staging_fd = None
        os.close(self.fd)

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()

    def lock(self) -> None:
        fcntl.flock(self.fd, fcntl.LOCK_EX)

    def lock_shared(self) -> None:
        fcntl.flock(self.fd, fcntl.LOCK_SH)

    def unlock(self) -> None:
        fcntl.flock(self.fd, fcntl.LOCK_UN)

    def profile_fd(self, profile: str, *, create: bool) -> int | None:
        fd = _open_child(self.fd, profile)
        if fd is None and create:
            try:
                os.mkdir(profile, DIR_MODE, dir_fd=self.fd)
            except FileExistsError:
                pass
            fd = _open_child(self.fd, profile)
        return fd

    def key_fd(self, profile: str, key: str) -> int | None:
        """Her folder's fd, or None when she has none yet."""
        pfd = self.profile_fd(profile, create=False)
        if pfd is None:
            return None
        try:
            return _open_child(pfd, key)
        finally:
            os.close(pfd)

    def read_key(self, profile: str, key: str) -> Tree:
        fd = self.key_fd(profile, key)
        if fd is None:
            return EMPTY_TREE
        try:
            return read_tree(fd)
        finally:
            os.close(fd)

    def read_skill(self, profile: str, key: str, skill: str) -> Tree:
        """Her folder as a tree holding only `skill` (empty if she has no such skill).
        Raises TreeRefused, but only for what is inside that skill."""
        fd = self.key_fd(profile, key)
        if fd is None:
            return EMPTY_TREE
        try:
            sfd = _open_child(fd, skill)
            if sfd is None:
                return EMPTY_TREE
            try:
                inner = read_tree_below(sfd, skill)
            finally:
                os.close(sfd)
        finally:
            os.close(fd)
        return inner

    def _staging(self) -> int:
        if self.staging_fd is None:
            try:
                os.mkdir(STAGING, DIR_MODE, dir_fd=self.fd)
            except FileExistsError:
                pass
            self.staging_fd = _open_dir(STAGING, self.fd)
            self._sweep()
        return self.staging_fd

    def _sweep(self) -> None:
        """Delete what a crash left in staging. Best effort."""
        now = time.time()
        try:
            names = os.listdir(self.staging_fd)
        except OSError:
            return
        for name in names:
            try:
                if now - os.stat(name, dir_fd=self.staging_fd, follow_symlinks=False).st_mtime > STAGING_STALE_S:
                    shutil.rmtree(name, dir_fd=self.staging_fd)
            except OSError:
                pass

    def stage(self, tree: Tree) -> str:
        """Write `tree` into a new staging folder and return its name."""
        sfd = self._staging()
        name = "t-" + secrets.token_hex(8)
        os.mkdir(name, DIR_MODE, dir_fd=sfd)
        try:
            fd = _open_dir(name, sfd)
            try:
                write_tree(fd, tree)
            finally:
                os.close(fd)
        except BaseException:
            self.discard(name)
            raise
        return name

    def retire(self, name: str) -> None:
        """A replaced folder, now in staging: leave it for the sweep, from now."""
        try:
            os.utime(name, dir_fd=self._staging(), follow_symlinks=False)
        except OSError as err:
            print(f"em-history-shell: could not date {name}: {err!r}", file=sys.stderr)

    def discard(self, name: str) -> None:
        try:
            shutil.rmtree(name, dir_fd=self._staging())
        except OSError as err:
            print(f"em-history-shell: could not delete staging {name}: {err!r}", file=sys.stderr)

    def put(self, parent_fd: int, target: str, staged: str | None) -> str | None:
        """Make `target` (in `parent_fd`) the staged folder, or remove it when `staged`
        is None. Atomic: a reader sees the old folder or the new one. Returns the
        staging name now holding the old folder (to `discard`), or None."""
        sfd = self._staging()
        exists = _open_child(parent_fd, target)
        if exists is not None:
            os.close(exists)
        if staged is None:
            if not exists:
                return None
            old = "o-" + secrets.token_hex(8)
            _renameat2(parent_fd, target, sfd, old, _RENAME_NOREPLACE)
            return old
        if exists is None:
            _renameat2(sfd, staged, parent_fd, target, _RENAME_NOREPLACE)
            return None
        _renameat2(sfd, staged, parent_fd, target, _RENAME_EXCHANGE)
        os.fsync(parent_fd)
        old = "o-" + secrets.token_hex(8)
        _renameat2(sfd, staged, sfd, old, _RENAME_NOREPLACE)
        return old


def replace_key(store: Store, profile: str, key: str, before: str, tree: Tree) -> str | None:
    """Swap her whole folder for `tree`, but only if it still reads as `before` (a
    `Tree.digest`). Returns the reason it was not kept, or None. Caller holds no lock."""
    staged = store.stage(tree) if (tree.dirs or tree.files) else None
    old = None
    try:
        store.lock()
        try:
            try:
                now = store.read_key(profile, key).digest()
            except TreeRefused:
                now = None
            if now != before:
                return "they changed while the command ran. Look again and redo the change"
            pfd = store.profile_fd(profile, create=staged is not None)
            if pfd is None:
                return None  # nothing there and nothing to write
            try:
                old = store.put(pfd, key, staged)
                staged = None
                os.fsync(pfd)
            finally:
                os.close(pfd)
        finally:
            store.unlock()
    finally:
        if staged is not None:
            store.discard(staged)
        if old is not None:
            store.retire(old)
    return None


# --- her skills folder: a run's mounts, copy in and copy out --------------------------


def _not_saved(reason: str) -> str:
    return f"Your skills were not saved because {reason}."


def work_is_full(path: str) -> bool:
    """The work tmpfs is (nearly) out of space or inodes: a write may have been cut."""
    info = os.statvfs(path)
    return info.f_bavail * info.f_frsize < WORK_LOW_BYTES or info.f_favail < WORK_LOW_INODES


@dataclass
class EditState:
    store: Store
    work: str
    before: str


COPY_IN_FAILED = (
    "Your skills folder could not be opened for writing this time, so it is read "
    "only and nothing you change there is kept."
)


def _own_read_mount(request: Request, base: str) -> tuple[str, str | None, str]:
    """Her folder bound read only at /skills/own, or an empty folder if she has none."""
    host = None
    try:
        with Store(base) as store:
            fd = store.key_fd(request.profile, request.key)
            if fd is not None:
                os.close(fd)
                host = os.path.join(os.path.realpath(base), SKILLS_OWN, request.profile, request.key)
    except Refused as err:
        if err.kind == "internal":
            raise
        host = None  # no skills-own on this host: she has nothing to read yet
    return ("--ro-bind", host, SANDBOX_OWN) if host else ("--dir", None, SANDBOX_OWN)


def _copy_in(store: Store, request: Request, work: str) -> str:
    """Copy her folder into `work` (under a shared lock, so no writer swaps it
    meanwhile) and return its digest. Raises TreeRefused or OSError."""
    store.lock_shared()
    try:
        before = store.read_key(request.profile, request.key)
    finally:
        store.unlock()
    shutil.rmtree(work, ignore_errors=True)
    os.mkdir(work, 0o700)
    fd = _open_dir(work)
    try:
        write_tree(fd, before)
    finally:
        os.close(fd)
    return before.digest()


def skills_mounts(
    request: Request, config: Config, base: str
) -> tuple[list[tuple[str, str | None, str]], EditState | None, dict | None]:
    """The /skills mounts of a run, `(bwrap flag, host path or None, sandbox path)`;
    for an "edit" run the state `finish_edit` needs (her folder is copied into the
    work tmpfs here); and, when the copy in failed, the answer's `skills` (she then
    gets her folder read only, rather than no shell at all). Raises `Refused`."""
    mounts: list[tuple[str, str | None, str]] = []
    own_root = os.path.join(os.path.realpath(base), SKILLS_OWN)
    state = None
    fallback = None
    if request.own == "edit":
        work_base = config.skills_work
        if not work_base or not os.path.isdir(work_base) or os.path.islink(work_base):
            raise Refused(
                "Her skills folder cannot be edited on this host (the service has no "
                "work space for it).",
                "unavailable",
            )
        store = Store(base)
        work = os.path.join(work_base, WORK_OWN)
        try:
            before = _copy_in(store, request, work)
        except (TreeRefused, OSError) as err:
            print(f"em-history-shell: copy in failed: {err!r}", file=sys.stderr)
            store.close()
            shutil.rmtree(work, ignore_errors=True)
            mounts.append(_own_read_mount(request, base))
            fallback = {"changed": False, "kept": False, "why": COPY_IN_FAILED}
        except BaseException:
            store.close()
            shutil.rmtree(work, ignore_errors=True)
            raise
        else:
            state = EditState(store=store, work=work, before=before)
            mounts.append(("--bind", work, SANDBOX_OWN))
    elif request.own == "read":
        mounts.append(_own_read_mount(request, base))
    if request.shared is not None:
        mounts.append(("--ro-bind", request.shared, SANDBOX_SHARED))
    if request.view == ("*",):
        host = None
        try:
            with Store(base) as store:
                fd = store.profile_fd(request.profile, create=False)
                if fd is not None:
                    os.close(fd)
                    host = os.path.join(own_root, request.profile)
        except Refused:
            host = None
        mounts.append(
            ("--ro-bind", host, SANDBOX_CHARACTERS) if host else ("--dir", None, SANDBOX_CHARACTERS)
        )
    return mounts, state, fallback


def oom_kills() -> int | None:
    """How many processes the kernel's OOM killer has taken in this instance's cgroup
    (`oom_kill` in its memory.events), or None when that cannot be read."""
    try:
        with open("/proc/self/cgroup", encoding="utf-8") as handle:
            line = next(ln for ln in handle.read().splitlines() if ln.startswith("0::"))
        path = os.path.join("/sys/fs/cgroup", line[3:].lstrip("/"), "memory.events")
        with open(path, encoding="utf-8") as handle:
            for ln in handle:
                name, _, value = ln.partition(" ")
                if name == "oom_kill":
                    return int(value)
    except (OSError, StopIteration, ValueError):
        return None
    return None


#: bash's exit status for a command killed by SIGKILL (128 + 9): inside the sandbox
#: that is the OOM killer or a kill -9, and bwrap passes it on as a plain exit code.
KILLED_EXIT = 137


def finish_edit(
    state: EditState,
    request: Request,
    result: Result,
    work_base: str,
    oom_before: int | None = None,
) -> dict:
    """Copy out: what the answer's `skills` says after an "edit" run. A killed command
    (stopped by us, killed by a signal, or with an OOM kill in the instance) keeps
    nothing, since a file it was writing may be cut short."""
    oom_after = oom_kills() if oom_before is not None else None
    killed = (
        result.timed_out
        or result.flooded
        or result.exit_code is None
        or result.exit_code < 0
        or result.exit_code == KILLED_EXIT
        or (oom_after is not None and oom_after > oom_before)
    )
    after = None
    reason = None
    try:
        fd = _open_dir(state.work)
    except OSError:
        reason = "your skills folder was gone after the command"
    else:
        try:
            after = read_tree(fd)
        except TreeRefused as err:
            reason = str(err)
        finally:
            os.close(fd)
    if after is not None and after.digest() == state.before:
        return {"changed": False, "kept": True, "why": None}
    if killed:
        reason = "the command was stopped before it finished"
    elif work_is_full(work_base):
        reason = "your skills folder ran out of room"
    if reason is not None:
        return {"changed": False, "kept": False, "why": _not_saved(reason)}
    try:
        reason = replace_key(state.store, request.profile, request.key, state.before, after)
    except OSError as err:
        print(f"em-history-shell: could not keep her skills: {err!r}", file=sys.stderr)
        reason = "the service could not write them. Try again later"
    if reason is not None:
        return {"changed": False, "kept": False, "why": _not_saved(reason)}
    return {"changed": True, "kept": True, "why": None}


# --- her skills folder: the dev-only ops ----------------------------------------------


def check_expect(value) -> str | None:
    if value is None or (isinstance(value, str) and _DIGEST.fullmatch(value)):
        return value
    raise Refused("expect_sha256 must be null or 64 lowercase hex digits.")


def files_tree(skill: str, files) -> Tree:
    """A skill folder from a sync's `files` ({relative path: UTF-8 text}), as a tree
    below her folder. Raises `Refused` on a bad shape, `TreeRefused` on a bad name."""
    if not isinstance(files, dict) or not files:
        raise Refused("files must be a non-empty object of path to text.")
    dirs = {skill}
    out = []
    for rel, text in files.items():
        if not isinstance(rel, str) or not isinstance(text, str):
            raise Refused("files must map each path to its text.")
        parts = rel.split("/")
        if any(not _COMPONENT.fullmatch(p) for p in parts):
            raise Refused(f"The file path {rel!r} is not allowed.")
        for i in range(1, len(parts)):
            dirs.add(skill + "/" + "/".join(parts[:i]))
        try:
            data = text.encode("utf-8")
        except UnicodeEncodeError:
            raise Refused(f"The text of {rel!r} is not valid UTF-8.") from None
        out.append((skill + "/" + rel, data))
    return Tree(dirs=tuple(sorted(dirs)), files=tuple(sorted(out)))


def _merge(base_tree: Tree, skill_tree: Tree) -> Tree:
    return Tree(
        dirs=tuple(sorted(set(base_tree.dirs) | set(skill_tree.dirs))),
        files=tuple(sorted(base_tree.files + skill_tree.files)),
    )


def handle_change(msg: dict, base: str) -> dict:
    """A `sync` (write one reviewed skill) or a `remove`, each only if the skill folder
    still hashes to `expect_sha256` (null: it must not exist). Returns the answer body.
    Raises `Refused` (kind `conflict` when the hash does not match)."""
    op = msg["op"]
    root = check_root(msg["root"], base)
    key = character_key(msg["character"])
    if key is None:
        raise Refused("A sync or remove needs a character.")
    skill = check_skill_name(msg["skill"])
    expect = check_expect(msg["expect_sha256"])
    new_skill = files_tree(skill, msg["files"]) if op == "sync" else None
    profile = os.path.basename(root)
    with Store(base) as store:
        staged = old = None
        store.lock()
        try:
            try:
                if new_skill is None:
                    # A remove reads only the skill it removes, so it can take away an
                    # entry that a stricter rule would now refuse.
                    current = store.read_skill(profile, key, skill)
                else:
                    current = store.read_key(profile, key)
            except TreeRefused as err:
                raise Refused(f"Her skills folder on disk does not pass the check ({err}).", "internal") from None
            now = files_sha256(current.skill(skill))
            if now != expect:
                raise Refused(
                    f"The skill {skill} is not as expected (it hashes to {now}).", "conflict"
                )
            if new_skill is not None:
                try:
                    check_tree(_merge(current.without(skill), new_skill))
                except TreeRefused as err:
                    raise Refused(f"The skill cannot be kept: {err}.") from None
                staged = store.stage(new_skill.skill(skill))
            pfd = store.profile_fd(profile, create=new_skill is not None)
            if pfd is None:
                return {"ok": True} if op == "remove" else {"ok": True, "files_sha256": None}
            try:
                kfd = _open_child(pfd, key)
                if kfd is None and new_skill is not None:
                    os.mkdir(key, DIR_MODE, dir_fd=pfd)
                    kfd = _open_child(pfd, key)
                if kfd is not None:
                    try:
                        old = store.put(kfd, skill, staged)
                        staged = None
                        os.fsync(kfd)
                        empty = not os.listdir(kfd)
                    finally:
                        os.close(kfd)
                    if empty:
                        os.rmdir(key, dir_fd=pfd)
                        os.fsync(pfd)
            finally:
                os.close(pfd)
        finally:
            store.unlock()
            if staged is not None:
                store.discard(staged)
            if old is not None:
                store.retire(old)
    if op == "remove":
        return {"ok": True}
    return {"ok": True, "files_sha256": files_sha256(new_skill.skill(skill))}


# --- the sandbox ---------------------------------------------------------------------


def build_argv(
    config: Config,
    mounts: list[tuple[str, str]],
    *,
    seccomp_fd: int,
    command: str,
    skills: list[tuple[str, str | None, str]] = (),
) -> list[str]:
    """The bwrap command line for one command. Pure: no filesystem access. Phase 1's
    argv (history_shell.build_argv) plus, from protocol v2, an empty /skills and the
    `skills` mounts in it (from `skills_mounts`): `("--dir", None, inside)` or
    `(flag, host, inside)`. Only an "edit" run has a writable one (`--bind`)."""
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
    argv += ["--dir", SANDBOX_SKILLS]
    for flag, host, inside in skills:
        argv += [flag, inside] if host is None else [flag, host, inside]
    # The root tmpfs (and with it the directories bwrap made above the history
    # mounts) and /dev (a tmpfs of its own, /dev/shm inside it) are read only. Only
    # /scratch and /tmp are writable, each with its own size, and /skills/own in an
    # "edit" run (a bind of the work tmpfs, which has its own size). --remount-ro is
    # not recursive, so it leaves those mounts as they are.
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
    skills: list[tuple[str, str | None, str]] = (),
) -> Result:
    """Run `command` once in a sandbox. The checks are the caller's. When `peer_fd`
    (the client's socket) hangs up, the command is killed and `PeerGone` raised. Only
    POLLHUP counts: a client that half-closes its write side after the request has not
    left."""
    seccomp_fd = os.open(config.seccomp, os.O_RDONLY)
    try:
        os.set_inheritable(seccomp_fd, True)
        argv = build_argv(
            config, mounts, seccomp_fd=seccomp_fd, command=command, skills=skills
        )
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
    if kind == "conflict":
        error = f"{error} Nothing was changed."
    elif kind != "internal" and "Nothing was run" not in error:
        error = f"{error} Nothing was run."
    return _answer(config, {"ok": False, "kind": kind, "error": error})


def run_answer(config: Config, result: Result, skills: dict | None = None) -> dict:
    """`skills` is None for a run with no character, else `{"changed", "kept", "why"}`:
    kept false means nothing was written and `why` says so in a sentence she can act
    on. changed is true only when something was kept."""
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
            "skills": skills,
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
    if op in ("sync", "remove"):
        check_keys(msg, SYNC_KEYS if op == "sync" else REMOVE_KEYS)
        return _answer(config, handle_change(msg, base))
    if op != "run":
        raise Refused(f"Unknown operation {op!r}. Nothing was run.")
    check_keys(msg, RUN_KEYS)
    request = validate_run(msg, base)
    check_installed(config)
    skills, state, fallback = skills_mounts(request, config, base)
    oom_before = oom_kills()
    try:
        result = execute(
            config,
            request.mounts,
            request.command,
            limits=limits,
            peer_fd=peer_fd,
            set_oom=set_oom,
            skills=skills,
        )
        if state is not None:
            own = finish_edit(state, request, result, config.skills_work, oom_before)
        elif fallback is not None:
            own = fallback
        elif request.own == "read":
            own = {"changed": False, "kept": False, "why": None}
        else:
            own = None
    finally:
        if state is not None:
            shutil.rmtree(state.work, ignore_errors=True)
            state.store.close()
    return run_answer(config, result, own)


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
        "--skills-work",
        required=True,
        help="the unit's TemporaryFileSystem, where her folder is copied in",
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
    config = replace(config, unit_digest=args.unit_digest, skills_work=args.skills_work)
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
