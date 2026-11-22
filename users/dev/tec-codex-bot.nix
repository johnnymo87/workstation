# tec-codex Mode A Discord bot and its own API process (devbox).
#
# WHY THIS EXISTS (tec-codex bead tec-codex-toi.9.17, plan
# docs/plans/2026-11-22-tec-codex-productization.md in that repo): a `/search`
# slash-command bot over the TEC wiki and forum, offered to the unofficial TEC
# Discord. "Bot only, by construction": the bot talks to its OWN API process
# (127.0.0.1:4012, read-only DB, wiki+forum allowlist, its own 0600 query log,
# no AI-provider key), never the agents' live :4010.
#
# INERT UNTIL THE TOKEN EXISTS. This module does NOT declare the sops secret:
# that is Jonathan's (tec-codex-toi.9.6). Until /run/secrets/discord_bot_token
# exists (readable by dev), nothing here runs. A .path unit, not just a
# Condition, because a ConditionPathExists alone is checked once at login and
# would never start the bot when the secret appears later (a nixos-rebuild
# switch swaps the /run/secrets symlink; PathExists re-checks on changes in
# /run, the watched parent).
#
#   tec-codex-bot.path     (enabled)  PathExists=/run/secrets/discord_bot_token
#     -> tec-codex-bot.service         python -m codex.bot --token-file <path>
#          Requires/After -> tec-codex-bot-api.service  python -m codex.bot.api
#                            (StopWhenUnneeded: stops with the bot)
#
# Traps handled:
# - Runs from the main checkout ~/projects/tec-codex with
#   `uv run --frozen --no-sync`: a plain `uv run` would sync the .venv that the
#   live :4010 service (eternal-machinery's devenv processes.codex) uses.
#   VIRTUAL_ENV is unset so uv cannot pick another environment.
# - A checkout without the codex.bot module (before tec-codex-toi.9.7 merged)
#   or a bot that exits 2 for an empty guild allowlist must not crash-loop:
#   Restart=on-failure with RestartSec=30 and a start limit of 3 per 10 min on
#   each service. PathExists re-triggers the bot whenever it is inactive, and
#   a start refused because the API hit ITS start limit is a dependency
#   failure, which does not count against the bot's own limit; without a
#   trigger limit the .path unit retried 201 times in one second before its
#   default limit (200/2s) stopped it (measured 2026-11-22). So the .path unit
#   has its own TriggerLimit of 5 per 10 min. Once a limit is hit everything
#   stays failed until re-armed:
#     systemctl --user reset-failed 'tec-codex-bot*'
#     systemctl --user restart tec-codex-bot.path
# - The token is only ever a FILE PATH here (the bot reads it, never env, argv
#   or logs). Non-secret settings (CODEX_BOT_GUILD_IDS, a comma-separated list
#   of guild ids, required: the bot exits 2 without it) go in the optional
#   ~/.config/tec-codex/bot.env, which this module does not create.
# - No AI-provider key reaches either process (UnsetEnvironment), and the
#   agents' query log is disabled (CODEX_QUERY_LOG_PATH="") as a backstop: the
#   bot API writes only CODEX_BOT_QUERY_LOG_PATH.
# - MemoryMax caps: devbox is short of memory, and a runaway must not touch
#   the live stack. Logs go to the journal:
#   journalctl --user -u tec-codex-bot -u tec-codex-bot-api
#
# - Query-log retention does not depend on the bot running: the bot API prunes
#   at startup and hourly, and tec-codex-bot-log-prune.timer runs
#   `python -m codex.bot.api --prune` hourly on its own (deletes day files
#   whose last write is more than CODEX_BOT_QUERY_LOG_BACKUP_DAYS=13 days old,
#   then exits), so the privacy page's "deleted within 15 days" holds while the
#   API is down or disabled. It is conditioned on the log directory existing,
#   so it is a no-op until the bot has logged something (and never runs
#   against a checkout without codex.bot). If devbox is off, nothing runs;
#   Persistent=true catches up at the next boot.
#
# Starting, stopping or switching these units never touches the live codex on
# :4010 or any eternal-machinery process.
{ config, pkgs, lib, isDevbox, ... }:

