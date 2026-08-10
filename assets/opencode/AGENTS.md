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
is the deployment target: `cross` = all machines (devbox, cloudbox, macOS),
`work-only` = macOS + cloudbox, `repo-only` = file present in the
repo but not deployed to any machine yet.

### Swarm Coordination

| Skill | Scope | Purpose |
|-------|-------|---------|
| [opencode-launch](skills/opencode-launch/SKILL.md) | cross | Spawn a headless opencode session in a given dir with an initial prompt. The basic primitive for swarm spin-up. Also covers `oc-mcp-enable`, which grants an MCP server (slack, atlassian, …) to an ALREADY-RUNNING session — no relaunch, no lost context. |
| [swarm-messaging](skills/swarm-messaging/SKILL.md) | cross | **Message economy first** (fewer messages, not shorter; no acks; batch and hold; never restate a swarm message to a human who can see it), the coordinator role (one brief upward, retract your own relays, don't assign from a stale board, silence reads as endorsement), then the protocol: `swarm_send`/`swarm_read`/`swarm_list`, the `<swarm_message>` envelope, kinds, priority, threading, replay. |
| [scheduling-wakes](skills/scheduling-wakes/SKILL.md) | cross | Waking yourself at a future time with `swarm_schedule`/`swarm_scheduled`. Durable across the nightly reset. Payload rules, what `delivered_late_ms` doesn't measure, the silent pruned-worktree failure, why a trigger on the dependent does not cover the dependency, and cancel-and-reschedule (inverting a retracted claim, not deleting it). |
| [swarm-shaped-work](skills/swarm-shaped-work/SKILL.md) | cross | When to swarm vs. iterate sequentially. Coordinator + workers topology. Spin-up sequence (`opencode-launch` × N → tell coordinator the worker ids → kick off). |

**Ending a turn with something owed to the future?** You cannot remember to do
it — when the turn ends, nothing runs until someone prompts you. Schedule a
wake *before you stop*:
`swarm_schedule(after: "13h", ref: "bd:...", message: "<self-contained>")`.
The payload must stand alone, because the session that receives it may have
compacted away why it was scheduled. See `scheduling-wakes`.

### Session Workflow

| Skill | Scope | Purpose |
|-------|-------|---------|
| [adding-opencode-skills](skills/adding-opencode-skills/SKILL.md) | cross | Add, edit, or move an OpenCode skill; debug why a newly-added skill is not picked up. |
| [attributing-causes](skills/attributing-causes/SKILL.md) | cross | Treat a memorable event (deploy, nightly job, restart) as a suspect, not evidence. The "could X even reach that state?" test, re-measuring inherited counts before destructive action, and interrogating the instrument itself — what entity it measures, snapshot-vs-series, and the correct-instrument-aimed-wrong failure that fails no check on its own output. |
| [preparing-for-compaction](skills/preparing-for-compaction/SKILL.md) | cross | Persist durable context before compaction so work survives. Beads + plan files + resumption prompt. |
| [searching-sessions](skills/searching-sessions/SKILL.md) | cross | `oc-search` patterns for grepping past session transcripts (PRs, Jira tickets, commands, payloads). |
| [beads](skills/beads/SKILL.md) | cross | Activate `bd` issue tracking when work spans multiple sessions or has complex dependencies. |
| [migrating-beads-schema](skills/migrating-beads-schema/SKILL.md) | cross | Resolve a bd cross-clone schema-migration block (#4259): single-migrator discipline, DoltHub-vs-git split-remote trap, adopt-vs-migrate, embedded-clone graft fallback, 0037 stripped-UUID-default repair (Error 1105), fresh-clone verification. |
| [reviewing-github-prs](skills/reviewing-github-prs/SKILL.md) | cross | Choosing the right response shape (threaded inline reply vs fresh review vs top-level issue comment) when posting on a PR, plus the `gh` CLI mechanics for each. |

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
`adversarial-reviewer-fable`, `adversarial-reviewer-sol`, `oracle-opus`,
`oracle-fable`, `oracle-sol`) have these git subcommands denied at the
permission layer (`assets/opencode/agents/*.md`),
so the rule holds even if a subagent forgets it. That guard is a backstop, not
a license — the convention above binds all sessions and subagents regardless of
which agent they run as.

## Host Identification

The `shell-env.ts` plugin injects `OPENCODE_HOSTNAME` into every bash tool
call. Use it to disambiguate which machine you're on without spawning a
subprocess:

```bash
echo $OPENCODE_HOSTNAME    # devbox | cloudbox | <macOS hostname>
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
(devbox/macOS) each lookup returns `undefined` and nothing is injected.

Note: `ba config syncsecrets` still must run from the Mac — even with
`JENKINS_API_TOKEN` loaded, the Jenkins host is unreachable from cloudbox
(behind the BA VPN / Mac-only network).

## Backgrounding Long-Running Processes

A bare `nohup ... &` can die when the parent shell is interrupted. To detach a
process from the **shell session** (so Ctrl+C / shell exit doesn't kill it),
use:

```bash
setsid nohup <command> < /dev/null > /tmp/log 2>&1 & disown
```

Then verify the process is alive (`ps -p <pid>` or check for its expected
side effect like a listening socket).

### This does NOT survive `systemctl restart` of the unit you're in

`setsid` and `nohup` escape the controlling terminal and the process session.
They do **not** escape the systemd unit's **cgroup**. `systemctl restart` (and
`stop`) kills the entire control group, so a `setsid nohup` child started from
inside a unit dies with it.

This matters constantly here, because an opencode bash tool call runs inside
`opencode-serve@<port>.service`. Anything that restarts the serve pool — or any
unit your session lives in — kills your "detached" job mid-flight.

**On cloudbox this is no longer true, and the difference matters in both
directions.** The `agent-scope` plugin now runs every bash-tool command in its
own transient scope under `oc-agent.slice` (bead `workstation-yt0p`), so:

- Your command's cgroup is `…/user@1000.service/oc-agent.slice/oc-agent-*.scope`,
  **not** the serve's. A `setsid nohup` job therefore *survives* a serve restart
  here. `systemd-run --user --unit=…` is still the right tool for anything
  genuinely durable — an `oc-agent` scope is per-command and unnamed.
- Your command has a **10 G memory cap**. A process killed at that cap reports
  **exit 137**; that is the scope cap, not the host running out of memory, and
  retrying unchanged will fail identically. Reduce the workload's parallelism
  instead (for vitest, `--maxWorkers`; for a build, its job count).
- Commands mentioning `git` are deliberately NOT scoped, so that the `git …`
  deny rules in the review agents keep matching. They behave exactly as
  described above.

Check with `cat /proc/self/cgroup` rather than assuming which case you are in.

**Verified on cloudbox 2026-08-01** with a throwaway user unit: three children
were started from inside the unit's cgroup, then the unit was restarted.

| Launch pattern | Child's cgroup | Survived `systemctl restart`? |
|---|---|---|
| `setsid nohup ... & disown` | *same* `…/cgroup-escape-parent.service` | **No — killed** |
| `systemd-run --user --scope --collect -- ...` | fresh `…/run-pNNN.scope` | Yes |
| `systemd-run --user --unit=NAME --no-block -- ...` | own `…/NAME.service` | Yes |

**Real incident that motivated this (bead workstation-4qvx):** a pool restart
staged as `setsid nohup bash -c '...' & disown` from a session on serve `:4098`
restarted 4096, 4097, 4098 — then died at 4098 and never reached 4099.

### Correct pattern: escape the cgroup, then detach

```bash
# Fire-and-forget job that must outlive a restart of your own unit.
# NOTE: transient units get a minimal PATH, and opencode bash calls have no
# XDG_RUNTIME_DIR -- pass both explicitly or the run fails with either
# "Failed to connect to user scope bus" or exit 127 "bash: No such file".
# --collect + a unique name: without them a finished-failed or still-running
# job holds the name and the NEXT invocation dies with "unit already exists",
# in exactly the fire-and-forget context where nobody is watching.
export XDG_RUNTIME_DIR=/run/user/$(id -u)
systemd-run --user --unit="my-job-$$" --no-block --collect \
  --setenv=PATH="$PATH" \
  bash -c '<command> >> /tmp/my-job.log 2>&1'
```

If you reuse a fixed unit name deliberately (so you can find it in the journal),
clear the old one first — and note that `reset-failed` only releases a name held
by a *failed* unit; one that is still running needs `stop`:

```bash
systemctl --user stop my-job 2>/dev/null
systemctl --user reset-failed my-job 2>/dev/null
```

Use `--scope` instead when you need the job to inherit your stdio and run
synchronously; use `--unit=... --no-block` for fire-and-forget with journal
capture (`journalctl --user -u my-job`).

`systemd-run` can fail even when systemd is healthy — most often when
`XDG_RUNTIME_DIR` (`/run/user/$UID`) is **full**, which surfaces as the
misleading "Failed to start transient scope unit: ... not found". Probe with a
throwaway (`systemd-run --user --scope --collect --quiet -- true`) before
committing to it, and degrade rather than hard-exit.
`pkgs/reset-workspace/default.nix` implements exactly this (it restarts the
serve pool it may itself be running inside); copy its shape rather than
reinventing it.

Two `systemd-run` traps, both found the hard way in `workstation-yt0p`, and both
of which fail **silently** rather than loudly:

- **systemd EXPANDS the command you hand it.** `$$` collapses to a single `$`,
  and `${VAR}` is substituted or errors, before your shell ever sees it:

  ```bash
  $ systemd-run --user --scope -q -- printf '%s\n' 'both=$$ and ${FOO}'
  both=$ and                 # <- silently corrupted
  $ systemd-run --user --scope -q --expand-environment=no -- printf '%s\n' 'both=$$ and ${FOO}'
  both=$$ and ${FOO}         # <- correct
  ```

  Pass **`--expand-environment=no`** whenever the payload is not yours to mangle.
  This had been quietly corrupting bazel arguments for as long as the bazel shim
  had shipped, and was found by review rather than by any symptom.

- **The auto unit name is PID-derived, so nested scopes collide.** `--scope`
  execs the payload *in place*, and `bash -c` exec-optimizes a final simple
  command, so a `systemd-run` running inside another scope can inherit the very
  PID that named the outer scope and die with `Unit run-pNNN.scope was already
  loaded or has a fragment file`. If anything you launch might itself re-scope
  (bazel does, via its shim), give the OUTER scope an explicit non-PID-derived
  name: `--unit=myjob-$RANDOM`.

One `pkill` footgun, hit twice while verifying the above: `pkill -f <pattern>`
matches **your own** command line, so `pkill -f 'job scope'` issued from a shell
whose argv contains that string kills the shell — and the surrounding command
chain silently stops mid-way, which looks exactly like a hang. Prefer
`kill <pid>` on PIDs you captured, or bracket the pattern (`'[j]ob scope'`).

Two caveats on the table above. It assumes the default
`KillMode=control-group`; a unit with `KillMode=process` does not sweep its
cgroup on restart. And `systemd-run --user` needs dev's user manager to exist
(lingering) — the throwaway probe catches its absence either way.
