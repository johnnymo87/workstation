#!/usr/bin/env bash
# Tests for agent-secret-env.sh. Sources the production file (default.nix is
# writeText of the same file), runs under the same `set -euo pipefail` the
# goose-serve start script uses, and asserts parity with shell-env.ts.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
plugin="$repo_root/assets/opencode/plugins/shell-env.ts"
# shellcheck source=agent-secret-env.sh
source "$script_dir/agent-secret-env.sh"

fail=0
pass() { printf 'PASS  %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1"; fail=1; }
assert_eq() {
  if [ "$1" = "$2" ]; then pass "$3"; else
    printf 'FAIL  %s\n        expected: %q\n        got:      %q\n' "$3" "$1" "$2"; fail=1
  fi
}

# --- 1. Parity with shell-env.ts ------------------------------------------
# Extract the `simple` table rows (["file", "VAR"]) from the plugin.
ts_rows="$(sed -n '/const simple:/,/^  \]/p' "$plugin" \
  | grep -oE '\["[a-z0-9_]+", "[A-Z0-9_]+"\]' \
  | sed -E 's/\["([a-z0-9_]+)", "([A-Z0-9_]+)"\]/\1 \2/' | sort)"
sh_rows="$(printf '%s\n' "${AGENT_SECRET_ENV_TABLE[@]}" | sort)"
ts_count="$(grep -c . <<<"$ts_rows" || true)"
# Every row-shaped line in the block must have been parsed; a row the regex
# above cannot read (e.g. a hyphenated file name) would otherwise drop out of
# BOTH sides and pass silently.
ts_candidates="$(sed -n '/const simple:/,/^  \]/p' "$plugin" | grep -cE '^[[:space:]]*\[' || true)"
if [ "$ts_candidates" != "$ts_count" ]; then
  bad "parity: shell-env.ts has $ts_candidates row-shaped lines but only $ts_count parsed"
fi
if [ "$ts_count" -lt 20 ]; then
  bad "parity: extracted only $ts_count rows from shell-env.ts; the extractor has rotted"
fi
if [ "$ts_rows" = "$sh_rows" ]; then
  pass "parity: table matches shell-env.ts simple table ($ts_count rows)"
else
  bad "parity: table differs from shell-env.ts simple table"
  diff <(printf '%s\n' "$ts_rows") <(printf '%s\n' "$sh_rows") | sed 's/^/        /' || true
fi
# The special cases must exist on both sides too.
for marker in azure_devops_pat bundle_source_host bundle_source_token; do
  if grep -q "/run/secrets/$marker" "$plugin" && grep -q "/$marker\"" "$script_dir/agent-secret-env.sh"; then
    pass "parity: special case $marker handled on both sides"
  else
    bad "parity: special case $marker missing on one side"
  fi
done

# --- 2. Behaviour against a fixture secrets dir -----------------------------
fx="$(mktemp -d)"
trap 'rm -rf "$fx"' EXIT
printf 'gh-value\n' >"$fx/github_api_token"
printf '  padded-site \n\n' >"$fx/atlassian_site"
printf '\n' >"$fx/dd_pat"                       # empty after trim
printf 'oauth\n' >"$fx/claude_personal_oauth_token"
printf 'gem\n' >"$fx/gemini_api_key"
printf 'ado\n' >"$fx/azure_devops_pat"
printf 'pkgs.example.com\n' >"$fx/bundle_source_host"
printf 'bundle-tok\n' >"$fx/bundle_source_token"
printf 'unreadable\n' >"$fx/jenkins_user"; chmod 000 "$fx/jenkins_user"

run() {
  # Fresh subshell with a clean slate for every name the script can export.
  env -i PATH="$PATH" AGENT_SECRET_ENV_SKIP="${1:-}" bash -c '
    set -euo pipefail
    source "$0"
    agent_secret_env_export "$1"
    env
  ' "$script_dir/agent-secret-env.sh" "$fx"
}

out="$(run "")"
get() { sed -n "s/^$1=//p" <<<"$out"; }
assert_eq "gh-value" "$(get GH_TOKEN)" "exports GH_TOKEN"
assert_eq "gh-value" "$(get GITHUB_API_TOKEN)" "same file exports GITHUB_API_TOKEN"
assert_eq "padded-site" "$(get ATLASSIAN_SITE)" "trims surrounding whitespace"
grep -q '^DD_PAT=' <<<"$out" && bad "empty file must export nothing" || pass "empty file exports nothing"
if [ "$(id -u)" -ne 0 ]; then
  grep -q '^JENKINS_USER=' <<<"$out" && bad "unreadable file must export nothing" || pass "unreadable file exports nothing"
fi
grep -q '^HCLOUD_TOKEN=' <<<"$out" && bad "missing file must export nothing" || pass "missing file exports nothing"
assert_eq "ado" "$(get SYSTEM_ACCESSTOKEN)" "exports SYSTEM_ACCESSTOKEN"
assert_eq "$(printf ado | base64 -w0)" "$(get ADO_NPM_PAT_B64)" "exports ADO_NPM_PAT_B64"
assert_eq "bundle-tok" "$(get BUNDLE_PKGS__EXAMPLE__COM)" "composes bundler var name from host"
assert_eq "oauth" "$(get CLAUDE_CODE_OAUTH_TOKEN)" "no skip list: model creds exported"

out="$(run "CLAUDE_CODE_OAUTH_TOKEN GOOGLE_GENERATIVE_AI_API_KEY GEMINI_API_KEY")"
for n in CLAUDE_CODE_OAUTH_TOKEN GOOGLE_GENERATIVE_AI_API_KEY GEMINI_API_KEY; do
  grep -q "^$n=" <<<"$out" && bad "skip list must suppress $n" || pass "skip list suppresses $n"
done
assert_eq "gh-value" "$(get GH_TOKEN)" "skip list leaves other names alone"

# Hostile host: must not produce a non-identifier export.
printf 'evil host;x\n' >"$fx/bundle_source_host"
out="$(run "")"
grep -q '^BUNDLE_EVIL' <<<"$out" && bad "non-identifier bundler host must be refused" || pass "non-identifier bundler host refused"

# Missing root entirely: exports nothing, does not fail under set -e.
if env -i PATH="$PATH" bash -c 'set -euo pipefail; source "$0"; agent_secret_env_export /nonexistent; env' \
    "$script_dir/agent-secret-env.sh" >"$fx/none.txt"; then
  grep -qE '^(GH_TOKEN|SYSTEM_ACCESSTOKEN)=' "$fx/none.txt" && bad "missing root exported something" || pass "missing root: exits 0, exports nothing"
else
  bad "missing root: failed under set -euo pipefail"
fi

# Silence: sourcing + exporting prints nothing (values must never reach a journal).
chmod 600 "$fx/jenkins_user"
noise="$(env -i PATH="$PATH" bash -c 'set -euo pipefail; source "$0"; agent_secret_env_export "$1"' \
  "$script_dir/agent-secret-env.sh" "$fx" 2>&1)"
assert_eq "" "$noise" "prints nothing on stdout or stderr"

if [ "$fail" -ne 0 ]; then
  echo "agent-secret-env-sh tests FAILED"
  exit 1
fi
echo "all agent-secret-env-sh tests passed"
