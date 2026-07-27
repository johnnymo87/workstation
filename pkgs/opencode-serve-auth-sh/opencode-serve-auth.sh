# Shell helper to load opencode serve HTTP Basic auth credentials into curl flags.
# Populates SERVE_AUTH_CURL_ARGS (bash array); empty when auth is off.
#
# TRADEOFF NOTE: Using `-u "$user:$pass"` with curl puts the password in the
# process's argv, visible via `ps` to other processes running as the same user.
# We accept this tradeoff because the secret file or environment variable is
# already readable by the same user, so exposing it in process argv grants no
# new capability to unprivileged or other-user processes -- but note it so
# nobody assumes argv is safe.
#
# NO EXTERNAL BINARIES. Trimming is pure bash parameter expansion rather than
# `sed`, because callers do not all ship the same PATH closure. The cloudbox
# serve canary REPLACES PATH outright (`export PATH=${lib.makeBinPath [...]}`
# with no `:$PATH`) and that closure has coreutils but not gnused. A sed-based
# trim there does not fail usefully: it writes "sed: command not found" to
# stderr -- one line, buried in the journal -- and then evaluates to the EMPTY
# string, so the password vanishes, the credential is silently omitted, and
# every probe 401s while looking correctly configured. That is precisely the
# silent auth-off failure this credential work exists to prevent, and it is the
# same class as the `sed -n 2p` bug already recorded at
# hosts/cloudbox/configuration.nix:141-145. Bash builtins cannot be missing.
serve_auth_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

serve_auth_load() {
  local pass
  pass="$(serve_auth_trim "${OPENCODE_SERVER_PASSWORD:-}")"

  if [ -z "$pass" ]; then
    local pass_file="${OPENCODE_SERVER_PASSWORD_FILE:-/run/secrets/opencode_server_password}"
    if [ -r "$pass_file" ]; then
      # `$(<file)` is a bash redirection builtin -- no `cat` dependency either.
      pass="$(serve_auth_trim "$(<"$pass_file")")" 2>/dev/null || pass=""
    fi
  fi

  SERVE_AUTH_CURL_ARGS=()
  if [ -n "$pass" ]; then
    local user="${OPENCODE_SERVER_USERNAME:-opencode}"
    SERVE_AUTH_CURL_ARGS=(-u "$user:$pass")
  fi
}
