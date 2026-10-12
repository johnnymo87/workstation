# Pause gamebox's em-ci runners while a Sunshine stream is active.
# Design: docs/plans/2026-10-11-em-ci-gamebox-design.md §4.
# The pause is the flag file; container units carry
# ConditionPathExists=!<flag> (modules/em-ci-runners.nix), so any start while
# paused is skipped, whoever asks. No Conflicts=: it is bidirectional, and a
# container start would end the pause mid-stream.
{ config, lib, pkgs, ... }:
let
  flag = config.services.em-ci-runners.pauseFlag;
  units = map (n: "container@${n}.service") (lib.attrNames config.services.em-ci-runners.runners);
  systemctl = "${pkgs.systemd}/bin/systemctl";
  resume = pkgs.writeShellScript "em-ci-resume" ''
    rm -f ${flag}
    ${systemctl} is-failed --quiet em-ci-disk-watchdog.service && exit 0
    ${systemctl} --no-block start ${lib.concatStringsSep " " units}
  '';
  # Sunshine's global_prep_cmd calls this STABLE path (hosts/gamebox/
  # streaming.nix). A store path would go stale: a switch does not restart
  # gamer's Sunshine, which keeps the old conf's paths, and GC can delete them,
  # after which every launch aborts. Always exits 0: Sunshine ABORTS a launch
  # when a `do` command exits non-zero, so a polkit denial or a dead bus must
  # cost the pause, never the game.
  hook = pkgs.writeShellScript "em-ci-pause-hook" ''
    case "''${1:-}" in start|stop) ;; *) echo "usage: $0 start|stop" >&2; exit 0 ;; esac
    ${systemctl} --no-block "$1" em-ci-pause.service ||
      echo "em-ci-pause: $1 failed; the stream continues without it" >&2
    exit 0
  '';
in {
  environment.etc."em-ci/pause-hook".source = hook;

  systemd.services.em-ci-pause = {
    description = "Pause em-ci runners (Sunshine stream active)";
    # A switch mid-stream must not bounce this unit: stop would run the resume
    # (containers start mid-game, may claim a job) and the new start would stop
    # them again. The new definition applies at the next stream.
    restartIfChanged = false;
    serviceConfig = {
      Type = "exec";
      ExecStartPre = "${pkgs.coreutils}/bin/touch ${flag}";
      # The 8 h stale-pause ceiling (a stream whose `undo` never ran: Sunshine
      # killed, or Moonlight closed without quitting the app). A sleep that
      # ends, not RuntimeMaxSec: the unit finishes inactive/success instead of
      # failed (timeout), and ExecStopPost resumes the runners either way.
      ExecStart = "${pkgs.coreutils}/bin/sleep 8h";
      ExecStartPost = "${systemctl} --no-block stop ${lib.concatStringsSep " " units}";
      # '-': a start refused during shutdown must not fail the stop.
      ExecStopPost = "-${resume}";
    };
  };

  # Belt and braces: while paused, keep the flag present and the containers
  # stopped; while not paused, remove a stale flag. It never STARTS containers:
  # ending a pause is the resume's job (ExecStopPost), and a container stopped
  # outside a pause -- by the disk watchdog (whose failed state clears on its
  # next passing run, so it is no latch) or by an admin -- stays stopped until
  # someone starts it, as modules/em-ci-runners.nix documents.
  systemd.services.em-ci-reconcile = {
    description = "Reconcile em-ci containers with the pause flag";
    serviceConfig.Type = "oneshot";
    script = ''
      # "activating" counts as paused: ExecStartPre has already touched the flag.
      paused=0
      case "$(${systemctl} is-active em-ci-pause.service || true)" in
        active|activating|reloading) paused=1 ;;
      esac
      if [ "$paused" = 0 ]; then
        rm -f ${flag}   # stale flag
        exit 0
      fi
      # Re-touch: a pass that read "inactive" just before ExecStartPre may have
      # removed the flag mid-pause.
      touch ${flag}
      for u in ${lib.concatStringsSep " " units}; do
        ${systemctl} is-active --quiet "$u" && ${systemctl} --no-block stop "$u"
      done
      exit 0   # NixOS `script` runs under -e; without this a pass ending on a non-zero is-active reads failed
    '';
  };
  systemd.timers.em-ci-reconcile = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnBootSec = "5min"; OnUnitActiveSec = "5min"; };
  };

  # `gamer` (Sunshine's user) may start/stop the pause unit and nothing else.
  security.polkit.extraConfig = ''
    polkit.addRule(function(action, subject) {
      if (action.id == "org.freedesktop.systemd1.manage-units" &&
          action.lookup("unit") == "em-ci-pause.service" &&
          (action.lookup("verb") == "start" || action.lookup("verb") == "stop") &&
          subject.user == "gamer") {
        return polkit.Result.YES;
      }
    });
  '';
}
