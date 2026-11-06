# Runbook (read first). Epic: agent instructions audit

Goal: the always-loaded instruction files are a table of contents plus the standing hard rules, and every
deployed skill follows Anthropic's skill best practices, with nothing wrong today. Requested by Jonathan
2026-11-06 (via the stall-watch coordinator gse_3b719e0e) after the same audit in eternal-machinery (epic
eternal-machinery-wt8d4).

## Sources (cold sessions read these, never this session's memory)
- Audit reports with file:line evidence, and the brief with the target design and the Anthropic best-practice
  summary: `docs/plans/2026-11-06-agent-instructions-audit/` (brief.md, report-agents-md.md,
  report-swarm-session-skills.md, report-beads-pr-deploy-skills.md, report-external-service-skills.md).
  Landed by T0. Until T0 merges, read them with
  `git show origin/agents-audit:docs/plans/2026-11-06-agent-instructions-audit/<file>`.
- The reports are a snapshot of origin/main d4775bfe (2026-11-06). Re-verify every WRONG-TODAY item against
  current code before fixing it. A claim that is no longer wrong is dropped, not "fixed".

## Decision procedure
0. `bd dolt pull` first. For each in_progress child whose bd note names a PR, check `gh pr view N --json state`.
   If it is merged, close the child (`--reason "Merged in PR #N"`), reconcile this epic, then `bd dolt push`.
   Nothing else closes a child: lgtm sends no merged signal to the author, and Jonathan merges whenever he likes.
1. An open PR from this epic belongs to its authoring session (bd note on the child names it). Do not touch it.
2. Otherwise `bd ready --parent=workstation-ye4i`. Take the highest-priority ready child.
3. Ready is empty but children are open: something in flight is blocking. Report it to Jonathan. Never start a
   blocked child; if one looks startable, the graph is wrong, so split the bead instead.

## Launching or working a child
- Host: devbox (the beads DB here is the epic's; `bd dolt pull` before reading and `bd dolt push` after every
  write, because the devbox and cloudbox DBs drift). Work-only items (T5) are re-verified by evaluating the cloudbox
  and darwin home configs (`nix eval .#homeConfigurations.<host>.config.home.file --apply builtins.attrNames`).
  Something that needs a live work host is checked on cloudbox with `swarm_launch`, or is stated as unverified in
  the PR.
- A worker is this session or one launched with `opencode-launch --worktree` on the default model. Either way the
  worker follows this runbook.
- One worktree per child, cut from origin/main: `git worktree add .worktrees/<bead-id> -b <bead-id> origin/main`
  (T0 reuses the existing `.worktrees/agents-audit`). One live session per worktree.
- The worker claims (`bd update <id> --claim`) and `bd note`s its session id. The launcher does not claim. If a
  launch fails after a claim, unclaim.
- The child bead is the briefing. A prompt carries: the bead id, "read `bd show <id>` and this epic's design
  first", the scope fence, and the merge rule below.

## Standing rules
- Jonathan merges workstation PRs. Agents never `gh pr merge` here. Shepherd each PR per
  shepherding-pull-requests. A child closes at MERGE (`bd close <id> --reason "Merged in PR #N"`), then reconcile
  this epic: `bd note` the verdict and anything the work proved wrong.
