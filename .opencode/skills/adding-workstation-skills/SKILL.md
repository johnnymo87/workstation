---
name: adding-workstation-skills
description: Use when adding, editing, or moving an OpenCode skill in this workstation repo, or debugging why a skill isn't picked up after editing it.
---

# Adding OpenCode Skills in workstation

This repo manages OpenCode skills in **two distinct locations** with **different deploy mechanisms**. Choose the right one or your skill won't appear (or will appear but won't be managed).

For generic skill-authoring discipline (TDD-for-skills, frontmatter, structure, search-optimization), see `superpowers:writing-skills` and Anthropic's [skill authoring best practices](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices). This skill covers **only what's specific to this repo**.

## Decision: Where Does the Skill Live?

| Skill is about... | Put it in | Deploy mechanism |
|---|---|---|
| **This repo's config** (rebuilding, secrets, host setup, scrubbing, OpenCode agent rationale) | `.opencode/skills/<name>/SKILL.md` | None — OpenCode auto-discovers when CWD is inside the repo |
| **A general workflow** usable from any project (creating PRs, using gws, fetching Atlassian content) | `assets/opencode/skills/<name>/SKILL.md` + register in `users/dev/opencode-skills.nix` | home-manager symlinks into `~/.config/opencode/skills/` |

**Rule of thumb:** if the skill mentions paths inside `~/projects/workstation`, it almost certainly belongs in `.opencode/skills/`. If it could just as well be in any other project's session, it goes under `assets/opencode/skills/`.

See also: `understanding-workstation` (the broader `assets/` vs `.opencode/` distinction, line 123-126).

## Workflow A: Repo-Local Skill (`.opencode/skills/`)

**Use when:** the skill is documentation about *this* repo.

1. Create `.opencode/skills/<gerund-name>/SKILL.md` with valid frontmatter (`name`, `description`).
2. (Optional) Add a row to the skills table in `AGENTS.md` (lines ~58-74) so humans browsing the README see it.
3. Commit. **No rebuild needed.** OpenCode auto-discovers `.opencode/skills/` when run from inside the repo.

That's it.

## Workflow B: System-Wide Skill (`assets/opencode/skills/`)

**Use when:** you want the skill available in `~/.config/opencode/skills/` on every shell, every project.

1. Create `assets/opencode/skills/<gerund-name>/SKILL.md` (and optional `REFERENCE.md`, scripts, etc.).
2. Register in `users/dev/opencode-skills.nix`:
   ```nix
   crossPlatformSkills = [
     # ...
     "your-new-skill"     # all platforms
   ];

   # OR

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
   Then merge it into `home.file = ... // yourSkillExtras;` (mirror the pattern of `atlassianExtras`).
4. Verify nix evaluates: `nix flake check --no-build`.
5. Apply: `nix run home-manager -- switch --flake .#<dev|cloudbox>` (devbox uses `#dev`, cloudbox uses `#cloudbox`, macOS uses `darwin-rebuild switch`).
6. Verify the deployment is **symlinks**, not regular files (see Gotchas §1):
   ```bash
   ls -la ~/.config/opencode/skills/your-new-skill/
   # Each entry should be a symlink into /nix/store/...
   ```

## Workflow C: Editing an Existing Skill

| Skill location | What to do |
|---|---|
| `.opencode/skills/<name>/SKILL.md` | Edit, commit. Effective immediately for any new OpenCode session run from the repo. |
| `assets/opencode/skills/<name>/SKILL.md` | Edit, then `nix run home-manager -- switch --flake .#<host>` to refresh the symlink target. |
| `~/.config/opencode/skills/<name>/SKILL.md` directly | **Don't.** It's either a Nix store symlink (read-only) or it'll get clobbered/skipped on next switch. Edit the source in `assets/`. |
| `~/projects/superpowers/skills/<name>/SKILL.md` | That's the upstream superpowers repo (`mkOutOfStoreSymlink`). Commit there separately. |

