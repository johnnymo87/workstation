# Shared Anthropic OAuth proxy module
# Runs on devbox and Crostini; skipped on cloudbox and Darwin
{ pkgs, lib, isDevbox, isCrostini, ... }:

lib.mkIf (isDevbox || isCrostini) {

  home.file.".local/bin/anthropic-oauth-proxy" = {
    executable = true;
    text = ''
      #!${pkgs.bash}/bin/bash
      set -euo pipefail

      export ANTHROPIC_PROXY_OVERRIDE_UA="''${ANTHROPIC_PROXY_OVERRIDE_UA:-true}"
      export ANTHROPIC_PROXY_STRIP_CACHE_MARKERS="''${ANTHROPIC_PROXY_STRIP_CACHE_MARKERS:-false}"
      export ANTHROPIC_PROXY_DEBUG="''${ANTHROPIC_PROXY_DEBUG:-false}"

      if [[ ! -f "$HOME/projects/workstation/assets/opencode/plugins/anthropic-oauth-proxy/main.ts" ]]; then
        echo "anthropic-oauth-proxy: source not found, exiting" >&2
        exit 1
      fi

      exec ${pkgs.bun}/bin/bun "$HOME/projects/workstation/assets/opencode/plugins/anthropic-oauth-proxy/main.ts"
    '';
  };

  systemd.user.services.anthropic-oauth-proxy = {
    Unit = {
      Description = "Anthropic OAuth proxy for OpenCode";
      After = [ "network-online.target" ];
      Wants = [ "network-online.target" ];
    };
    Service = {
      ExecStart = "%h/.local/bin/anthropic-oauth-proxy";
      Restart = "always";
      RestartSec = 2;
      StandardOutput = "journal";
      StandardError = "journal";
      Environment = [
        "HOME=%h"
      ];
    };
    Install = {
      WantedBy = [ "default.target" ];
    };
  };

}
