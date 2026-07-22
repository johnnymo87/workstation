#!/usr/bin/env bash
set -euo pipefail

# audit/gate.sh - Pass/fail regression gate for front-door dispositions (F-D5)
#
# SAFETY PROPERTY: Every denied mutation this gate sends (PATCH /config,
# POST /experimental/workspace, POST /global/dispose, POST /mcp, etc.) is
# rejected by the door BEFORE it proxies to any serve — so the gate is
# side-effect-free even against the live production door. It must NOT send
# session-mutating requests (create/message/fork) — those are validated separately
# by a live "real turn" gate.

BASE_URL="http://127.0.0.1:4700"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      echo "Usage: $0 [BASE_URL]"
      echo "  BASE_URL   Base URL of the front door (default: http://127.0.0.1:4700)"
      exit 0
      ;;
    *)
      BASE_URL="$1"
      shift
      ;;
  esac
done

# Strip trailing slash
BASE_URL="${BASE_URL%/}"

echo "Front Door Through-Door Disposition Gate (F-D5)"
echo "Target Base URL: ${BASE_URL}"
echo "--------------------------------------------------------------------------------"

# Temporary files for curl output
BODY_FILE=$(mktemp)
HEADERS_FILE=$(mktemp)

cleanup() {
  rm -f "$BODY_FILE" "$HEADERS_FILE"
}
trap cleanup EXIT

# Global counters
PASSED=0
FAILED=0

# Helper to run checks
# Args:
#   1: check_class
#   2: method
#   3: path
#   4: expected_status_desc (e.g. "405", "403", "501", "410", "404", "400", or "NON-DENY")
#   5: allow_header_mode (GET, NONE, or ANY)
#   6: optional body substring pattern
assert_route() {
  local check_class="$1"
  local method="$2"
  local path="$3"
  local expected_status_desc="$4"
  local allow_mode="$5"
  local body_pattern="${6:-}"

  # Reset temp files
  echo -n "" > "$BODY_FILE"
  echo -n "" > "$HEADERS_FILE"

  local url="${BASE_URL}${path}"
  local -a curl_opts=("-s" "-S" "-o" "$BODY_FILE" "-D" "$HEADERS_FILE" "-w" "%{http_code}" "-X" "$method")

  # Add empty JSON body where mutate payload might be expected
  if [[ "$method" == "POST" || "$method" == "PATCH" ]]; then
    curl_opts+=("-H" "Content-Type: application/json" "-d" "{}")
  fi

  set +e
  local status_code
  status_code=$(curl "${curl_opts[@]}" "$url" 2>/dev/null)
  local curl_exit=$?
  set -e

  local details=""
  local result="PASS"

  if [ $curl_exit -ne 0 ]; then
    result="FAIL"
    details="curl failed with exit code ${curl_exit}"
  else
    # 1. Assert Status Code
    if [[ "$expected_status_desc" == "NON-DENY" ]]; then
      # Must NOT be in {403, 404, 405, 501, 410}
      if [[ "$status_code" =~ ^(403|404|405|501|410)$ ]]; then
        result="FAIL"
        details="Expected non-deny status, got ${status_code}"
      else
        details="Status: ${status_code} (not in deny-set)"
      fi
    else
      if [[ "$status_code" != "$expected_status_desc" ]]; then
        result="FAIL"
        details="Expected status ${expected_status_desc}, got ${status_code}"
      else
        details="Status: ${status_code}"
      fi
    fi

    # 2. Assert Allow Header if status matched and curl succeeded
    if [[ "$result" == "PASS" ]]; then
      # Extract allow header (case-insensitive)
      local allow_val=""
      if [ -f "$HEADERS_FILE" ]; then
        # Matches e.g. "allow: GET" or "Allow: GET"
        allow_val=$(grep -i "^allow:" "$HEADERS_FILE" | head -n1 | sed -E 's/^allow:[[:space:]]*//i' | tr -d '\r\n' || true)
      fi

      if [[ "$allow_mode" == "GET" ]]; then
        # Case-insensitive match on GET
        if [[ ! "$allow_val" =~ [Gg][Ee][Tt] ]]; then
          result="FAIL"
          details="${details}, Expected 'Allow: GET' header, got: '${allow_val}'"
        else
          details="${details}, Allow: ${allow_val}"
        fi
      elif [[ "$allow_mode" == "NONE" ]]; then
        if [[ -n "$allow_val" ]]; then
          result="FAIL"
          details="${details}, Expected NO 'Allow' header, got: '${allow_val}'"
        fi
      fi
    fi

    # 3. Assert Body Pattern if result is still PASS and a pattern is provided
    if [[ "$result" == "PASS" && -n "$body_pattern" ]]; then
      local body_content=""
      if [ -f "$BODY_FILE" ]; then
        body_content=$(cat "$BODY_FILE")
      fi
      if [[ ! "$body_content" =~ $body_pattern ]]; then
        result="FAIL"
        details="${details}, Body missing expected pattern '${body_pattern}' (got: '${body_content:0:40}...')"
      else
        details="${details}, Body verified"
      fi
    fi
  fi

  if [[ "$result" == "PASS" ]]; then
    printf "[PASS] %-15s %-6s %-38s | %s\n" "${check_class}" "${method}" "${path}" "${details}"
    PASSED=$((PASSED + 1))
  else
    printf "[FAIL] %-15s %-6s %-38s | %s\n" "${check_class}" "${method}" "${path}" "${details}"
    FAILED=$((FAILED + 1))
  fi
}

