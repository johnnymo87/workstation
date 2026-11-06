# Audit: `assets/agents/AGENTS.md` and `assets/opencode/AGENTS.opencode.md`

This was read-only: no files changed. The checkout is at origin/main `d4775bfe`. Both deployed copies, `~/.agents/AGENTS.md` and `~/.config/opencode/AGENTS.opencode.md`, are byte-identical to the source.

## Recent commits (overlap with #797 / workstation-pp9r)

**`assets/agents/AGENTS.md`** (with `--follow`):
- `d4775bfe` 2026-11-06 #805: changed one line, the finding-program-coordinators scope at :39.
- `72711421` 2026-11-05 #797: renamed the file from `assets/opencode/AGENTS.md`. `git blame` attributes 65 lines to it.
- `b0463400` #779, `ee883bcc` #772, `d6aa3974` #769 are older.

**`assets/opencode/AGENTS.opencode.md`**:
- It was created in #797 (`72711421`). Its content was moved from the old file; the handle section came from #769 (`d6aa3974`, 2026-11-02).

**Lines #797 touched in AGENTS.md:** 1-20, 24-26, 100-103, 105-119, 253-255, 289-304, 321-325 and 396-401. Any slimming will conflict with these, so coordinate with the pp9r worker.

**Bead:** `bd show workstation-pp9r` and `pp9r.1` both return "no issue found" in the local workstation bead DB. The DB is probably not synced.

**Related guard, already in place:** `eng-agent-platform/stallwatch/coordinator.py:2161` refuses to start a coordinator if its goose home contains `AGENTS.md`.

## Content tests and live citations

**No test checks the content of either file.**
- `users/dev/agents-instructions.nix:28-31` only asserts that the file is not deployed as a `home.file` link.
- `eng-agent-platform/lanes/capture-rendered-surface.py:69` only checks whether `~/.agents/AGENTS.md` exists.

**Live places that cite the files** (docs/plans excluded). If a section moves, each of these must be updated or the heading kept:

| Cited section | Cited from |
|---|---|
| "Backgrounding Long-Running Processes" | `pkgs/opencode-launch/default.nix:876`, `skills/using-gws/SKILL.md:53`, `skills/ask-question/SKILL.md:77`, `pigeon/.agents/skills/cross-device-deployment/SKILL.md:224`, `AGENTS.opencode.md:91` |
| "Bash Environment" / bundled sleeps | `using-gws/SKILL.md:45`, `shepherding-pull-requests/SKILL.md:358`, `shepherding-pull-requests/reference/common-mistakes.md:19` |
| "Reporting to Humans" and its tiebreaker | `shepherding-pull-requests/SKILL.md:271` |
| Override: no `git worktree remove` | `reviving-worktree-orphaned-sessions/SKILL.md:145`, `users/dev/disk-cleanup.nix:2439` |
| Throwaway `--detach` worktree recipe | `users/dev/disk-cleanup.nix:290`, `users/dev/test-tmp-scratch-sweep.sh:274` |
| Commit-as-human "named exception" | `lgtm/tests/reawakenOwnership.test.ts:24`, `lgtm-deploy/tests/reawakenOwnership.test.ts:24` (comments only) |
| AGENTS.opencode.md: stop-and-report when `-opus` fails | `assets/opencode/plugins/subagent-failure.ts:68` |
| AGENTS.opencode.md: `-fable` disambiguation | `users/dev/opencode-config.nix:302-305` (this comment goes stale if :58-70 is deleted) |
| Deploy paths | `agents-instructions.nix:24-25`, `opencode-config.nix:1009, 1029-1031` |

Historical citations in docs, which do not bind anything: about 20 in `workstation/docs/plans/*`, `eng-agent-platform/docs/plans/2026-09-28-classifier-benchmark-plan.md:292`, and `eternal-machinery/docs/archive/agents-md/root.md:511`.

---

## File 1: `assets/agents/AGENTS.md` (517 lines, 34,516 B)

### Section verdicts

**Header, :1-20 — TRIM to about 5 lines.**
- Keep: the source path, "a hand edit is reverted", and the pointer to the harness file.
- Drop :13-15, the explanation of why it is a real file. The same explanation is in `agents-instructions.nix:10-17`.

**(a) Skills table, :22-87 — DELETE, leaving a 3-line pointer. Keep the scheduling-wakes nudge at :41-47 inline (3 lines).**

The table repeats the name and description that both harnesses already inject. opencode lists them in `available_skills`; goose uses its skills index, which `eng-agent-platform/lanes/capture-rendered-surface.py:83-90` measures.

