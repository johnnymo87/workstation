#!/usr/bin/env bash
# unwired-test(workstation-k7t4): genuinely live host state -- curls the running front door on 127.0.0.1 and asserts it is not degraded. A GitHub-runner step would be worse than nothing here: no door there either, so it would go green having asserted nothing. Belongs to workstation-4ze8 as ALERTING, keeping this marker as the coverage claim
# Runtime regression guard for Pigeon Auth & Frontdoor Aggregate Degrade Detection (dx8p Stage 1, Task 8)
#
# Asserts two live-service properties:
#   1. Pigeon anonymous endpoint protection (GET /sessions, GET /swarm/inbox, GET /route -> 401; GET /health -> 200).
#   2. Frontdoor healthz reports pigeon reachable ("pigeon": true) and no aggregate degradation
#      ("status": "ok", "degraded": false, "notRoutedMutationToAnchor": 0).
#
# Usage:
#   bash users/dev/test-pigeon-auth-canary.sh
# Options via env:
#   PIGEON_URL (default: http://127.0.0.1:4731)
#   FRONTDOOR_URL (default: http://127.0.0.1:4700)
#   STRICT_AUTH (default: 1 if token present, or 1 if set; if no token and STRICT_AUTH=0, skips auth probes)

set -o errexit -o nounset -o pipefail

pigeon_url="${PIGEON_URL:-http://127.0.0.1:4731}"
frontdoor_url="${FRONTDOOR_URL:-http://127.0.0.1:4700}"

fail=0
note() { printf 'ok: %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1"; fail=1; }

# Token / Back-compat detection
token_file="/run/secrets/pigeon_daemon_auth_token"
token_present=false
if [ -n "${PIGEON_DAEMON_AUTH_TOKEN:-}" ] || [ -f "$token_file" ]; then
  token_present=true
fi

# By default, run strict auth assertions if token is present or if STRICT_AUTH=1.
# If STRICT_AUTH is unset: default to 1 so explicit calls assert auth, but allow STRICT_AUTH=0 to skip on devbox/darwin.
strict_auth="${STRICT_AUTH:-1}"

echo "--- Pigeon Auth & Frontdoor Degrade Runtime Guard ---"
echo "Target Pigeon:    $pigeon_url"
echo "Target Frontdoor: $frontdoor_url"

# -----------------------------------------------------------------------------
# Assertion Set (1): Pigeon Anonymous Auth Enforcement
# -----------------------------------------------------------------------------
echo "--- Assertion Set (1): Pigeon anonymous endpoint auth"

if [ "$token_present" = false ] && [ "$strict_auth" = "0" ]; then
  echo "SKIP: pigeon auth token not present (/run/secrets/pigeon_daemon_auth_token absent) and STRICT_AUTH=0."
  echo "      Skipping pigeon 401 auth assertion (unauthenticated back-compat mode)."
else
  probe_pigeon() {
    local path="$1"
    # Read-only GET request without Authorization header
    curl -s -o /dev/null -w "%{http_code}" --max-time 5 "${pigeon_url}${path}" || echo "000"
  }

  # (1a) Anonymous GET /sessions -> 401
  code="$(probe_pigeon "/sessions")"
  if [ "$code" = "401" ]; then
    note "anonymous GET /sessions returned 401 Unauthorized"
  else
    bad "anonymous GET /sessions returned $code, expected 401 (pigeon auth unauthenticated or regressed)"
  fi

  # (1b) Anonymous GET /swarm/inbox -> 401
  code="$(probe_pigeon "/swarm/inbox")"
  if [ "$code" = "401" ]; then
    note "anonymous GET /swarm/inbox returned 401 Unauthorized"
  else
    bad "anonymous GET /swarm/inbox returned $code, expected 401 (route left unprotected)"
  fi

  # (1c) Anonymous GET /route -> 401
  code="$(probe_pigeon "/route")"
  if [ "$code" = "401" ]; then
    note "anonymous GET /route returned 401 Unauthorized"
  else
    bad "anonymous GET /route returned $code, expected 401 (route left unprotected)"
  fi

  # (1d) Anonymous GET /health -> 200 (allowlist entry must stay open)
  code="$(probe_pigeon "/health")"
  if [ "$code" = "200" ]; then
    note "anonymous GET /health returned 200 OK (liveness probe open)"
  else
    bad "anonymous GET /health returned $code, expected 200 (liveness allowlist blocked or broken)"
  fi
fi

# -----------------------------------------------------------------------------
# Assertion Set (2): Frontdoor Aggregate Degrade Detection
# -----------------------------------------------------------------------------
echo "--- Assertion Set (2): Frontdoor aggregate degrade healthz check"

healthz_body="$(curl -s --max-time 5 "${frontdoor_url}/healthz" || echo "")"

if [ -z "$healthz_body" ]; then
  bad "frontdoor /healthz produced no response from ${frontdoor_url}"
else
  # Parse fields from healthz response
  status="$(echo "$healthz_body" | jq -r 'if .status == null then "missing" else .status end' 2>/dev/null || echo "parse_error")"
  pigeon_ok="$(echo "$healthz_body" | jq -r 'if .pigeon == null then "missing" else .pigeon end' 2>/dev/null || echo "false")"
  degraded="$(echo "$healthz_body" | jq -r 'if .degraded == null then "missing" else .degraded end' 2>/dev/null || echo "true")"
  not_routed_mutations="$(echo "$healthz_body" | jq -r 'if .notRoutedMutationToAnchor == null then -1 else .notRoutedMutationToAnchor end' 2>/dev/null || echo "-1")"

  # (2a) status must be "ok"
  if [ "$status" = "ok" ]; then
    note "frontdoor /healthz status is 'ok'"
  else
    bad "frontdoor /healthz status is '$status', expected 'ok'"
  fi

  # (2b) pigeon must be true
  if [ "$pigeon_ok" = "true" ]; then
    note "frontdoor /healthz reports pigeon is reachable (pigeon: true)"
  else
    bad "frontdoor /healthz reports pigeon is unreachable or rejected frontdoor token (pigeon: false)"
  fi

  # (2c) degraded must be false
  if [ "$degraded" = "false" ]; then
    note "frontdoor /healthz reports not degraded (degraded: false)"
  else
    bad "frontdoor /healthz reports DEGRADED mode active (degraded: true)"
  fi

  # (2d) notRoutedMutationToAnchor counter must be ~0
  if [ "$not_routed_mutations" -ge 0 ] && [ "$not_routed_mutations" -le 0 ]; then
    note "frontdoor /healthz notRoutedMutationToAnchor is $not_routed_mutations (staying ~0)"
  else
    bad "frontdoor /healthz notRoutedMutationToAnchor is $not_routed_mutations, expected 0"
  fi
fi

if [ "$fail" -eq 0 ]; then
  echo "ALL PASS"
  exit 0
else
  echo "SOME TESTS FAILED"
  exit 1
fi
