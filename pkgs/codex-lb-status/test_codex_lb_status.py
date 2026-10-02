#!/usr/bin/env python3
"""Tests for codex-lb-status, run against the SHIPPED executable.

`CODEX_LB_STATUS_BIN` is set by the flake check to the store path that
home-manager installs, so a passing suite says something about the binary on
PATH rather than about a copy of its logic.

No subscription, network, or live codex-lb is needed: each test stands up a
throwaway HTTP server on 127.0.0.1 and points the tool at it with
`CODEX_LB_PORT`. Time is pinned with `CODEX_LB_STATUS_NOW` so durations are
exact, and HOME is a temp dir so the opt-in-marker branch is controllable.

Exit-code contract under test:
    0 = printed a status, 1 = codex-lb unreachable or answered an HTTP error,
    2 = codex-lb answered something this tool does not understand (or bad usage)
"""

import http.server
import json
import os
import socket
import subprocess
import tempfile
import threading
import unittest
from datetime import datetime, timezone

BIN = os.environ.get("CODEX_LB_STATUS_BIN", "codex-lb-status")

NOW = 1_790_000_000  # fixed "now" handed to the tool


def iso(offset_s, frac=False):
    t = datetime.fromtimestamp(NOW + offset_s, tz=timezone.utc)
    s = t.strftime("%Y-%m-%dT%H:%M:%S")
    return s + (".063686Z" if frac else "Z")


def account(**over):
    a = {
        "accountId": "acct-1",
        "email": "a@example.com",
        "alias": None,
        "displayName": "a@example.com",
        "planType": "plus",
        "status": "active",
        "usage": {
            "primaryRemainingPercent": 78.0,
            "secondaryRemainingPercent": 56.0,
            "monthlyRemainingPercent": None,
        },
        "resetAtPrimary": iso(4 * 3600 + 6 * 60),
        "resetAtSecondary": iso(5 * 86400 + 11 * 3600),
        "resetAtMonthly": None,
        "lastRefreshAt": iso(-120, frac=True),
        "requestUsage": {
            "requestCount": 104,
            "totalTokens": 10114829,
            "totalCostUsd": 4.336103,
        },
        "deactivationReason": None,
    }
    a.update(over)
    return a


SUMMARY = {
    "primaryWindow": {"remainingPercent": 82.0, "resetAt": iso(3600)},
    "secondaryWindow": {"remainingPercent": 56.0, "resetAt": iso(2 * 86400)},
    "monthlyWindow": None,
    "metrics": {"requests7d": 73, "errorRate7d": 0.123, "topError": "stream_incomplete"},
}


class RoutedServer(http.server.HTTPServer):
    routes: dict = {}


class Fixture(http.server.BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802
        status, body = getattr(self.server, "routes", {}).get(self.path, (404, "{}"))
        payload = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, format, *args):  # noqa: A002
        pass


def body(v):
    return v if isinstance(v, str) else json.dumps(v)


