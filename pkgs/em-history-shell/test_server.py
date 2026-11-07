#!/usr/bin/env python3
"""Tests for the em-history-shell server (pkgs/em-history-shell/server.py): the pure
parts (validation, the bwrap argv, the root rules, framing) and the protocol over a
socketpair with a FAKE bwrap that runs the command with plain `sh`. The real sandbox
is not tested here: EM's escape suite does that, black-box, against the deployed
server.

Run:  python3 pkgs/em-history-shell/test_server.py
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import textwrap
import threading
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import server  # noqa: E402
from server import Limits, Refused  # noqa: E402

SH = shutil.which("sh")
UID = os.getuid()
STORE_A = "/nix/store/" + "a" * 32 + "-tools"
STORE_B = "/nix/store/" + "b" * 32 + "-dep"
SERVER_PATH = "/nix/store/" + "c" * 32 + "-em-history-shell"
UNIT_DIGEST = "e" * 64
LIBSECCOMP = "2.6.0"
POLICY_SHA = "f" * 64

FAKE_BWRAP = """\
#!{python}
import json, os, sys
argv = sys.argv[1:]
fd = int(argv[argv.index("--seccomp") + 1])
fds = {{}}
for name in os.listdir("/proc/self/fd"):
    try:
        fds[name] = os.readlink("/proc/self/fd/" + name)
    except OSError:
        pass
with open({log!r}, "w") as handle:
    json.dump({{
        "argv": argv,
        "seccomp_head": os.pread(fd, 64, 0).decode("latin-1"),
        "fds": fds,
        "env": dict(os.environ),
        "oom": open("/proc/self/oom_score_adj").read().strip(),
    }}, handle)
os.environ["PATH"] = {path!r}  # the real sandbox has /bin; the stand-in needs a PATH
# The /skills mounts, as host paths, so a test command can stand in for the sandbox.
for flag, env in (("/skills/own", "SKILLS_OWN"), ("/skills/shared", "SKILLS_SHARED"),
                  ("/skills/characters", "SKILLS_CHARACTERS")):
    for i, word in enumerate(argv):
        if word == flag and argv[i - 2] in ("--bind", "--ro-bind"):
            os.environ[env] = argv[i - 1]
