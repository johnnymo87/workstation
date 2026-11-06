# Workstation agent-instructions audit: shared brief (READ-ONLY research)

Repo: /home/dev/projects/workstation (johnnymo87/workstation), at origin/main. Do NOT modify any file,
do not run destructive git. Read with `git show origin/main:<path>` or the working tree (main is clean).

## What is deployed
- `assets/agents/AGENTS.md` (517 lines, 34.5 KB): deployed as a real file to `~/.agents/AGENTS.md` on every host
  (devbox, cloudbox, macOS). Read by opencode (as its global AGENTS.md) AND goose (global hints). It sits in
  EVERY session's system prompt on every host, so every byte costs on every turn of every session.
- `assets/opencode/AGENTS.opencode.md` (113 lines, 7 KB): opencode-only, loaded via its `instructions` config.
- `assets/opencode/skills/<name>/` (32 skills): deployed to `~/.agents/skills/` by `users/dev/opencode-skills.nix`
  (files are listed individually there; work-only skills deploy to macOS + cloudbox only). Both harnesses list
  each skill's name + description in the system prompt; the body loads on demand.
- Note: a repo-root `AGENTS.md` (21 KB) exists for developing the workstation repo itself; it is NOT installed.

## Target design (the same one just applied to the eternal-machinery repo)
- An always-loaded instruction file is a table of contents and a light jump start, plus the short list of
  standing hard rules that must bite even when no skill is loaded. Everything else (procedures, incident
  narratives, measurements, verification tables, history of renames) moves into a skill or reference that loads on
  demand, or is deleted if it is history.
- Sort material three ways: current truth -> skill / reference file; live operating state -> runbook or bead;
  history (incidents, "until 2026-xx-xx it was ...", "verified on ...") -> delete (git history keeps it) or a
  one-clause "why" if the rule would otherwise look arbitrary.
- Nothing harness-specific in the shared file (opencode vs goose specifics belong in the harness file or a skill).
- Anthropic skill best practices (https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices):
  - Concise: assume the model is smart; only add context it lacks. SKILL.md body under 500 lines.
  - Frontmatter `name`: lowercase letters/numbers/hyphens, <=64 chars, matches the directory. `description`:
    non-empty, <=1024 chars, THIRD PERSON ("Explains ...", "Covers ..."), says what it does AND when to use it,
    with concrete trigger terms. No first/second person.
  - Progressive disclosure: SKILL.md is an overview that links reference files ONE level deep; each reference says
    when to load it; references over 100 lines get a contents list at the top.
  - Avoid time-sensitive information (or put it in an "old patterns" collapsible section); consistent terminology;
    no deeply nested references; workflows with checklists for multi-step tasks; feedback loops (validate, fix,
    repeat); no Windows paths; avoid offering too many options.
- House description style used in eternal-machinery (recommend, not mandatory): no ": " , no dashes, no
  semicolons, no "you"/"your".

## Hazards (record, do not resolve)
- Skills are read by more than the agent that loads them: stall-watch coordinators (their `sw` skill and system
  prompt cite opencode-launch, swarm-messaging, scheduling-wakes, formatting-slack-messages,
  enabling-mcp-servers and others), lgtm-shepherd wake prompts, pigeon, honk, and repo-local skills that point at
  global ones. Repos on this host: /home/dev/projects/{eng-agent-platform,lgtm,lgtm-deploy,pigeon,honk,
  eternal-machinery,workstation}. Any skill rename/delete, or a heading another file cites by title, is a
  cross-repo break.
- workstation PR #797 (bead workstation-pp9r) just made AGENTS.md harness-agnostic; its worker is turning hints off
  for stall-watch's tool-less coordinators. Note any lines that look recently touched by that work
  (`git log -L` / `git blame` on assets/agents/AGENTS.md).

## Output (your final message, structured, concise)
For each file you audit: size; a section-by-section (or per-skill) verdict: KEEP-INLINE / TRIM (what) /
MOVE-TO (target skill or reference, new or existing) / DELETE (history) / WRONG-TODAY (claim + evidence
file:line); best-practice violations (description person, length, nesting, missing contents list, missing
"load when", time-sensitive text, duplicated content across files with the duplicate's location); and an
estimated size after cleanup. Cite file:line for every claim. No prose padding.
