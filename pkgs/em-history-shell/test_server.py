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
        self.config = server.Config(
            server=SERVER_PATH,
            bwrap=self.bwrap,
            tools=self.tools,
            seccomp=self.seccomp,
            closure=(self.tools,),
            unit_digest=UNIT_DIGEST,
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
            "v": 1,
            "op": "run",
            "root": self.root,
            "view": "*",
            "agent": "jonathan/warrior",
            "command": "echo hi",
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

    def test_bad(self):
        cases = {
            "bwrap not store": {"bwrap": "/usr/bin/bwrap"},
            "bwrap dotdot": {"bwrap": "/nix/store/" + "d" * 32 + "-b/../../bin/x"},
            "seccomp missing": {"seccomp": None},
            "tools not in closure": {"closure": [STORE_B]},
            "empty closure": {"closure": []},
            "closure junk": {"closure": [STORE_A, "/etc"]},
            "server junk": {"server": "/tmp/x"},
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
        self.assertEqual(answer["v"], 1)
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
        answer = self.ask({"v": 1, "op": "ping"})
        self.assertEqual(
            answer,
            {
                "v": 1,
                "ok": True,
                "uid": UID,
                "seccomp_sha256": hashlib.sha256(b"BPF-fake-program").hexdigest(),
                "server": SERVER_PATH,
                "unit_digest": UNIT_DIGEST,
            },
        )
        self.assertFalse(os.path.exists(self.log))  # nothing ran

    def test_ping_with_extra_key_refused(self):
        self.assertRefused(
            self.ask({"v": 1, "op": "ping", "command": "id"}), "refused", "unexpected"
        )

    def test_ping_when_broken_is_unavailable(self):
        os.unlink(self.seccomp)
        self.assertRefused(self.ask({"v": 1, "op": "ping"}), "unavailable")

    def test_version_mismatch(self):
        for v in (2, 0, "1", 1.0, True, None):
            with self.subTest(v=v):
                self.assertRefused(
                    self.ask({"v": v, "op": "ping"}), "version", "version 1"
                )
        self.assertRefused(self.ask({"op": "ping"}), "version")
        # the version is judged before the other fields
        self.assertRefused(self.ask({"v": 2, "op": "future", "zzz": 1}), "version")

    def test_not_json(self):
        for raw in (b"hello\n", b"\xff\xfe\n", b"\n", b"[1]\n", b'"x"\n', b"null\n",
                    b"[" * 100000 + b"\n"):
            with self.subTest(raw=raw[:20]):
                self.assertRefused(self.ask(raw), "refused")

    def test_unknown_op(self):
        self.assertRefused(self.ask({"v": 1, "op": "stop"}), "refused", "Unknown operation")
        self.assertRefused(self.ask({"v": 1}), "refused", "Unknown operation")

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
                "v": 1,
                "ok": True,
                "exit_code": 3,
                "stdout": "out\n",
                "stderr": "err\n",
                "timed_out": False,
                "flooded": False,
                "stdout_dropped": 0,
                "stderr_dropped": 0,
                "scratch_reset": False,
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
                 "closure": [store]},
                handle,
            )
        return store, cfg

    def command(self, tmp, cfg, *, uid=None, digest=UNIT_DIGEST):
        argv = [sys.executable, os.path.join(HERE, "server.py"),
                "--allowed-uid", str(UID if uid is None else uid),
                "--base", tmp, "--config", cfg]
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
            code, data, err = self.talk(self.command(tmp, cfg), b'{"v":1,"op":"ping"}\n')
            self.assertEqual(code, 0, err)
            answer = json.loads(data)
            self.assertTrue(answer["ok"])
            self.assertEqual(answer["server"], store)
            self.assertEqual(answer["uid"], UID)
            self.assertEqual(answer["unit_digest"], UNIT_DIGEST)
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
            {"v": 1, "ok": False, "kind": "unavailable",
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
                self.command(tmp, os.path.join(tmp, "no")), b'{"v":1,"op":"ping"}\n'
            )
        self.assertEqual(code, 2)
        self.assertIn(b"bad config", err)
        self.assertEqual(data.count(b"\n"), 1)
        answer = json.loads(data)
        # no config, so no server to name; the digest comes from the command line
        self.assertEqual(
            answer,
            {"v": 1, "ok": False, "kind": "unavailable",
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
            if name not in ("Refused", "refusal"):
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
            {"v": 2, "op": "ping"},
            {"v": 1, "op": "ping", "x": 1},
            {k: v for k, v in good.items() if k != "agent"},
            {**good, "env": 1, "x": 1},
            {**good, "view": "a"},
            {**good, "root": "/tmp"},
            {**good, "command": " "},
            {"v": 1, "op": "nope"},
        ]
        for request in cases:
            with self.subTest(request=request):
                answer = self.ask(request)
                self.assertFalse(answer["ok"])
                self.assertPlain(answer["error"])


if __name__ == "__main__":
    unittest.main(verbosity=1)
