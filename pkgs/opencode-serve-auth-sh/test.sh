#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/opencode-serve-auth.sh"

fail=0
assert_eq() {
  local expected="$1" actual="$2" desc="$3"
  if [ "$expected" = "$actual" ]; then
    printf 'PASS  %s\n' "$desc"
  else
    printf 'FAIL  %s\n        expected: %q\n        got:      %q\n' "$desc" "$expected" "$actual"
    fail=1
  fi
}

assert_array_len() {
  local expected="$1" actual_len="$2" desc="$3"
  if [ "$expected" -eq "$actual_len" ]; then
    printf 'PASS  %s\n' "$desc"
  else
    printf 'FAIL  %s\n        expected len: %d\n        got len:      %d\n' "$desc" "$expected" "$actual_len"
    fail=1
  fi
}

# Helper to test expanding SERVE_AUTH_CURL_ARGS into dummy command
count_expanded_args() {
  set -- "${SERVE_AUTH_CURL_ARGS[@]+"${SERVE_AUTH_CURL_ARGS[@]}"}"
  echo "$#"
}

# 1. Unset env & missing file -> empty array
unset OPENCODE_SERVER_PASSWORD OPENCODE_SERVER_PASSWORD_FILE OPENCODE_SERVER_USERNAME
OPENCODE_SERVER_PASSWORD_FILE="/nonexistent/path/to/secret"
serve_auth_load
assert_array_len 0 "${#SERVE_AUTH_CURL_ARGS[@]}" "unset env & missing file yields empty array"
assert_eq 0 "$(count_expanded_args)" "empty array expands to 0 args with set -u guard"

# 2. Env set with leading/trailing whitespace
OPENCODE_SERVER_PASSWORD="  secret123  "$'\n'
serve_auth_load
assert_array_len 2 "${#SERVE_AUTH_CURL_ARGS[@]}" "env password yields array of length 2"
assert_eq "-u" "${SERVE_AUTH_CURL_ARGS[0]}" "first arg is -u"
assert_eq "opencode:secret123" "${SERVE_AUTH_CURL_ARGS[1]}" "password trimmed and default user opencode used"

# 3. Custom username
OPENCODE_SERVER_USERNAME="customuser"
serve_auth_load
assert_eq "customuser:secret123" "${SERVE_AUTH_CURL_ARGS[1]}" "custom username used"

# 4. Internal whitespace preserved
OPENCODE_SERVER_PASSWORD="  secret with spaces  "
serve_auth_load
assert_eq "customuser:secret with spaces" "${SERVE_AUTH_CURL_ARGS[1]}" "internal whitespace preserved"

# 5. Secret file fallback
unset OPENCODE_SERVER_PASSWORD
tmp_file="$(mktemp)"
trap 'rm -f "$tmp_file"' EXIT
printf "  file_pass_456 \r\n" > "$tmp_file"
OPENCODE_SERVER_PASSWORD_FILE="$tmp_file"
serve_auth_load
assert_array_len 2 "${#SERVE_AUTH_CURL_ARGS[@]}" "file password yields array of length 2"
assert_eq "customuser:file_pass_456" "${SERVE_AUTH_CURL_ARGS[1]}" "file password trimmed of leading/trailing whitespace & newlines"

if [ "$fail" -eq 0 ]; then
  echo "all opencode-serve-auth-sh tests passed"
  exit 0
else
  echo "opencode-serve-auth-sh tests failed"
  exit 1
fi
