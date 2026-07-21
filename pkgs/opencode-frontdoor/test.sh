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