os.execv({sh!r}, ["sh", "-c", argv[-1]])
"""


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="em-hs-test-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.base = os.path.join(self.tmp, "base")
        os.mkdir(self.base)
        self.root = self.make_root("agent-history")
        self.log = os.path.join(self.tmp, "bwrap.json")
        self.bwrap = os.path.join(self.tmp, "fake-bwrap")
        with open(self.bwrap, "w") as handle:
            handle.write(FAKE_BWRAP.format(python=sys.executable, log=self.log, sh=SH, path=os.environ.get("PATH", "")))
        os.chmod(self.bwrap, 0o755)
        self.seccomp = os.path.join(self.tmp, "seccomp.bpf")
        with open(self.seccomp, "wb") as handle:
            handle.write(b"BPF-fake-program")
        self.tools = os.path.join(self.tmp, "tools")
        os.makedirs(os.path.join(self.tools, "bin"))
        self.skills_own = os.path.join(self.base, server.SKILLS_OWN)
        os.mkdir(self.skills_own, 0o750)
        self.work = os.path.join(self.tmp, "work")
        os.mkdir(self.work, 0o700)
        self.config = server.Config(
            server=SERVER_PATH,
            bwrap=self.bwrap,
            tools=self.tools,
            seccomp=self.seccomp,
            closure=(self.tools,),
            unit_digest=UNIT_DIGEST,
            libseccomp_version=LIBSECCOMP,
            policy_sha256=POLICY_SHA,
            skills_work=self.work,
        )

    def make_root(self, name="agent-history", marker=True):
        root = os.path.join(self.base, name)
        os.makedirs(os.path.join(root, "jonathan", "warrior"), exist_ok=True)
        os.makedirs(os.path.join(root, "jonathan", "coach"), exist_ok=True)
        os.makedirs(os.path.join(root, "livia", "son"), exist_ok=True)
        if marker:
            with open(os.path.join(root, server.ROOT_MARKER), "w") as handle:
                handle.write("")
        return root

    def run_request(self, **over):
        msg = {
            "v": 2,
            "op": "run",
            "root": self.root,
            "view": "*",
            "agent": "jonathan/warrior",
            "command": "echo hi",
            "character": None,
            "own": None,
        }
        msg.update(over)
        return msg


class TestViewGrammar(unittest.TestCase):
    def test_star(self):
        self.assertEqual(server.parse_view("*"), ("*",))
        self.assertEqual(server.parse_view(" * "), ("*",))

    def test_entries_sorted_and_distinct(self):
        self.assertEqual(
            server.parse_view("b/x, a/y,b/x"), ("a/y", "b/x")
        )

    def test_bad(self):
        for bad in (
            "", "  ", "*,a/b", "a", "a/b/c", "/a", "a/", ".a/b", "a/.b", "a/..",
            "../x", "a b/c", "a/b;c", "a\n/b", "*/x", ",", "a/b,", None, 5, ["a/b"],
        ):
            with self.subTest(bad=bad), self.assertRaises(Refused):
                server.parse_view(bad)


class TestAgentAndCommand(unittest.TestCase):
    def test_agent_in_view_or_star(self):
        self.assertEqual(server.check_agent("a/b", ("a/b", "a/c")), "a/b")
        self.assertEqual(server.check_agent("x/y", ("*",)), "x/y")
        with self.assertRaises(Refused):
            server.check_agent("x/y", ("a/b",))
        for bad in ("a", "a/b/c", "", ".a/b", 5, None, "a/b "):
            with self.subTest(bad=bad), self.assertRaises(Refused):
                server.check_agent(bad, ("*",))

    def test_command_limits(self):
        self.assertEqual(server.check_command("ls"), "ls")
        self.assertEqual(
            server.check_command("x" * server.MAX_COMMAND_CHARS),
            "x" * server.MAX_COMMAND_CHARS,
        )
        for bad in ("", "  \n", "a\x00b", "x" * (server.MAX_COMMAND_CHARS + 1), None, 5):
            with self.subTest(bad=bad), self.assertRaises(Refused):
                server.check_command(bad)


class TestRoot(Base):
    def test_good_root(self):
        self.assertEqual(
            server.check_root(self.root, self.base), os.path.realpath(self.root)
        )

    def test_profile_roots(self):
        for name in ("agent-history-livia", "agent-history-a_b-c"):
            root = self.make_root(name)
            self.assertEqual(server.check_root(root, self.base), root)

    def test_name_rule(self):
        for name in (
            "agent-history.moved-2026", "agent-history-", "agent-history-a.b",
            "agent-history2", "other", "agent-history-a b", ".agent-history",
        ):
            root = self.make_root(name)
            with self.subTest(name=name), self.assertRaises(Refused):
                server.check_root(root, self.base)

    def test_not_a_direct_child(self):
        nested = os.path.join(self.base, "sub")
        os.mkdir(nested)
        deep = self.make_root("agent-history")  # exists, for contrast
        other = os.path.join(nested, "agent-history")
        shutil.copytree(deep, other)
        for bad in (
            other,
            self.root + "/",
            self.root + "/../agent-history",
            os.path.join(self.base, "..", "base", "agent-history"),
            "agent-history",
            "",
            self.root + "\x00",
            "/",
            self.base,
        ):
            with self.subTest(bad=bad), self.assertRaises(Refused):
                server.check_root(bad, self.base)
        for bad in (None, 5, ["x"]):
            with self.assertRaises(Refused):
                server.check_root(bad, self.base)

    def test_symlinked_root_refused(self):
        real = self.make_root("agent-history-real")
        link = os.path.join(self.base, "agent-history-link")
        os.symlink(real, link)
        with self.assertRaises(Refused):
            server.check_root(link, self.base)

    def test_root_that_is_a_file(self):
        path = os.path.join(self.base, "agent-history-file")
        with open(path, "w"):
            pass
        with self.assertRaises(Refused):
            server.check_root(path, self.base)

    def test_missing_root(self):
        with self.assertRaises(Refused):
            server.check_root(os.path.join(self.base, "agent-history-none"), self.base)

    def test_marker_rules(self):
        root = self.make_root("agent-history-nomarker", marker=False)
        with self.assertRaises(Refused):
            server.check_root(root, self.base)
        os.symlink("/etc/passwd", os.path.join(root, server.ROOT_MARKER))
        with self.assertRaises(Refused):
            server.check_root(root, self.base)
        root2 = self.make_root("agent-history-dirmarker", marker=False)
        os.mkdir(os.path.join(root2, server.ROOT_MARKER))
        with self.assertRaises(Refused):
            server.check_root(root2, self.base)

    def test_symlinked_base_is_fine(self):
        link = os.path.join(self.tmp, "base-link")
        os.symlink(self.base, link)
        root = os.path.join(link, "agent-history")
        self.assertEqual(
            server.check_root(root, link), os.path.realpath(self.root)
        )


class TestMounts(Base):
    def test_star_binds_real_account_dirs_only(self):
        os.symlink("/etc", os.path.join(self.root, "evil"))
        with open(os.path.join(self.root, "afile"), "w"):
            pass
        os.mkdir(os.path.join(self.root, ".hidden"))
        os.mkdir(os.path.join(self.root, "bad name"))
        mounts = server.view_mounts(self.root, ("*",))
        self.assertEqual(
            mounts,
            [
                (f"{self.root}/jonathan", "/history/jonathan"),
                (f"{self.root}/livia", "/history/livia"),
            ],
        )

    def test_view_entries(self):
        mounts = server.view_mounts(self.root, ("jonathan/warrior", "livia/son"))
        self.assertEqual(
            mounts,
            [
                (f"{self.root}/jonathan/warrior", "/history/jonathan/warrior"),
                (f"{self.root}/livia/son", "/history/livia/son"),
            ],
        )
        server.check_mounts(mounts, self.root)

    def test_missing_dir_refused(self):
        mounts = server.view_mounts(self.root, ("jonathan/nobody",))
        with self.assertRaises(Refused) as ctx:
            server.check_mounts(mounts, self.root)
        self.assertNotIn(self.tmp, str(ctx.exception))  # no host path in the sentence

    def test_symlink_dir_refused(self):
        os.symlink(self.tmp, os.path.join(self.root, "jonathan", "link"))
        with self.assertRaises(Refused):
            server.check_mounts(
                server.view_mounts(self.root, ("jonathan/link",)), self.root
            )

    def test_link_in_the_middle_refused(self):
        outside = os.path.join(self.tmp, "outside")
        os.makedirs(os.path.join(outside, "agent"))
        os.symlink(outside, os.path.join(self.root, "mid"))
        with self.assertRaises(Refused):
            server.check_mounts(
                server.view_mounts(self.root, ("mid/agent",)), self.root
            )

    def test_unreadable_root_is_unavailable(self):
        if UID == 0:
            self.skipTest("root reads everything")
        os.chmod(self.root, 0)
        self.addCleanup(os.chmod, self.root, 0o755)
        with self.assertRaises(Refused) as ctx:
            server.account_dirs(self.root)
        self.assertEqual(ctx.exception.kind, "unavailable")

    def test_validate_run(self):
        req = server.validate_run(self.run_request(view="jonathan/warrior"), self.base)
        self.assertEqual(req.view, ("jonathan/warrior",))
        self.assertEqual(req.root, os.path.realpath(self.root))
        self.assertEqual(
            req.mounts,
            [(f"{req.root}/jonathan/warrior", "/history/jonathan/warrior")],
        )
        with self.assertRaises(Refused):  # agent outside its view
            server.validate_run(
                self.run_request(view="jonathan/coach"), self.base
            )


class TestBuildArgv(unittest.TestCase):
    def test_golden(self):
        config = server.Config(
            server=SERVER_PATH,
            bwrap="/nix/store/" + "d" * 32 + "-bubblewrap/bin/bwrap",
            tools=STORE_A,
            seccomp="/unused",
            closure=(STORE_A, STORE_B),
        )
        argv = server.build_argv(
            config,
            [("/b/jonathan/warrior", "/history/jonathan/warrior")],
            seccomp_fd=7,
            command="echo 'hi there'; ls",
        )
        self.assertEqual(
            argv,
            [
                "/nix/store/" + "d" * 32 + "-bubblewrap/bin/bwrap",
                "--unshare-user", "--unshare-pid", "--unshare-net", "--unshare-ipc",
                "--unshare-uts", "--unshare-cgroup", "--disable-userns",
                "--die-with-parent", "--new-session", "--clearenv",
                "--cap-drop", "ALL", "--seccomp", "7",
                "--ro-bind", STORE_A, STORE_A,
                "--ro-bind", STORE_B, STORE_B,
                "--symlink", STORE_A + "/bin", "/bin",
                "--proc", "/proc", "--dev", "/dev",
                "--size", "67108864", "--tmpfs", "/scratch",
                "--size", "16777216", "--tmpfs", "/tmp",
                "--dir", "/history",
                "--ro-bind", "/b/jonathan/warrior", "/history/jonathan/warrior",
                "--dir", "/skills",
                "--remount-ro", "/", "--remount-ro", "/dev",
                "--setenv", "PATH", "/bin",
                "--setenv", "HOME", "/scratch",
                "--setenv", "TMPDIR", "/tmp",
                "--setenv", "LANG", "C.UTF-8",
                "--setenv", "PYTHONNOUSERSITE", "1",
                "--setenv", "PYTHONDONTWRITEBYTECODE", "1",
                "--chdir", "/scratch",
                "--", "/bin/bash", "--noprofile", "--norc", "-c",
                "echo 'hi there'; ls",
            ],
        )

    def test_command_is_one_argument_after_double_dash(self):
        config = server.Config(SERVER_PATH, "/b", STORE_A, "/s", (STORE_A,))
        nasty = "--ro-bind / /x; $(rm -rf /)\n"
        argv = server.build_argv(config, [], seccomp_fd=3, command=nasty)
        self.assertEqual(argv[-1], nasty)
        self.assertEqual(argv.count("--"), 1)
        self.assertNotIn("/x", argv[:-1])


class TestConfig(unittest.TestCase):
    def write(self, tmp, **over):
        raw = {
            "server": SERVER_PATH,
            "bwrap": "/nix/store/" + "d" * 32 + "-bubblewrap/bin/bwrap",
            "tools": STORE_A,
            "seccomp": "/nix/store/" + "e" * 32 + "-seccomp/seccomp.bpf",
            "closure": [STORE_B, STORE_A],
            "libseccomp_version": LIBSECCOMP,
            "policy_sha256": POLICY_SHA,
        }
        raw.update(over)
        path = os.path.join(tmp, "config.json")
        with open(path, "w") as handle:
            json.dump(raw, handle)
        return path

    def test_good(self):
        with tempfile.TemporaryDirectory() as tmp:
            config = server.load_config(self.write(tmp))
        self.assertEqual(config.closure, (STORE_A, STORE_B))
        self.assertEqual(config.server, SERVER_PATH)
        self.assertEqual(config.libseccomp_version, LIBSECCOMP)
        self.assertEqual(config.policy_sha256, POLICY_SHA)

    def test_bad(self):
        cases = {
            "bwrap not store": {"bwrap": "/usr/bin/bwrap"},
            "bwrap dotdot": {"bwrap": "/nix/store/" + "d" * 32 + "-b/../../bin/x"},
            "seccomp missing": {"seccomp": None},
            "tools not in closure": {"closure": [STORE_B]},
            "empty closure": {"closure": []},
            "closure junk": {"closure": [STORE_A, "/etc"]},
            "server junk": {"server": "/tmp/x"},
            "libseccomp missing": {"libseccomp_version": None},
            "libseccomp junk": {"libseccomp_version": "2.6"},
            "libseccomp newline": {"libseccomp_version": "2.6.0\n"},
            "policy sha missing": {"policy_sha256": None},
            "policy sha upper": {"policy_sha256": "F" * 64},
            "policy sha short": {"policy_sha256": "f" * 63},
        }
        for label, over in cases.items():
            with self.subTest(label), tempfile.TemporaryDirectory() as tmp:
                with self.assertRaises(ValueError):
                    server.load_config(self.write(tmp, **over))


class TestInstalled(Base):
    def test_ok(self):
        server.check_installed(self.config)

    def test_missing_pieces_are_unavailable(self):
        for label, change in (
            ("bwrap", dict(bwrap=self.bwrap + "-gone")),
            ("seccomp", dict(seccomp=self.seccomp + "-gone")),
            ("tool", dict(closure=(self.tools + "-gone",))),
            ("tools bin", dict(tools=self.tmp, closure=(self.tmp,))),
        ):
            config = server.Config(**{**self.config.__dict__, **change})
            with self.subTest(label), self.assertRaises(Refused) as ctx:
                server.check_installed(config)
            self.assertEqual(ctx.exception.kind, "unavailable")

    def test_bwrap_not_executable(self):
        os.chmod(self.bwrap, 0o644)
        with self.assertRaises(Refused):
            server.check_installed(self.config)


class TestFraming(unittest.TestCase):
    def pair(self):
        a, b = socket.socketpair()
        self.addCleanup(a.close)
        self.addCleanup(b.close)
        return a, b

    def test_line(self):
        srv, cli = self.pair()
        cli.sendall(b'{"a":1}\n')
        self.assertEqual(server.read_line(srv, limit=100, timeout_s=2), b'{"a":1}')

    def test_split_across_sends(self):
        srv, cli = self.pair()
        cli.sendall(b"abc")
        threading.Timer(0.1, cli.sendall, args=(b"def\n",)).start()
        self.assertEqual(server.read_line(srv, limit=100, timeout_s=2), b"abcdef")

    def test_exactly_at_limit_and_over(self):
        srv, cli = self.pair()
        cli.sendall(b"x" * 100 + b"\n")
        self.assertEqual(server.read_line(srv, limit=100, timeout_s=2), b"x" * 100)
        srv, cli = self.pair()
        cli.sendall(b"x" * 101 + b"\n")
        with self.assertRaises(Refused) as ctx:
            server.read_line(srv, limit=100, timeout_s=2)
        self.assertIn("larger than", str(ctx.exception))

    def test_oversize_without_newline(self):
        srv, cli = self.pair()
        cli.sendall(b"x" * 5000)
        with self.assertRaises(Refused):
            server.read_line(srv, limit=100, timeout_s=2)

    def test_eof_before_anything_is_none(self):
        srv, cli = self.pair()
        cli.close()
        self.assertIsNone(server.read_line(srv, limit=100, timeout_s=2))

    def test_eof_mid_line_is_refused(self):
        srv, cli = self.pair()
        cli.sendall(b"abc")
        cli.close()
        with self.assertRaises(Refused):
            server.read_line(srv, limit=100, timeout_s=2)

    def test_slow_client(self):
        srv, cli = self.pair()
        cli.sendall(b"abc")
        t0 = time.monotonic()
        with self.assertRaises(Refused):
            server.read_line(srv, limit=100, timeout_s=0.3)
        self.assertLess(time.monotonic() - t0, 3)

    def test_bytes_after_newline_are_ignored(self):
        srv, cli = self.pair()
        cli.sendall(b"one\ntwo\n")
        self.assertEqual(server.read_line(srv, limit=100, timeout_s=2), b"one")


class TestPeerCred(unittest.TestCase):
    def test_peer_uid_of_a_socketpair_is_ours(self):
        a, b = socket.socketpair()
        self.addCleanup(a.close)
        self.addCleanup(b.close)
        self.assertEqual(server.peer_uid(a), UID)
        self.assertEqual(server.peer_uid(b), UID)


class Exchange(Base):
    """Run `serve` on one end of a socketpair and talk to it from the other."""

    def exchange(self, payload, *, allowed_uid=None, limits=Limits(), after_send=None):
        srv, cli = socket.socketpair()
        self.addCleanup(cli.close)
        result = {}

        def target():
            server.serve(
                srv,
                self.config,
                allowed_uid=UID if allowed_uid is None else allowed_uid,
                base=self.base,
                limits=limits,
            )
            result["done"] = time.monotonic()

        thread = threading.Thread(target=target, daemon=True)
        thread.start()
        if payload is not None:
            body = payload if isinstance(payload, bytes) else json.dumps(payload).encode() + b"\n"
            try:
                cli.sendall(body)
            except (BrokenPipeError, ConnectionResetError):
                pass  # the server refused and hung up before we finished; read its answer
        if after_send:
            return after_send(cli, thread)
        cli.settimeout(20)
        data = b""
        while True:
            try:
                chunk = cli.recv(1 << 20)
            except ConnectionResetError:  # unread request bytes at close: answer first
                break
            if not chunk:
                break
            data += chunk
        thread.join(10)
        self.assertFalse(thread.is_alive())
        return data

    def ask(self, request, **kw):
        data = self.exchange(request, **kw)
        self.assertTrue(data.endswith(b"\n"), data)
        self.assertEqual(data.count(b"\n"), 1)  # one line each way
        answer = json.loads(data)
        self.assertEqual(answer["v"], 2)
        self.assertEqual(answer["server"], SERVER_PATH)  # on every answer
        self.assertEqual(answer["unit_digest"], UNIT_DIGEST)  # and so is the unit digest
        return answer

    def assertRefused(self, answer, kind, *words):
        self.assertFalse(answer["ok"], answer)
        self.assertEqual(answer["kind"], kind)
        for word in words:
            self.assertIn(word, answer["error"])
        return answer

    def bwrap_log(self):
        with open(self.log) as handle:
            return json.load(handle)


class TestProtocol(Exchange):
    def test_ping(self):
        answer = self.ask({"v": 2, "op": "ping"})
        self.assertEqual(
            answer,
            {
                "v": 2,
                "ok": True,
                "uid": UID,
                "seccomp_sha256": hashlib.sha256(b"BPF-fake-program").hexdigest(),
                "libseccomp_version": LIBSECCOMP,
                "policy_sha256": POLICY_SHA,
                "server": SERVER_PATH,
                "unit_digest": UNIT_DIGEST,
            },
        )
        self.assertFalse(os.path.exists(self.log))  # nothing ran

    def test_ping_with_extra_key_refused(self):
        self.assertRefused(
            self.ask({"v": 2, "op": "ping", "command": "id"}), "refused", "unexpected"
        )

    def test_ping_when_broken_is_unavailable(self):
        os.unlink(self.seccomp)
        self.assertRefused(self.ask({"v": 2, "op": "ping"}), "unavailable")

    def test_version_mismatch(self):
        for v in (1, 3, 0, "2", 2.0, True, None):
            with self.subTest(v=v):
                self.assertRefused(
                    self.ask({"v": v, "op": "ping"}), "version", "version 2"
                )
        self.assertRefused(self.ask({"op": "ping"}), "version")
        # the version is judged before the other fields
        self.assertRefused(self.ask({"v": 3, "op": "future", "zzz": 1}), "version")

    def test_not_json(self):
        for raw in (b"hello\n", b"\xff\xfe\n", b"\n", b"[1]\n", b'"x"\n', b"null\n",
                    b"[" * 100000 + b"\n"):
            with self.subTest(raw=raw[:20]):
                self.assertRefused(self.ask(raw), "refused")

    def test_unknown_op(self):
        self.assertRefused(self.ask({"v": 2, "op": "stop"}), "refused", "Unknown operation")
        self.assertRefused(self.ask({"v": 2}), "refused", "Unknown operation")

    def test_exact_key_set(self):
        good = self.run_request()
        for label, msg in (
            ("missing", {k: v for k, v in good.items() if k != "agent"}),
            ("extra", {**good, "env": {"X": "1"}}),
        ):
            with self.subTest(label):
                self.assertRefused(self.ask(msg), "refused", "wrong fields")
        both = {k: v for k, v in good.items() if k != "agent"}
        both["env"] = 1
        self.assertRefused(
            self.ask(both), "refused", "missing agent and unexpected env"
        )
        self.assertFalse(os.path.exists(self.log))

    def test_oversize_request(self):
        data = self.exchange(b"x" * (server.MAX_REQUEST_BYTES + 10) + b"\n")
        answer = json.loads(data)
        self.assertRefused(answer, "refused", "larger than")

    def test_empty_connection_gets_no_answer(self):
        def close_at_once(cli, thread):
            cli.shutdown(socket.SHUT_WR)
            thread.join(5)
            self.assertFalse(thread.is_alive())
            return cli.recv(100)

        self.assertEqual(self.exchange(None, after_send=close_at_once), b"")

    def test_other_uid_is_refused_before_reading_or_running(self):
        answer = self.ask(self.run_request(), allowed_uid=UID + 1)
        self.assertRefused(answer, "refused", "only answers the user")
        self.assertFalse(os.path.exists(self.log))

    def test_refusals_do_not_run_anything(self):
        for label, over in (
            ("bad view", {"view": "a"}),
            ("agent outside view", {"view": "livia/son"}),
            ("empty command", {"command": " "}),
            ("nul", {"command": "a\x00b"}),
            ("long", {"command": "x" * 20000}),
            ("root elsewhere", {"root": "/tmp"}),
            ("root with dotdot", {"root": self.root + "/../agent-history"}),
            ("view missing dir", {"view": "jonathan/nobody", "agent": "jonathan/nobody"}),
        ):
            with self.subTest(label):
                self.assertRefused(self.ask(self.run_request(**over)), "refused", "Nothing")
        self.assertFalse(os.path.exists(self.log))

    def test_run(self):
        answer = self.ask(self.run_request(command="echo out; echo err >&2; exit 3"))
        self.assertEqual(
            answer,
            {
                "v": 2,
                "ok": True,
                "exit_code": 3,
                "stdout": "out\n",
                "stderr": "err\n",
                "timed_out": False,
                "flooded": False,
                "stdout_dropped": 0,
                "stderr_dropped": 0,
                "scratch_reset": False,
                "skills": None,
                "server": SERVER_PATH,
                "unit_digest": UNIT_DIGEST,
            },
        )

    def test_run_sees_the_phase1_argv(self):
        self.ask(self.run_request(view="jonathan/warrior", command="true"))
        info = self.bwrap_log()
        real = os.path.realpath(self.root)
        self.assertEqual(
            info["argv"],
            server.build_argv(
                self.config,
                [(f"{real}/jonathan/warrior", "/history/jonathan/warrior")],
                seccomp_fd=int(info["argv"][info["argv"].index("--seccomp") + 1]),
                command="true",
            )[1:],
        )
        self.assertEqual(info["seccomp_head"], "BPF-fake-program")

    def test_star_view_binds_each_account(self):
        self.ask(self.run_request(command="true"))
        argv = self.bwrap_log()["argv"]
        real = os.path.realpath(self.root)
        self.assertIn(f"{real}/jonathan", argv)
        self.assertIn(f"{real}/livia", argv)
        self.assertNotIn(real, argv)

    def test_child_gets_no_socket_and_an_empty_env_and_max_oom(self):
        self.ask(self.run_request(command="true"))
        info = self.bwrap_log()
        # python adds LC_CTYPE to an empty environment itself
        self.assertEqual({k: v for k, v in info["env"].items() if k != "LC_CTYPE"}, {})
        self.assertEqual(info["oom"], "1000")
        for name, target in info["fds"].items():
            self.assertFalse(target.startswith("socket:"), (name, target))

    def test_timeout(self):
        t0 = time.monotonic()
        answer = self.ask(
            self.run_request(command="echo before; sleep 30"),
            limits=Limits(timeout_s=0.7),
        )
        self.assertLess(time.monotonic() - t0, 8)
        self.assertTrue(answer["ok"])
        self.assertTrue(answer["timed_out"])
        self.assertEqual(answer["stdout"], "before\n")
        self.assertLess(answer["exit_code"], 0)  # killed by a signal

    def test_output_caps_count_the_rest(self):
        answer = self.ask(
            self.run_request(command="head -c 5000 /dev/zero | tr '\\0' o; head -c 900 /dev/zero | tr '\\0' e >&2"),
            limits=Limits(stdout_cap=1000, stderr_cap=100),
        )
        self.assertEqual(len(answer["stdout"]), 1000)
        self.assertEqual(answer["stdout_dropped"], 4000)
        self.assertEqual(len(answer["stderr"]), 100)
        self.assertEqual(answer["stderr_dropped"], 800)
        self.assertFalse(answer["flooded"])

    def test_flood_stops_the_command(self):
        t0 = time.monotonic()
        answer = self.ask(
            self.run_request(command="yes"),
            limits=Limits(drain_ceiling=200_000),
        )
        self.assertLess(time.monotonic() - t0, 10)
        self.assertTrue(answer["flooded"])
        self.assertFalse(answer["timed_out"])
        self.assertGreater(answer["stdout_dropped"], 200_000)

    def test_non_utf8_output_is_replaced(self):
        answer = self.ask(self.run_request(command="printf '\\377\\376ok'"))
        self.assertEqual(answer["stdout"], "\ufffd\ufffdok")

    def test_half_close_is_not_a_disconnect(self):
        def half_close(cli, thread):
            cli.shutdown(socket.SHUT_WR)
            cli.settimeout(20)
            data = b""
            while True:
                chunk = cli.recv(1 << 16)
                if not chunk:
                    break
                data += chunk
            thread.join(5)
            return data

        data = self.exchange(
            self.run_request(command="sleep 0.5; echo still here"), after_send=half_close
        )
        self.assertEqual(json.loads(data)["stdout"], "still here\n")

    def test_peer_close_kills_the_command(self):
        pidfile = os.path.join(self.tmp, "pid")

        def disconnect(cli, thread):
            for _ in range(100):
                if os.path.exists(pidfile) and os.path.getsize(pidfile):
                    break
                time.sleep(0.05)
            else:
                self.fail("the command never started")
            with open(pidfile) as handle:
                pid = int(handle.read())
            os.kill(pid, 0)  # alive now
            t0 = time.monotonic()
            cli.close()
            thread.join(8)
            self.assertFalse(thread.is_alive(), "serve did not notice the disconnect")
            self.assertLess(time.monotonic() - t0, 6)
            for _ in range(50):
                try:
                    os.kill(pid, 0)
                except ProcessLookupError:
                    return pid
                time.sleep(0.05)
            self.fail("the command is still running after the client left")

        self.exchange(
            self.run_request(command=f"echo $$ > {pidfile}; sleep 60"),
            after_send=disconnect,
        )

    def test_bwrap_failing_to_start_is_unavailable(self):
        os.unlink(self.bwrap)
        self.assertRefused(self.ask(self.run_request()), "unavailable", "Nothing was run")

    def test_internal_error_is_an_answer(self):
        real = server.handle_request

        def boom(*a, **k):
            raise RuntimeError("secret detail")

        server.handle_request = boom
        self.addCleanup(setattr, server, "handle_request", real)
        answer = self.ask(self.run_request())
        self.assertRefused(answer, "internal", "internal error")
        self.assertNotIn("secret", answer["error"])


class TestWholeProcess(unittest.TestCase):
    """server.py as systemd runs it: a process whose fd 0 is the connected socket."""

    def store_python(self):
        real = os.path.realpath(sys.executable)
        if not server._STORE_FILE.fullmatch(real):
            self.skipTest("needs an interpreter in the nix store")
        return real

    def write_config(self, tmp, py):
        store = "/".join(py.split("/")[:4])
        cfg = os.path.join(tmp, "config.json")
        with open(cfg, "w") as handle:
            json.dump(
                {"server": store, "bwrap": py, "tools": store, "seccomp": py,
                 "closure": [store], "libseccomp_version": LIBSECCOMP,
                 "policy_sha256": POLICY_SHA},
                handle,
            )
        return store, cfg

    def command(self, tmp, cfg, *, uid=None, digest=UNIT_DIGEST):
        argv = [sys.executable, os.path.join(HERE, "server.py"),
                "--allowed-uid", str(UID if uid is None else uid),
                "--base", tmp, "--config", cfg, "--skills-work", tmp]
        if digest is not None:
            argv += ["--unit-digest", digest]
        return argv

    def talk(self, argv, request):
        srv, cli = socket.socketpair()
        self.addCleanup(cli.close)
        proc = subprocess.Popen(argv, stdin=srv, stdout=srv, stderr=subprocess.PIPE)
        srv.close()
        if request is not None:
            cli.sendall(request)
        cli.settimeout(20)
        data = b""
        while True:
            try:
                chunk = cli.recv(65536)
            except ConnectionResetError:  # unread request bytes at close: answer first
                break
            if not chunk:
                break
            data += chunk
        code = proc.wait(20)
        err = proc.stderr.read()
        proc.stderr.close()
        return code, data, err

    def test_ping_over_fd0(self):
        py = self.store_python()
        with tempfile.TemporaryDirectory() as tmp:
            store, cfg = self.write_config(tmp, py)
            code, data, err = self.talk(self.command(tmp, cfg), b'{"v":2,"op":"ping"}\n')
            self.assertEqual(code, 0, err)
            answer = json.loads(data)
            self.assertTrue(answer["ok"])
            self.assertEqual(answer["server"], store)
            self.assertEqual(answer["uid"], UID)
            self.assertEqual(answer["unit_digest"], UNIT_DIGEST)
            self.assertEqual(answer["libseccomp_version"], LIBSECCOMP)
            self.assertEqual(answer["policy_sha256"], POLICY_SHA)
            with open(py, "rb") as handle:
                self.assertEqual(
                    answer["seccomp_sha256"], hashlib.sha256(handle.read()).hexdigest()
                )

    def test_not_a_socket_is_a_startup_error(self):
        py = self.store_python()
        with tempfile.TemporaryDirectory() as tmp:
            _, cfg = self.write_config(tmp, py)
            done = subprocess.run(
                self.command(tmp, cfg, uid=1),
                stdin=subprocess.DEVNULL, capture_output=True, timeout=20,
            )
        self.assertEqual(done.returncode, 2)
        self.assertIn(b"not a connected unix socket", done.stderr)

    def test_not_a_socket_still_tries_to_say_so_on_fd0(self):
        py = self.store_python()
        with tempfile.TemporaryDirectory() as tmp:
            store, cfg = self.write_config(tmp, py)
            path = os.path.join(tmp, "stdin")
            with open(path, "w+b") as handle:
                done = subprocess.run(
                    self.command(tmp, cfg, uid=1), stdin=handle,
                    capture_output=True, timeout=20,
                )
                handle.seek(0)
                written = handle.read()
        self.assertEqual(done.returncode, 2)
        self.assertEqual(
            json.loads(written),
            {"v": 2, "ok": False, "kind": "unavailable",
             "error": "The history shell is broken on this host. Nothing was run.",
             "server": store, "unit_digest": UNIT_DIGEST},
        )

    def test_bad_config_is_a_startup_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            done = subprocess.run(
                self.command(tmp, os.path.join(tmp, "no"), uid=1),
                stdin=subprocess.DEVNULL, capture_output=True, timeout=20,
            )
        self.assertEqual(done.returncode, 2)
        self.assertIn(b"bad config", done.stderr)

    def test_bad_config_answers_unavailable_on_the_socket(self):
        with tempfile.TemporaryDirectory() as tmp:
            code, data, err = self.talk(
                self.command(tmp, os.path.join(tmp, "no")), b'{"v":2,"op":"ping"}\n'
            )
        self.assertEqual(code, 2)
        self.assertIn(b"bad config", err)
        self.assertEqual(data.count(b"\n"), 1)
        answer = json.loads(data)
        # no config, so no server to name; the digest comes from the command line
        self.assertEqual(
            answer,
            {"v": 2, "ok": False, "kind": "unavailable",
             "error": "The history shell is broken on this host. Nothing was run.",
             "unit_digest": UNIT_DIGEST},
        )

    def test_bad_unit_digest_is_refused_at_startup(self):
        py = self.store_python()
        with tempfile.TemporaryDirectory() as tmp:
            _, cfg = self.write_config(tmp, py)
            for bad in ("", "xyz", "E" * 64, "e" * 63, "e" * 65):
                with self.subTest(bad=bad):
                    done = subprocess.run(
                        self.command(tmp, cfg, digest=bad),
                        stdin=subprocess.DEVNULL, capture_output=True, timeout=20,
                    )
                    self.assertEqual(done.returncode, 2)
            done = subprocess.run(
                self.command(tmp, cfg, digest=None),
                stdin=subprocess.DEVNULL, capture_output=True, timeout=20,
            )
            self.assertEqual(done.returncode, 2)


class TestPolicyHash(unittest.TestCase):
    """policy_sha256 is a protocol-visible definition: EM computes the same over its own
    copy of the policy. Lines whose stripped form starts with # are dropped, so are blank
    lines, trailing whitespace goes, and the rest is joined with \\n (no final newline)."""

    def digest(self, text):
        return hashlib.sha256(text.encode("utf-8")).hexdigest()

    def test_definition(self):
        text = "# header\n\n  \nx = 1  \n   # indented comment\n\ty\t\r\n#: doc\nz\n\n"
        self.assertEqual(server.policy_sha256(text), self.digest("x = 1\n\ty\nz"))

    def test_code_comments_after_code_are_kept(self):
        self.assertEqual(
            server.policy_sha256("a = 1  # why\n"), self.digest("a = 1  # why")
        )

    def test_empty(self):
        self.assertEqual(server.policy_sha256("# only\n\n"), self.digest(""))

    def test_comment_and_blank_changes_do_not_move_it(self):
        base = "a = 1\nb = 2\n"
        noisy = "# new header\n\na = 1   \n\n# between\nb = 2\n\n\n"
        self.assertEqual(server.policy_sha256(base), server.policy_sha256(noisy))
        self.assertNotEqual(server.policy_sha256(base), server.policy_sha256("a = 1\nb = 3\n"))

    def test_the_shipped_policy_ignores_the_ws_header(self):
        with open(os.path.join(HERE, "seccomp_policy.py"), encoding="utf-8") as handle:
            text = handle.read()
        body = text.split("\n", 5)[5]  # EM's file: everything below the five-line header
        self.assertTrue(body.startswith('"""Write the history shell'), body[:40])
        self.assertEqual(server.policy_sha256(text), server.policy_sha256(body))
        self.assertRegex(server.policy_sha256(text), r"[0-9a-f]{64}")


