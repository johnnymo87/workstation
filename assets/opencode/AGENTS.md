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
| [reviewing-github-prs](skills/reviewing-github-prs/SKILL.md) | repo-only | Posting PR reviews on GitHub with inline comments via `gh` CLI. Not deployed; reach into source if needed. |

### External Services

| Skill | Scope | Purpose |
|-------|-------|---------|
| [ask-question](skills/ask-question/SKILL.md) | cross | Draft a technical research question and send to ChatGPT for investigation. |
| [using-chatgpt-relay-from-devbox](skills/using-chatgpt-relay-from-devbox/SKILL.md) | cross | Send ChatGPT queries from devbox via `ask-question` CLI. Setup + troubleshooting for the chatgpt-relay. |
| [using-gws](skills/using-gws/SKILL.md) | cross | Google Workspace APIs (Gmail, Drive, Docs, Sheets, Calendar) via the `gws` CLI. Account switching, available services, common commands. |
| [using-atlassian](skills/using-atlassian/SKILL.md) | work-only | Read/write Jira tickets, fetch Confluence pages, JQL search, comments, attachment downloads. |
| [formatting-slack-messages](skills/formatting-slack-messages/SKILL.md) | cross | Slack mrkdwn dialect quirks (single-asterisk bold, underscore italic, no headers, angle-bracket links). |
| [slack-mcp-setup](skills/slack-mcp-setup/SKILL.md) | work-only | Set up the Slack MCP server with an `xoxp` User OAuth token. macOS Keychain or cloudbox sops. |
| [notify-telegram](skills/notify-telegram/SKILL.md) | cross | Enable Telegram notifications when this Claude finishes tasks (`/notify-telegram`). |

### Platform Tooling

| Skill | Scope | Purpose |
|-------|-------|---------|
| [working-with-kubernetes](skills/working-with-kubernetes/SKILL.md) | work-only | Generic `kubectl` patterns: pod interaction, file transfer, distroless container debugging, kubeconfig management. |
| [using-gcloud-bq-cli](skills/using-gcloud-bq-cli/SKILL.md) | work-only | Gotchas for `gcloud` and `bq`: service-account auth, IAM permission checks, BigQuery access errors. |
| [creating-pull-requests](skills/creating-pull-requests/SKILL.md) | work-only | PR title format, description template, pre-PR checks, post-PR monitoring. |
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

## Backgrounding Long-Running Processes

A bare `nohup ... &` can die when the parent shell is interrupted. To fully
detach a process from the shell session (so Ctrl+C / shell exit doesn't kill
it), use:

```bash
setsid nohup <command> < /dev/null > /tmp/log 2>&1 & disown
```

Then verify the process is alive (`ps -p <pid>` or check for its expected
side effect like a listening socket).
