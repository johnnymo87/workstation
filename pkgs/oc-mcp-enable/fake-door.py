#!/usr/bin/env python3
"""Fake front door for oc-mcp-enable's behavioural tests (test.sh).

Serves just the routes oc-mcp-enable calls, with the connect outcome chosen by
the SCENARIO env var, and appends every PATCH body it receives to PATCH_LOG so
the test can assert whether a permission grant was (or was not) attempted.

Usage: fake-door.py <port-file>   (binds an ephemeral 127.0.0.1 port and writes
it to <port-file> once listening)
"""
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SCENARIO = os.environ["SCENARIO"]
PATCH_LOG = os.environ["PATCH_LOG"]
SID = "ses_fake123"

# Response bodies copied from pkgs/opencode-frontdoor/src/proxy.ts.
DOOR_TIMEOUT = {"error": "service_unavailable", "message": "Upstream did not send response headers in time"}
DOOR_PIGEON = {"error": "service_unavailable", "message": "pigeon unavailable; refusing to route a mutating request to a non-owner"}

# scenario -> (connect HTTP code, connect body, status of the server afterwards)
SCENARIOS = {
    "ok": (200, True, {"status": "connected"}),
    # Measured 2026-10-22 against a real serve: 200 `true`, then status failed.
    "failed-after-200": (200, True, {"status": "failed", "error": "Failed to get tools"}),
    "needs-auth": (200, True, {"status": "needs_auth"}),
    "door-timeout": (503, DOOR_TIMEOUT, {"status": "disabled"}),
    "pigeon-down": (503, DOOR_PIGEON, {"status": "disabled"}),
    "not-configured": (404, {"name": "NotFoundError"}, {"status": "disabled"}),
    # Connect OK, but the status read itself fails: state unknown, not failed.
    "status-unreadable": (200, True, None),
}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):  # keep test output clean
        pass

    def _send(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/global/health":
            return self._send(200, {"healthy": True})
        if self.path == f"/session/{SID}":
            return self._send(200, {"id": SID, "directory": "/tmp/fake", "permission": []})
        if self.path == f"/session/{SID}/mcp":
            state = SCENARIOS[SCENARIO][2]
            if state is None:
                return self._send(500, {"name": "UnknownError"})
            return self._send(200, {"atlassian": state, "slack-ro": {"status": "disabled"}})
        return self._send(404, {"name": "NotFoundError"})

    def do_POST(self):
        if self.path == f"/session/{SID}/mcp/atlassian/connect":
            code, body, _ = SCENARIOS[SCENARIO]
            return self._send(code, body)
        return self._send(404, {"name": "NotFoundError"})

    def do_PATCH(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length).decode()
        with open(PATCH_LOG, "a") as f:
            f.write(body + "\n")
        return self._send(200, {"id": SID})


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    with open(sys.argv[1], "w") as f:
        f.write(str(server.server_address[1]))
    server.serve_forever()


if __name__ == "__main__":
    main()
