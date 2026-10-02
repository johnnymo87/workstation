# codex-lb-status -- `teamclaude status`, but for codex-lb.
#
# Per-account usage of the local codex-lb rotator (5h / weekly / monthly USED
# percent with time-to-reset, account status, last usage refresh, deactivation
# reason, lifetime request totals), then a fleet footer from /api/usage/summary.
#
# DESIGN DECISIONS (from an adversarial review, session ses_f5ffc5011ffe...):
#
# * PER-ACCOUNT IS THE DEFAULT, FLEET IS A FOOTER. codex-lb's summary is a
#   capacity-weighted mean with resetAt = min(); one dead account plus one full
#   one reads "50% left". The footer says so on screen.
#
# * USED, NOT REMAINING. codex-lb reports remaining percent; teamclaude shows
#   used. We print used, labelled, so the two readouts compare at a glance.
#
# * PERCENT, NOT CREDITS. codex-lb's "credits" are synthesized from a
#   hard-coded plan table x (1 - used%); used-percent is the only real datum.
#
# * STALENESS SIGNALS. An account in reauth_required keeps showing its
#   last-known percentages, so the readout marks old numbers three ways:
#   "reset passed ... (stale)" on a window whose reset time is in the past,
#   the status/"Reason" lines, and "Token refreshed N ago (OVERDUE...)".
#   Note lastRefreshAt is the OAuth TOKEN refresh (every 8 days upstream),
#   not usage freshness: codex-lb's per-account usage timestamp
#   (usage_refreshed_at) is excluded from /api/accounts and only exposed on
#   the API-key-authenticated /api/fleet/summary. Hence the 9-day threshold.
#
# * "Lifetime" request/token/cost totals are per-account lifetime, unlike the
#   footer's 7d figures -- they are not expected to agree.
#
# AUTH: NONE, AND THAT IS FRAGILE ON PURPOSE. codex-lb grants implicit admin to
# a request that is LOCAL -- loopback socket AND Host header in {localhost,
# 127.0.0.1, ::1} AND no X-Forwarded-For-family header -- on an install with no
# dashboard password. So the host is hard-coded to 127.0.0.1 and only the port
# is configurable (CODEX_LB_PORT); a CODEX_LB_URL override would let a hostname
# alias in and turn every call into a 401. ONE-WAY DOOR: setting a dashboard
# password (or TOTP) makes every endpoint here 401 permanently; this tool has
# no login path and says so when it sees the 401.
#
# EXIT CODES: 0 printed a status; 1 codex-lb unreachable or answered an HTTP
# error; 2 codex-lb answered something unrecognized, or bad usage.
#
# Tests: test_codex_lb_status.py, run against this derivation's binary by the
# `codex-lb-status-tests` flake check.
{ writeShellApplication, curl, jq, coreutils, gnused }:

writeShellApplication {
  name = "codex-lb-status";
  runtimeInputs = [ curl jq coreutils gnused ];
  text = ''
    usage() {
      cat <<'EOF'
    Usage: codex-lb-status

    Show per-account usage of the local codex-lb (ChatGPT/Codex rotator):
    5h / weekly used %, time to reset, account status, last usage refresh,
    and a capacity-weighted fleet footer.

    Environment:
      CODEX_LB_PORT   codex-lb port on 127.0.0.1 (default 2455). The host is
                      fixed: codex-lb only skips auth for 127.0.0.1/localhost.

    Exit: 0 ok, 1 unreachable / HTTP error, 2 unrecognized response.
    EOF
    }

    case "''${1:-}" in
      -h|--help) usage; exit 0 ;;
      "") ;;
      *) echo "codex-lb-status: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac

    port="''${CODEX_LB_PORT:-2455}"
    case "$port" in
      ""|*[!0-9]*)
        echo "codex-lb-status: CODEX_LB_PORT must be a port number, got '$port' (the host is always 127.0.0.1)" >&2
        exit 2 ;;
    esac
    base="http://127.0.0.1:$port"
    now="''${CODEX_LB_STATUS_NOW:-$(date +%s)}"

    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    if [ "$(uname -s)" = Darwin ]; then
      svc_hint="launchctl print gui/$(id -u)/org.nix-community.home.codex-lb"
    else
      svc_hint="systemctl --user status codex-lb"
    fi

    # fetch <path> <body-file>: 0 on 2xx; otherwise prints a diagnostic on
    # stdout and returns 1 (connection failure) or 3 (HTTP error).
    fetch() {
      local path="$1" out="$2" code rc detail
      code="$(curl -sS -o "$out" -w '%{http_code}' --max-time 5 "$base$path" 2>/dev/null)" && rc=0 || rc=$?
      if [ "$rc" -ne 0 ]; then
        if [ -e "$HOME/.codex-lb/enabled" ]; then
          printf 'codex-lb is enabled on this host but not answering at %s (curl exit %s); check: %s' "$base" "$rc" "$svc_hint"
        else
          printf 'codex-lb is not enabled on this host (no ~/.codex-lb/enabled) and nothing answers at %s' "$base"
        fi
        return 1
      fi
      case "$code" in
        2??) return 0 ;;
      esac
      detail="$(jq -r '(.error.code? // .error.message? // .error? // .detail? // empty) | tostring' "$out" 2>/dev/null || true)"
      printf 'codex-lb answered HTTP %s for %s%s' "$code" "$path" "''${detail:+ ($detail)}"
      case "$code" in
        401|403)
          printf -- '; loopback requests are password-free only while no codex-lb dashboard password/TOTP is set, and codex-lb-status has no login path' ;;
        *)
          printf -- '; the service is up, see its log' ;;
      esac
      return 3
    }

    acc="$tmp/accounts.json"
    if ! msg="$(fetch /api/accounts "$acc")"; then
      echo "codex-lb-status: $msg" >&2
      exit 1
    fi
    if ! jq -e . "$acc" >/dev/null 2>&1; then
      echo "codex-lb-status: unrecognized /api/accounts response (not JSON)" >&2
      exit 2
    fi

    # The summary is a footer: if it fails, still show the accounts.
    sum="$tmp/summary.json"
    sumerr=""
    if ! sumerr="$(fetch /api/usage/summary "$sum")"; then
      : > "$sum"
    elif ! jq -e . "$sum" >/dev/null 2>&1; then
      sumerr="/api/usage/summary returned non-JSON"
      : > "$sum"
    fi

    if ! out="$(jq -n -r \
        --slurpfile acc "$acc" \
        --slurpfile summary "$sum" \
        --arg sumerr "$sumerr" \
        --arg port "$port" \
        --argjson now "$now" \
        -f ${./status.jq} 2>"$tmp/err")"; then
      echo "codex-lb-status: $(sed 's/^jq: error[^:]*: //' "$tmp/err")" >&2
      exit 2
    fi
    printf '%s\n' "$out"
  '';
}
