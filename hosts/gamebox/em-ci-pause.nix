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
in {
  systemd.services.em-ci-pause = {
    description = "Pause em-ci runners (Sunshine stream active)";
    serviceConfig = {
      Type = "exec";
      ExecStartPre = "${pkgs.coreutils}/bin/touch ${flag}";
      ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
      ExecStartPost = "${systemctl} --no-block stop ${lib.concatStringsSep " " units}";
      # '-': a start refused during shutdown must not fail the stop.
      ExecStopPost = "-${resume}";
      RuntimeMaxSec = "8h";   # stale-pause ceiling
    };
  };

  # Belt and braces for paths the hook can miss (Sunshine crash, Moonlight
  # disconnect with an app still running, a stale flag after the pause unit died).
  systemd.services.em-ci-reconcile = {
    description = "Reconcile em-ci containers with the pause flag";
    serviceConfig.Type = "oneshot";
    script = ''
      paused=0; ${systemctl} is-active --quiet em-ci-pause.service && paused=1
      if [ "$paused" = 0 ] && [ -e ${flag} ]; then rm -f ${flag}; fi   # stale flag
      for u in ${lib.concatStringsSep " " units}; do
        if [ "$paused" = 1 ]; then
          ${systemctl} is-active --quiet "$u" && ${systemctl} --no-block stop "$u"
        elif ! ${systemctl} is-failed --quiet em-ci-disk-watchdog.service; then
          ${systemctl} is-active --quiet "$u" || ${systemctl} --no-block start "$u"
        fi
      done
      exit 0   # NixOS `script` runs under -e; without this a no-op pass ends on a non-zero is-active and the unit reads failed
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
