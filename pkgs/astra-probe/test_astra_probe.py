#!/usr/bin/env python3
"""Tests for astra-probe, run against the SHIPPED executable.

The point of this suite is that the thing under test is the same binary
home-manager installs -- `ASTRA_PROBE_BIN` is set by the flake check to
`${astra-probe}/bin/astra-probe`. A suite that re-implemented the jq logic
could pass while the shipped script printed UP on a malformed response, which
is exactly the defect that motivated most of these cases.

No subscription, network, or live codex-lb is needed: each test stands up a
throwaway HTTP server on loopback and points the probe at it with
`CODEX_LB_URL`. That the probe HAS such an override is the only reason it is
testable at all.

Exit-code contract under test:
    0 = UP, 1 = DOWN (named blocking condition), 2 = UNKNOWN (cannot classify)
"""

import http.server
import json
import os
import subprocess
import sys
import threading
import unittest

PROBE = os.environ.get("ASTRA_PROBE_BIN", "astra-probe")

ASTRA_CATALOG = {"data": [{"id": "gpt-6-astra"}, {"id": "gpt-5.6-sol"}]}
NO_ASTRA_CATALOG = {"data": [{"id": "gpt-5.6-sol"}]}


def account(status="active", name="acct@example.com", primary=99.0, secondary=100.0):
    return {
        "accountId": "aaaa-bbbb",
        "displayName": name,
        "status": status,
        "usage": {
            "primaryRemainingPercent": primary,
            "secondaryRemainingPercent": secondary,
        },
        "resetAtPrimary": "2026-09-21T21:28:22Z",
        "resetAtSecondary": "2026-09-27T17:20:56Z",
    }


class RoutedServer(http.server.HTTPServer):
    """HTTPServer carrying a per-test route table."""

    routes: dict = {}


class Fixture(http.server.BaseHTTPRequestHandler):
    """Serves whatever the test told it to; routes are set per-server."""

    def do_GET(self):  # noqa: N802 (stdlib naming)
        routes = getattr(self.server, "routes", {})
        status, body = routes.get(self.path, (404, "{}"))
        payload = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, format, *args):  # noqa: A002 (stdlib signature)
        pass


