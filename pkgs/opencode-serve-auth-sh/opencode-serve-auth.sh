# Shell helper to load opencode serve HTTP Basic auth credentials into curl flags.
# Populates SERVE_AUTH_CURL_ARGS (bash array); empty when auth is off.
#
# TRADEOFF NOTE: Using `-u "$user:$pass"` with curl puts the password in the
# process's argv, visible via `ps` to other processes running as the same user.
# We accept this tradeoff because the secret file or environment variable is
# already readable by the same user, so exposing it in process argv grants no
# new capability to unprivileged or other-user processes -- but note it so
# nobody assumes argv is safe.
serve_auth_load() {
  local pass="${OPENCODE_SERVER_PASSWORD:-}"
  pass="$(printf '%s' "$pass" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

  if [ -z "$pass" ]; then
    local pass_file="${OPENCODE_SERVER_PASSWORD_FILE:-/run/secrets/opencode_server_password}"
    if [ -r "$pass_file" ]; then
      pass="$(cat "$pass_file" 2>/dev/null || true)"
      pass="$(printf '%s' "$pass" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    fi
  fi

  SERVE_AUTH_CURL_ARGS=()
  if [ -n "$pass" ]; then
    local user="${OPENCODE_SERVER_USERNAME:-opencode}"
    SERVE_AUTH_CURL_ARGS=(-u "$user:$pass")
  fi
}
