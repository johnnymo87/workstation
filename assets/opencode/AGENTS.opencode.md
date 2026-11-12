# User-level Instructions: opencode only

The shared rules for every harness (git safety, commit identity, reporting,
bash, backgrounding, skills, ...) are in `~/.agents/AGENTS.md`, which opencode
reads as its global `~/.config/opencode/AGENTS.md` (a link to it). This file,
loaded through the `instructions` key of opencode's config, holds only what is
specific to opencode: its Task-tool agents, its plugins, and its serve.

Source: `assets/opencode/AGENTS.opencode.md` in the
[workstation](https://github.com/johnnymo87/workstation) repo (the shared file
is `assets/agents/AGENTS.md`). This one is deployed by `users/dev/opencode-config.nix`, the shared one by
`users/dev/agents-instructions.nix`.

## Superpowers Overrides (opencode)

Continues the table in `~/.agents/AGENTS.md`; ours wins there too.

| Superpowers says | Do this instead |
|---|---|
| `Task tool (general-purpose)` for implementation or review | The named agents — see the `<subagent-routing>` block, where deployed |
| The injected bootstrap: "Superpowers skills are in `~/.config/opencode/skills/superpowers/`" | They are in `~/.agents/skills/superpowers/`, where every system-wide skill now lives. The plugin hardcodes the old path. Load skills with the `skill` tool; don't browse that path, and don't add a compatibility symlink there, because opencode would scan it and see every skill twice. |

## Oracle and Adversarial Reviewer: Which Handle, Per Host

**The `-opus` handle is the default on every host.** Other twins are opt-in:

| Host | Oracle | Adversarial reviewer | If unavailable | Opt-in only when asked |
|---|---|---|---|---|
| devbox | `oracle-opus` | `adversarial-reviewer-opus` | stop and report | `-astra`, `-fable` |
| cloudbox | `oracle-opus` | `adversarial-reviewer-opus` | stop and report | `-astra`, `-fable` |
| macOS | `oracle-opus` | `adversarial-reviewer-opus` | stop and report | `-fable` |

`-astra` is gpt-6-astra (codex-lb); `-fable` is claude-fable-5-2.

A dead `-opus` does not authorize an opt-in twin. When the human asked for
astra and it is unavailable (not listed, `astra-probe` says DOWN, or the
dispatch errors or returns empty — an empty result is no review), falling back
to `-opus` is fine, but say so in one clause. If they asked for *both* twins,
report the failure instead: two opus answers are not a second opinion.

**A dead astra fails loudly, not silently.** The `subagent-failure` plugin
runs `astra-probe` before every `-astra` dispatch and *refuses* the Task call
when it says DOWN. The error names the `-opus` twin, so just follow it. If the
child dies mid-dispatch, the plugin turns the empty or truncated "completed"
result into a `state="error"` `<task_error>` that names the same twin.
Truncated text in it is not a review. If codex-lb stalls before sending
headers, `headerTimeout` ends the child in about 13 minutes. Every one of these
counts as "errors" above.

**A hang is still possible, and it is not yours to time out.** A dispatch can
hang if codex-lb stalls *after* response headers, because keepalives defeat
every client timeout. Elapsed time is not evidence of a hang: about 1 in 5
healthy astra reviews run longer than 15 minutes, and some run for hours. The
dispatching agent is blocked inside the call and cannot act anyway. The signal
is lack of **progress**: the child session has gained no new parts for 15+
minutes (in 30 days of astra children the largest within-turn gap was under
5), or its status *stays* `retry` across several attempts. Whoever notices that (the human, or a
watcher) aborts the child, and the parent then falls back as for an error.

**`-fable` is an opt-in twin, never the default.** `oracle-fable` and
`adversarial-reviewer-fable` run claude-fable-5-2 with the same prompt as
`-opus`. Dispatch one only when a human has asked for fable. These count as
asking:

- the human names fable or a `-fable` handle, in this conversation or in
  their own words quoted to you by anyone (a program coordinator, a parent
  session, a launch prompt);
- an artifact dated 2026-11-12 or later names the model beside the handle,
  e.g. "`adversarial-reviewer-fable` (claude-fable-5-2, Jonathan's ask)". That
  is how an agent records a human's fable choice so it survives handoffs and
  compaction. Write it that way, never a bare handle.

A bare `-fable` handle in an artifact is not a choice, whatever its date. Until 2026-09-28
`-fable` was the name of the *default* slot (renamed `-opus` when the model
moved to opus-5-5), and many plan docs and bead notes from before then say
`adversarial-reviewer-fable` or `oracle-fable` meaning "the reviewer". Dispatch
`-opus` for those.

The `-fable` handles were added to devbox and macOS on 2026-11-12 (cloudbox
had a fable-5-1 twin before). A serve that has not restarted since the switch
that deployed them may list them in some directories and not others, and on
devbox a listed `-fable` fails there until the restart, because the serve's
process env lacks the Claude Code version override fable-5-2 needs. If a human
asked for fable and the handle is missing or fails, say so in one clause and
name the fix (the nightly reset, or `reset-workspace`); falling back to `-opus`
is fine, as for astra above.

An "Unknown agent type" for a handle in the default slot is a naming mismatch,
not a reason to stop.

**A handle named in a request is a role.** Humans, older prompts and your own
resumption prompt may name a suffixed handle out of habit — including
`oracle-astra` / `adversarial-reviewer-astra`, which were devbox's defaults
until 2026-11-02. Dispatch the host's default handle for that role, as above.
A handle written into an agent-authored artifact (plan doc, bead note, queued
wake) is a role reference, not a model choice, unless it names the model as
described for `-fable` above.
The exceptions, honored on every host: the human deliberately picked the model
("use astra", "use fable"), or asked for both twins (independent opinions).
Then dispatch exactly what they named. Never write a suffixed handle into a
resumption prompt from memory. Write the role, or the handle the Task tool
actually lists, with the model beside it when a human chose it.

## Bash Tool Scoping on cloudbox

Read with "Backgrounding Long-Running Processes" in `~/.agents/AGENTS.md`,
which explains why a `setsid nohup` job normally dies with the serve unit.

**On cloudbox an opencode bash call does not live in the serve's cgroup, and the
difference matters in both directions.** The `oc-scoped-shell` wrapper now runs every bash-tool command in its
own transient scope under `oc-agent.slice` (beads `workstation-yt0p` and `workstation-rdsq.4`), so:

- Your command's cgroup is `…/user@1000.service/oc-agent.slice/oc-agent-*.scope`,
  **not** the serve's. A `setsid nohup` job therefore *survives* a serve restart
  here. `systemd-run --user --unit=…` is still the right tool for anything
  genuinely durable — an `oc-agent` scope is per-command and unnamed.
- Your command has a **10 G memory cap**. A process killed at that cap reports
  **exit 137**; that is the scope cap, not the host running out of memory, and
  retrying unchanged will fail identically. Reduce the workload's parallelism
  instead (for vitest, `--maxWorkers`; for a build, its job count).
- Every bash-tool command is scoped, including ones that mention or invoke
  `git`. The wrap happens at spawn time (opencode's `shell` config points at
  `oc-scoped-shell`) rather than by rewriting the command text, so it no longer
  interferes with permission parsing and the `git …` deny rules keep matching.
  The one exception is the degrade path: if `systemd-run --user` is unusable,
  the wrapper prints a `WARNING: ... running UNSCOPED` line and runs the command
  in the serve cgroup. Seeing that line in your output means the memory
  protection is off, not that your command failed.
