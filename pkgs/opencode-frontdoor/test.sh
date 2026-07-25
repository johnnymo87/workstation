#!/usr/bin/env bash
# The frontdoor vitest suite runs OUTSIDE the nix build sandbox: the integration
# tests bind loopback sockets and drive undici/fake-timers against 127.0.0.1,
# which a hermetic sandbox forbids. Hence default.nix sets doCheck=false and the
# suite is run here (manually or in CI).
#
# NOTE: the /doc route gate below does NOT have that limitation — booting the
# pinned opencode and binding loopback was verified to work inside the nix build
# sandbox. The authoritative gate is therefore the nix check derivation
# (route-gate.nix, wired into the home-manager closure); this script is the
# pre-deploy developer signal for the same check.
set -euo pipefail
cd "$(dirname "$0")"
npm ci
npm run typecheck
npm test

echo "--- Running Route Classification Gate (Check A) ---"
npm run build

# Resolve the opencode binary WITHOUT hardcoding a store path. A checked-in
# /nix/store/... path is a third copy of the pin: it rots the moment the pin is
# bumped or the path is GC'd, and it would then silently fall back to a DIFFERENT
# binary than the one the gate is supposed to validate. The profile symlink is
# the pin (home-manager installs the pinned opencode into it), and it follows
# pin bumps for free.
OPENCODE_BIN="${OPENCODE_BIN:-$(command -v opencode 2>/dev/null || true)}"

# Fail LOUD, never skip. A gate that silently no-ops when its subject is missing
# reports success while checking nothing — the exact class of defect this gate
# exists to catch. Set OPENCODE_BIN explicitly to run against a specific binary.
if [ -z "$OPENCODE_BIN" ] || [ ! -x "$OPENCODE_BIN" ]; then
  echo "ERROR: opencode binary not found (OPENCODE_BIN='${OPENCODE_BIN}')." >&2
  echo "       The /doc route gate cannot run. Set OPENCODE_BIN to the pinned binary." >&2
  exit 1
fi
echo "Using opencode: $(readlink -f "$OPENCODE_BIN")"

GATE_TMP=$(mktemp -d)
export HOME="$GATE_TMP/home"
export XDG_CONFIG_HOME="$GATE_TMP/config"
export XDG_DATA_HOME="$GATE_TMP/data"
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME"

# Random high port: a fixed port collides with a concurrent run or an unrelated
# listener, which would fail the gate for a reason unrelated to route drift.
PORT=$(( 40000 + RANDOM % 20000 ))
SERVE_LOG="$GATE_TMP/serve.log"
DOC_JSON="$GATE_TMP/doc.json"

"$OPENCODE_BIN" serve --port "$PORT" --hostname 127.0.0.1 < /dev/null > "$SERVE_LOG" 2>&1 &
SERVE_PID=$!

cleanup() {
  if [ -n "${SERVE_PID:-}" ] && kill -0 "$SERVE_PID" 2>/dev/null; then
    kill -9 "$SERVE_PID" 2>/dev/null || true
    wait "$SERVE_PID" 2>/dev/null || true
  fi
  rm -rf "$GATE_TMP" 2>/dev/null || true
}
trap cleanup EXIT

# Generous bound (~60s). Cold-start on a loaded box is seconds, but a too-tight
# bound turns this gate into a flaky build failure, which trains people to ignore
# it — worse than not having it.
SUCCESS=0
for _ in $(seq 1 120); do
  if curl -sf --connect-timeout 1 --max-time 3 "http://127.0.0.1:$PORT/doc" -o "$DOC_JSON" 2>/dev/null \
     && [ -s "$DOC_JSON" ]; then
    SUCCESS=1
    break
  fi
  if ! kill -0 "$SERVE_PID" 2>/dev/null; then
    echo "ERROR: opencode serve exited before answering /doc." >&2
    break
  fi
  sleep 0.5
done

if [ "$SUCCESS" -ne 1 ]; then
  echo "ERROR: opencode serve failed to answer /doc within timeout!" >&2
  echo "=== Serve Log ===" >&2
  cat "$SERVE_LOG" >&2 || true
  echo "=================" >&2
  exit 1
fi

node dist/route-gate.js "$DOC_JSON"
