---
name: adding-opencode-skills
description: Use when adding, editing, or moving an OpenCode skill, or debugging why a newly-added skill is not picked up.
---

# Adding OpenCode Skills

Two valid locations for an OpenCode skill, with different deploy mechanics. Pick the right one or your skill won't appear (or will appear stale).

For generic skill-authoring discipline (TDD-for-skills, frontmatter rules, structure, search-optimization), see `superpowers:writing-skills` and Anthropic's [skill authoring best practices](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices). This skill covers **placement and deployment**, not authoring.

## Decision: Where Does the Skill Live?

| Skill is about... | Put it in | Deploy |
|---|---|---|
| **One specific repo** (its config, its workflows, its conventions) | `<repo>/.opencode/skills/<name>/SKILL.md` | None — auto-discovered when CWD is inside that repo |
| **A workflow usable from any project** (creating PRs, using gws, fetching Atlassian content, etc.) | `~/projects/workstation/assets/opencode/skills/<name>/` + register in `users/dev/opencode-skills.nix` | home-manager switch — symlinks into `~/.config/opencode/skills/` |

**Rule of thumb:** if the skill mentions paths inside one specific repo, it belongs in that repo's `.opencode/skills/`. If it could just as well be invoked from any project, it goes system-wide via workstation.

## Workflow A: Repo-Local Skill (most common, simplest)

**Use when:** the skill documents *one* repo's setup or workflows.

1. Create `<repo>/.opencode/skills/<gerund-name>/SKILL.md` with valid frontmatter:
   ```yaml
   ---
   name: gerund-name-with-hyphens
   description: Use when [specific triggering conditions, third person, no workflow summary]
   ---
   ```
2. Commit. **No rebuild needed.** OpenCode auto-discovers `.opencode/skills/` when CWD is inside the repo.
3. Optionally add a row to that repo's `AGENTS.md` skills table for human discoverability.

That's it.

## Workflow B: System-Wide Skill (workstation-deployed)

**Use when:** the skill is general workflow guidance you want available in every project.

1. Create `~/projects/workstation/assets/opencode/skills/<gerund-name>/SKILL.md` (and optional `REFERENCE.md`, helper scripts).
2. Register in `~/projects/workstation/users/dev/opencode-skills.nix`:
   ```nix
   crossPlatformSkills = [
     # ...
     "your-new-skill"     # all platforms (devbox, cloudbox, crostini, macOS)
   ];

   # OR, for skills that need work-only env (Atlassian, kubectl, etc.):
   workOnlySkills = [
     # ...
     "your-new-skill"     # macOS + cloudbox only
   ];
   ```
3. **For extra files (REFERENCE.md, scripts):** add a custom attrset alongside `atlassianExtras` / `beadsReferences`. Executable scripts need `executable = true`:
   ```nix
   yourSkillExtras = {
     ".config/opencode/skills/your-new-skill/REFERENCE.md".source =
       "${assetsPath}/opencode/skills/your-new-skill/REFERENCE.md";
     ".config/opencode/skills/your-new-skill/helper.sh" = {
       source = "${assetsPath}/opencode/skills/your-new-skill/helper.sh";
       executable = true;
     };
   };
   ```
   Then merge into `home.file = ... // yourSkillExtras;` (mirror `atlassianExtras`).
4. Verify Nix evaluates: `nix flake check --no-build`.
5. Apply on the host you're logged into:
   - **devbox:** `nix run home-manager -- switch --flake .#dev`
   - **cloudbox:** `nix run home-manager -- switch --flake .#cloudbox`
   - **crostini:** `nix run home-manager -- switch --flake .#livia`
   - **macOS:** `sudo darwin-rebuild switch --flake .#Y0FMQX93RR-2`
6. **Verify the deployment is symlinks**, not regular files (see Gotchas §1):
   ```bash
   ls -la ~/.config/opencode/skills/your-new-skill/
   # Each entry should be lrwxrwxrwx → /nix/store/.../...
   ```

## Workflow C: Editing an Existing Skill

| Skill location | What to do |
|---|---|
| `<repo>/.opencode/skills/<name>/SKILL.md` | Edit, commit. Effective immediately for any new OpenCode session run from that repo. |
| `workstation/assets/opencode/skills/<name>/` | Edit the source, then `nix run home-manager -- switch --flake .#<host>` to refresh the symlink target. |
| `~/.config/opencode/skills/<name>/` directly | **Don't.** It's either a Nix store symlink (read-only) or it'll be skipped/clobbered on next switch. Edit the source in workstation. |
| `~/projects/superpowers/skills/<name>/` | That's the upstream superpowers repo (deployed via `mkOutOfStoreSymlink`). Commit and push there separately; live immediately on next session. |