class Case(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp()

    def env(self, port):
        return dict(
            os.environ,
            HOME=self.home,
            CODEX_LB_PORT=str(port),
            CODEX_LB_STATUS_NOW=str(NOW),
        )

    def run_tool(self, accounts, summary=SUMMARY, accounts_status=200,
                 summary_status=200, args=()):
        srv = RoutedServer(("127.0.0.1", 0), Fixture)
        srv.routes = {
            "/api/accounts": (accounts_status, body(accounts)),
            "/api/usage/summary": (summary_status, body(summary)),
        }
        t = threading.Thread(target=srv.serve_forever, daemon=True)
        t.start()
        try:
            p = subprocess.run([BIN, *args], env=self.env(srv.server_address[1]),
                               capture_output=True, text=True, timeout=60)
        finally:
            srv.shutdown()
            srv.server_close()
        return p.returncode, p.stdout + p.stderr

    def dead_port(self):
        s = socket.socket()
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
        s.close()
        return port

    def assertNoNull(self, out):
        self.assertNotIn("null", out)
        self.assertNotIn("NaN", out)

    # ---- happy path -------------------------------------------------------

    def test_active_account_shows_used_percent_and_resets(self):
        rc, out = self.run_tool({"accounts": [account()]})
        self.assertEqual(rc, 0, out)
        self.assertIn("a@example.com (plus) active", out)
        # remaining 78 -> used 22; remaining 56 -> used 44 (teamclaude shows USED)
        self.assertRegex(out, r"5h\s+\[[█░]{18}\] 22% used, reset 4h6m")
        self.assertRegex(out, r"Weekly\s+\[[█░]{18}\] 44% used, reset 5d11h")
        self.assertNoNull(out)

    def test_refresh_age_parses_fractional_seconds(self):
        rc, out = self.run_tool({"accounts": [account()]})
        self.assertEqual(rc, 0, out)
        self.assertRegex(out, r"Refresh\s+2m ago\n")

    def test_usage_line(self):
        rc, out = self.run_tool({"accounts": [account()]})
        self.assertRegex(out, r"Usage\s+104 req, 10\.1m tok, \$4\.34")

    def test_alias_preferred_over_display_name(self):
        rc, out = self.run_tool({"accounts": [account(alias="work")]})
        self.assertIn("work (plus) active", out)

    def test_multiple_accounts_all_listed(self):
        rc, out = self.run_tool({"accounts": [
            account(), account(accountId="acct-2", displayName="b@example.com",
                               email="b@example.com")]})
        self.assertEqual(rc, 0, out)
        self.assertIn("a@example.com", out)
        self.assertIn("b@example.com", out)
        self.assertIn("2 accounts, 2 active", out)

    def test_monthly_only_shown_when_present(self):
        rc, out = self.run_tool({"accounts": [account()]})
        self.assertNotIn("Monthly", out)
        u = dict(account()["usage"], monthlyRemainingPercent=90.0)
        rc, out = self.run_tool({"accounts": [account(usage=u, resetAtMonthly=iso(86400))]})
        self.assertRegex(out, r"Monthly\s+\[[█░]{18}\] 10% used, reset 1d0h")

    # ---- the silent-failure signals ---------------------------------------

    def test_unhealthy_account_flagged_with_reason(self):
        u = dict(account()["usage"], primaryRemainingPercent=None)
        rc, out = self.run_tool({"accounts": [account(
            status="reauth_required", usage=u, resetAtPrimary=None,
            deactivationReason="Usage API error: HTTP 401 - token expired")]})
        self.assertEqual(rc, 0, out)
        self.assertIn("reauth_required !!", out)
        self.assertIn("Reason   Usage API error: HTTP 401 - token expired", out)
        self.assertIn("0 active", out)
        self.assertRegex(out, r"5h\s+no data")
        self.assertNoNull(out)

    def test_stale_refresh_is_flagged(self):
        rc, out = self.run_tool({"accounts": [account(lastRefreshAt=iso(-10 * 86400))]})
        self.assertRegex(out, r"Refresh\s+10d0h ago \(STALE")

    def test_never_refreshed(self):
        rc, out = self.run_tool({"accounts": [account(lastRefreshAt=None)]})
        self.assertRegex(out, r"Refresh\s+never")

    def test_reset_in_the_past_is_marked_stale(self):
        rc, out = self.run_tool({"accounts": [account(resetAtPrimary=iso(-3 * 3600))]})
        self.assertRegex(out, r"5h\s+\[[█░]{18}\] 22% used, reset passed 3h0m ago \(stale\)")

    # ---- fleet footer -----------------------------------------------------

    def test_fleet_footer_labeled_as_weighted(self):
        rc, out = self.run_tool({"accounts": [account()]})
        self.assertIn("Fleet (capacity-weighted", out)
        self.assertRegex(out, r"Fleet[^\n]*\n\s+5h\s+\[[█░]{18}\] 18% used, reset 1h0m")
        self.assertRegex(out, r"7d\s+73 req, 12\.3% errors, top: stream_incomplete")

    def test_fleet_unavailable_does_not_hide_accounts(self):
        rc, out = self.run_tool({"accounts": [account()]}, summary_status=500)
        self.assertEqual(rc, 0, out)
        self.assertIn("a@example.com (plus) active", out)
        self.assertIn("Fleet    unavailable", out)

    def test_fleet_null_metrics(self):
        s = dict(SUMMARY, metrics={"requests7d": 0, "errorRate7d": None, "topError": None})
        rc, out = self.run_tool({"accounts": [account()]}, summary=s)
        self.assertRegex(out, r"7d\s+0 req\n")
        self.assertNoNull(out)

    def test_no_accounts(self):
        rc, out = self.run_tool({"accounts": []})
        self.assertEqual(rc, 0, out)
        self.assertIn("no accounts", out)

    # ---- failures ---------------------------------------------------------

    def test_refused_without_marker_says_not_enabled(self):
        p = subprocess.run([BIN], env=self.env(self.dead_port()),
                           capture_output=True, text=True, timeout=60)
        self.assertEqual(p.returncode, 1, p.stdout + p.stderr)
        self.assertIn("not enabled on this host", p.stderr)

    def test_refused_with_marker_says_not_answering(self):
        os.makedirs(os.path.join(self.home, ".codex-lb"))
        open(os.path.join(self.home, ".codex-lb", "enabled"), "w").close()
        p = subprocess.run([BIN], env=self.env(self.dead_port()),
                           capture_output=True, text=True, timeout=60)
        self.assertEqual(p.returncode, 1, p.stdout + p.stderr)
        self.assertIn("not answering", p.stderr)

    def test_http_401_explains_auth(self):
        rc, out = self.run_tool({"error": {"code": "authentication_required"}},
                                accounts_status=401)
        self.assertEqual(rc, 1, out)
        self.assertIn("HTTP 401", out)
        self.assertIn("authentication_required", out)
        self.assertIn("dashboard password", out)
        self.assertNoNull(out)

    def test_accounts_as_object_is_drift(self):
        rc, out = self.run_tool({"accounts": {"x": account()}})
        self.assertEqual(rc, 2, out)
        self.assertIn("unrecognized", out)

    def test_invalid_json_is_drift(self):
        rc, out = self.run_tool("<html>not json</html>")
        self.assertEqual(rc, 2, out)
        self.assertIn("unrecognized", out)

    def test_wrong_field_types_degrade_not_crash(self):
        rc, out = self.run_tool({"accounts": [account(
            usage={"primaryRemainingPercent": "78", "secondaryRemainingPercent": None},
            planType=7, resetAtSecondary="garbage", requestUsage=None)]})
        self.assertEqual(rc, 0, out)
        self.assertIn("a@example.com (?) active", out)
        self.assertRegex(out, r"5h\s+no data")
        self.assertNoNull(out)

    def test_bad_port_is_usage_error(self):
        p = subprocess.run([BIN], env=dict(self.env(1), CODEX_LB_PORT="cloudbox:2455"),
                           capture_output=True, text=True, timeout=60)
        self.assertEqual(p.returncode, 2)
        self.assertIn("CODEX_LB_PORT", p.stderr)

    def test_help(self):
        p = subprocess.run([BIN, "--help"], capture_output=True, text=True, timeout=60)
        self.assertEqual(p.returncode, 0)
        self.assertIn("Usage: codex-lb-status", p.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=1)
