# shellcheck shell=bash
#
# agent-secret-env.sh -- sourceable: export the sops-derived CLI/tool
# credentials an agent's shell needs (gh, Atlassian, BuildBuddy, Datadog,
# Jenkins, ...), reading /run/secrets/<file> directly.
#
# WHY THIS EXISTS. opencode sessions get these through the shell-env plugin
# (assets/opencode/plugins/shell-env.ts, loadSecretEnv), which injects them into
# every bash tool call. Agents that are NOT opencode -- goose, whose shells are
# children of goose-serve.service and inherit only that unit's environment --
# have no plugin hook, so the variables have to be in the serve's own
# environment. This file is that mechanism in bash.
#
# THE TABLE BELOW MUST MATCH shell-env.ts's `simple` table, row for row.
# pkgs/agent-secret-env-sh/test.sh parses both and fails `nix flake check` on
# any difference, so add a row in both places or neither. The two special cases
# (azure_devops_pat, bundle_source_host/token) mirror shell-env.ts too and are
# exercised by the same test.
#
# USAGE
#   source /nix/store/...-agent-secret-env.sh
#   AGENT_SECRET_ENV_SKIP="CLAUDE_CODE_OAUTH_TOKEN GEMINI_API_KEY" \
#     agent_secret_env_export            # reads /run/secrets
#   agent_secret_env_export /some/dir    # alternate root (tests)
#
# CONTRACT
#   - Every secret is optional: a missing, unreadable, or empty (after trimming)
#     file exports nothing. Host-safe where /run/secrets does not exist.
#   - Values are trimmed of leading/trailing whitespace, as shell-env.ts does.
#   - Names listed in AGENT_SECRET_ENV_SKIP (space-separated) are never exported.
#   - Never prints a value. Prints nothing at all.
#   - Safe under `set -euo pipefail`; defines only agent_secret_env_* names.

AGENT_SECRET_ENV_TABLE=(
  "github_api_token GH_TOKEN"
  "github_api_token GITHUB_API_TOKEN"
  "cloudflare_api_token CLOUDFLARE_API_TOKEN"
  "dolthub_api_token DOLTHUB_API_TOKEN"
  "claude_personal_oauth_token CLAUDE_CODE_OAUTH_TOKEN"
  "gemini_api_key GOOGLE_GENERATIVE_AI_API_KEY"
  "gemini_api_key GEMINI_API_KEY"
  "lichess_pat LICHESS_PAT"
  "typesafe_api_key TYPESAFE_API_KEY"
  "hcloud_token HCLOUD_TOKEN"
  "atlassian_api_token ATLASSIAN_API_TOKEN"
  "atlassian_site ATLASSIAN_SITE"
  "atlassian_email ATLASSIAN_EMAIL"
  "atlassian_cloud_id ATLASSIAN_CLOUD_ID"
  "google_cloud_project GOOGLE_CLOUD_PROJECT"
  "ba_cli_repo BA_CLI_REPO"
  "jenkins_api_token JENKINS_API_TOKEN"
  "jenkins_user JENKINS_USER"
  "jenkins_host JENKINS_HOST"
  "bundle_gem_fury_io BUNDLE_GEM__FURY__IO"
  "bundle_enterprise_contribsys_com BUNDLE_ENTERPRISE__CONTRIBSYS__COM"
  "bundle_gems_graphql_pro BUNDLE_GEMS__GRAPHQL__PRO"
  "dd_pat DD_PAT"
  "buildbuddy_host BUILDBUDDY_HOST"
  "buildbuddy_api_key BUILDBUDDY_API_KEY"
)

# Print the trimmed contents of a readable file, or nothing.
agent_secret_env_read() {
  local val
  [ -r "$1" ] || return 0
  val="$(cat -- "$1" 2>/dev/null)" || return 0
  val="${val#"${val%%[![:space:]]*}"}"
  val="${val%"${val##*[![:space:]]}"}"
  printf '%s' "$val"
}

agent_secret_env_skipped() {
  case " ${AGENT_SECRET_ENV_SKIP:-} " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

agent_secret_env_export() {
  local root="${1:-/run/secrets}" row file name val host token
  for row in "${AGENT_SECRET_ENV_TABLE[@]}"; do
    file="${row%% *}"
    name="${row##* }"
    agent_secret_env_skipped "$name" && continue
    val="$(agent_secret_env_read "$root/$file")"
    [ -n "$val" ] || continue
    export "$name=$val"
  done

  # Azure DevOps PAT: raw, and base64 for the private npm registry .npmrc.
  if ! agent_secret_env_skipped SYSTEM_ACCESSTOKEN; then
    val="$(agent_secret_env_read "$root/azure_devops_pat")"
    if [ -n "$val" ]; then
      export "SYSTEM_ACCESSTOKEN=$val"
      export "ADO_NPM_PAT_B64=$(printf '%s' "$val" | base64 -w0)"
    fi
  fi

  # Bundler source whose host is org-identifying: the variable NAME is derived
  # from a secret (BUNDLE_<HOST upper-cased, dots -> "__">), so the host never
  # appears in source. Refuse anything that would not be a plain identifier.
  host="$(agent_secret_env_read "$root/bundle_source_host")"
  token="$(agent_secret_env_read "$root/bundle_source_token")"
  if [ -n "$host" ] && [ -n "$token" ]; then
    host="${host^^}"
    name="BUNDLE_${host//./__}"
    if [[ "$name" =~ ^[A-Z0-9_]+$ ]] && ! agent_secret_env_skipped "$name"; then
      export "$name=$token"
    fi
  fi
}
