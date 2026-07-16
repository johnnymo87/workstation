#!/usr/bin/env bash
set -euo pipefail

# audit/probe.sh - Live curl -N probe matrix against opencode serve
# Runs strictly read-only against a serve by default.
# Used to verify route-to-class mapping and diff direct-to-serve vs through-the-door.

MUTATE=false
BASE="http://127.0.0.1:4096"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mutate)
      MUTATE=true
      shift
      ;;
    --help|-h)
      echo "Usage: $0 [--mutate] [BASE_URL]"
      echo "  --mutate   Execute mutating checks (POST /session, POST /global/dispose, etc.)"
      echo "  BASE_URL   Base URL of the target service (default: http://127.0.0.1:4096)"
      exit 0
      ;;
    *)
      BASE="$1"
      shift
      ;;
  esac
done

# Strip trailing slash from BASE if present
BASE="${BASE%/}"

# Fetch an active session ID if available, otherwise use a placeholder
SID=""
if curl -sS --connect-timeout 2 "${BASE}/session" > /dev/null; then
  SID=$(curl -sS --connect-timeout 2 "${BASE}/session" | jq -r '.[0].id // empty' 2>/dev/null || true)
fi

if [ -z "$SID" ]; then
  SID="ses_dummy_session_id"
fi

printf "Probing surface against base: %s\n" "${BASE}"
printf "Using active Session ID: %s\n" "${SID}"
printf "Mutative checks: %s\n" "${MUTATE}"
echo "-------------------------------------------------------------------------------------------------------"
printf "%-17s | %-52s | %-11s | %s\n" "class" "method path" "http_status" "first-bytes/notes"
echo "-------------------------------------------------------------------------------------------------------"

probe() {
  local class="$1"
  local method="$2"
  local path="$3"
  local is_stream="${4:-false}"
  local is_mutating="${5:-false}"

  if [ "$is_mutating" = "true" ] && [ "$MUTATE" != "true" ]; then
    printf "%-17s | %-6s %-45s | %-11s | %s\n" "$class" "$method" "$path" "SKIP" "Mutating route; run with --mutate to execute"
    return
  fi

  # Replace placeholder {sessionID} in path
  local real_path="${path//\{sessionID\}/$SID}"
  local url="${BASE}${real_path}"
  local curl_opts=("-s" "-S")

  if [ "$is_stream" = "true" ]; then
    curl_opts+=("-N" "--max-time" "3")
  fi

  if [ "$method" = "POST" ]; then
    curl_opts+=("-X" "POST" "-d" "{}")
  fi

  set +e
  local response
  response=$(curl "${curl_opts[@]}" -w "\n%{http_code}" "$url" 2>/dev/null)
  local exit_status=$?
  set -e

  # Handle timeouts or curl failures
  if [ $exit_status -ne 0 ] && [ $exit_status -ne 28 ]; then
    printf "%-17s | %-6s %-45s | %-11s | %s\n" "$class" "$method" "$path" "ERROR" "curl failed with exit code $exit_status"
    return
  fi

  local status_code="${response##*$'\n'}"
  local body="${response%$'\n'*}"

  # Clean and truncate body for display
  local first_line=""
  IFS=$'\n' read -r first_line <<< "$body"
  # Trim leading/trailing whitespace
  first_line=$(echo "$first_line" | xargs)
  # Limit first line length to 80 chars
  if [ ${#first_line} -gt 80 ]; then
    first_line="${first_line:0:77}..."
  fi

  if [ -z "$first_line" ]; then
    if [ $exit_status -eq 28 ]; then
      first_line="(stream connection closed/timeout)"
    else
      first_line="(empty response)"
    fi
  fi

  printf "%-17s | %-6s %-45s | %-11s | %s\n" "$class" "$method" "$path" "$status_code" "$first_line"
}

# 1. session-path: sid is in the path
probe "session-path" "GET" "/session/{sessionID}" "false" "false"

# 2. session-query: sid in query param
probe "session-query" "GET" "/event?session_ids={sessionID}" "true" "false"

# 3. create: POST /session (mutating)
probe "create" "POST" "/session" "false" "true"

# 4. pty: /pty/* (out of scope v1)
probe "pty" "GET" "/pty" "false" "false"

# 5. global-ro: read-only global
probe "global-ro" "GET" "/global/health" "false" "false"

# 6. global-sideeffect: /global/dispose (mutating)
probe "global-sideeffect" "POST" "/global/dispose" "false" "true"

# 7. global-event: /global/event (stream)
probe "global-event" "GET" "/global/event" "true" "false"

# 8. web-ui: web UI root / static assets (not in /doc)
probe "web-ui" "GET" "/" "false" "false"

# 9. unrecognized: default fallthrough
probe "unrecognized" "GET" "/nonexistent-path" "false" "false"
