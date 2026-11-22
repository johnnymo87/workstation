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
# otherwise a ~3 min scrape to /tmp, gzip, and `gh release upload --clobber`
# of tec-wiki-YYYY-MM-DD.jsonl.gz + last-scrape.json to the tec-codex repo.
# It does NOT ingest: the live codex_dev DB is untouched (auto-ingest is
# tec-codex-toi.6.2, Jonathan's call). Exit codes 2-5 = precheck / scrape /
# gzip / upload failed; the unit then shows failed in
# `systemctl --user list-units --failed`.
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
# - MemoryMax caps it; devbox is short of memory.
#
# Logs: journalctl --user -u tec-codex-wiki-scrape
# Manual run: systemctl --user start tec-codex-wiki-scrape
{ config, pkgs, lib, isDevbox, ... }:

let
  checkout = "${config.home.homeDirectory}/projects/tec-codex";
  venvPython = "${checkout}/.venv/bin/python";
in
lib.mkIf isDevbox {
  systemd.user.services.tec-codex-wiki-scrape = {
    Unit = {
      Description = "tec-codex weekly wiki scrape + archive to GitHub Releases";
      ConditionPathExists = [ venvPython "${checkout}/scripts/scrape_and_archive.py" ];
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
      ExecStart = "${pkgs.uv}/bin/uv run --frozen --no-sync python -m scripts.scrape_and_archive";
      TimeoutStartSec = "30min";
      NoNewPrivileges = true;
      MemoryMax = "1G";
      MemorySwapMax = 0;
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
