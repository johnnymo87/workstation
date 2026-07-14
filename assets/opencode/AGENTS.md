# User-level OpenCode Instructions

Global instructions that apply to all OpenCode sessions for this user, on any
machine. Repo-specific instructions live in each project's `AGENTS.md`.

Skills sources for this AGENTS.md live in `assets/opencode/skills/` of the
[workstation](https://github.com/johnnymo87/workstation) repo. They're deployed
to `~/.config/opencode/skills/` by `users/dev/opencode-skills.nix` so OpenCode
auto-discovers them.

## Skills

OpenCode auto-discovers skills via the platform's skill mechanism (the
`available_skills` block in the system prompt). The table below is a quick
reference for humans reading this file directly, grouped by purpose. **Scope**
is the deployment target: `cross` = all machines (devbox, cloudbox, macOS,
crostini), `work-only` = macOS + cloudbox, `repo-only` = file present in the
repo but not deployed to any machine yet.

### Swarm Coordination

| Skill | Scope | Purpose |
|-------|-------|---------|
| [opencode-launch](skills/opencode-launch/SKILL.md) | cross | Spawn a headless opencode session in a given dir with an initial prompt. The basic primitive for swarm spin-up. |
| [swarm-messaging](skills/swarm-messaging/SKILL.md) | cross | Sender + receiver protocol: the `swarm_send`/`swarm_read`/`swarm_list` tools, the `<swarm_message>` envelope, message kinds, priority, threading via `reply_to`, replay via `swarm_read`. |
| [swarm-shaped-work](skills/swarm-shaped-work/SKILL.md) | cross | When to swarm vs. iterate sequentially. Coordinator + workers topology. Spin-up sequence (`opencode-launch` × N → tell coordinator the worker ids → kick off). |

### Session Workflow

