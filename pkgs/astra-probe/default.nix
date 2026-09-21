# astra-probe -- can `openai/gpt-6-astra` be dispatched through codex-lb right now?
#
# WHY THIS EXISTS. On devbox `adversarial-reviewer-astra` is the DEFAULT
# adversarial reviewer, and opencode's Task tool renders a subagent whose turn
# died on an API error as an EMPTY task_result with state "completed" -- no
# error reaches the dispatching agent. A codex-lb outage therefore presents as
# "the reviewer had nothing to say". See the incident note in
# users/dev/codex-lb.nix for the 2026-09-21 quota exhaustion that motivated it.
#
# WHAT IT DOES AND DOES NOT CLAIM. It reads two codex-lb endpoints and reports
# what codex-lb *says about itself*. It does NOT prove a dispatch will succeed:
# the real selection path also weighs per-account error backoff, cooldowns,
# model/account eligibility and remaining budget, and another caller can drain
# the window between the probe and your request. So UP means "nothing known to
# be blocking", not "guaranteed". Treat DOWN as authoritative (it names a
# condition that does block) and UP as permission to try.
#
# Deliberately NOT a live inference request. A real call is the only truthful
# test, but it spends credits from the same 5h window the probe exists to
# protect -- a review measured 35-157 credits against a 1125-credit Pro 5x
# window, so a probe you run before every dispatch must stay free.
#
# EXIT CODES ARE THE INTERFACE (an agent branches on these):
#   0  UP       -- catalog has astra and at least one account reports `active`
#   1  DOWN     -- a specific, named blocking condition
#   2  UNKNOWN  -- could not classify: HTTP error, or a response shape/status
#                  this probe does not understand
#
# UNKNOWN exists because the alternative is worse. codex-lb is a pinned
# third-party service we do not control; when it renames a status or reshapes
# its JSON, a probe that folds that into UP is a false green in front of the
# reviewer, and one that folds it into DOWN blocks work for a schema change.
# Neither is honest, so drift gets its own exit code and says so out loud.
{ lib, writeShellApplication, curl, jq }:

