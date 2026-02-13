# Claude Code hooks deployment
# Wraps hook scripts with dependencies for cross-platform compatibility
# Hook scripts live in the pigeon repo; wrappers add PATH and exec them
{ config, lib, pkgs, ... }:

let
  # Dependencies for hook scripts
  # coreutils provides tac (not available on macOS by default)
  hookInputs = [
    pkgs.jq
    pkgs.curl
    pkgs.coreutils
  ];

  # Runtime path to pigeon hooks (resolved at exec time, not Nix build time)
  pigeonHooksDir =
    if pkgs.stdenv.isDarwin
    then "${config.home.homeDirectory}/Code/pigeon/packages/hooks"
    else "${config.home.homeDirectory}/projects/pigeon/packages/hooks";

  # Create a wrapper that sets PATH and execs the real script
  mkHook = name: scriptName: pkgs.writeShellApplication {
    name = "claude-hook-${name}";
    runtimeInputs = hookInputs;
    text = ''
      exec ${pigeonHooksDir}/${scriptName} "$@"
    '';
  };

  hookStart = mkHook "session-start" "on-session-start.sh";
  hookStop = mkHook "stop" "on-stop.sh";
  hookNotification = mkHook "notification" "on-notification.sh";

  # Absolute paths for settings.json (no tilde expansion needed)
  hooksDir = "${config.home.homeDirectory}/.claude/hooks";
in
{
  # Export hook paths for use in managedSettings (home.base.nix)
  options.claude.hooks = {
    sessionStartPath = lib.mkOption {
      type = lib.types.str;
      default = "${hooksDir}/on-session-start.sh";
      description = "Path to session start hook";
    };
    stopPath = lib.mkOption {
      type = lib.types.str;
      default = "${hooksDir}/on-stop.sh";
      description = "Path to stop hook";
    };
    notificationPath = lib.mkOption {
      type = lib.types.str;
      default = "${hooksDir}/on-notification.sh";
      description = "Path to notification hook";
    };
  };

  # Deploy wrapper scripts to ~/.claude/hooks/
  config.home.file.".claude/hooks/on-session-start.sh" = {
    source = "${hookStart}/bin/claude-hook-session-start";
    executable = true;
  };

  config.home.file.".claude/hooks/on-stop.sh" = {
    source = "${hookStop}/bin/claude-hook-stop";
    executable = true;
  };

  config.home.file.".claude/hooks/on-notification.sh" = {
    source = "${hookNotification}/bin/claude-hook-notification";
    executable = true;
  };
}
