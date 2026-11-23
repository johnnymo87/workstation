# devbox reads cloudbox's Claude Max quota verdict (bead workstation-91cw; epic
# eng-agent-platform-ul4.24, design docs/plans/2026-11-23-quota-aware-coordinators-design.md
# in eng-agent-platform).
#
# The Max accounts are one pool shared by both hosts, and quota-watch's headroom and
# burn come from per-account 7-day utilization, which is account-wide. So cloudbox's
# verdict already reflects devbox's draw, and devbox runs no ledger or quota-watch of
# its own. Devbox cannot reach cloudbox directly; the carrier is pigeon's worker R2
# media store, which both hosts already authenticate to with their machine key:
#
#   cloudbox, after each llm-quota-watch run:
#     llm-ledger quota-outlook  -> POST /media/upload  key=state/cloudbox/quota-outlook.json
#   devbox, every 2 min (this module):
#     GET /media/state/cloudbox/quota-outlook.json -> ~/.local/state/quota-outlook/cloudbox.json
#
# `llm-ledger` on dev's PATH here is the real package with LLM_LEDGER_OUTLOOK_JSON
# pointed at that copy, so a bare `llm-ledger quota-outlook` (stall-watch, agent-wait)
# re-derives age and staleness from the reading's own ts: a copy that stops being
# refreshed reads `unknown` 20 min after cloudbox's last quota-watch run, however
# the chain broke. A fetch failure therefore leaves the old copy in place and needs
# no alert of its own.
#
# Like cloudbox (home.cloudbox.nix), llm-ledger goes in home.packages, never
# environment.systemPackages (that restarts teamclaude.service).
{ config, pkgs, lib, isDevbox, ... }:

let
  stateDir = "${config.home.homeDirectory}/.local/state/quota-outlook";
  copy = "${stateDir}/cloudbox.json";
  objectKey = "state/cloudbox/quota-outlook.json";

  llmLedger = pkgs.callPackage ../../pkgs/llm-ledger { };
  llmLedgerRemote = pkgs.symlinkJoin {
    name = "llm-ledger-remote-outlook";
    paths = [ llmLedger ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram $out/bin/llm-ledger --set-default LLM_LEDGER_OUTLOOK_JSON ${copy}
    '';
  };

  fetch = pkgs.writeShellApplication {
    name = "quota-outlook-fetch";
    runtimeInputs = [ pkgs.curl pkgs.jq pkgs.coreutils ];
    text = ''
      # Overridable only so the script can be exercised against a stub worker.
      url_file="''${QUOTA_OUTLOOK_URL_FILE:-/run/secrets/ccr_worker_url}"
      key_file="''${QUOTA_OUTLOOK_KEY_FILE:-/run/secrets/pigeon_worker_key}"
      state_dir="''${QUOTA_OUTLOOK_STATE_DIR:-${stateDir}}"
      for f in "$url_file" "$key_file"; do
        [ -r "$f" ] && [ -s "$f" ] || { echo "quota-outlook-fetch: $f missing or empty" >&2; exit 1; }
      done
      url="$(tr -d '[:space:]' < "$url_file")"

      mkdir -p "$state_dir"
      tmp="$(mktemp "$state_dir/.cloudbox.json.XXXXXX")"
      trap 'rm -f "$tmp"' EXIT

      # The key goes in a header read from a file descriptor, never on argv.
      code="$(curl -sS --max-time 20 --max-filesize 65536 -o "$tmp" -w '%{http_code}' \
        -H @<(printf 'Authorization: Bearer %s\n' "$(tr -d '[:space:]' < "$key_file")") \
        "$url/media/${objectKey}")" || { echo "quota-outlook-fetch: curl failed (http $code)" >&2; exit 1; }

      if [ "$code" = 404 ]; then
        # The router answers an unknown path with the same 404 body as a missing object, so
        # prove the URL and key with /whoami before calling this "not published yet".
        who="$(curl -sS --max-time 20 -o /dev/null -w '%{http_code}' \
          -H @<(printf 'Authorization: Bearer %s\n' "$(tr -d '[:space:]' < "$key_file")") \
          "$url/whoami")" || who=000
        if [ "$who" != 200 ]; then
          echo "quota-outlook-fetch: 404 for ${objectKey} and /whoami answered HTTP $who; check the worker URL and key" >&2
          exit 1
        fi
        echo "quota-outlook-fetch: cloudbox has not published ${objectKey} yet; leaving the old copy" >&2
        exit 0
      fi
      if [ "$code" != 200 ]; then
        echo "quota-outlook-fetch: HTTP $code from the worker; leaving the old copy" >&2
        exit 1
      fi
      if ! jq -e 'type == "object" and (.verdict | type == "string")' "$tmp" > /dev/null; then
        echo "quota-outlook-fetch: response is not an outlook object; leaving the old copy" >&2
        exit 1
      fi
      chmod 0644 "$tmp"
      mv -f "$tmp" "$state_dir/cloudbox.json"
      trap - EXIT
      echo "quota-outlook-fetch: $(jq -r '"\(.verdict) ts=\(.ts)"' "$state_dir/cloudbox.json")"
    '';
  };
in
lib.mkIf isDevbox {
  home.packages = [ llmLedgerRemote ];

  systemd.user.services.quota-outlook-fetch = {
    Unit.Description = "Copy cloudbox's Claude Max quota outlook from pigeon's worker (workstation-91cw)";
    Service = {
      Type = "oneshot";
      ExecStart = "${fetch}/bin/quota-outlook-fetch";
      Nice = 10;
      TimeoutStartSec = "1min";
    };
  };

  systemd.user.timers.quota-outlook-fetch = {
    Unit.Description = "Copy cloudbox's quota outlook every 2 min";
    Timer = {
      OnBootSec = "1min";
      OnUnitActiveSec = "2min";
      AccuracySec = "15s";
    };
    Install.WantedBy = [ "timers.target" ];
  };
}
