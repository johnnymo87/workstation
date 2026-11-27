"""Tests for goose_canary.py (bead workstation-6w7i.7). Stdlib only.

Run: python3 test_goose_canary.py   (needs no goose, no systemd, no network)
"""
import json
import os
import shutil
import socketserver
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "goose_canary.py"
sys.path.insert(0, str(HERE))
import goose_canary as gc  # noqa: E402


class FakeGoose:
    """Just enough of goose's ACP-over-HTTP: initialize answered inline,
    everything else answered on the connection's SSE stream."""

    def __init__(self, mode="ok"):
        self.mode = mode  # ok | hang | init500 | listerror
        self.deleted = []
        streams = {}
        outer = self

        class H(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *a):
                pass

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["content-length"])))
                if self.headers.get("x-secret-key") != "s3cret":
                    self.send_response(401); self.send_header("content-length", "0"); self.end_headers(); return
                if body["method"] == "initialize":
                    if outer.mode == "init500":
                        self.send_response(500); self.send_header("content-length", "0"); self.end_headers(); return
                    out = json.dumps({"jsonrpc": "2.0", "id": body["id"], "result": {"protocolVersion": 1}}).encode()
                    self.send_response(200)
                    self.send_header("acp-connection-id", "c1")
                    self.send_header("content-type", "application/json")
                    self.send_header("content-length", str(len(out)))
                    self.end_headers(); self.wfile.write(out); return
                self.send_response(202); self.send_header("content-length", "0"); self.end_headers()
                if outer.mode == "hang":
                    return
                if outer.mode == "listerror":
                    msg = {"jsonrpc": "2.0", "id": body["id"], "error": {"code": -1, "message": "boom"}}
                else:
                    msg = {"jsonrpc": "2.0", "id": body["id"], "result": {"sessions": []}}
                w = streams[self.headers["acp-connection-id"]]
                w.write(b"event: message\ndata: " + json.dumps(msg).encode() + b"\n\n"); w.flush()

            def do_GET(self):
                self.send_response(200)
                self.send_header("content-type", "text/event-stream")
                self.end_headers()
                self.wfile.write(b": hello\n\n"); self.wfile.flush()
                streams[self.headers["acp-connection-id"]] = self.wfile
                time.sleep(5)

            def do_DELETE(self):
                outer.deleted.append(self.headers.get("acp-connection-id"))
                self.send_response(202); self.send_header("content-length", "0"); self.end_headers()

        class S(socketserver.ThreadingMixIn, HTTPServer):
            daemon_threads = True

        self.srv = S(("127.0.0.1", 0), H)
        self.port = self.srv.server_address[1]
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()

    def close(self):
        self.srv.shutdown()


class ProbeGoose(unittest.TestCase):
    def run_mode(self, mode, timeout=3):
        g = FakeGoose(mode)
        try:
            return gc.probe_goose("127.0.0.1", g.port, "s3cret", timeout=timeout), g
        finally:
            g.close()

    def test_healthy(self):
        why, g = self.run_mode("ok")
        self.assertIsNone(why)
        self.assertEqual(g.deleted, ["c1"], "the probe connection must be deleted")

    def test_session_list_hang_is_a_failure_and_bounded(self):
        t = time.monotonic()
        why, g = self.run_mode("hang", timeout=2)
        self.assertIsNotNone(why)
        self.assertLess(time.monotonic() - t, 6)
        self.assertEqual(g.deleted, ["c1"], "connection deleted even on failure")

    def test_initialize_error(self):
        why, _ = self.run_mode("init500")
        self.assertIn("HTTP 500", why)

    def test_session_list_error(self):
        why, _ = self.run_mode("listerror")
        self.assertIn("error", why)

    def test_refused(self):
        why = gc.probe_goose("127.0.0.1", 1, "s3cret", timeout=2)
        self.assertIsNotNone(why)


def script(d, name, body):
    p = Path(d) / name
    # Shebang from PATH: a build sandbox has no /usr/bin/env.
    p.write_text("#!" + shutil.which("bash") + "\n" + body + "\n")
    p.chmod(0o755)
    return str(p)