writeShellApplication {
  name = "astra-probe";
  runtimeInputs = [ curl jq ];
  text = ''
    base="''${CODEX_LB_URL:-http://127.0.0.1:2455}"

    # fetch <path> <body-file> -> body written to the file, nothing on stdout.
    # On failure it prints the DIAGNOSTIC on stdout and returns 1, so the caller
    # can capture it with $(...). An earlier version set a global instead, which
    # command substitution runs in a subshell and silently discards -- the error
    # text vanished and every failure reported an empty reason.
    #
    # The two failure families are kept apart because they need different
    # actions: a refused connection means "start the unit", while a 401/500
    # means codex-lb is alive and something else is wrong. "Not answering"
    # covered both and pointed the reader at the wrong one.
    fetch() {
      local path="$1" body="$2" code rc
      code="$(curl -sS -o "$body" -w '%{http_code}' --max-time 5 "$base$path" 2>/dev/null)" && rc=0 || rc=$?
      if [ "$rc" -ne 0 ]; then
        printf 'codex-lb not answering at %s%s (curl exit %s; check: systemctl --user status codex-lb)' "$base" "$path" "$rc"
        return 1
      fi
      case "$code" in
        2??) return 0 ;;
        *)   printf 'codex-lb answered HTTP %s for %s -- the service is up, so a restart is not the fix; check its log (journalctl --user -u codex-lb)' "$code" "$path"
             return 1 ;;
      esac
    }

    # Both jq programs below slurp (-s) and require EXACTLY ONE document, then
    # type-check every field they touch before using it. The first draft used
    # `.accounts[]` directly, which happily iterates an OBJECT: a response of
    # {"accounts":{"oops":{"status":"active"}}} printed UP. Iterating an
    # unvalidated container is the whole bug class, so nothing here indexes
    # before checking `type`.
    # shellcheck disable=SC2016  # jq program: $-expressions are jq's, not bash's
    accounts_jq='
      def known: ["active","paused","rate_limited","quota_exceeded","reauth_required","deactivated"];
      def pct($v): if ($v|type) == "number" then "\($v)%" else "?" end;
      def acctname: (.displayName // .accountId // "<unnamed>");
      def detail: [ .accounts[]
        | "\(acctname): \(.status), 5h \(pct(.usage.primaryRemainingPercent)) left (resets \(.resetAtPrimary // "?")), weekly \(pct(.usage.secondaryRemainingPercent)) left (resets \(.resetAtSecondary // "?"))" ]
        | join("; ");
      if length != 1 then
        "UNKNOWN\texpected exactly one JSON document from /api/accounts, got \(length)"
      else .[0] |
        if (type != "object") or ((.accounts|type) != "array") then
          "UNKNOWN\tunsupported /api/accounts shape (expected an object with an .accounts array)"
        elif ([.accounts[] | select(type != "object")] | length) > 0 then
          "UNKNOWN\tunsupported /api/accounts shape (.accounts holds non-object entries)"
        elif (.accounts | length) == 0 then
          "DOWN\tno accounts configured in codex-lb (log one in via the dashboard on \(env.CODEX_LB_URL // "http://127.0.0.1:2455"))"
        # `.status as $s` first: inside `known | index(...)` the input `.` is the
        # known-status ARRAY, so a bare `index(.status)` indexes that array with
        # a string and dies ("Cannot index array with string").
        elif ([.accounts[] | select(((.status|type) != "string") or (.status as $s | (known | index($s)) == null))] | length) > 0 then
          "UNKNOWN\tcodex-lb reported an account status this probe does not know (\([.accounts[] | .status | tostring] | join(", "))) -- the status table here is stale, do not read this as an outage; \(detail)"
        elif ([.accounts[] | select(.status == "active")] | length) > 0 then
          "UP\t\([.accounts[] | select(.status == "active")] | length) account(s) report active -- \(detail)"
        else
          "DOWN\tno account in status active -- \(detail)"
        end
      end'

    # shellcheck disable=SC2016  # jq program: $-expressions are jq's, not bash's
    models_jq='
      if length != 1 then
        "UNKNOWN\texpected exactly one JSON document from /v1/models, got \(length)"
      else .[0] |
        if (type != "object") or ((.data|type) != "array") then
          "UNKNOWN\tunsupported /v1/models shape (expected an object with a .data array)"
        elif ([.data[] | select((.id? // null) == "gpt-6-astra")] | length) > 0 then
          "PRESENT\t"
        else
          "DOWN\tgpt-6-astra absent from the codex-lb model catalog (catalog refresh unhealthy, or it was cleared while no account was active -- it repopulates on the 300s refresh)"
        end
      end'

    # classify <json> <program> -> "<CODE>\t<message>"; UNKNOWN if jq itself fails.
    classify() {
      local out
      if out="$(jq -rs "$2" <<<"$1" 2>/dev/null)" && [ -n "$out" ]; then
        printf '%s\n' "$out"
      else
        printf 'UNKNOWN\tcould not parse the codex-lb response as JSON\n'
      fi
    }

    report() {  # <CODE> <message> -> prints one line, exits with the code's status
      case "$1" in
        UP)      printf 'astra UP: %s\n' "$2"      ; exit 0 ;;
        DOWN)    printf 'astra DOWN: %s\n' "$2"    ; exit 1 ;;
        *)       printf 'astra UNKNOWN: %s\n' "$2" ; exit 2 ;;
      esac
    }

    accounts_body="$(mktemp)"
    models_body="$(mktemp)"
    trap 'rm -f "$accounts_body" "$models_body"' EXIT

    if ! err="$(fetch /api/accounts "$accounts_body")"; then
      report DOWN "$err"
    fi
    if ! err="$(fetch /v1/models "$models_body")"; then
      report DOWN "$err"
    fi
    accounts="$(cat "$accounts_body")"
    models="$(cat "$models_body")"

    # Catalog first: astra missing is a more specific answer than "an account is
    # blocked", and during a re-auth both are true at once for ~5 minutes.
    line="$(classify "$models" "$models_jq")"
    code="''${line%%$'\t'*}"
    msg="''${line#*$'\t'}"
    [ "$code" = "PRESENT" ] || report "$code" "$msg"

    line="$(classify "$accounts" "$accounts_jq")"
    code="''${line%%$'\t'*}"
    msg="''${line#*$'\t'}"
    report "$code" "$msg"
  '';

  meta = {
    description = "Report whether openai/gpt-6-astra is dispatchable through codex-lb";
    mainProgram = "astra-probe";
    platforms = lib.platforms.unix;
  };
}
