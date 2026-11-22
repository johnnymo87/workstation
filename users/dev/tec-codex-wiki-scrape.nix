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
# Exit codes 2-6 = precheck / scrape / gzip / upload / published.json failed.
#
# AUTO-INGEST (tec-codex-toi.6.2, approved by Jonathan; standing OK from the
# eternal-machinery stack coordinator, 2026-11-22): a successful scrape run
# starts tec-codex-wiki-ingest.service (OnSuccess), which runs
# scripts/auto_ingest_wiki.py. It ingests the archive named in the scrape's
# published.json into the LIVE codex_dev once, and does nothing on a week with
# no new archive. It waits (exit 75, retried every 30 min) for the opt-in hold
# file ~/.local/state/tec-codex/ingest-hold, Postgres not accepting
# connections on :5434, a running bin/devenv-up or bin/shutdown-all, or another
# heavy codex DB job; refuses (exit 8, not retried, alerts) an archive that
# fails its sha256 or has under 80% of last time's pages; backs up first
# (backup_db.sh keeps 2 dumps); then ingests, checks /health/db and sends the
# result to the eternal-machinery coordinator over pigeon. It never starts or
# stops a devenv process. Unlike the scrape it DOES get the OpenAI key (as a
# file path, to embed the new segments) and the pigeon token (read at send).
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
# Logs: journalctl --user -u tec-codex-wiki-scrape -u tec-codex-wiki-ingest
# Manual run: systemctl --user start tec-codex-wiki-scrape (ingest follows)
{ config, pkgs, lib, isDevbox, ... }:

let
  checkout = "${config.home.homeDirectory}/projects/tec-codex";
  venvPython = "${checkout}/.venv/bin/python";
  driftAlert = pkgs.callPackage ../../pkgs/opencode-drift-alert { };
  alertState = "${config.home.homeDirectory}/.local/state/tec-codex-wiki-scrape";
  ingestAlertState = "${config.home.homeDirectory}/.local/state/tec-codex-wiki-ingest";
  # eternal-machinery's stack coordinator: gets every ingest result.
  emCoordinator = "gse_c82dc1cc-cd47-50fd-a5a2-7860b54abc20";
in
lib.mkIf isDevbox {
  systemd.user.services.tec-codex-wiki-scrape = {
    Unit = {
      Description = "tec-codex weekly wiki scrape + archive to GitHub Releases";
      ConditionPathExists = [ venvPython "${checkout}/scripts/scrape_and_archive.py" ];
      StartLimitIntervalSec = 12 * 3600;
      StartLimitBurst = 4;
      OnFailure = [ "tec-codex-wiki-scrape-failure.service" ];
      OnSuccess = [ "tec-codex-wiki-ingest.service" ];
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

  systemd.user.services.tec-codex-wiki-ingest = {
    Unit = {
      Description = "tec-codex: ingest the newest published wiki archive into live codex_dev";
      ConditionPathExists = [ venvPython "${checkout}/scripts/auto_ingest_wiki.py" ];
      StartLimitIntervalSec = 12 * 3600;
      StartLimitBurst = 4;
      OnFailure = [ "tec-codex-wiki-ingest-failure.service" ];
    };
    Service = {
      Type = "oneshot";
      WorkingDirectory = checkout;
      Environment = [
        # backup_db.sh needs bash + coreutils + findutils (xargs); pg_dump
        # comes from eternal-machinery's devenv profile (its default path).
        "PATH=${lib.makeBinPath [ pkgs.bash pkgs.coreutils pkgs.findutils ]}"
        "CODEX_QUERY_LOG_PATH="
        "UV_PYTHON_DOWNLOADS=never"
      ];
      UnsetEnvironment = [
        "VIRTUAL_ENV"
        "UV_PROJECT_ENVIRONMENT"
        "CODEX_DATABASE_URL"
        "CODEX_DATABASE_URL_SYNC"
        "DISCORD_TOKEN"
      ];
      ExecStart = "${pkgs.uv}/bin/uv run --frozen --no-sync python -m scripts.auto_ingest_wiki --scrape-dir %C/tec-codex-wiki-scrape --openai-key-file /run/secrets/openai_api_key --notify-to ${emCoordinator}";
      TimeoutStartSec = "90min";
      Restart = "on-failure";
      RestartSec = "30min";
      # 2 = usage, 8 = archive refused: retrying cannot help; alert instead.
      RestartPreventExitStatus = "2 8";
      NoNewPrivileges = true;
      # Measured 2026-11-22: the 533-page ingest ran in ~140 s; the pg_dump
      # child is streaming. 3G leaves headroom on a short-memory box.
      MemoryMax = "3G";
      MemorySwapMax = 0;
    };
  };

  systemd.user.services.tec-codex-wiki-ingest-failure = {
    Unit.Description = "Alert: the tec-codex weekly wiki auto-ingest failed";
    Service = {
      Type = "oneshot";
      ExecStart = toString (pkgs.writeShellScript "tec-codex-wiki-ingest-alert" ''
        ${pkgs.coreutils}/bin/mkdir -p ${ingestAlertState}
        ${driftAlert} ${ingestAlertState}/alerted "$(${pkgs.coreutils}/bin/date -u +%F)" \
          "tec-codex weekly wiki auto-ingest into live codex_dev failed or stayed blocked on devbox (refused archive, failed backup/ingest, or a guard held for 4 tries). Check: journalctl --user -u tec-codex-wiki-ingest; dry run: cd ~/projects/tec-codex && uv run --frozen --no-sync python -m scripts.auto_ingest_wiki --dry-run; rerun: systemctl --user reset-failed tec-codex-wiki-ingest && systemctl --user start tec-codex-wiki-ingest" 0 0
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
