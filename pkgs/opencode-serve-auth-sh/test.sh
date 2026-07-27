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
minimal_dir="$(mktemp -d)"
trap 'rm -f "$tmp_file"; rm -rf "$minimal_dir"' EXIT
printf "  file_pass_456 \r\n" > "$tmp_file"
OPENCODE_SERVER_PASSWORD_FILE="$tmp_file"
serve_auth_load
assert_array_len 2 "${#SERVE_AUTH_CURL_ARGS[@]}" "file password yields array of length 2"
assert_eq "customuser:file_pass_456" "${SERVE_AUTH_CURL_ARGS[1]}" "file password trimmed of leading/trailing whitespace & newlines"

# 6. The resolver must not depend on any external binary that callers might not
#    ship. This is not hypothetical: the cloudbox serve canary REPLACES PATH
#    (`export PATH=${lib.makeBinPath [...]}`, no `:$PATH`) with a closure that
#    has coreutils but NOT gnused. A sed-based trim there does not error
#    loudly -- `$(printf ... | sed ...)` just yields the empty string, so the
#    password silently becomes empty, the credential is silently omitted, and
#    every probe 401s. That is exactly the silent auth-off failure this whole
#    change exists to prevent. Same class as the driftAlert `sed -n 2p` bug
#    already recorded in hosts/cloudbox/configuration.nix:141-145.
#
#    Run the resolver with a PATH pointing at an EMPTY directory -- no sed, no
#    cat, nothing -- and assert it still resolves and still trims. That pins
#    the stronger property: the resolver uses bash builtins only.
for probe in "  nosed_pass  " $'\tnosed_pass\r\n'; do
  actual="$(
    PATH="$minimal_dir" \
    OPENCODE_SERVER_PASSWORD="$probe" \
    OPENCODE_SERVER_USERNAME="opencode" \
    OPENCODE_SERVER_PASSWORD_FILE="/nonexistent/path/to/secret" \
    "$BASH" -c 'source "$1"; serve_auth_load; printf "%s" "${SERVE_AUTH_CURL_ARGS[1]:-<none>}"' _ \
      "$script_dir/opencode-serve-auth.sh"
  )"
  assert_eq "opencode:nosed_pass" "$actual" "resolves+trims with a sed-less PATH (canary PATH shape)"
done

# 7. Same, via the secret-file branch (the path systemd units actually take).
actual="$(
  PATH="$minimal_dir" \
  OPENCODE_SERVER_PASSWORD_FILE="$tmp_file" \
  OPENCODE_SERVER_USERNAME="opencode" \
  "$BASH" -c 'unset OPENCODE_SERVER_PASSWORD; source "$1"; serve_auth_load; printf "%s" "${SERVE_AUTH_CURL_ARGS[1]:-<none>}"' _ \
    "$script_dir/opencode-serve-auth.sh"
)"
assert_eq "opencode:file_pass_456" "$actual" "resolves+trims from secret file with a sed-less PATH"

if [ "$fail" -eq 0 ]; then
  echo "all opencode-serve-auth-sh tests passed"
  exit 0
else
  echo "opencode-serve-auth-sh tests failed"
  exit 1
fi
