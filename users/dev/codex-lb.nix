# codex-lb: multi-account ChatGPT/Codex rotator — the OpenAI/Codex analog of
# teamclaude. A local OpenAI-compatible proxy on 127.0.0.1:2455 that pools
# personal ChatGPT *subscription* OAuth accounts, injects the active account's
# token + chatgpt-account-id server-side, tracks per-account 5h/weekly quota, and
# fails over between accounts. opencode's first-party `openai` provider is pointed
# at it by `injectCodexLbBaseUrl` in opencode-config.nix (gated on this unit being
# active), and the sol/terra/luna subscription model catalog is injected there.
#
# HOSTS: devbox + cloudbox (both NixOS/systemd). NOT macOS
# (launchd, not systemd — would need a separate darwin flavor). Each host runs
# its OWN codex-lb instance with its OWN account logins; ~/.codex-lb is per-host
# runtime state, never synced.
#
# OPT-IN PER HOST (ConditionPathExists = %h/.codex-lb/enabled): the code is
# present on every gated host, but the service only starts where the marker file
# exists. This keeps an un-bootstrapped host from starting an *empty* codex-lb
# that injectCodexLbBaseUrl would then reroute opencode's `openai` provider into
# (breaking openai there until an account is logged in). devbox's marker is
# created automatically below (it is already bootstrapped). To enable a NEW host:
#   1. run codex-lb once by hand to bootstrap the store + log in an account via
#      the dashboard (SSH-forward 2455, browser OAuth):
#        SSL_CERT_FILE=$(nix eval --raw nixpkgs#cacert)/etc/ssl/certs/ca-bundle.crt \
#          uvx --from codex-lb==1.20.1 codex-lb --host 127.0.0.1 --port 2455
#   2. touch ~/.codex-lb/enabled
#   3. systemctl --user start codex-lb   (and re-run home-manager switch to wire opencode)
#
# RUN VIA uvx (not a nix package): codex-lb is a FastAPI + bun-SPA app; packaging
# it purely in Nix is a big lift, so we run the pinned PyPI release through uv's
# ephemeral-tool runner (cached under ~/.cache/uv). Bump the pin deliberately.
#
# CONFIG/STATE IS RUNTIME (NOT nix-managed): codex-lb reads + REWRITES
# ~/.codex-lb/ (store.db with accounts + OAuth tokens that auto-refresh, plus
# encryption.key), so it must stay writable + persistent and is LOST on a full
# reprovision.
#
# TWO NixOS gotchas the env below fixes: (1) SSL_CERT_FILE — a bare user service
# has no CA bundle, so httpx/aiohttp can't verify chatgpt.com and every upstream
# call fails CERTIFICATE_VERIFY_FAILED; (2) PATH — the uvx-generated wrapper
# shells out to realpath/dirname, which need coreutils on PATH.
#
# BIND + PRIVACY: bound to 127.0.0.1 explicitly (--host); neither box opens 2455
# in its firewall. opencode connects via 127.0.0.1 (auth-exempt on codex-lb), so
# no proxy API key is needed locally.
{ config, pkgs, lib, isDevbox, isCloudbox, ... }:

lib.mkIf (isDevbox || isCloudbox) {
  systemd.user.services.codex-lb = {
    Unit = {
      Description = "codex-lb (multi-account ChatGPT/Codex rotator)";
      After = [ "network-online.target" ];
      Wants = [ "network-online.target" ];
      # Per-host opt-in: stays inactive (not failed) until the marker exists.
      ConditionPathExists = "%h/.codex-lb/enabled";
      StartLimitIntervalSec = 300;
      StartLimitBurst = 5;
    };
    Service = {
      Type = "simple";
      WorkingDirectory = config.home.homeDirectory;
      Environment = [
        "HOME=${config.home.homeDirectory}"
        "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
        "PATH=/run/wrappers/bin:/run/current-system/sw/bin:${config.home.homeDirectory}/.nix-profile/bin"
      ];
      ExecStart = "${pkgs.uv}/bin/uvx --from codex-lb==1.20.1 codex-lb --host 127.0.0.1 --port 2455";
      Restart = "always";
      RestartSec = 10;
    };
    Install = {
      WantedBy = [ "default.target" ];
    };
  };

  # devbox is already bootstrapped (account seeded, service running), so keep it
  # enabled by ensuring the opt-in marker exists. Runs before reloadSystemd so the
  # ConditionPathExists above is satisfied when the (re)generated unit is applied.
  # cloudbox is deliberately NOT auto-marked — it's opt-in (seed an account first).
  home.activation.codexLbEnableMarker = lib.mkIf isDevbox
    (lib.hm.dag.entryBefore [ "reloadSystemd" ] ''
      ${pkgs.coreutils}/bin/mkdir -p "$HOME/.codex-lb"
      [ -e "$HOME/.codex-lb/enabled" ] || ${pkgs.coreutils}/bin/touch "$HOME/.codex-lb/enabled"
    '');
}