| Skill | Scope | Purpose |
|-------|-------|---------|
| [adding-opencode-skills](skills/adding-opencode-skills/SKILL.md) | cross | Add, edit, or move an OpenCode skill; debug why a newly-added skill is not picked up. |
| [preparing-for-compaction](skills/preparing-for-compaction/SKILL.md) | cross | Persist durable context before compaction so work survives. Beads + plan files + resumption prompt. |
| [searching-sessions](skills/searching-sessions/SKILL.md) | cross | `oc-search` patterns for grepping past session transcripts (PRs, Jira tickets, commands, payloads). |
| [beads](skills/beads/SKILL.md) | cross | Activate `bd` issue tracking when work spans multiple sessions or has complex dependencies. |
| [migrating-beads-schema](skills/migrating-beads-schema/SKILL.md) | cross | Resolve a bd cross-clone schema-migration block (#4259): single-migrator discipline, DoltHub-vs-git split-remote trap, adopt-vs-migrate, embedded-clone graft fallback, 0037 stripped-UUID-default repair (Error 1105), fresh-clone verification. |
| [reviewing-github-prs](skills/reviewing-github-prs/SKILL.md) | cross | Choosing the right response shape (threaded inline reply vs fresh review vs top-level issue comment) when posting on a PR, plus the `gh` CLI mechanics for each. |
| [understanding-workspace-reset](skills/understanding-workspace-reset/SKILL.md) | cross | Consumer-side facts for the headless morning recommendation agent: the manifest == live `main`-tmux TUIs, why a session may be missing, and reopen via `oc-auto-attach --tmux-session main`. Companion to the repo-local `resetting-workspace`. |

### External Services

| Skill | Scope | Purpose |
|-------|-------|---------|
| [ask-question](skills/ask-question/SKILL.md) | cross | Draft a technical research question and send to ChatGPT for investigation. |
| [using-chatgpt-relay](skills/using-chatgpt-relay/SKILL.md) | cross | Send ChatGPT queries from any remote NixOS host (devbox or cloudbox) via `ask-question` CLI. Setup + troubleshooting for the chatgpt-relay. |
| [using-gws](skills/using-gws/SKILL.md) | cross | Google Workspace APIs (Gmail, Drive, Docs, Sheets, Calendar) via the `gws` CLI. Account switching, available services, common commands. |
| [using-atlassian](skills/using-atlassian/SKILL.md) | work-only | Read/write Jira tickets, fetch Confluence pages, JQL search, comments, attachment downloads. |
| [formatting-slack-messages](skills/formatting-slack-messages/SKILL.md) | cross | Slack mrkdwn dialect quirks (single-asterisk bold, underscore italic, no headers, angle-bracket links). |
| [slack-mcp-setup](skills/slack-mcp-setup/SKILL.md) | work-only | Set up the Slack MCP server with an `xoxp` User OAuth token. macOS Keychain or cloudbox sops. |
| [pagerduty-mcp-setup](skills/pagerduty-mcp-setup/SKILL.md) | work-only | Set up the PagerDuty MCP server with a User API token. macOS Keychain or cloudbox sops. |
| [rollbar-mcp-setup](skills/rollbar-mcp-setup/SKILL.md) | work-only | Set up Rollbar's official MCP server (project access token) for error triage. macOS Keychain or cloudbox sops. Pairs with pagerduty-mcp-setup for the paged-about-Rollbar flow. |

### Platform Tooling

| Skill | Scope | Purpose |
|-------|-------|---------|
| [working-with-kubernetes](skills/working-with-kubernetes/SKILL.md) | work-only | Generic `kubectl` patterns: pod interaction, file transfer, distroless container debugging, kubeconfig management. |
| [using-gcloud-bq-cli](skills/using-gcloud-bq-cli/SKILL.md) | work-only | Gotchas for `gcloud` and `bq`: service-account auth, IAM permission checks, BigQuery access errors. |
| [using-buildbuddy](skills/using-buildbuddy/SKILL.md) | work-only | Fetch raw, untruncated test logs from a BuildBuddy invocation by URL/ID via the `bb-test-log` helper or the enterprise API directly. |
| [shepherding-pull-requests](skills/shepherding-pull-requests/SKILL.md) | work-only | The whole arc of a PR you authored: pre-PR checks, title/description, and the monitoring loop until it lands. PR creation is not a terminal state — invoke this skill any time you have an open PR that still needs your attention. |
| [cleaning-disk](skills/cleaning-disk/SKILL.md) | work-only | Reclaim disk on devbox/macOS: Nix store/generations, Python caches, app caches, project bloat. |

## Bash Environment

`sleep` itself works. Short, standalone sleeps are fine — `sleep 5` and
`date && sleep 5 && date` behave normally.

What is *suspected* (but not fully understood) to hang is **long, multi-step
bash one-liners that include a `sleep`** — e.g. a single command that chains
`sleep`, `gh`, `grep`, and another `gh` call together with `&&`, `;`, or
pipes. Treat that pattern as the smell.

Practical guidance:

- When you need to wait *and then* run several follow-up steps, split the
  wait into its own bash invocation: one tool call for `sleep N`, then a
  separate tool call for the rest. Don't bundle them into one long chain.
- Prefer not to wait at all when you can check the condition directly
  (most servers are ready fast enough that no sleep is needed).
- For waiting on a condition, a bounded poll is still the cleanest option:
  ```bash
  for i in $(seq 1 20); do
    ss -tlnp | grep -q ":$PORT " && break
  done
  ```
- Use `wait` for backgrounded child processes you actually own.
- Use `timeout` to bound an operation.

## Git Safety in Shared Worktrees

**Never run tree-wide destructive git operations in a shared or main worktree.
This applies to every session AND every subagent, without exception.** A swarm
(or two sessions in the same checkout) shares one working tree and index; a
destructive op run "to clean up" clobbers a peer's *uncommitted, untracked, or
in-flight* data with no undo. This has already caused real data loss — a
review subagent ran `git stash`/`git checkout` in a shared worktree and wiped a
peer session's uncommitted SQLite DB.

The banned operations (they mutate the working tree / index / refs for
everyone, not just you):

- `git reset` (especially `--hard`), `git checkout -- <path>` / `git checkout <ref>`,
  `git restore`, `git switch`
- `git stash` (moves everyone's uncommitted changes out from under them)
- `git clean` (deletes untracked files — often exactly the data a peer hasn't
  committed yet)
- history/remote mutation you don't own: `git rebase`, `git merge`,
  `git cherry-pick`, `git revert`, `git commit --amend`, `git push --force`

Do this instead:

- **Inspect read-only.** Review and verification work needs only
  `git diff <base>..<head>`, `git show <sha>`, `git log`, `git status`,
  `git blame`, `git rev-parse`. None of these touch the tree.
- **Need a checked-out tree at a specific commit?** Add a *throwaway* worktree
  instead of mutating the shared one:

  ```bash
  wt="$(mktemp -d)"; git worktree add --detach "$wt" <sha>
  # ...operate inside "$wt"...
  git worktree remove --force "$wt"
  ```

  `/tmp/*` is already allowed for external-directory access, so a `$(mktemp -d)`
  worktree works out of the box.

**Structural enforcement:** the read-only review/advisor subagents
(`code-reviewer`, `spec-reviewer`, `adversarial-reviewer-opus`,
`adversarial-reviewer-fable`, `adversarial-reviewer-sol`, `oracle`) have these
git subcommands denied at the permission layer (`assets/opencode/agents/*.md`),
so the rule holds even if a subagent forgets it. That guard is a backstop, not
a license — the convention above binds all sessions and subagents regardless of
which agent they run as.

## Host Identification

The `shell-env.ts` plugin injects `OPENCODE_HOSTNAME` into every bash tool
call. Use it to disambiguate which machine you're on without spawning a
subprocess:

```bash
echo $OPENCODE_HOSTNAME    # devbox | cloudbox | <macOS hostname> | penguin (crostini)
```

The repo-level `AGENTS.md` (in any workstation checkout) has a full host
table mapping hostnames to flake targets and rebuild commands; this env var
is the primitive. Don't assume "devbox" — `cloudbox` and `devbox` are both
NixOS hosts running on `dev@` and look identical from inside opencode.

## Secrets in bash sessions

opencode's bash tool runs **non-interactive** shells. `~/.bashrc` short-circuits
on the interactive guard (`[[ $- == *i* ]] || return`), so the
`programs.bash.initExtra` block in `users/dev/home.cloudbox.nix` — which exports
the work tokens — never runs. To close that gap, the same `shell-env.ts` plugin
reads the sops-decrypted `/run/secrets/*` files directly and injects them into
every bash invocation (see `loadSecretEnv` in `shell-env.ts`). On cloudbox that means
`JENKINS_API_TOKEN`, `JENKINS_USER`, `GH_TOKEN`, `GITHUB_API_TOKEN`, `BUNDLE_*`,
`DD_PAT`, `BUILDBUDDY_*`, `BA_CLI_REPO`, `GOOGLE_CLOUD_PROJECT`,
the Atlassian vars, etc. are all available in opencode bash sessions.

The read is host-safe: where `/run/secrets/*` does not exist
(devbox/crostini/macOS) each lookup returns `undefined` and nothing is injected.

Note: `ba config syncsecrets` still must run from the Mac — even with
`JENKINS_API_TOKEN` loaded, the Jenkins host is unreachable from cloudbox
(behind the BA VPN / Mac-only network).

## Backgrounding Long-Running Processes

A bare `nohup ... &` can die when the parent shell is interrupted. To fully
detach a process from the shell session (so Ctrl+C / shell exit doesn't kill
it), use:

```bash
setsid nohup <command> < /dev/null > /tmp/log 2>&1 & disown
```

Then verify the process is alive (`ps -p <pid>` or check for its expected
side effect like a listening socket).