let
  tokenPath = "/run/secrets/discord_bot_token";
  checkout = "${config.home.homeDirectory}/projects/tec-codex";
  apiPort = 4012;
  # Default CODEX_BOT_QUERY_LOG_PATH directory (tec-codex codex/bot settings).
  queryLogDir = "${config.home.homeDirectory}/.local/share/tec-codex/bot-query-log";
  uvRun = "${pkgs.uv}/bin/uv run --frozen --no-sync";

  commonUnit = {
    StartLimitIntervalSec = 600;
    StartLimitBurst = 3;
  };
  commonService = {
    Type = "simple";
    WorkingDirectory = checkout;
    EnvironmentFile = "-${config.home.homeDirectory}/.config/tec-codex/bot.env";
    UnsetEnvironment = [
      "VIRTUAL_ENV"
      "UV_PROJECT_ENVIRONMENT"
      "CODEX_OPENAI_API_KEY"
      "OPENAI_API_KEY"
      "CODEX_GEMINI_API_KEY"
      "GEMINI_API_KEY"
      "DISCORD_TOKEN"
    ];
    Restart = "on-failure";
    RestartSec = 30;
    NoNewPrivileges = true;
    MemorySwapMax = 0;
  };
in
lib.mkIf isDevbox {
  systemd.user.paths.tec-codex-bot = {
    Unit.Description = "Start the tec-codex Discord bot once its token exists (${tokenPath})";
    Path = {
      PathExists = tokenPath;
      Unit = "tec-codex-bot.service";
      TriggerLimitIntervalSec = 600;
      TriggerLimitBurst = 5;
    };
    Install.WantedBy = [ "default.target" ];
  };

  systemd.user.services.tec-codex-bot-api = {
    Unit = commonUnit // {
      Description = "tec-codex bot API (127.0.0.1:${toString apiPort}, wiki+forum, read-only)";
      StopWhenUnneeded = true;
    };
    Service = commonService // {
      Environment = [
        "CODEX_BOT_HOST=127.0.0.1"
        "CODEX_BOT_PORT=${toString apiPort}"
        "CODEX_QUERY_LOG_PATH="
      ];
      ExecStart = "${uvRun} python -m codex.bot.api";
      MemoryMax = "1G";
    };
  };

  systemd.user.services.tec-codex-bot = {
    Unit = commonUnit // {
      Description = "tec-codex Mode A Discord bot (/search, wiki+forum)";
      ConditionPathExists = tokenPath;
      Requires = [ "tec-codex-bot-api.service" ];
      After = [ "tec-codex-bot-api.service" ];
    };
    Service = commonService // {
      Environment = [
        "CODEX_BOT_API_URL=http://127.0.0.1:${toString apiPort}"
        "CODEX_QUERY_LOG_PATH="
      ];
      ExecStart = "${uvRun} python -m codex.bot --token-file ${tokenPath}";
      MemoryMax = "512M";
    };
  };

  systemd.user.services.tec-codex-bot-log-prune = {
    Unit = {
      Description = "Delete tec-codex bot query-log files past retention";
      ConditionPathExists = queryLogDir;
    };
    Service = {
      Type = "oneshot";
      WorkingDirectory = checkout;
      EnvironmentFile = commonService.EnvironmentFile;
      UnsetEnvironment = commonService.UnsetEnvironment;
      Environment = [ "CODEX_QUERY_LOG_PATH=" ];
      ExecStart = "${uvRun} python -m codex.bot.api --prune";
      NoNewPrivileges = true;
      MemoryMax = "512M";
      MemorySwapMax = 0;
    };
  };

  systemd.user.timers.tec-codex-bot-log-prune = {
    Unit.Description = "Hourly retention pruning of the tec-codex bot query log";
    Timer = {
      OnCalendar = "hourly";
      Persistent = true;
      RandomizedDelaySec = 300;
    };
    Install.WantedBy = [ "timers.target" ];
  };
}
