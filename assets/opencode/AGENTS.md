# User-level Instructions: opencode only

The shared rules for every harness (git safety, commit identity, reporting,
bash, backgrounding, skills, ...) are in `~/.agents/AGENTS.md`, which opencode
loads through the `instructions` key of its config. This file holds only what
is specific to opencode: its Task-tool agents, its plugins, and its serve.

Source: `assets/opencode/AGENTS.md` in the
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
| devbox | `oracle-opus` | `adversarial-reviewer-opus` | stop and report | `-astra` |
| cloudbox | `oracle-opus` | `adversarial-reviewer-opus` | stop and report | `-astra`, `-fable` |
| macOS | `oracle-opus` | `adversarial-reviewer-opus` | stop and report | — |

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

**`-fable` means one of two things, and the list tells you which.** It was
the name of the default slot until 2026-09-28, when that slot was renamed
`-opus` (same prompt, model moved from fable-5-1 to opus-5-5). A serve loads its
agent list once at startup, so one started before a `home-manager switch` may
still list the old names. On cloudbox, `-fable` is also deployed as an opt-in
fable-5-1 twin.

- **`-opus` is listed:** any `-fable` alongside it is the opt-in twin (cloudbox).
  Dispatch it only when the human asks for fable.
- **`-opus` is not listed but `-fable` is:** the serve predates the rename and
  `-fable` *is* the default slot. Dispatch it wherever the docs say `-opus`.
  fable-5-1 is still configured on every host, so it works; it just runs the
  older model.

An "Unknown agent type" for a handle in the default slot is a naming mismatch,
not a reason to stop. A human asking for *fable* is a model choice, which is a
different case. On cloudbox, dispatch `-fable`. On devbox and macOS there is no
fable twin: say so rather than silently substituting another model.

**A handle named in a request is a role.** Humans, older prompts and your own
resumption prompt may name a suffixed handle out of habit — including
`oracle-astra` / `adversarial-reviewer-astra`, which were devbox's defaults
until 2026-11-02. Dispatch the host's default handle for that role, as above.
A handle written into an agent-authored artifact (plan doc, bead note, queued
wake) is always a role reference, not a model choice.
The exceptions, honored on every host: the human deliberately picked the model
("use astra"), or asked for both twins (independent opinions). Then dispatch
exactly what they named. Never write a suffixed handle into a
resumption prompt from memory. Write the role, or the handle the Task tool
actually lists.

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