class TestAgentVisibleText(Exchange):
    """Every sentence an agent may read follows the agent-voice rule: no semicolons, no
    dashes. (Journal lines on stderr are for humans and are not covered.)"""

    BAD = (";", "\u2014", "\u2013", " - ", " -- ")

    def assertPlain(self, text):
        for mark in self.BAD:
            self.assertNotIn(mark, text, text)

    def test_source_strings_of_refusals(self):
        import ast

        with open(os.path.join(HERE, "server.py"), encoding="utf-8") as handle:
            tree = ast.parse(handle.read())
        seen = 0
        for node in ast.walk(tree):
            if not isinstance(node, ast.Call):
                continue
            func = node.func
            name = getattr(func, "id", None) or getattr(func, "attr", None)
            if name not in ("Refused", "refusal", "TreeRefused", "_not_saved"):
                continue
            for part in ast.walk(node):
                # literal pieces of f-strings and plain strings, but not the .join(...)
                # separators inside a replacement field
                if isinstance(part, ast.Constant) and isinstance(part.value, str):
                    seen += 1
                    self.assertPlain(part.value)
        self.assertGreater(seen, 20)

    def test_answers(self):
        good = self.run_request()
        cases = [
            {"v": 3, "op": "ping"},
            {"v": 2, "op": "ping", "x": 1},
            {k: v for k, v in good.items() if k != "agent"},
            {**good, "env": 1, "x": 1},
            {**good, "view": "a"},
            {**good, "root": "/tmp"},
            {**good, "command": " "},
            {"v": 2, "op": "nope"},
        ]
        for request in cases:
            with self.subTest(request=request):
                answer = self.ask(request)
                self.assertFalse(answer["ok"])
                self.assertPlain(answer["error"])