class Pass(unittest.TestCase):
    """main(): thresholds, attribution, alert-only, state reset."""

    def setUp(self):
        self.d = tempfile.mkdtemp()
        self.state = Path(self.d, "state")
        self.alerts = Path(self.d, "alerts")
        self.goose = FakeGoose("ok")
        Path(self.d, "secret").write_text("s3cret\n")
        self.unitstate = Path(self.d, "unitstate")
        self.unitstate.write_text("active")
        self.honkrc = Path(self.d, "honkrc")
        self.honkrc.write_text("0")
        self.env = dict(os.environ,
                        GOOSE_CANARY_HOST="testbox",
                        GOOSE_CANARY_STATE=str(self.state),
                        GOOSE_CANARY_ALERT=script(self.d, "alert", f'printf "%s\\t%s\\n" "$1" "$2" >> {self.alerts}'),
                        GOOSE_CANARY_HONK=script(self.d, "honk", f'[ "$(cat {self.honkrc})" = 0 ] && echo "[]" || exit 3'),
                        GOOSE_CANARY_SYSTEMCTL=script(self.d, "systemctl",
                            f'case "$*" in *is-active*) cat {self.unitstate};; *show*) echo 0;; esac'),
                        GOOSE_CANARY_SECRET_FILE=str(Path(self.d, "secret")),
                        GOOSE_CANARY_PORT=str(self.goose.port),
                        GOOSE_CANARY_RESET_LOCK=str(Path(self.d, "nolock")),
                        GOOSE_CANARY_GOOSE_CGROUP=str(Path(self.d, "nocg")),
                        GOOSE_CANARY_TIMEOUT="2")

    def tearDown(self):
        self.goose.close()

    def run_pass(self):
        p = subprocess.run([sys.executable, str(SCRIPT)], env=self.env,
                           capture_output=True, text=True, timeout=30)
        self.assertEqual(p.returncode, 0, p.stderr)
        return p.stdout

    def alert_sigs(self):
        if not self.alerts.exists():
            return []
        return [l.split("\t")[1] for l in self.alerts.read_text().splitlines()]

    def test_healthy_pass_alerts_nothing(self):
        self.run_pass()
        self.assertEqual(self.alert_sigs(), [])
        self.assertTrue((self.state / "last-healthy").exists())

    def test_goose_wedge_alerts_on_third_pass_only(self):
        self.goose.mode = "hang"
        self.run_pass(); self.run_pass()
        self.assertEqual(self.alert_sigs(), [])
        out = self.run_pass()
        self.assertEqual(self.alert_sigs(), ["goose-wedge"])
        self.assertIn("forensics", out)
        self.assertTrue(list(self.state.glob("wedge-goose-serve-*")))

    def test_goose_wedge_is_not_blamed_on_honkd(self):
        self.goose.mode = "hang"
        self.honkrc.write_text("1")
        for _ in range(4):
            self.run_pass()
        self.assertNotIn("honkd-wedge", self.alert_sigs())

    def test_honkd_wedge_while_goose_answers(self):
        self.honkrc.write_text("1")
        for _ in range(3):
            self.run_pass()
        self.assertEqual(self.alert_sigs(), ["honkd-wedge"])

    def test_recovery_resets_the_count_and_alert_state(self):
        self.goose.mode = "hang"
        for _ in range(3):
            self.run_pass()
        Path(self.state, "alert-goose-wedge-x").write_text("x")
        self.goose.mode = "ok"
        self.run_pass()
        self.assertFalse((self.state / "goose-fails").exists())
        self.assertFalse((self.state / "alert-goose-wedge-x").exists())
        self.goose.mode = "hang"
        self.run_pass(); self.run_pass()
        self.assertEqual(self.alert_sigs(), ["goose-wedge"], "count restarted after recovery")

    def test_unit_down_is_down_not_wedge(self):
        self.unitstate.write_text("activating")
        for _ in range(3):
            self.run_pass()
        self.assertEqual(self.alert_sigs(), ["goose-down"])

    def test_never_restarts_anything(self):
        log = Path(self.d, "sysctl.log")
        self.env["GOOSE_CANARY_SYSTEMCTL"] = script(self.d, "systemctl2",
            f'echo "$*" >> {log}; case "$*" in *is-active*) echo active;; *show*) echo 0;; esac')
        self.goose.mode = "hang"
        for _ in range(4):
            self.run_pass()
        verbs = {l.split()[0] if l.split()[0] != "--user" else l.split()[1]
                 for l in log.read_text().splitlines()}
        self.assertLessEqual(verbs, {"is-active", "show"})

    def test_reset_lock_held_skips(self):
        lock = Path(self.d, "lock"); lock.write_text("")
        self.env["GOOSE_CANARY_RESET_LOCK"] = str(lock)
        self.goose.mode = "hang"
        holder = subprocess.Popen(["flock", "-x", str(lock), "sleep", "20"])
        try:
            time.sleep(0.3)
            for _ in range(3):
                self.assertIn("skipping", self.run_pass())
        finally:
            holder.kill()
        self.assertEqual(self.alert_sigs(), [])


if __name__ == "__main__":
    unittest.main(verbosity=1)