- Adversarial review (the host's default adversarial reviewer) on every child's diff before the PR opens; resolve
  material findings.
- Never rename or delete a skill directory or name. Every name is load-bearing somewhere: the self-compact plugin
  (`assets/opencode/plugins/self-compact.ts:82`), stall-watch (`eng-agent-platform/stallwatch/coordinator_tools.yaml`,
  `tests/test_slack_posting.py`), the Confluence fetch list in `users/dev/opencode-skills.nix`, the repo-root
  AGENTS.md GitHub URL to attributing-causes, lgtm wake prompts. A heading cited by title elsewhere keeps its exact
  text, or every citer is updated in the same PR, cross-repo included. The reports list the cited headings.
- Before changing a skill, grep `/home/dev/projects/{eng-agent-platform,lgtm,lgtm-deploy,pigeon,honk,eternal-machinery,workstation}`
  (excluding .git, node_modules, .worktrees) for its name and headings.
- Delete history (incident stories, "until 2026-xx it was", "verified on", bead ids, rename history). Keep at most
  one clause of "why" when a rule would otherwise look arbitrary.
- Descriptions: third person, what it does and when to use it, concrete triggers, at most 1024 characters, no
  ": ", dashes, semicolons, "you" or "your". SKILL.md at most 500 lines. References one level deep, each with a
  "Load when" line and a contents list if over 100 lines.
- Shared AGENTS.md text must hold for both opencode and goose. opencode-only text goes in AGENTS.opencode.md.
- Merges deploy themselves (pull-workstation every 4 h on devbox and cloudbox; the Mac on its next switch). Before
  a PR, build the home configuration or run the flake check the repo AGENTS.md names, so a broken deploy never
  merges. New files must be `git add`ed before any switch, or they deploy as dangling links.
- No tree-wide destructive git in a shared worktree. The repo-root AGENTS.md "Landing the Plane" steps
  ("clear stashes", `git pull --rebase` at the root) are overridden for this epic until T8 rewrites them: the stash
  is shared by every worktree, so never touch it. Work in your own worktree and push your branch.
- Canonical copies of duplicated text (the other place points at it): the `--no-attach` story and the kill commands
  live in opencode-launch (T7), so swarm-shaped-work (T2) points there. The relay-hazard rules and the retry
  backoff live in swarm-messaging (T2), so attributing-causes and reviving-worktree-orphaned-sessions (T7) point
  there. Commit-identity, reporting and bash rules live in assets/agents/AGENTS.md (T1), so skills point at its
  headings.
- Frozen headings, because other children point at them: in assets/agents/AGENTS.md "Reporting to Humans",
  "Bash Environment", "Backgrounding Long-Running Processes", "Git Safety in Shared Worktrees" and
  "Commit As The Human, Never As An Invented Identity". In AGENTS.opencode.md "Oracle and Adversarial Reviewer:
  Which Handle, Per Host".

## Decisions (Jonathan, 2026-11-06)
1. cleaning-disk deploys to devbox too (move it to the cross-platform list). In T4.
2. shepherding-pull-requests keeps "never `gh pr merge`" with an exception: unless the repo's own AGENTS.md
   grants agents self-merge (eternal-machinery does). In T4, and anywhere T1 restates the rule.
3. The repo-root workstation AGENTS.md (not installed, loads in workstation sessions) is in scope. T8.
4. The four *-mcp-setup skills: the shared Keychain/sops/rotation recipe moves to repo-local
   `.agents/skills/managing-secrets`, and each global skill keeps only what an agent needs at use time. In T5.

## Not beads (do not try to do these here)
- lgtm's stale fallback path `~/.config/opencode/skills/monitoring-deployments/...` (`lgtm/src/rollout.ts:314`) and
  stall-watch's `find_coordinator.py:212` exit-2 text are other repos. Mention them to Jonathan; do not fix them
  from this epic.
- lgtm's wake payload (`lgtm/src/agentRouting.ts:531`) orders "Do NOT merge. Merging stays with the human." in
  every wake, including for repos whose AGENTS.md grants self-merge (eternal-machinery, routed to devbox). After T4
  the skill and that order disagree. Raise it with Jonathan as an lgtm change.
- Repo-local skills under workstation `.agents/skills/` (28) get no audit of their bodies. T8 only brings them under
  the caps T6b enforces.
- The superpowers skills are an upstream clone and are never edited.

## Task graph (orientation only; `bd ready` is the authority)
- T0 (plan docs + skill-dir deploy) -> T1, T2, T3, T4, T5, T7.
- T5 -> T8, because both edit managing-secrets. T8's read-only audit can start before that.
- T6a (link and cited-heading checker) starts at once and blocks nothing.
- T1, T2, T3, T4, T5, T7, T8 -> T6b (hard caps, then the epic closes).