# --- protocol v2: her skills folder ---------------------------------------------------


def _tree_of(**files):
    """A Tree from path=text keyword pairs (use __ for /), with its folders."""
    out = []
    dirs = set()
    for key, text in files.items():
        path = key.replace("__", "/")
        parts = path.split("/")
        for i in range(1, len(parts)):
            dirs.add("/".join(parts[:i]))
        out.append((path, text.encode()))
    return server.Tree(dirs=tuple(sorted(dirs)), files=tuple(sorted(out)))


class TestCharacter(unittest.TestCase):
    def test_key(self):
        self.assertEqual(server.character_key("Aelinthia Corvella"), "aelinthia-corvella")
        self.assertEqual(server.character_key("Lyra"), "lyra")
        self.assertIsNone(server.character_key(None))
        self.assertEqual(server.character_key("A" + "b" * 63), "a" + "b" * 63)

    def test_bad_names(self):
        for bad in ("lyra", "Lyra  Vance", "Lyra vance", " Lyra", "Lyra ", "Lyra-Vance",
                    "../Etc", "Lyra/Vance", ".Lyra", "LYRA", "L", "Lyr4", "Lyra\nVance",
                    "A" + "b" * 64, "", 7, ["Lyra"], "Ly\u00e9ra"):
            with self.subTest(bad=bad):
                with self.assertRaises(Refused):
                    server.character_key(bad)

    def test_own(self):
        self.assertIsNone(server.check_own(None, None))
        self.assertEqual(server.check_own("edit", "lyra"), "edit")
        self.assertEqual(server.check_own("read", "lyra"), "read")
        for own, key in (("edit", None), ("read", None), (None, "lyra"), ("write", "lyra"),
                         (True, "lyra")):
            with self.subTest(own=own, key=key):
                with self.assertRaises(Refused):
                    server.check_own(own, key)

    def test_skill_name(self):
        self.assertEqual(server.check_skill_name("keistos-shack"), "keistos-shack")
        for bad in ("Keistos", "a--b", "-a", "a-", "a_b", "a" * 65, "", None, "a/b"):
            with self.subTest(bad=bad):
                with self.assertRaises(Refused):
                    server.check_skill_name(bad)


