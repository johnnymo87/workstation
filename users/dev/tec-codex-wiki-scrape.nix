# tec-codex weekly wiki scrape + archive (devbox).
#
# WHY THIS EXISTS (tec-codex bead tec-codex-toi.6.1): tec-codex's AGENTS.md
# promised a weekly timer for scripts/scrape_and_archive.py that existed
# nowhere, so the published wiki archive (release data-2026-03-16,
# last-scrape.json) was still April's. This is that timer.
#
#   tec-codex-wiki-scrape.timer   Sundays 04:00 UTC, Persistent
#     -> tec-codex-wiki-scrape.service  python -m scripts.scrape_and_archive
#
# What a run does: a cheap precheck (tec-wiki.com's sitemap and build time,
# plus a fetch of the wiki's ~1 MB blobless git clone in
# ~/.cache/tec-codex/tec-wiki.git); a skip heartbeat if nothing changed;
# otherwise a ~2-3 min scrape to ~/.cache/tec-codex-wiki-scrape, gzip, and `gh release upload --clobber`
# of tec-wiki-YYYY-MM-DD.jsonl.gz + last-scrape.json to the tec-codex repo.
# It does NOT ingest: the live codex_dev DB is untouched (auto-ingest is
# tec-codex-toi.6.2, Jonathan's call). Exit codes 2-5 = precheck / scrape /
# gzip / upload failed.
#
# Failure: retried every 30 min (up to 4 starts in 12 h; a network blip at
# 04:00 must not cost a week), then the unit is failed and
# tec-codex-wiki-scrape-failure.service posts a pigeon alert (at most one per
# day). Exit 1 (usage) is not retried. A run skipped by its
# ConditionPathExists (no venv) is not a failure and alerts nobody.
#
# Traps handled (same as tec-codex-bot.nix):
# - Runs from the main checkout ~/projects/tec-codex with
#   `uv run --frozen --no-sync`, which neither syncs nor creates the .venv the
#   live :4010 service uses; ConditionPathExists on .venv/bin/python skips the
#   run (never "fixes" the venv) when it is missing, and UV_PYTHON_DOWNLOADS is
#   off. The script runs its scraper subprocess with the same interpreter, not
#   `uv run` (tec-codex PR #36).
# - gh authenticates from ~/.config/gh/hosts.yml (no token in the unit).
# - No AI-provider key or Discord token reaches it (UnsetEnvironment).
# - MemoryMax caps it; devbox is short of memory. Measured: a full scrape
#   peaks at ~160 MB and takes ~95 s.
# - Output files go to its own CacheDirectory (~7 MB per week that scrapes),
#   not shared /tmp.
#
# Logs: journalctl --user -u tec-codex-wiki-scrape
# Manual run: systemctl --user start tec-codex-wiki-scrape
{ config, pkgs, lib, isDevbox, ... }:

let
  checkout = "${config.home.homeDirectory}/projects/tec-codex";
  venvPython = "${checkout}/.venv/bin/python";
  driftAlert = pkgs.callPackage ../../pkgs/opencode-drift-alert { };
  alertState = "${config.home.homeDirectory}/.local/state/tec-codex-wiki-scrape";
in
lib.mkIf isDevbox {
  systemd.user.services.tec-codex-wiki-scrape = {
    Unit = {
      Description = "tec-codex weekly wiki scrape + archive to GitHub Releases";
      ConditionPathExists = [ venvPython "${checkout}/scripts/scrape_and_archive.py" ];
      StartLimitIntervalSec = 12 * 3600;
      StartLimitBurst = 4;
      OnFailure = [ "tec-codex-wiki-scrape-failure.service" ];
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
        "CODEX_OPENAI_API_KEY"
        "OPENAI_API_KEY"
        "CODEX_GEMINI_API_KEY"
        "GEMINI_API_KEY"
        "DISCORD_TOKEN"
      ];
      ExecStart = "${pkgs.uv}/bin/uv run --frozen --no-sync python -m scripts.scrape_and_archive --output-dir %C/tec-codex-wiki-scrape";
      CacheDirectory = "tec-codex-wiki-scrape";
      TimeoutStartSec = "30min";
      Restart = "on-failure";
      RestartSec = "30min";
      RestartPreventExitStatus = 1;
      NoNewPrivileges = true;
      MemoryMax = "1G";
      MemorySwapMax = 0;
    };
  };

  systemd.user.services.tec-codex-wiki-scrape-failure = {
    Unit.Description = "Alert: the tec-codex weekly wiki scrape failed";
    Service = {
      Type = "oneshot";
      ExecStart = toString (pkgs.writeShellScript "tec-codex-wiki-scrape-alert" ''
        ${pkgs.coreutils}/bin/mkdir -p ${alertState}
        ${driftAlert} ${alertState}/alerted "$(${pkgs.coreutils}/bin/date -u +%F)" \
          "tec-codex weekly wiki scrape failed on devbox (retries exhausted). The wiki archive on release data-2026-03-16 was not updated. Check: journalctl --user -u tec-codex-wiki-scrape; rerun: systemctl --user reset-failed tec-codex-wiki-scrape && systemctl --user start tec-codex-wiki-scrape" 0 0
      '');
    };
  };

  systemd.user.timers.tec-codex-wiki-scrape = {
    Unit.Description = "Weekly tec-codex wiki scrape (Sundays 04:00 UTC)";
    Timer = {
      OnCalendar = "Sun *-*-* 04:00:00 UTC";
      Persistent = true;
      RandomizedDelaySec = 600;
    };
    Install.WantedBy = [ "timers.target" ];
  };
}
