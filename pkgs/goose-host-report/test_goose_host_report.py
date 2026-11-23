#!/usr/bin/env python3
"""Unit tests for goose-host-report (workstation-6w7i.27.12)."""

import json
import unittest
from typing import Any, Optional

from goose_host_report import (
    MockRunner,
    RunResult,
    generate_report,
    publish_report,
    fetch_reports,
    parse_honk_version,
)


class TestGooseHostReport(unittest.TestCase):
    def setUp(self):
        self.runner = MockRunner()
        self.runner.current_time = 1700000000.0

    def test_parse_honk_version(self):
        self.assertEqual(parse_honk_version("honk 0.5.0\n"), "0.5.0")
        self.assertEqual(parse_honk_version("honk v1.2.3"), "1.2.3")
        self.assertEqual(parse_honk_version("0.0.0"), "0.0.0")
        self.assertEqual(parse_honk_version("honk 1.60.2-patched.1"), "1.60.2-patched.1")
        with self.assertRaises(ValueError):
            parse_honk_version("")
        with self.assertRaises(ValueError):
            parse_honk_version("invalid version string")

    def test_generate_report_devbox_with_goose_link(self):
        self.runner.commands["goose-link"] = RunResult(
            0,
            "current=/nix/store/abc-goose-1.60.2\nprevious=<none>\npinned=/nix/store/abc-goose-1.60.2\npinned_is_current=yes\n",
        )
        self.runner.commands["honk"] = RunResult(0, "honk 0.5.0\n")

        rep = generate_report(self.runner, host="devbox")
        self.assertEqual(
            rep,
            {
                "host": "devbox",
                "ts": 1700000000,
                "link_current": "/nix/store/abc-goose-1.60.2",
                "honk_version": "0.5.0",
            },
        )

    def test_generate_report_mac_without_goose_link(self):
        # On macOS, goose-link is not present. Real path of goose binary is reported.
        self.runner.binaries["goose"] = "/Users/dev/.nix-profile/bin/goose"
        self.runner.realpaths["/Users/dev/.nix-profile/bin/goose"] = (
            "/nix/store/xyz-goose-1.54.0.18/bin/goose"
        )
        self.runner.commands["honk"] = RunResult(0, "honk 0.5.0\n")

        rep = generate_report(self.runner, host="mac")
        self.assertEqual(
            rep,
            {
                "host": "mac",
                "ts": 1700000000,
                "link_current": "/nix/store/xyz-goose-1.54.0.18/bin/goose",
                "honk_version": "0.5.0",
            },
        )

    def test_generate_report_goose_link_fails(self):
        self.runner.commands["goose-link"] = RunResult(1, "", "goose-link: /var/lib/goose/current is missing")
        self.runner.commands["honk"] = RunResult(0, "honk 0.5.0\n")

        with self.assertRaises(RuntimeError) as ctx:
            generate_report(self.runner, host="devbox")
        self.assertIn("goose-link status failed", str(ctx.exception))

    def test_generate_report_goose_link_none(self):
        self.runner.commands["goose-link"] = RunResult(
            0,
            "current=<none>\nprevious=<none>\npinned=/nix/store/abc\npinned_is_current=no\n",
        )
        self.runner.commands["honk"] = RunResult(0, "honk 0.5.0\n")

        with self.assertRaises(RuntimeError) as ctx:
            generate_report(self.runner, host="devbox")
        self.assertIn("link_current is <none>", str(ctx.exception))

    def test_generate_report_honk_fails(self):
        self.runner.commands["goose-link"] = RunResult(
            0,
            "current=/nix/store/abc\nprevious=<none>\npinned=/nix/store/abc\npinned_is_current=yes\n",
        )
        self.runner.commands["honk"] = RunResult(1, "", "honk not found")

        with self.assertRaises(RuntimeError) as ctx:
            generate_report(self.runner, host="devbox")
        self.assertIn("honk --version failed", str(ctx.exception))

    def test_publish_report_success(self):
        self.runner.commands["goose-link"] = RunResult(
            0,
            "current=/nix/store/abc-goose-1.60.2\nprevious=<none>\npinned=/nix/store/abc-goose-1.60.2\npinned_is_current=yes\n",
        )
        self.runner.commands["honk"] = RunResult(0, "honk 0.5.0\n")
        self.runner.commands["gh"] = RunResult(0, "")

        publish_report(self.runner, host="devbox", repo="johnnymo87/workstation")

        # Verify gh variable set command was executed
        gh_calls = [cmd for cmd in self.runner.history if cmd[0] == "gh"]
        self.assertEqual(len(gh_calls), 1)
        argv = gh_calls[0]
        self.assertEqual(argv[0:3], ["gh", "variable", "set"])
        self.assertEqual(argv[3], "GOOSE_HOST_REPORT_DEVBOX")
        self.assertEqual(argv[4], "--body")
        payload = json.loads(argv[5])
        self.assertEqual(payload["host"], "devbox")
        self.assertEqual(payload["link_current"], "/nix/store/abc-goose-1.60.2")
        self.assertEqual(payload["honk_version"], "0.5.0")
        self.assertEqual(argv[6:8], ["-R", "johnnymo87/workstation"])

    def test_publish_report_gh_fails(self):
        self.runner.commands["goose-link"] = RunResult(
            0,
            "current=/nix/store/abc\nprevious=<none>\npinned=/nix/store/abc\npinned_is_current=yes\n",
        )
        self.runner.commands["honk"] = RunResult(0, "honk 0.5.0\n")
        self.runner.commands["gh"] = RunResult(1, "", "HTTP 403: Forbidden")

        with self.assertRaises(RuntimeError) as ctx:
            publish_report(self.runner, host="devbox", repo="johnnymo87/workstation")
        self.assertIn("failed to set gh variable", str(ctx.exception))

    def test_fetch_reports_success(self):
        devbox_payload = {
            "host": "devbox",
            "ts": 1700000000,
            "link_current": "/nix/store/devbox-goose",
            "honk_version": "0.5.0",
        }
        mac_payload = {
            "host": "mac",
            "ts": 1700000000,
            "link_current": "/nix/store/mac-goose",
            "honk_version": "0.5.0",
        }

        def gh_handler(argv: list[str]) -> RunResult:
            var_name = argv[3]
            if var_name == "GOOSE_HOST_REPORT_DEVBOX":
                return RunResult(0, json.dumps(devbox_payload) + "\n")
            if var_name == "GOOSE_HOST_REPORT_MAC":
                return RunResult(0, json.dumps(mac_payload) + "\n")
            return RunResult(1, "", f"variable {var_name} not found")

        self.runner.command_handlers["gh"] = gh_handler

        ok = fetch_reports(
            self.runner,
            reports_dir="/var/lib/goose-cutover/host-reports",
            hosts=["devbox", "mac"],
            repo="johnnymo87/workstation",
        )
        self.assertTrue(ok)

        # Verify files were written atomically and match payloads
        self.assertIn("/var/lib/goose-cutover/host-reports/devbox.json", self.runner.files)
        self.assertIn("/var/lib/goose-cutover/host-reports/mac.json", self.runner.files)

        dev_written = json.loads(self.runner.files["/var/lib/goose-cutover/host-reports/devbox.json"])
        self.assertEqual(dev_written, devbox_payload)

        mac_written = json.loads(self.runner.files["/var/lib/goose-cutover/host-reports/mac.json"])
        self.assertEqual(mac_written, mac_payload)

    def test_fetch_reports_gh_get_fails(self):
        def gh_handler(argv: list[str]) -> RunResult:
            var_name = argv[3]
            if var_name == "GOOSE_HOST_REPORT_DEVBOX":
                return RunResult(0, json.dumps({
                    "host": "devbox",
                    "ts": 1700000000,
                    "link_current": "/nix/store/devbox-goose",
                    "honk_version": "0.5.0",
                }))
            return RunResult(1, "", "variable not found")

        self.runner.command_handlers["gh"] = gh_handler

        ok = fetch_reports(
            self.runner,
            reports_dir="/var/lib/goose-cutover/host-reports",
            hosts=["devbox", "mac"],
            repo="johnnymo87/workstation",
        )
        self.assertFalse(ok)
        # devbox succeeded and was written, mac failed
        self.assertIn("/var/lib/goose-cutover/host-reports/devbox.json", self.runner.files)
        self.assertNotIn("/var/lib/goose-cutover/host-reports/mac.json", self.runner.files)

    def test_fetch_reports_invalid_json(self):
        self.runner.commands["gh"] = RunResult(0, "not valid json")
        ok = fetch_reports(
            self.runner,
            reports_dir="/var/lib/goose-cutover/host-reports",
            hosts=["devbox"],
            repo="johnnymo87/workstation",
        )
        self.assertFalse(ok)
        self.assertNotIn("/var/lib/goose-cutover/host-reports/devbox.json", self.runner.files)

    def test_main_help(self):
        from goose_host_report import main
        with self.assertRaises(SystemExit) as ctx:
            main(["--help"])
        self.assertEqual(ctx.exception.code, 0)


if __name__ == "__main__":
    unittest.main()