class TestTree(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="em-hs-tree-")
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def put(self, rel, text="x"):
        path = os.path.join(self.tmp, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as handle:
            handle.write(text)
        return path

    def read(self):
        fd = os.open(self.tmp, os.O_RDONLY | os.O_DIRECTORY)
        try:
            return server.read_tree(fd)
        finally:
            os.close(fd)

    def refused(self, *words):
        with self.assertRaises(server.TreeRefused) as ctx:
            self.read()
        for word in words:
            self.assertIn(word, str(ctx.exception))
        return str(ctx.exception)

    def patch(self, name, value):
        old = getattr(server, name)
        setattr(server, name, value)
        self.addCleanup(setattr, server, name, old)

    def test_good_tree(self):
        self.put("keistos/SKILL.md", "hello")
        self.put("keistos/references/sources.md", "src")
        os.makedirs(os.path.join(self.tmp, "empty-skill"))
        tree = self.read()
        self.assertEqual(tree.dirs, ("empty-skill", "keistos", "keistos/references"))
        self.assertEqual(
            tree.files,
            (("keistos/SKILL.md", b"hello"), ("keistos/references/sources.md", b"src")),
        )

    def test_file_at_top(self):
        self.put("notes.txt")
        self.refused("/skills/own/notes.txt", "Each skill is a folder")

    def test_skill_names(self):
        self.put("Keistos/SKILL.md")
        self.refused("/skills/own/Keistos", "not a skill name")

    def test_component_names(self):
        for bad in (".hidden", "a b", "-x", "\u00e9", "x" * 65):
            with self.subTest(bad=bad):
                shutil.rmtree(self.tmp)
                os.mkdir(self.tmp)
                self.put(f"skill/{bad}")
                self.refused("name that is not allowed")

    def test_symlink(self):
        self.put("skill/SKILL.md")
        os.symlink("/etc/passwd", os.path.join(self.tmp, "skill", "link.md"))
        self.refused("/skills/own/skill/link.md is a link")

    def test_symlinked_folder(self):
        os.makedirs(os.path.join(self.tmp, "real"))
        os.symlink("real", os.path.join(self.tmp, "skill"))
        self.refused("is a link")

    def test_fifo(self):
        os.makedirs(os.path.join(self.tmp, "skill"))
        os.mkfifo(os.path.join(self.tmp, "skill", "pipe"))
        self.refused("not a plain file or folder")

    def test_socket(self):
        os.makedirs(os.path.join(self.tmp, "skill"))
        path = os.path.join(self.tmp, "skill", "sock")
        if len(path) > 100:
            self.skipTest("path too long for a unix socket")
        sock = socket.socket(socket.AF_UNIX)
        self.addCleanup(sock.close)
        sock.bind(path)
        self.refused("not a plain file or folder")

    def test_hardlink(self):
        path = self.put("skill/SKILL.md")
        os.link(path, os.path.join(self.tmp, "skill", "again.md"))
        self.refused("hard link")

    def test_hardlink_to_outside(self):
        outside = os.path.join(tempfile.mkdtemp(prefix="em-hs-out-"), "secret")
        self.addCleanup(shutil.rmtree, os.path.dirname(outside), True)
        with open(outside, "w") as handle:
            handle.write("s")
        os.makedirs(os.path.join(self.tmp, "skill"))
        os.link(outside, os.path.join(self.tmp, "skill", "SKILL.md"))
        self.refused("hard link")

    def test_depth(self):
        self.put("a/b/c/d/ok.md")  # a file four folders down
        self.read()
        self.put("a/b/c/d/e/deep.md")
        self.refused("nested too deep")

    def test_file_cap(self):
        self.patch("MAX_FILE_BYTES", 10)
        self.put("skill/SKILL.md", "x" * 10)
        self.read()
        self.put("skill/SKILL.md", "x" * 11)
        self.refused("larger than")

    def test_count_cap(self):
        self.patch("MAX_SKILL_FILES", 3)
        for i in range(3):
            self.put(f"skill/f{i}")
        self.read()
        self.put("skill/f3")
        self.refused("more than 3 files")

    def test_total_cap(self):
        self.patch("MAX_TOTAL_BYTES", 10)
        self.put("a/x", "x" * 6)
        self.put("b/x", "x" * 5)
        self.refused("more than 0 MiB")

    def test_unreadable_file(self):
        if os.geteuid() == 0:
            self.skipTest("root reads everything")
        path = self.put("skill/SKILL.md")
        os.chmod(path, 0)
        self.refused("cannot be read")

    def test_check_tree_matches_read_tree(self):
        server.check_tree(_tree_of(skill__SKILL_md="x"))
        for tree, word in (
            (_tree_of(top="x"), "Each skill is a folder"),
            (_tree_of(Bad__x="x"), "not a skill name"),
            (_tree_of(skill___x="x"), "not allowed"),
            (_tree_of(a__b__c__d__e__f="x"), "nested too deep"),
            (server.Tree(dirs=(), files=(("skill/x", b""),)), "no folder above"),
        ):
            with self.subTest(word=word):
                with self.assertRaises(server.TreeRefused) as ctx:
                    server.check_tree(tree)
                self.assertIn(word, str(ctx.exception))

    def test_write_tree_round_trip_and_modes(self):
        tree = _tree_of(skill__SKILL_md="hello", skill__refs__a_md="a")
        tree = server.Tree(dirs=tree.dirs + ("empty",), files=tree.files)
        tree = server.Tree(dirs=tuple(sorted(tree.dirs)), files=tree.files)
        fd = os.open(self.tmp, os.O_RDONLY | os.O_DIRECTORY)
        try:
            server.write_tree(fd, tree)
        finally:
            os.close(fd)
        self.assertEqual(self.read(), tree)
        st = os.stat(os.path.join(self.tmp, "skill", "SKILL_md"))
        self.assertEqual(stat.S_IMODE(st.st_mode) & ~0o022, server.FILE_MODE & ~0o022)
        self.assertFalse(st.st_mode & 0o111)
        dst = os.stat(os.path.join(self.tmp, "skill"))
        self.assertEqual(stat.S_IMODE(dst.st_mode) & ~0o022, server.DIR_MODE & ~0o022)

    def test_files_sha256_definition(self):
        tree = server.Tree(dirs=("refs",), files=(("refs/b.md", b"B"), ("SKILL.md", b"A")))
        h = hashlib.sha256()
        for path, data in (("SKILL.md", b"A"), ("refs/b.md", b"B")):
            h.update(path.encode() + b"\0" + hashlib.sha256(data).hexdigest().encode() + b"\n")
        self.assertEqual(server.files_sha256(tree), h.hexdigest())
        # folders do not count, and None is no folder
        self.assertEqual(
            server.files_sha256(server.Tree(dirs=("refs", "x"), files=tree.files)),
            h.hexdigest(),
        )
        self.assertIsNone(server.files_sha256(None))
        # sorted by UTF-8 bytes: "Z" (0x5a) before "a" (0x61)
        two = server.Tree(dirs=(), files=(("a", b"1"), ("Z", b"2")))
        h = hashlib.sha256()
        for path, data in (("Z", b"2"), ("a", b"1")):
            h.update(path.encode() + b"\0" + hashlib.sha256(data).hexdigest().encode() + b"\n")
        self.assertEqual(server.files_sha256(two), h.hexdigest())

    def test_digest_sees_empty_folders(self):
        a = _tree_of(skill__x="1")
        b = server.Tree(dirs=a.dirs + ("zz",), files=a.files)
        self.assertNotEqual(a.digest(), b.digest())
        self.assertEqual(a.digest(), _tree_of(skill__x="1").digest())

    def test_renameat2_exchange(self):
        for name, text in (("a", "A"), ("b", "B")):
            os.mkdir(os.path.join(self.tmp, name))
            self.put(f"{name}/f", text)
        fd = os.open(self.tmp, os.O_RDONLY | os.O_DIRECTORY)
        try:
            server._renameat2(fd, "a", fd, "b", server._RENAME_EXCHANGE)
            with self.assertRaises(OSError):
                server._renameat2(fd, "a", fd, "b", server._RENAME_NOREPLACE)
        finally:
            os.close(fd)
        with open(os.path.join(self.tmp, "b", "f")) as handle:
            self.assertEqual(handle.read(), "A")


class SkillsExchange(Exchange):
    def edit(self, command, character="Lyra Vance", **kw):
        return self.ask(
            self.run_request(view="jonathan/warrior", character=character, own="edit",
                             command=command),
            **kw,
        )

    def her(self, *parts, profile="agent-history", key="lyra-vance"):
        return os.path.join(self.skills_own, profile, key, *parts)

    def seed(self, rel, text, **kw):
        path = self.her(*rel.split("/"), **kw)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as handle:
            handle.write(text)

    def staging_left(self):
        path = os.path.join(self.skills_own, server.STAGING)
        return os.listdir(path) if os.path.isdir(path) else []

    def argv(self):
        return self.bwrap_log()["argv"]

    def patch(self, name, value):
        old = getattr(server, name)
        setattr(server, name, value)
        self.addCleanup(setattr, server, name, old)


class TestSkillsRun(SkillsExchange):
    def test_no_character_has_an_empty_skills_dir(self):
        answer = self.ask(self.run_request(view="jonathan/warrior", command="true"))
        self.assertIsNone(answer["skills"])
        argv = self.argv()
        self.assertIn("/skills", argv)
        self.assertNotIn("/skills/own", argv)
        self.assertNotIn("/skills/characters", argv)

    def test_first_write_is_kept(self):
        answer = self.edit('mkdir "$SKILLS_OWN/keistos" && echo hi > "$SKILLS_OWN/keistos/SKILL.md"')
        self.assertEqual(answer["skills"], {"changed": True, "kept": True, "why": None})
        with open(self.her("keistos", "SKILL.md")) as handle:
            self.assertEqual(handle.read(), "hi\n")
        self.assertFalse(os.stat(self.her("keistos", "SKILL.md")).st_mode & 0o111)
        self.assertEqual(self.staging_left(), [])
        self.assertEqual(os.listdir(self.work), [])  # the copy is gone

    def test_the_bind_is_the_only_writable_skills_mount(self):
        self.edit("true")
        argv = self.argv()
        i = argv.index("/skills/own")
        self.assertEqual(argv[i - 2], "--bind")
        self.assertEqual(argv[i - 1], os.path.join(self.work, server.WORK_OWN))
        self.assertEqual(argv.count("--bind"), 1)
        self.assertLess(i, argv.index("--remount-ro"))

    def test_copy_in_shows_her_folder(self):
        self.seed("keistos/SKILL.md", "old text")
        answer = self.edit('cat "$SKILLS_OWN/keistos/SKILL.md"')
        self.assertEqual(answer["stdout"], "old text")
        self.assertEqual(answer["skills"], {"changed": False, "kept": True, "why": None})

    def test_unchanged_writes_nothing(self):
        answer = self.edit("true")
        self.assertEqual(answer["skills"], {"changed": False, "kept": True, "why": None})
        self.assertFalse(os.path.exists(os.path.join(self.skills_own, "agent-history")))

    def test_edit_replaces_and_deletes(self):
        self.seed("keistos/SKILL.md", "old")
        self.seed("gone/SKILL.md", "bye")
        answer = self.edit(
            'echo new > "$SKILLS_OWN/keistos/SKILL.md"; rm -r "$SKILLS_OWN/gone"; exit 1'
        )
        self.assertEqual(answer["exit_code"], 1)  # any exit code keeps
        self.assertTrue(answer["skills"]["kept"])
        self.assertTrue(answer["skills"]["changed"])
        with open(self.her("keistos", "SKILL.md")) as handle:
            self.assertEqual(handle.read(), "new\n")
        self.assertFalse(os.path.exists(self.her("gone")))
        self.assertEqual(self.staging_left(), [])

    def test_emptying_her_folder_removes_it(self):
        self.seed("keistos/SKILL.md", "old")
        answer = self.edit('rm -r "$SKILLS_OWN/keistos"')
        self.assertTrue(answer["skills"]["changed"])
        self.assertFalse(os.path.exists(self.her()))

    def test_a_link_keeps_nothing(self):
        self.seed("keistos/SKILL.md", "old")
        answer = self.edit(
            'echo new > "$SKILLS_OWN/keistos/SKILL.md"; ln -s /etc/passwd "$SKILLS_OWN/keistos/p"'
        )
        skills = answer["skills"]
        self.assertFalse(skills["kept"])
        self.assertFalse(skills["changed"])
        self.assertEqual(
            skills["why"],
            "Your skills were not saved because /skills/own/keistos/p is a link. "
            "Only plain files and folders are kept.",
        )
        with open(self.her("keistos", "SKILL.md")) as handle:
            self.assertEqual(handle.read(), "old")

    def test_a_stopped_command_keeps_nothing(self):
        answer = self.edit(
            'mkdir "$SKILLS_OWN/k"; echo x > "$SKILLS_OWN/k/SKILL.md"; sleep 30',
            limits=Limits(timeout_s=0.7),
        )
        self.assertTrue(answer["timed_out"])
        self.assertEqual(
            answer["skills"],
            {"changed": False, "kept": False,
             "why": "Your skills were not saved because the command was stopped before it finished."},
        )
        self.assertFalse(os.path.exists(self.her()))

    def test_a_stopped_command_that_changed_nothing_is_fine(self):
        answer = self.edit("sleep 30", limits=Limits(timeout_s=0.5))
        self.assertEqual(answer["skills"], {"changed": False, "kept": True, "why": None})

    def test_a_full_work_space_keeps_nothing(self):
        self.patch("work_is_full", lambda path: True)
        answer = self.edit('mkdir "$SKILLS_OWN/k"; echo x > "$SKILLS_OWN/k/SKILL.md"')
        self.assertIn("ran out of room", answer["skills"]["why"])
        self.assertFalse(os.path.exists(self.her()))

    def test_a_racing_writer_wins_and_she_hears_why(self):
        self.seed("keistos/SKILL.md", "old")
        disk = self.her("keistos", "SKILL.md")
        answer = self.edit(f'echo mine > "$SKILLS_OWN/keistos/SKILL.md"; echo theirs > {disk}')
        self.assertFalse(answer["skills"]["kept"])
        self.assertIn("changed while the command ran", answer["skills"]["why"])
        with open(disk) as handle:
            self.assertEqual(handle.read(), "theirs\n")
        self.assertEqual(self.staging_left(), [])

    def test_names_key_her_folder_not_the_agent(self):
        self.edit('mkdir "$SKILLS_OWN/a"; : > "$SKILLS_OWN/a/SKILL.md"', character="Mira")
        self.assertTrue(os.path.isfile(self.her("a", "SKILL.md", key="mira")))
        # the same name from another agent of the profile is the same folder
        answer = self.ask(self.run_request(
            view="jonathan/coach", agent="jonathan/coach", character="Mira", own="edit",
            command='ls "$SKILLS_OWN"'))
        self.assertEqual(answer["stdout"], "a\n")

    def test_profiles_have_their_own_roots(self):
        livia = self.make_root("agent-history-livia")
        self.ask(self.run_request(root=livia, view="livia/son", agent="livia/son",
                                  character="Lyra Vance", own="edit",
                                  command='mkdir "$SKILLS_OWN/a"; : > "$SKILLS_OWN/a/SKILL.md"'))
        self.assertTrue(os.path.isfile(self.her("a", "SKILL.md", profile="agent-history-livia")))
        self.assertFalse(os.path.exists(self.her()))

    def test_no_work_space_or_no_skills_root_is_unavailable(self):
        shutil.rmtree(self.work)
        self.assertRefused(self.edit("true"), "unavailable", "cannot be edited")
        os.mkdir(self.work)
        os.rmdir(self.skills_own)
        self.assertRefused(self.edit("true"), "unavailable", "not set up")
        self.assertFalse(os.path.exists(self.log))

    def test_skills_root_not_ours_or_writable_by_others(self):
        os.chmod(self.skills_own, 0o770)
        self.assertRefused(self.edit("true"), "unavailable", "not set up")
        os.chmod(self.skills_own, 0o750)
        os.rename(self.skills_own, self.skills_own + ".real")
        os.symlink(self.skills_own + ".real", self.skills_own)
        self.assertRefused(self.edit("true"), "unavailable", "not set up")

    def test_a_linked_profile_root_is_an_error_not_followed(self):
        os.mkdir(os.path.join(self.tmp, "elsewhere"))
        os.symlink(os.path.join(self.tmp, "elsewhere"), os.path.join(self.skills_own, "agent-history"))
        answer = self.edit("true")
        self.assertRefused(answer, "internal")
        self.assertFalse(os.path.exists(self.log))

    def test_request_rules(self):
        for over in ({"character": "lyra", "own": "edit"},
                     {"character": None, "own": "edit"},
                     {"character": "Lyra", "own": None},
                     {"character": "Lyra", "own": "write"}):
            with self.subTest(over=over):
                self.assertRefused(self.ask(self.run_request(**over)), "refused", "Nothing was run")
        self.assertFalse(os.path.exists(self.log))

    def test_read_binds_her_folder_read_only(self):
        self.seed("keistos/SKILL.md", "old")
        answer = self.ask(self.run_request(view="jonathan/warrior", character="Lyra Vance",
                                           own="read", command='cat "$SKILLS_OWN/keistos/SKILL.md"'))
        self.assertEqual(answer["stdout"], "old")
        self.assertEqual(answer["skills"], {"changed": False, "kept": False, "why": None})
        argv = self.argv()
        i = argv.index("/skills/own")
        self.assertEqual(argv[i - 2:i], ["--ro-bind", self.her()])
        self.assertNotIn("--bind", argv)

    def test_read_with_no_folder_is_an_empty_dir(self):
        self.ask(self.run_request(view="jonathan/warrior", character="Lyra Vance",
                                  own="read", command="true"))
        argv = self.argv()
        i = argv.index("/skills/own")
        self.assertEqual(argv[i - 1], "--dir")

    def test_shared_root(self):
        shared = os.path.join(self.base, "skills-shared")
        os.makedirs(os.path.join(shared, "fishing"))
        self.ask(self.run_request(view="jonathan/warrior", command="true"))
        self.assertNotIn("/skills/shared", self.argv())  # no marker
        with open(os.path.join(shared, server.SHARED_MARKER), "w"):
            pass
        self.ask(self.run_request(view="jonathan/warrior", command="true"))
        argv = self.argv()
        i = argv.index("/skills/shared")
        self.assertEqual(argv[i - 2:i], ["--ro-bind", os.path.realpath(shared)])
        # another profile's shared root is not this one's
        livia = self.make_root("agent-history-livia")
        self.ask(self.run_request(root=livia, view="livia/son", agent="livia/son", command="true"))
        self.assertNotIn("/skills/shared", self.argv())

    def test_linked_shared_root_is_not_mounted(self):
        real = os.path.join(self.tmp, "real-shared")
        os.mkdir(real)
        with open(os.path.join(real, server.SHARED_MARKER), "w"):
            pass
        os.symlink(real, os.path.join(self.base, "skills-shared"))
        self.ask(self.run_request(view="jonathan/warrior", command="true"))
        self.assertNotIn("/skills/shared", self.argv())

    def test_star_view_reads_every_character(self):
        self.ask(self.run_request(command="true"))
        argv = self.argv()
        self.assertEqual(argv[argv.index("/skills/characters") - 1], "--dir")
        self.seed("keistos/SKILL.md", "x")
        self.ask(self.run_request(command='cat "$SKILLS_CHARACTERS/lyra-vance/keistos/SKILL.md"'))
        argv = self.argv()
        i = argv.index("/skills/characters")
        self.assertEqual(argv[i - 2:i], ["--ro-bind", os.path.join(self.skills_own, "agent-history")])
        self.ask(self.run_request(view="jonathan/warrior", command="true"))
        self.assertNotIn("/skills/characters", self.argv())


class TestSyncRemove(SkillsExchange):
    def sync(self, files, expect=None, skill="keistos", character="Lyra Vance", **kw):
        return self.ask({"v": 2, "op": "sync", "root": self.root, "character": character,
                         "skill": skill, "expect_sha256": expect, "files": files}, **kw)

    def remove(self, expect, skill="keistos", character="Lyra Vance"):
        return self.ask({"v": 2, "op": "remove", "root": self.root, "character": character,
                         "skill": skill, "expect_sha256": expect})

    def sha(self, files):
        return server.files_sha256(server.Tree(
            dirs=(), files=tuple((p, t.encode()) for p, t in files.items())))

    def test_sync_new_then_replace_then_remove(self):
        files = {"SKILL.md": "reviewed", "references/sources.md": "codex"}
        answer = self.sync(files)
        self.assertEqual(answer["ok"], True)
        self.assertEqual(answer["files_sha256"], self.sha(files))
        with open(self.her("keistos", "references", "sources.md")) as handle:
            self.assertEqual(handle.read(), "codex")
        new = {"SKILL.md": "second"}
        answer = self.sync(new, expect=self.sha(files))
        self.assertEqual(answer["files_sha256"], self.sha(new))
        self.assertFalse(os.path.exists(self.her("keistos", "references")))
        self.assertEqual(self.remove(self.sha(new))["ok"], True)
        self.assertFalse(os.path.exists(self.her()))  # an emptied key folder goes too
        self.assertEqual(self.staging_left(), [])

    def test_sync_leaves_her_other_skills(self):
        self.seed("mine/SKILL.md", "hers")
        self.sync({"SKILL.md": "x"})
        with open(self.her("mine", "SKILL.md")) as handle:
            self.assertEqual(handle.read(), "hers")
        self.remove(self.sha({"SKILL.md": "x"}))
        self.assertTrue(os.path.isfile(self.her("mine", "SKILL.md")))

    def test_conflicts_change_nothing(self):
        self.seed("keistos/SKILL.md", "she edited it")
        answer = self.sync({"SKILL.md": "reviewed"}, expect=self.sha({"SKILL.md": "old"}))
        self.assertRefused(answer, "conflict", "not as expected", "Nothing was changed")
        self.assertRefused(self.sync({"SKILL.md": "r"}), "conflict")  # null: must not exist
        self.assertRefused(self.remove(self.sha({"SKILL.md": "old"})), "conflict")
        with open(self.her("keistos", "SKILL.md")) as handle:
            self.assertEqual(handle.read(), "she edited it")

    def test_remove_of_nothing_with_null_is_fine(self):
        self.assertEqual(self.remove(None)["ok"], True)

    def test_bad_requests(self):
        good_files = {"SKILL.md": "x"}
        for label, kw in (
            ("path dotdot", {"files": {"../x": "x"}}),
            ("path hidden", {"files": {".x": "x"}}),
            ("path abs", {"files": {"/x": "x"}}),
            ("path empty part", {"files": {"a//b": "x"}}),
            ("not text", {"files": {"SKILL.md": 1}}),
            ("empty files", {"files": {}}),
            ("bad skill", {"files": good_files, "skill": "Bad"}),
            ("bad character", {"files": good_files, "character": "lyra"}),
            ("no character", {"files": good_files, "character": None}),
            ("bad expect", {"files": good_files, "expect": "abc"}),
            ("too deep", {"files": {"a/b/c/d/e": "x"}}),
        ):
            with self.subTest(label):
                self.assertRefused(self.sync(**kw), "refused")
        self.assertFalse(os.path.exists(self.her()))

    def test_sync_respects_the_caps_on_her_whole_folder(self):
        self.patch("MAX_TOTAL_BYTES", 10)
        self.seed("mine/SKILL.md", "x" * 6)
        self.assertRefused(self.sync({"SKILL.md": "y" * 6}), "refused", "cannot be kept")

    def test_key_sets(self):
        msg = {"v": 2, "op": "sync", "root": self.root, "character": "Lyra",
               "skill": "k", "expect_sha256": None, "files": {"SKILL.md": "x"}, "x": 1}
        self.assertRefused(self.ask(msg), "refused", "wrong fields")
        msg = {"v": 2, "op": "remove", "root": self.root, "character": "Lyra",
               "skill": "k", "expect_sha256": None, "files": {}}
        self.assertRefused(self.ask(msg), "refused", "wrong fields")

    def test_a_run_sees_what_sync_wrote(self):
        self.sync({"SKILL.md": "reviewed"})
        answer = self.edit('cat "$SKILLS_OWN/keistos/SKILL.md"')
        self.assertEqual(answer["stdout"], "reviewed")

    def test_stale_staging_is_swept(self):
        staging = os.path.join(self.skills_own, server.STAGING)
        os.makedirs(os.path.join(staging, "t-old", "x"))
        os.makedirs(os.path.join(staging, "t-new"))
        old = time.time() - server.STAGING_STALE_S - 10
        os.utime(os.path.join(staging, "t-old"), (old, old))
        self.sync({"SKILL.md": "x"})
        self.assertEqual(sorted(os.listdir(staging)), ["t-new"])


if __name__ == "__main__":
    unittest.main(verbosity=1)
