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
| [opencode-send](skills/opencode-send/SKILL.md) | cross | Post a message into another local opencode session. Auto-routes through pigeon for `ses_*` targets (durable, retry, race-safe); `--direct` is the legacy escape hatch. |
| [swarm-messaging](skills/swarm-messaging/SKILL.md) | cross | Sender + receiver protocol: `<swarm_message>` envelope, message kinds, priority, threading via `--reply-to`, replay via `swarm_read`. |
| [swarm-shaped-work](skills/swarm-shaped-work/SKILL.md) | cross | When to swarm vs. iterate sequentially. Coordinator + workers topology. Spin-up sequence (`opencode-launch` × N → tell coordinator the worker ids → kick off). |

### Session Workflow

| Skill | Scope | Purpose |
|-------|-------|---------|
| [adding-opencode-skills](skills/adding-opencode-skills/SKILL.md) | cross | Add, edit, or move an OpenCode skill; debug why a newly-added skill is not picked up. |
| [preparing-for-compaction](skills/preparing-for-compaction/SKILL.md) | cross | Persist durable context before compaction so work survives. Beads + plan files + resumption prompt. |
| [searching-sessions](skills/searching-sessions/SKILL.md) | cross | `oc-search` patterns for grepping past session transcripts (PRs, Jira tickets, commands, payloads). |
| [beads](skills/beads/SKILL.md) | cross | Activate `bd` issue tracking when work spans multiple sessions or has complex dependencies. |
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
`DD_API_KEY`/`DD_APP_KEY`, `BUILDBUDDY_*`, `BA_CLI_REPO`, `GOOGLE_CLOUD_PROJECT`,
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