## Workflow D: Renaming or Removing a Skill

1. Move/delete the directory under `assets/opencode/skills/` or `.opencode/skills/`.
2. If system-wide: update `users/dev/opencode-skills.nix` (remove from `crossPlatformSkills`/`workOnlySkills`, drop any custom `*Extras` attrset, drop the merge into `home.file`).
3. Also remove any entry from the table in `AGENTS.md`.
4. Apply home-manager. Stale symlinks get cleaned up automatically.
5. **Manually delete any non-symlink leftovers** at `~/.config/opencode/skills/<old-name>/` — see Gotchas §1.

## Gotchas

### 1. "Existing file ... will be skipped since they are the same"

If you prototyped a skill manually under `~/.config/opencode/skills/<name>/` *before* mirroring to `assets/opencode/skills/`, home-manager will detect that the deployed file already exists with identical content and **skip writing the symlink**. The skill works, but it's not actually under home-manager's management — next time the source changes, the deployed file will be stale.

**Symptom:**
```bash
ls -la ~/.config/opencode/skills/your-skill/
# Files are regular -rw-r--r-- with old timestamps (not lrwxrwxrwx into /nix/store/)
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

`#dev` is for devbox. `#cloudbox` is for cloudbox. Applying the wrong one aborts with a `FATAL: flake target #X is for Y, but running on Z` guard. Always check `cat /etc/hostname` first. See the `rebuilding` skill.

### 3. `.opencode/skills/` does not need home-manager

OpenCode auto-discovers skills relative to the current working directory's `.opencode/skills/`. No deploy step. **If you put a repo-local skill in `assets/opencode/skills/` by mistake**, it will deploy system-wide rather than only when you're in the workstation repo — confusing scope.

### 4. Don't duplicate superpowers content

Generic skill-writing discipline already lives in `superpowers:writing-skills` (which is symlinked at `~/.config/opencode/skills/superpowers/`). When writing a workstation-local skill, focus on **what's specific to this repo**, not on TDD-for-skills theory.

### 5. Executable bit is opt-in

Default `home.file."path".source = ...` deploys read-only and **not executable**. Helper scripts need:
```nix
".config/opencode/skills/your-skill/helper.sh" = {
  source = "${assetsPath}/...";
  executable = true;
};
```
Existing examples: `notifyTelegramScript`, `atlassianExtras`'s `confluence-to-md.sh`.

## Quick Reference

| Action | Command / file |
|--------|---------------|
| Find skill source (system-wide) | `assets/opencode/skills/<name>/` |
| Find skill source (repo-local) | `.opencode/skills/<name>/` |
| Register system-wide skill | `users/dev/opencode-skills.nix` (`crossPlatformSkills` or `workOnlySkills`) |
| Register extra files / scripts | Custom `*Extras` attrset in `users/dev/opencode-skills.nix` |
| Apply on devbox | `nix run home-manager -- switch --flake .#dev` |
| Apply on cloudbox | `nix run home-manager -- switch --flake .#cloudbox` |
| Apply on macOS | `sudo darwin-rebuild switch --flake .#Y0FMQX93RR-2` |
| Verify deployment | `ls -la ~/.config/opencode/skills/<name>/` (must be symlinks) |
| List deployed skills | `ls ~/.config/opencode/skills/` |

## Further Reading

- **Generic skill-authoring discipline:** `superpowers:writing-skills` (TDD-for-skills, RED-GREEN-REFACTOR, search optimization, structure)
- **Anthropic's official guidance:** https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices
- **Repo structure:** [understanding-workstation](../understanding-workstation/SKILL.md)
- **Rebuild mechanics:** [rebuilding](../rebuilding/SKILL.md)
- **Worked example of a merge:** commit `348be81` (merged `using-atlassian-cli` + `fetching-atlassian-content` into `using-atlassian`)
