# tec-codex daily forum scrape + archive (devbox).
#
# WHY THIS EXISTS (tec-codex bead tec-codex-9i9): the wpForo forum had no
# scheduled scrape; its only archive was a hand-run DB export. This is the
# forum twin of tec-codex-wiki-scrape.nix.
#
#   tec-codex-forum-scrape.timer   daily 05:30 UTC, Persistent
#     -> tec-codex-forum-scrape.service  python -m scripts.scrape_forum_and_archive
#
# What a run does: reads the whole forum, every page of every topic (~165
# topics, ~4 min, ~160 MB peak), read-only. When the fingerprint (every post's
# id, content hash and date) differs from last-forum-scrape.json on the
# tec-codex release data-2026-03-16, it uploads tec-forum-scrape-YYYY-MM-DD.jsonl.gz,
# then the anchor (two `gh release upload --clobber` calls); otherwise it logs a
# skip heartbeat. No DB, no OpenAI key. There is NO auto-ingest into codex_dev
# yet (a follow-up bead); published.json is written for it.
#
# Exit codes: 2 precheck (gh or forum unreadable), 3 a topic failed, 5 upload,
# 6 published.json: retried every 30 min (4 starts in 12 h), then a pigeon
# alert. Not retried, alert at once: 1 usage/uncaught, 4 archive validation,
# 8 refused (under 80% of last archive's posts, or a topic lost its posts;
# a human checks and reruns with --force).
#
# Traps handled (same as tec-codex-wiki-scrape.nix):
# - Runs from the main checkout ~/projects/tec-codex with
#   `uv run --frozen --no-sync`, which never syncs the live :4010 service's
#   .venv; ConditionPathExists skips the run when the venv or the script is
#   missing (e.g. before the tec-codex PR is pulled).
# - gh authenticates from ~/.config/gh/hosts.yml; git is on PATH (git_sha).
# - No AI-provider key or Discord token reaches it (UnsetEnvironment).
# - Output goes to its own CacheDirectory (~430 KB per day with a change).
#
# Logs: journalctl --user -u tec-codex-forum-scrape
# Manual run: systemctl --user start tec-codex-forum-scrape
{ config, pkgs, lib, isDevbox, ... }:

let
  checkout = "${config.home.homeDirectory}/projects/tec-codex";
  venvPython = "${checkout}/.venv/bin/python";
  driftAlert = pkgs.callPackage ../../pkgs/opencode-drift-alert { };
  alertState = "${config.home.homeDirectory}/.local/state/tec-codex-forum-scrape";
in
lib.mkIf isDevbox {
  systemd.user.services.tec-codex-forum-scrape = {
    Unit = {
      Description = "tec-codex daily forum scrape + archive to GitHub Releases";
      ConditionPathExists = [ venvPython "${checkout}/scripts/scrape_forum_and_archive.py" ];
      StartLimitIntervalSec = 12 * 3600;
      StartLimitBurst = 4;
      OnFailure = [ "tec-codex-forum-scrape-failure.service" ];
    };
    Service = {
      Type = "oneshot";
      WorkingDirectory = checkout;
      Environment = [
        "PATH=${lib.makeBinPath [ pkgs.git pkgs.gh pkgs.gzip pkgs.coreutils ]}"
        "CODEX_QUERY_LOG_PATH="
        "UV_PYTHON_DOWNLOADS=never"
      ];
      UnsetEnvironment = [
        "VIRTUAL_ENV"
        "UV_PROJECT_ENVIRONMENT"
        "CODEX_DATABASE_URL"
        "CODEX_DATABASE_URL_SYNC"
        "CODEX_OPENAI_API_KEY"
        "OPENAI_API_KEY"
        "CODEX_GEMINI_API_KEY"
        "GEMINI_API_KEY"
        "DISCORD_TOKEN"
      ];
      ExecStart = "${pkgs.uv}/bin/uv run --frozen --no-sync python -m scripts.scrape_forum_and_archive --output-dir %C/tec-codex-forum-scrape";
      CacheDirectory = "tec-codex-forum-scrape";
      TimeoutStartSec = "30min";
      Restart = "on-failure";
      RestartSec = "30min";
      # direct: the alert fires once retries are exhausted, not per attempt
      # (see tec-codex-wiki-scrape.nix).
      RestartMode = "direct";
      RestartPreventExitStatus = "1 4 8";
      NoNewPrivileges = true;
      MemoryMax = "1G";
      MemorySwapMax = 0;
    };
  };

  systemd.user.services.tec-codex-forum-scrape-failure = {
    Unit.Description = "Alert: the tec-codex daily forum scrape failed";
    Service = {
      Type = "oneshot";
      ExecStart = toString (pkgs.writeShellScript "tec-codex-forum-scrape-alert" ''
        ${pkgs.coreutils}/bin/mkdir -p ${alertState}
        ${driftAlert} ${alertState}/alerted "$(${pkgs.coreutils}/bin/date -u +%F)" \
          "tec-codex daily forum scrape failed or was refused on devbox. The forum archive on release data-2026-03-16 was not updated. Check: journalctl --user -u tec-codex-forum-scrape (exit 8 = refused: shrink or a topic lost its posts; check the forum, then rerun by hand with --force). Rerun: systemctl --user reset-failed tec-codex-forum-scrape && systemctl --user start tec-codex-forum-scrape" 0 0
      '');
    };
  };

  systemd.user.timers.tec-codex-forum-scrape = {
    Unit.Description = "Daily tec-codex forum scrape (05:30 UTC)";
    Timer = {
      OnCalendar = "*-*-* 05:30:00 UTC";
      Persistent = true;
      RandomizedDelaySec = 600;
    };
    Install.WantedBy = [ "timers.target" ];
  };
}