## Workflow D: Renaming or Removing a Skill

1. Move/delete the directory at the source location.
2. **If system-wide:** also update `users/dev/opencode-skills.nix` — remove from `crossPlatformSkills`/`workOnlySkills`, drop any custom `*Extras` attrset, drop the merge into `home.file`.
3. **If repo-local:** also remove any `AGENTS.md` table row.
4. Apply home-manager (system-wide only). Stale symlinks get cleaned automatically.
5. **Manually delete any non-symlink leftovers** at `~/.config/opencode/skills/<old-name>/` — see Gotchas §1.

## Gotchas

### 1. "Existing file ... will be skipped since they are the same"

If you prototyped a skill manually under `~/.config/opencode/skills/<name>/` *before* mirroring to `assets/opencode/skills/`, home-manager will detect that the deployed file already exists with identical content and **skip writing the symlink**. The skill works, but it's not actually under home-manager's management — next time the source changes, the deployed file will be stale.

**Symptom:**
```bash
ls -la ~/.config/opencode/skills/your-skill/
# Files are regular -rw-r--r-- with old timestamps
# (managed files are lrwxrwxrwx → /nix/store/...)
```
**Activation log shows:**
```
Existing file '~/.config/opencode/skills/your-skill/SKILL.md' is in the way of
'/nix/store/.../SKILL.md', will be skipped since they are the same
```

**Fix:** delete the regular files and re-activate:
```bash
rm ~/.config/opencode/skills/your-skill/{SKILL.md,REFERENCE.md,...}
nix run home-manager -- switch --flake .#<host>
ls -la ~/.config/opencode/skills/your-skill/   # should now be symlinks
```

### 2. Wrong flake target

`#dev` is for devbox, `#cloudbox` is for cloudbox, `#livia` is for crostini. Applying the wrong one aborts with `FATAL: flake target #X is for Y, but running on Z`. Always check `cat /etc/hostname` first. See the `rebuilding` repo-local skill in workstation for the full host→target mapping.

### 3. Wrong placement: repo-local content deployed system-wide

If you put a repo-specific skill in `assets/opencode/skills/` by mistake, it deploys system-wide and fires in projects where it doesn't apply — confusing scope and noise in `<available_skills>`. Test: would this skill make sense if I were working in some other repo? If no, it belongs in `<repo>/.opencode/skills/`.

### 4. Wrong placement: general workflow buried in one repo

Conversely, a generally-useful workflow stuck in one repo's `.opencode/skills/` only fires when CWD is inside that repo — invisible elsewhere. If you ever wish "I had this skill available right now in another project," promote it system-wide.

### 5. Don't duplicate superpowers content

Generic skill-writing discipline lives in `superpowers:writing-skills` (deployed via symlink at `~/.config/opencode/skills/superpowers/`). Focus your skill on **what's specific to its domain**, not on TDD-for-skills theory or frontmatter validation rules.

### 6. Executable bit is opt-in

Default `home.file."path".source = ...` deploys read-only and **not executable**. Helper scripts need:
```nix
".config/opencode/skills/your-skill/helper.sh" = {
  source = "${assetsPath}/...";
  executable = true;
};
```
Existing examples: `notifyTelegramScript`, `atlassianExtras`'s `confluence-to-md.sh`.

## Quick Reference

| Action | Where |
|--------|-------|
| Repo-local skill source | `<repo>/.opencode/skills/<name>/` |
| System-wide skill source | `~/projects/workstation/assets/opencode/skills/<name>/` |
| System-wide registration | `~/projects/workstation/users/dev/opencode-skills.nix` |
| Apply system-wide changes (devbox) | `nix run home-manager -- switch --flake .#dev` |
| Apply system-wide changes (cloudbox) | `nix run home-manager -- switch --flake .#cloudbox` |
| Apply system-wide changes (crostini) | `nix run home-manager -- switch --flake .#livia` |
| Apply system-wide changes (macOS) | `sudo darwin-rebuild switch --flake .#Y0FMQX93RR-2` |
| Verify deployment | `ls -la ~/.config/opencode/skills/<name>/` (must be symlinks) |
| List all deployed skills | `ls ~/.config/opencode/skills/` |

## Further Reading

- **Generic skill-authoring:** `superpowers:writing-skills` (TDD-for-skills, RED-GREEN-REFACTOR, search optimization, structure)
- **Anthropic's official guidance:** https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices
- **Workstation repo structure:** `understanding-workstation` (repo-local skill in `~/projects/workstation/.opencode/skills/`)
- **Worked example of a skill merge:** `~/projects/workstation` commit `348be81` (merged `using-atlassian-cli` + `fetching-atlassian-content` into `using-atlassian`)
