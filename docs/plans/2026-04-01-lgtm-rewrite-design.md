# LGTM: AI-Powered PR Review via OpenCode

Automated PR review daemon for cloudbox. Discovers PRs assigned for review, dispatches them to OpenCode headless sessions for full codebase-aware review, and lets OpenCode post the review directly via `gh pr review`.

## Context

- Original `food-truck/lgtm` is a 1,500-line TypeScript macOS app (launchd, terminal-notifier, SQLite)
- Rewrite targets cloudbox only (NixOS, systemd, Telegram via pigeon)
- Follows the pigeon deployment pattern: separate repo in projects.nix, run via tsx, systemd service
- Delegates all review intelligence to OpenCode, making lgtm a thin discovery + dispatch layer

## Architecture

```
systemd timer (every 10 min)
     │
     ▼
lgtm-run (systemd oneshot)
     │
     ├─ gh search prs → discover PRs needing review
     │
     ├─ check state dir → skip already-dispatched
     │
     ├─ for each new PR:
     │    ├─ ensure repo cloned at ~/projects/<repo>
     │    ├─ git fetch + create worktree at <repo>/.worktrees/pr-<N>
     │    ├─ opencode-launch <worktree-dir> "<review prompt>"
     │    └─ touch dispatched/<org>/<repo>/<N>
     │
     └─ exit
```

## Key Design Decisions

### OpenCode does the full review

lgtm does NOT parse AI verdicts or call `gh pr review` itself. The prompt instructs OpenCode to review the PR and submit the review. OpenCode has full tool access (file reading, grep, gh CLI) -- strictly more powerful than piping a diff to `claude --print`.

### Timer + oneshot, not long-running daemon

Unlike pigeon (persistent daemon polling every 5s), lgtm is a periodic task. Systemd timer triggers a oneshot service. Simpler, more robust -- no reconnection logic, no memory leaks, no state between runs.

### Worktrees inside the repo

Worktrees are created at `~/projects/<repo>/.worktrees/pr-<N>`, not in a centralized state directory. Follows existing git worktree convention.

### Flat file state

```
~/.local/state/lgtm/
  dispatched/
    food-truck/
      my-repo/
        42    # marker file: PR #42 has been dispatched
        43
  lgtm.log    # simple log file
```

Touch a marker file when a PR is dispatched to OpenCode. Check existence to skip on next run. No database.

### Notifications via pigeon (free)

No custom notification code. When the OpenCode session completes, pigeon's existing plugin fires a session-stop event routed to Telegram. The review itself is posted by OpenCode as a GitHub review comment.

### Config via environment variables

Injected via systemd service `Environment` and sops-nix secrets:
- `LGTM_ORG` -- GitHub org to search (default: `food-truck`)
- `LGTM_INTERVAL` -- timer interval (configured in systemd timer)
- `LGTM_AUTO_APPROVE_AUTHORS` -- comma-separated list of authors for auto-approve hint in prompt
- `OPENCODE_URL` -- opencode-serve endpoint (default: `http://127.0.0.1:4096`)
- `HOME` -- for gh auth and git config

### Repo discovery convention

All codebases live at `~/projects/`. If a PR's repo isn't cloned there, lgtm clones it. The prompt tells OpenCode: "All our codebases are in ~/projects/. If you need to reference another repo, check there first or clone it there."

## Source Code Location

Fresh repo: `johnnymo87/lgtm` (private). TypeScript, following the pigeon pattern (run via `node tsx`, not compiled/packaged via Nix).

Deployed to cloudbox via:
1. `projects.nix` entry with `platforms = [ "cloudbox" ]`
2. Auto-cloned to `~/projects/lgtm` by `ensure-projects`
3. Systemd timer + oneshot service in `hosts/cloudbox/configuration.nix`

## Workstation Integration

### projects.nix
```nix
lgtm = { url = "git@github.com:johnnymo87/lgtm.git"; platforms = [ "cloudbox" ]; };
```

### hosts/cloudbox/configuration.nix
```nix
systemd.services.lgtm-run = {
  description = "LGTM PR review cycle";
  wants = [ "network-online.target" ];
  after = [ "network-online.target" ];
  path = [ pkgs.nodejs pkgs.git pkgs.gh pkgs.jq pkgs.coreutils ];
  serviceConfig = {
    Type = "oneshot";
    User = "dev";
    Group = "dev";
    WorkingDirectory = "/home/dev/projects/lgtm";
    Environment = [
      "HOME=/home/dev"
      "LGTM_ORG=food-truck"
      "OPENCODE_URL=http://127.0.0.1:4096"
    ];
    ExecStart = "${pkgs.writeShellScript "lgtm-run" ''
      set -euo pipefail
      exec ${pkgs.nodejs}/bin/node \
        /home/dev/projects/lgtm/node_modules/tsx/dist/cli.mjs \
        /home/dev/projects/lgtm/src/index.ts
    ''}";
  };
};

systemd.timers.lgtm-run = {
  wantedBy = [ "timers.target" ];
  timerConfig = {
    OnCalendar = "*:0/10";
    Persistent = true;
  };
};
```

## Scope

### In scope (v1)
- PR discovery via `gh search prs`
- Deduplication via flat marker files
- Repo cloning + worktree creation
- Dispatch to OpenCode via `opencode-launch`
- Prompt construction (PR metadata, diff, triage instructions)
- Worktree cleanup (on next run or separate timer)

### Out of scope (future)
- Interactive review mode (attach to OpenCode session)
- Per-repo triage prompts (custom review instructions per repository)
- Review quality feedback loop (learn from rejected reviews)
- Multi-org support
