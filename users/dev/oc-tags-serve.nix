# oc-tags chart server as a declared user service.
#
# WHY THIS EXISTS: this was previously started by hand with
# `systemd-run --user --unit=oc-tags-serve --collect`, which has three
# failure modes that all bit in practice:
#
#   1. `--collect` garbage-collects a TRANSIENT unit when it stops -- the
#      definition goes with it. Stopping it once (to preview a branch build)
#      deleted the unit, and the documented `systemctl --user start
#      oc-tags-serve` then failed with "Unit not found" while the chart was
#      down.
#   2. It did not survive a reboot; nothing pulled it back up.
#   3. It pinned the store path it exec'd, so every `home-manager switch`
#      needed a manual restart or the chart silently served stale code. That
#      is not hypothetical: the serve ran pre-hover code for hours after the
#      hover feature merged, so the feature appeared not to work at all.
#
# Declaring it fixes all three. ExecStart references the derivation rather
# than ~/.nix-profile/bin, which is what lets home-manager notice the change
# and restart the unit -- so a switch alone now deploys.
#
# BIND + PRIVACY: 127.0.0.1 only, never a routable interface. It is reached
# from the Mac through the on-demand `cloudbox-chart` SSH LocalForward (see
# scripts/update-ssh-config.sh), not by opening a port. Port 4710 is
# deliberately NOT in the always-on cloudbox-tunnel block, because that runs
# under ExitOnForwardFailure=yes and a busy :4710 would tear down gclpr,
# chatgpt-relay and the Jenkins forward with it.
#
# It never addresses the opencode serve pool (:4096-4099) or the front door
# (:4700) -- it is a dashboard, not a serve proxy -- which is what keeps the
# front-door opacity guard disengaged.
{ config, pkgs, lib, localPkgs, isCloudbox, ... }:

lib.mkIf isCloudbox {
  systemd.user.services.oc-tags-serve = {
    Unit = {
      Description = "oc-tags chart server (per-tag LLM list-price consumption)";
      # Deliberately no After=: loopback only, and opencode.db is local, so
      # there is nothing to wait for. In particular NOT After=default.target,
      # which together with the WantedBy below is an ordering cycle -- systemd
      # would break it by dropping an edge at random and only whisper about it
      # in the journal.
      #
      # No start limit, on purpose. The ONLY way this exits at startup is
      # EADDRINUSE -- `cmd_serve` binds the socket and touches no database, so
      # a locked or missing opencode.db cannot kill it (those surface as a
      # per-request 503, or an empty chart). EADDRINUSE means a human left an
      # ad-hoc `oc-tags serve` in a tmux pane, which clears when they notice.
      # A burst limit would convert that transient condition into
      # permanently-down with nothing to retrigger it. Retry forever instead,
      # backing off so the loop is cheap rather than silent.
      StartLimitIntervalSec = 0;
    };
    Service = {
      Type = "simple";
      WorkingDirectory = config.home.homeDirectory;
      # Reference the derivation, not ~/.nix-profile/bin -- that is what lets
      # home-manager notice the change and restart the unit on switch.
      ExecStart = "${localPkgs.oc-tags}/bin/oc-tags serve --host 127.0.0.1 --port 4710";
      Environment = [
        "HOME=${config.home.homeDirectory}"
        # Python block-buffers stdout when it is not a tty, so the startup
        # banner would never reach the journal.
        "PYTHONUNBUFFERED=1"
      ];
      Restart = "always";
      RestartSec = 10;
      # 10s, then backing off to a 5min ceiling (systemd >= 254).
      RestartSteps = 5;
      RestartMaxDelaySec = 300;
      # Every "/" scans the whole message table of a ~9 GB database and
      # materialises the window with fetchall. Peak observed is ~103 MB, but
      # it grows with the window and is not bounded in code. Restart=always
      # turns an OOM kill into a recovery rather than an outage.
      MemoryMax = "1G";
    };
    Install = {
      WantedBy = [ "default.target" ];
    };
  };

  # A hand-started `systemd-run --user --unit=oc-tags-serve` leaves a TRANSIENT
  # unit in /run/user/$UID/systemd/transient, which outranks
  # ~/.config/systemd/user in systemd's search path (verify with
  # `systemd-analyze --user unit-paths`). Without this, a switch silently does
  # nothing useful: the declared unit is written and linked, sd-switch asks to
  # start it, the name still resolves to the live transient fragment, the start
  # is a no-op on an already-active unit, and the switch reports success while
  # the old process keeps the port and the old code. Nothing is logged, and
  # even `systemctl --user restart oc-tags-serve` would restart the transient
  # definition rather than cutting over.
  home.activation.ocTagsServeStopTransient = lib.mkIf isCloudbox (
    lib.hm.dag.entryBefore [ "reloadSystemd" ] ''
      if [ "$(${pkgs.systemd}/bin/systemctl --user show -p Transient --value oc-tags-serve.service 2>/dev/null)" = "yes" ]; then
        echo "ocTagsServeStopTransient: stopping hand-started transient oc-tags-serve so the declared unit can take over"
        ${pkgs.systemd}/bin/systemctl --user stop oc-tags-serve.service || true
      fi
    ''
  );
}