class ProbeCase(unittest.TestCase):
    def run_probe(self, accounts, models=ASTRA_CATALOG, accounts_status=200,
                  models_status=200):
        """Start a fixture server, run the real probe against it, return (rc, out)."""

        def body(v):
            return v if isinstance(v, str) else json.dumps(v)

        srv = RoutedServer(("127.0.0.1", 0), Fixture)
        srv.routes = {
            "/api/accounts": (accounts_status, body(accounts)),
            "/v1/models": (models_status, body(models)),
        }
        thread = threading.Thread(target=srv.serve_forever, daemon=True)
        thread.start()
        try:
            port = srv.server_address[1]
            env = dict(os.environ, CODEX_LB_URL=f"http://127.0.0.1:{port}")
            proc = subprocess.run(
                [PROBE], env=env, capture_output=True, text=True, timeout=60
            )
        finally:
            srv.shutdown()
            srv.server_close()
        return proc.returncode, proc.stdout.strip()

    def assertOneLine(self, out):
        """The contract is one line. A probe an agent parses must not ramble."""
        self.assertEqual(len(out.splitlines()), 1, f"expected one line, got: {out!r}")

    # -- the happy path ---------------------------------------------------

    def test_active_account_and_astra_in_catalog_is_up(self):
        rc, out = self.run_probe({"accounts": [account()]})
        self.assertEqual(rc, 0, out)
        self.assertTrue(out.startswith("astra UP:"), out)
        self.assertOneLine(out)

    def test_up_when_one_of_several_accounts_is_active(self):
        rc, out = self.run_probe(
            {"accounts": [account(status="rate_limited"), account(status="active")]}
        )
        self.assertEqual(rc, 0, out)
        self.assertTrue(out.startswith("astra UP:"), out)

    # -- named blocking conditions (exit 1) -------------------------------

    def test_rate_limited_account_is_down_and_names_both_windows(self):
        rc, out = self.run_probe(
            {"accounts": [account(status="rate_limited", primary=0.0, secondary=59.0)]}
        )
        self.assertEqual(rc, 1, out)
        self.assertIn("rate_limited", out)
        # Weekly exhaustion is invisible if only the 5h window is printed, and
        # the reader then waits for a reset that will not unblock them.
        # (jq echoes the JSON literal, so 0.0 stays "0.0" rather than "0".)
        self.assertIn("5h 0.0% left", out)
        self.assertIn("weekly 59.0% left", out)
        self.assertIn("2026-09-27", out)

    def test_reauth_required_is_down(self):
        rc, out = self.run_probe({"accounts": [account(status="reauth_required")]})
        self.assertEqual(rc, 1, out)
        self.assertIn("reauth_required", out)

    def test_missing_astra_in_catalog_is_down(self):
        rc, out = self.run_probe({"accounts": [account()]}, models=NO_ASTRA_CATALOG)
        self.assertEqual(rc, 1, out)
        self.assertIn("absent from the codex-lb model catalog", out)

    def test_catalog_checked_before_accounts(self):
        """During a re-auth both are broken; the catalog is the specific answer."""
        rc, out = self.run_probe(
            {"accounts": [account(status="reauth_required")]}, models=NO_ASTRA_CATALOG
        )
        self.assertEqual(rc, 1, out)
        self.assertIn("catalog", out)

    def test_empty_account_pool_is_down(self):
        rc, out = self.run_probe({"accounts": []})
        self.assertEqual(rc, 1, out)
        self.assertIn("no accounts configured", out)

    def test_connection_refused_is_down_and_says_so(self):
        env = dict(os.environ, CODEX_LB_URL="http://127.0.0.1:1")
        proc = subprocess.run([PROBE], env=env, capture_output=True, text=True,
                              timeout=60)
        self.assertEqual(proc.returncode, 1, proc.stdout)
        self.assertIn("not answering", proc.stdout)
        self.assertIn("systemctl", proc.stdout)
        self.assertOneLine(proc.stdout.strip())

    # -- drift and malformed input must NOT read as UP (exit 2) -----------

    def test_object_shaped_accounts_is_unknown_not_up(self):
        """The regression that motivated the rewrite.

        `.accounts[]` iterates an OBJECT as happily as an array, so this payload
        printed `astra UP` -- a false green in front of the default reviewer.
        """
        rc, out = self.run_probe({"accounts": {"oops": account()}})
        self.assertEqual(rc, 2, out)
        self.assertIn("unsupported", out)
        self.assertNotIn("astra UP", out)

    def test_object_shaped_model_catalog_is_unknown(self):
        rc, out = self.run_probe(
            {"accounts": [account()]}, models={"data": {"oops": {"id": "gpt-6-astra"}}}
        )
        self.assertEqual(rc, 2, out)
        self.assertIn("unsupported", out)

    def test_null_accounts_is_unknown_with_a_message(self):
        """Used to exit 5 from raw jq with no astra line at all."""
        rc, out = self.run_probe({"accounts": None})
        self.assertEqual(rc, 2, out)
        self.assertTrue(out.startswith("astra UNKNOWN:"), out)
        self.assertOneLine(out)

    def test_non_object_account_entries_are_unknown(self):
        rc, out = self.run_probe({"accounts": ["active"]})
        self.assertEqual(rc, 2, out)
        self.assertIn("non-object", out)

    def test_unknown_status_is_unknown_not_down(self):
        """A status codex-lb adds later is drift, not an outage.

        Reporting DOWN here would block every review for a rename; reporting UP
        would dispatch into a state we cannot reason about. Say so instead.
        """
        rc, out = self.run_probe({"accounts": [account(status="healthy")]})
        self.assertEqual(rc, 2, out)
        self.assertIn("does not know", out)
        self.assertIn("stale", out)

    def test_empty_body_is_unknown(self):
        rc, out = self.run_probe("")
        self.assertEqual(rc, 2, out)
        self.assertTrue(out.startswith("astra UNKNOWN:"), out)

    def test_invalid_json_is_unknown(self):
        rc, out = self.run_probe("{not json")
        self.assertEqual(rc, 2, out)
        self.assertIn("could not parse", out)

    def test_multiple_json_documents_is_unknown(self):
        rc, out = self.run_probe('{"accounts":[]} {"accounts":[]}')
        self.assertEqual(rc, 2, out)
        self.assertIn("exactly one JSON document", out)

    def test_missing_accounts_key_is_unknown(self):
        rc, out = self.run_probe({"totally": "different"})
        self.assertEqual(rc, 2, out)
        self.assertIn("unsupported", out)

    def test_http_error_is_not_reported_as_service_down(self):
        """401/500 means codex-lb is alive; "restart it" is the wrong advice."""
        rc, out = self.run_probe({"accounts": [account()]}, accounts_status=401)
        self.assertEqual(rc, 1, out)
        self.assertIn("HTTP 401", out)
        self.assertIn("restart is not the fix", out)

    def test_missing_usage_fields_do_not_crash_the_report(self):
        """remainingCreditsPrimary went null on a live account mid-window."""
        acct = account(status="paused")
        del acct["usage"]
        del acct["resetAtPrimary"]
        rc, out = self.run_probe({"accounts": [acct]})
        self.assertEqual(rc, 1, out)
        self.assertIn("paused", out)
        self.assertIn("?", out)
        self.assertOneLine(out)


if __name__ == "__main__":
    print(f"astra-probe under test: {PROBE}", file=sys.stderr)
    unittest.main(verbosity=2)
