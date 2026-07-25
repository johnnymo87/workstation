#!/usr/bin/env bash
# The frontdoor vitest suite runs OUTSIDE the nix build sandbox: the integration
# tests bind loopback sockets and drive undici/fake-timers against 127.0.0.1,
# which a hermetic sandbox forbids. Hence default.nix sets doCheck=false and the
# suite is run here (manually or in CI).
set -euo pipefail
cd "$(dirname "$0")"
npm ci
npm run typecheck
npm test

echo "--- Running Route Classification Gate (Check A) ---"
npm run build

OPENCODE_BIN="${OPENCODE_BIN:-/nix/store/niqliars0nacijlzc7ma2bxmh60sappn-opencode-patched-1.17.13.4/bin/opencode}"
if [ ! -x "$OPENCODE_BIN" ]; then
  OPENCODE_BIN=$(which opencode 2>/dev/null || true)
fi

if [ -n "$OPENCODE_BIN" ] && [ -x "$OPENCODE_BIN" ]; then
  TMPDIR=$(mktemp -d)
  export HOME="$TMPDIR/home"
  export XDG_CONFIG_HOME="$TMPDIR/config"
  export XDG_DATA_HOME="$TMPDIR/data"
  mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME"

  PORT=49196
  SERVE_LOG="$TMPDIR/serve.log"
  DOC_JSON="$TMPDIR/doc.json"

  "$OPENCODE_BIN" serve --port $PORT --hostname 127.0.0.1 < /dev/null > "$SERVE_LOG" 2>&1 &
  SERVE_PID=$!

  cleanup() {
    if [ -n "${SERVE_PID:-}" ] && kill -0 "$SERVE_PID" 2>/dev/null; then
      kill -9 "$SERVE_PID" 2>/dev/null || true
      wait "$SERVE_PID" 2>/dev/null || true
    fi
    rm -rf "$TMPDIR" 2>/dev/null || true
  }
  trap cleanup EXIT

  SUCCESS=0
  for i in $(seq 1 10); do
    if curl -s --connect-timeout 1 --max-time 2 "http://127.0.0.1:$PORT/doc" -o "$DOC_JSON" 2>/dev/null; then
      if [ -s "$DOC_JSON" ]; then
        SUCCESS=1
        break
      fi
    fi
    sleep 0.2
  done

  if [ $SUCCESS -ne 1 ]; then
    echo "ERROR: opencode serve failed to answer /doc within timeout!"
    echo "=== Serve Log ==="
    cat "$SERVE_LOG" || true
    echo "================="
    exit 1
  fi

  node dist/route-gate.js "$DOC_JSON"
  cleanup
  trap - EXIT
else
  echo "WARNING: Opencode binary not found; skipping live /doc gate check in test.sh"
fi