What would be lost:
1. **The Scope column** (cross / work-only). An agent never needs it, because an undeployed skill is not listed. Humans can find it in `users/dev/opencode-skills.nix:35-83`.
2. **Grouping by purpose.** This is cosmetic.
3. **The :41-47 nudge.** This is a real always-on rule (#259 called it "an always-on nudge"), so keep it.

Nothing else is lost. The rule-like text in rows, such as "coordinator role is banned" in the swarm-messaging row at :37, already appears in the skills' own descriptions.

The table is also already wrong:
- **WRONG-TODAY:** it omits three deployed skills: `enabling-mcp-servers` (`opencode-skills.nix:40`, cross), `escalating-azure-aks-rbac` (:72) and `monitoring-deployments` (:74).
- **WRONG-TODAY:** :86 says cleaning-disk works on "devbox/macOS", but it is deployed work-only (macOS and cloudbox, `opencode-skills.nix:71`). The skill's own description says "any NixOS host (devbox, cloudbox)", which matches neither.
- **Dead definition:** the "repo-only" scope at :29 is used by no row.

Hazard: the table is only an index where skills are visible. For a goose session with `GOOSE_GLOBAL_SKILLS=false` the table would be the only listing, but the skills would not be loadable there either.

**Superpowers Overrides, :88-103 — KEEP-INLINE, trimmed to 4-5 lines.**
- These have to bite while a superpowers skill is loaded, so they cannot live in a skill.
- Keep: "PR → load shepherding-pull-requests first"; "no worktree remove after Option 2; keep the tree until merged or closed"; "add a row if you find a third route".
- Drop the rationale prose at :90-93 and the second half of :98.

**Advisor and Reviewer Subagents, :105-119 — TRIM to 2 lines inline.**
- Keep: "a skill naming `adversarial-reviewer-opus` names a role; use your harness's handle".
- Move the opencode bullet (:111-113) to AGENTS.opencode.md.
- The goose bullet (:114-116) has no goose-only file to go to. This is a gap: no goose harness file is deployed, because `goose-config.nix` deploys no hints file. Record it and either keep the bullet or create a goose hints file. Note that `stallwatch/coordinator.py:2161` refuses `AGENTS.md` in the coordinator's goose home.

**(b) Reporting to Humans, :122-181 — KEEP-INLINE, trimmed from 60 to about 28 lines.**
- Must keep: the heading, which is cited; the bold rule at :124; the three "does not license" bullets, including the tiebreaker at :153-155, which is cited by `shepherding:271`; the scope rule at :165-169; the one line at :171-173; and the named exception at :175-181.
- Can trim: the elaboration at :127-130, the example sentences inside the bullets, and the parenthetical at :146-147.

**Bash Environment, :183-207 — TRIM to 3 lines, keeping the heading because it is cited.**
- Keep: "standalone sleep is fine; never chain sleep with follow-ups; poll a condition or use `timeout`".
- Delete the poll code block at :200-205.
- It duplicates `shepherding-pull-requests/reference/common-mistakes.md:19`.

**(b) Git Safety in Shared Worktrees, :209-257 — KEEP-INLINE, trimmed from 49 to about 16 lines.**
- Keep: the bold rule; the banned list at :222-228, compressed to 2 lines; "inspect read-only"; and the throwaway worktree recipe at :238-242, which is cited.
- Reduce the incident at :215-217 to a clause ("a review subagent's stash wiped a peer's DB").
- Reduce :247-257 to one sentence: "read-only subagents have these denied; that is a backstop, not a license".
- Inaccuracy at :249: `-astra` twins do not exist on macOS (`opencode-config.nix:1079, 1096`, `isDevbox || isCloudbox`), and cloudbox's `-fable` twins are not mentioned.
- Harness-specific details: :244 (opencode's external-directory permission) and :247-255.

**(b) Commit As The Human, :259-287 — KEEP-INLINE, trimmed from 29 to about 8 lines.**
- Keep: the bold rule at :261-263; the `git init` throwaway exception at :272-275, which the lgtm tests call the "named exception"; and the "Author identity unknown → stop and report" rule at :277-279.
- Delete the history at :268-270 ("Twenty-one such commits…").
- Reduce :281-287 to a clause: "cloudbox's pre-commit hook enforces this; on other hosts it is convention". Checked at `home.base.nix:1292`, which is `mkIf isCloudbox`.

**Host Identification, :289-304 — TRIM to 2 lines.**
- Keep: "run `hostname`; cloudbox and devbox look identical; the repo root `AGENTS.md` has the host table". The table exists at `workstation/AGENTS.md:5`.
- Move the opencode-specific `$OPENCODE_HOSTNAME` note at :297-299 to AGENTS.opencode.md.

**(b) Secrets in bash sessions, :306-325 — TRIM to 2-3 lines inline.**
- Keep: "work tokens (GH_TOKEN, JENKINS_*, Atlassian…) are in every agent shell on work hosts; goose sees a rotated secret only after goose-serve restarts".
- Delete the mechanism at :308-319, which is mostly opencode-specific (`shell-env.ts` internals). It belongs in a code comment.
- The variable list at :313-316 will go stale.

**Jenkins, :327-337 — DELETE.** It duplicates `reading-jenkins-builds/SKILL.md:3` (the description already triggers on "unreachable, refused, or hangs") and :8-10. If one line is wanted, keep "connection refused or reset means the Mac tunnel is down; retry in about 2 minutes; do not retry a hang".

**(b) Read-Only Database Queries, :339-349 — KEEP-INLINE, about 3 lines.**
- Keep the bold rule at :341-345 and "load working-with-kubernetes".
- :346-348 can be one clause.
- It duplicates `working-with-kubernetes/SKILL.md:12-54`, which is the canonical version, but that skill is work-only and the rule has to bite everywhere.

**bazel `--build_tests_only`, :351-374 — TRIM to 2 lines inline.**
- Keep: "on cloudbox, `bazel test` silently skips non-test targets you name; use `bazel build` to verify a build". The failure mode is a false verification with no warning, so it has to bite without a skill being loaded.
- Delete the measurements at :353-356 and :365-369 (83%, 144.3 MB, Bazel 8.5.1). The full rationale is in the generated `~/.bazelrc` comment (`home.base.nix:821-827`).
- An optional home for more detail is the `using-buildbuddy` reference, which is also work-only.

**(c) Backgrounding Long-Running Processes, :376-489 and :508-517 — MOVE-TO a new skill, `backgrounding-processes`.**
- Leave a 4-line stub that keeps the cited heading: "`setsid nohup` survives the shell but not a restart of your unit (a serve restarts nightly); for a job that must outlive it, use a capped `systemd-run --user --unit=… --collect` with `--expand-environment=no`; load `backgrounding-processes`".
- History to delete:
  - :405-406 ("Verified on cloudbox 2026-08-01"), keeping the table at :408-412 as evidence in the skill;
  - the incident at :414-416;
  - :437 ("On 2026-10-11 … froze devbox");
  - :465 (`workstation-yt0p`);
  - :479-480;
  - :508 ("hit twice").
- The skill also gets the cloudbox bash scoping from `AGENTS.opencode.md:94-113` as a reference, `references/cloudbox-oc-scoped-shell.md`.
- Proposed description: "Explains how to start a job that outlives the shell or a restart of the agent's serve unit on these hosts, covering setsid versus systemd-run, cgroups and memory caps, unit naming and reuse, the systemd-run expansion and nested-scope traps, pkill self-matching and cloudbox's per-command scopes. Use when backgrounding a process, starting a fire-and-forget job, restarting a serve pool from inside it, or reading exit 137 or a running UNSCOPED warning."
- `using-gws/SKILL.md:47-53` partly duplicates :378-387.

**Prose in double-quoted shell arguments, :490-506 — KEEP-INLINE, 3 lines.**
- It is a general hazard that applies to `bd note`, `gh pr create --body` and similar, unrelated to backgrounding.
- Keep: "write prose to a file and pass `"$(cat file)"`; backticks inside `"…"` are executed".
- Delete the incident narrative at :495-503.

### Best-practice violations
- **Harness-specific text in the shared file:** :24-26, :102-103, :111-116, :244, :247-255, :297-299, :308-319, :396-401, :422-423 (opencode bash has no `XDG_RUNTIME_DIR`).
- **Time-sensitive text:** :215-217, :268-270, :353-354, :365, :405, :414-416, :437, :465, :479-480, :495-503, :508.
- **Duplicated content:**
  - the skills table duplicates 29 frontmatter descriptions;
  - :339-349 duplicates `working-with-kubernetes:12-54`;
  - :327-337 duplicates `reading-jenkins-builds:3, 8-10`;
  - :351-374 duplicates `home.base.nix:821-827`;
  - :195-197 duplicates `shepherding common-mistakes.md:19` and `:358`;
  - :378-387 duplicates `using-gws:47-53`;
  - :98 duplicates `reviving-worktree-orphaned-sessions:145`.

### Estimated size after cleanup
About 115-130 lines, about 8-9 KB, a 74% cut. Draft outline below.

---

## File 2: `assets/opencode/AGENTS.opencode.md` (113 lines, 7,060 B)

**Header, :1-12 — TRIM to 3 lines.** Keep the source and the pointer to the shared file. Drop the deploy narrative.

**Superpowers Overrides (opencode), :14-21 — KEEP-INLINE.**
- The :21 claim is correct today: the bootstrap that is actually injected still says `~/.config/opencode/skills/superpowers/`, that path does not exist, and `~/.agents/skills/superpowers` does.
- Clarify :20: the `<subagent-routing>` block is deployed only on darwin and cloudbox (`opencode-config.nix:1128`). On devbox the row points at nothing.

**Which Handle, Per Host, :23-87 — TRIM from 65 to about 18 lines.**

Current rules to keep:
- The table at :27-31, or one line: "`-opus` everywhere; opt-in only when asked: devbox `-astra`, cloudbox `-astra` and `-fable`, macOS none". This matches `opencode-config.nix:1079-1098`.
- :33-37: a dead `-opus` does not authorize an opt-in twin; if the human asked for astra and it is unavailable, fall back to `-opus` and say so in one clause; if they asked for both twins, report the failure. `subagent-failure.ts:68` depends on this.
- :39-46, compressed to 2 lines: the plugin refuses or errors a dead astra and names the `-opus` twin, and truncated text is not a review.
- :48-56, compressed to 2 lines: a hang shows as no progress for 15 minutes or more, or a status that stays `retry`; elapsed time alone is not a hang; the parent does not time it out.
- :73-75: a human asking for fable is a model choice; on cloudbox dispatch `-fable`, elsewhere say there is none.
- :77-87, minus the history clause: a handle named in a request is a role.

History to delete:
- :58-70, the pre-rename stale-serve case. The rename was 2026-09-28 and serves restart nightly. Hazard: this makes the comment at `opencode-config.nix:302-305` stale.
- :79-80, "which were devbox's defaults until 2026-11-02".
- :50-51 and :54-55, the measurements ("1 in 5", "in 30 days … under 5").
- Unverified, delete anyway: :69, "fable-5-1 is still configured on every host".

**Bash Tool Scoping on cloudbox, :89-113 — split.**
- Keep 3 lines inline:
  - "On cloudbox each bash call runs in its own scope, so `setsid` survives a serve restart."
  - "Exit 137 is the 10 G per-command cap, not host OOM; reduce parallelism instead of retrying unchanged."
  - "A `running UNSCOPED` warning means the memory protection is off."
- Move the rest to the `backgrounding-processes` reference. That covers the spawn-time-wrap rationale at :106-109 and the bead IDs at :96.
- Verified: cloudbox only (`opencode-config.nix:935-937`). On devbox, a bash call runs in the serve's cgroup (`/proc/self/cgroup` shows `opencode-serve@4096.service`).

**New content to add, from AGENTS.md:** :111-113 (handles), :297-299 (`$OPENCODE_HOSTNAME`), and the opencode half of :308-319 (`shell-env.ts` injects `/run/secrets/*`, in one line).

**Estimated size after cleanup:** about 35-40 lines, about 2.5 KB.

---

## Proposed outline for the slimmed `assets/agents/AGENTS.md` (about 120 lines)

```
# User-level Agent Instructions                          (~5)
  source path; hand edits revert; harness file pointer; repo AGENTS.md for repo rules
## Skills                                                (~6)
  both harnesses list skills; sources in assets/opencode/skills, deploy list in opencode-skills.nix
  "Ending a turn with something owed to the future?" -> swarm_schedule before you stop (scheduling-wakes)
## Reporting to Humans                                   (~28)  [heading cited]
  rule; 3 rules-out bullets (1 line each); 4 does-not-license bullets incl. tiebreaker;
  scope (turn-ending, to a human; not subagent->parent); where the route goes; named exception
## Git Safety in Shared Worktrees                        (~16)  [heading cited]
  rule + one-clause why; banned verbs; read-only inspection; throwaway --detach worktree recipe;
  subagent denylist is a backstop, not a license
## Commit As The Human, Never As An Invented Identity    (~8)
  bare `git commit`; git-init fixture exception; "Author identity unknown" -> stop and report;
  cloudbox hook enforces
## Workflow Overrides (superpowers)                      (~6)
  PR -> shepherding-pull-requests first; never remove the worktree of an open PR; add a row for a third route
## Subagent Roles                                        (~3)
  skill-named handles are roles; harness file says which handle
## Read-Only Database Queries Use the Read-Only Role     (~4)
## Shell Hazards                                         (~25)
  ### Host Identification (2)
  ### Bash Environment (3)               [heading cited]
  ### Quoting prose into shell arguments (3)
  ### Backgrounding Long-Running Processes (4) -> backgrounding-processes   [heading cited]
  ### Secrets in agent shells (3)
  ### bazel on cloudbox (2)
```

New skill: `backgrounding-processes`, cross-host, about 110 lines, with one reference file for cloudbox's per-command scopes. Deploy it with its reference file in `opencode-skills.nix` `crossPlatformSkills`. Nothing is merged into an existing skill except the optional bazel note into `using-buildbuddy`. When the headings move, update the five live "Backgrounding" citations and the three "Bash Environment" citations listed above, or keep those headings as stubs as the outline does.