# ==============================================================================
# ASSERTIONS
# ==============================================================================

# A) The five 405 Allow: GET twins (must return 405 AND Allow: GET).
# This list MUST stay in sync with the vitest table-driven five-twin pin in
# test/dispatch.test.ts (derived from ROUTE_CLASSIFICATION_TABLE). The count went
# six -> five in T2/F3: GET /mcp was reclassified per-process-ro (501), so POST /mcp
# lost its GET twin and moved into the 403 deny set (group B) below.
assert_route "5-twins-config" "PATCH"  "/config"                           "405" "GET"
assert_route "5-twins-global" "PATCH"  "/global/config"                    "405" "GET"
assert_route "5-twins-worksp" "POST"   "/experimental/workspace"           "405" "GET"
assert_route "5-twins-worktr" "POST"   "/experimental/worktree"            "405" "GET"
assert_route "5-twins-apiint" "DELETE" "/api/integration/attempt/xyz"     "405" "GET"

# B) The 403 deny set (must return 403 AND NO Allow: GET)
assert_route "403-deny-mcp"   "POST"   "/mcp"                              "403" "NONE"
assert_route "403-deny-disp"  "POST"   "/global/dispose"                   "403" "NONE"

# C) Fixed per-class dispositions
# GET /mcp -> 501 (per-process MCP status is denied; body mentions per-process/MCP)
assert_route "fixed-mcp-get"  "GET"    "/mcp"                              "501" "ANY" "per-process|MCP"
# GET /global/event -> 410 (firehose is gone)
assert_route "fixed-glo-event" "GET"   "/global/event"                     "410" "ANY"
# GET /api/pty -> 501 (pty)
assert_route "fixed-pty-get"   "GET"   "/api/pty"                          "501" "ANY" "pty|PTY"
# GET / -> 404 (web-ui)
assert_route "fixed-root-get"  "GET"   "/"                                 "404" "ANY" "web_ui_not_served|web UI"
# GET /nonexistent-path-xyz -> 404 (unrecognized)
assert_route "fixed-unrec-get" "GET"   "/nonexistent-path-xyz"             "404" "ANY"
# GET /event (bare, no session_ids) -> 400 (session_ids required)
assert_route "fixed-event-get" "GET"   "/event"                            "400" "ANY"

# D) global-ro forwards (backend-dependent, assert "not denied by the door")
assert_route "forward-health"  "GET"   "/global/health"                    "NON-DENY" "ANY"

# ==============================================================================
# SUMMARY
# ==============================================================================
echo "--------------------------------------------------------------------------------"
echo "Summary: ${PASSED} passed, ${FAILED} failed"

if [ ${FAILED} -gt 0 ]; then
  exit 1
else
  exit 0
fi