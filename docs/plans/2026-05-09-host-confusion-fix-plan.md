# Host Confusion Fix — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (or
> subagent-driven-development) to implement this plan task-by-task. Companion
> design doc: `docs/plans/2026-05-09-host-confusion-fix-design.md`.

**Goal:** Eliminate the "agent confidently asserts wrong host" failure mode by
(a) injecting `OPENCODE_HOSTNAME` into every bash call, (b) adding a host
identification preamble to AGENTS.md, and (c) renaming three devbox-named
skills whose content is host-generic.

**Architecture:** Two AGENTS.md files (root repo + user-level deployed via
`opencode-skills.nix`), one TypeScript plugin (`shell-env.ts`), three skill
directories renamed via `git mv`. All changes deploy via `home-manager switch`.

**Tech Stack:** Bash, TypeScript (Bun), Markdown, Nix (home-manager), git
worktrees.

**Worktree:** `/home/dev/projects/workstation/.worktrees/host-confusion-fix`
(branch `host-confusion-fix` off `origin/main`).

**Beads parent epic:** see `bd list --json | jq '.[] | select(.title | contains("Host confusion"))'`
(filed as part of this plan; child issues link to it via `discovered-from`).

---

## Pre-flight (run once at start)

```bash
cd /home/dev/projects/workstation/.worktrees/host-confusion-fix
git status                                    # expect: clean, on host-confusion-fix
git log -1 --oneline origin/main..HEAD        # expect: empty (no commits yet)
echo $OPENCODE_HOSTNAME                       # expect: empty (not yet deployed) — sanity check
```

---

## Task 1: Inject `OPENCODE_HOSTNAME` into bash env

**Files:**
- Modify: `assets/opencode/plugins/shell-env.ts`

**Step 1: Read current shell-env.ts**

```bash
cat assets/opencode/plugins/shell-env.ts
```

Expected: 30-line file with `Plugin` import, `shell.env` async hook, env
injections for `GIT_EDITOR`, `EDITOR`, `GIT_SEQUENCE_EDITOR`, `GIT_PAGER`,
and `OPENCODE_SESSION_ID`.

**Step 2: Add hostname injection**

Use Edit tool. Add `import * as os from "node:os"` near the top (after the
existing import), and add `output.env.OPENCODE_HOSTNAME = os.hostname()`
inside the `shell.env` hook, after the `OPENCODE_SESSION_ID` line.

Update the doc comment to mention the new env var (third bullet under the
existing "Two purposes" list — make it "Three purposes").

**Step 3: Verify TypeScript still parses**

```bash
cd assets/opencode/plugins && bun build shell-env.ts --target=node --outdir=/tmp/shell-env-check 2>&1 | tail -10
```

Expected: build succeeds, no type errors. (If `bun build` is wrong tool, try
`bun run --print "import('./shell-env.ts')"` or just `bun check`.)

**Step 4: Commit**

```bash
cd /home/dev/projects/workstation/.worktrees/host-confusion-fix
git add assets/opencode/plugins/shell-env.ts
git commit -m "feat(opencode): inject OPENCODE_HOSTNAME into bash env

Lets agents disambiguate which host they're running on without spawning
a hostname subprocess. Closes part of host-confusion fix; see
docs/plans/2026-05-09-host-confusion-fix-design.md."
```

**Step 5: Update beads**

```bash
bd update <task-1-bead-id> --status closed --reason "Injected via shell-env.ts hook"
```

---

## Task 2: Root AGENTS.md — host identification preamble

**Files:**
- Modify: `AGENTS.md` (root)

**Step 1: Re-read current AGENTS.md head**

```bash
sed -n '1,20p' AGENTS.md
```

**Step 2: Edit tagline (line 3)**

Use Edit tool. Replace:
> NixOS devbox + nix-darwin macOS configuration with standalone home-manager.

with:
> NixOS hosts (devbox on Hetzner, cloudbox on GCP) + nix-darwin (macOS) + Crostini (Chromebook), all sharing standalone home-manager.

**Step 3: Insert "Host Identification" section before "Quick Start"**

Use Edit tool. Insert this block between line 3 (tagline) and line 5 (`## Quick Start`):

```markdown

## Host Identification (READ FIRST)

**Always check `$OPENCODE_HOSTNAME` (injected into every bash call by `assets/opencode/plugins/shell-env.ts`) or run `hostname` at the start of any session.** This repo configures four first-class hosts; do NOT assume "devbox" — `cloudbox` and `devbox` are both NixOS, both run on `dev@`, and look superficially identical from inside an opencode session.

| `hostname` returns | Host kind | Flake target | System rebuild |
|---|---|---|---|
| `devbox` | NixOS on Hetzner | `.#devbox` | `sudo nixos-rebuild switch --flake .#devbox` |
| `cloudbox` | NixOS on GCP ARM | `.#cloudbox` | `sudo nixos-rebuild switch --flake .#cloudbox` |
| `Y0FMQX93RR-2` (or similar) | macOS (nix-darwin) | `.#Y0FMQX93RR-2` | `sudo darwin-rebuild switch --flake .#Y0FMQX93RR-2` |
| anything in a `penguin` container | Crostini (Chromebook) | (home-manager only) | `nix run home-manager -- switch --flake .#dev-crostini` |
```

**Step 4: Update Quick Start to add cloudbox-aware example**

Use Edit tool. Replace the existing `**Devbox (NixOS):**` block with:

```markdown
**NixOS hosts (devbox or cloudbox):**
```bash
sudo nixos-rebuild switch --flake .#$(hostname)   # System changes
nix run home-manager -- switch --flake .#dev      # User changes (fast, no sudo)
```
```

(Keep the `**macOS (nix-darwin):**` block intact below it.)

**Step 5: Verify rendering**

```bash
sed -n '1,40p' AGENTS.md
```

Eyeball: tagline reads correctly, Host ID section is present, Quick Start uses `$(hostname)`.

**Step 6: Commit**

```bash
git add AGENTS.md
git commit -m "docs(agents): add host identification preamble + cloudbox quick start

Root cause of recurring 'agent thinks it's on devbox when it's on cloudbox'
failures: tagline frames devbox + macOS as the two first-class hosts and
Quick Start only shows .#devbox. Add explicit host-disambiguation table at
the top, generalize Quick Start with \$(hostname). See
docs/plans/2026-05-09-host-confusion-fix-design.md for full root-cause
analysis."
```

---

## Task 3: User-level AGENTS.md — mention OPENCODE_HOSTNAME

**Files:**
- Modify: `assets/opencode/AGENTS.md`

**Step 1: Add a "Host Identification" mini-section**

Use Edit tool. After the existing "Bash Environment" section (currently at
line 61), insert before "## Backgrounding Long-Running Processes":

```markdown

## Host Identification

The `shell-env.ts` plugin injects `OPENCODE_HOSTNAME` into every bash tool
call. Use it to disambiguate which machine you're on without spawning a
subprocess:

```bash
echo $OPENCODE_HOSTNAME    # devbox | cloudbox | <macOS hostname> | crostini-ish
```

The repo-level `AGENTS.md` (in any workstation checkout) has a full host
table; this env var is the primitive.
```

**Step 2: Commit**

```bash
git add assets/opencode/AGENTS.md
git commit -m "docs(agents): document OPENCODE_HOSTNAME in user-level AGENTS.md

Companion to the new shell-env.ts hostname injection."
```

---

## Task 4: Rename `troubleshooting-devbox` → `troubleshooting-nixos-host`

**Files:**
- Rename: `.opencode/skills/troubleshooting-devbox/` → `.opencode/skills/troubleshooting-nixos-host/`
- Modify (frontmatter): `.opencode/skills/troubleshooting-nixos-host/SKILL.md`
- Modify: root `AGENTS.md` skills table
- Search-and-update cross-references repo-wide

**Step 1: git mv the directory**

```bash
git mv .opencode/skills/troubleshooting-devbox .opencode/skills/troubleshooting-nixos-host
ls .opencode/skills/troubleshooting-nixos-host/    # expect: SKILL.md + any helper files
```

**Step 2: Update `name:` frontmatter and any host-specific framing**

Read `.opencode/skills/troubleshooting-nixos-host/SKILL.md`. Change:
- `name: troubleshooting-devbox` → `name: troubleshooting-nixos-host`
- `description: Use when SSH connection fails, host key mismatch, NixOS
  issues, CPU/IO contention (high load), or verifying devbox is properly
  configured` → `description: Use on any NixOS host (devbox, cloudbox) when
  SSH connection fails, host key mismatch, NixOS issues, CPU/IO contention
  (high load), or verifying the host is properly configured`
- Body text: where the skill says "devbox" generically (e.g., "verify devbox
  is up"), change to "the host" or "your NixOS host". Where it's truly
  Hetzner-specific (e.g., a known-host-key snippet), leave it but prefix
  with `> **(devbox-only)**` so the host-specificity is explicit.

**Step 3: Update root AGENTS.md skills table**

Use Edit tool. Replace:
```
| [Troubleshooting Devbox](.opencode/skills/troubleshooting-devbox/SKILL.md) | SSH issues, host keys, NixOS problems |
```
with:
```
| [Troubleshooting NixOS Host](.opencode/skills/troubleshooting-nixos-host/SKILL.md) | SSH issues, host keys, NixOS problems (devbox + cloudbox) |
```

**Step 4: Find and update all other references**

```bash
rg "troubleshooting-devbox" --type md --type nix --type sh --type ts -l
```

For each match, decide: is it a path reference (update) or historical mention
in a beads issue (leave alone, but maybe add a note)?

Likely matches:
- `.opencode/skills/*/SKILL.md` (cross-references in `Related:` sections)
- Possibly `users/dev/opencode-skills.nix` if skill names are listed (unlikely;
  it probably globs the directory)

For each updateable match: use Edit tool to swap the name.

**Step 5: Verify nix still evaluates**

```bash
nix flake check 2>&1 | tail -20
```

(If this is too slow / requires network, skip and trust that
`opencode-skills.nix` globs the dir.)

**Step 6: Commit**

```bash
git add -A .opencode/skills/ AGENTS.md
git status    # verify no other unintended changes
git commit -m "refactor(skills): rename troubleshooting-devbox -> troubleshooting-nixos-host

Skill content is host-generic (sops, nixos-rebuild, SSH); only a couple of
sections are truly Hetzner-specific and are now marked inline. Removes a
piece of the devbox-bias documented in
docs/plans/2026-05-09-host-confusion-fix-design.md."
```

---

## Task 5: Rename `screenshot-to-devbox` → `screenshot-to-remote-opencode`

Same pattern as Task 4. The skill currently lives in `.opencode/skills/`.

**Step 1: git mv**

```bash
git mv .opencode/skills/screenshot-to-devbox .opencode/skills/screenshot-to-remote-opencode
```

**Step 2: Update `name:` frontmatter and body**

Change `name:` and `description:`. Body: replace "devbox" with "the remote
host" / "remote opencode" where generic.

**Step 3: Update root AGENTS.md skills table**

Replace:
```
| [Screenshot to Devbox](.opencode/skills/screenshot-to-devbox/SKILL.md) | Sharing screenshots with remote OpenCode |
```
with:
```
| [Screenshot to Remote OpenCode](.opencode/skills/screenshot-to-remote-opencode/SKILL.md) | Sharing screenshots with remote OpenCode (devbox/cloudbox over SSH) |
```

**Step 4: Find/update other refs**

```bash
rg "screenshot-to-devbox" --type md --type nix -l
```

**Step 5: Commit**

```bash
git add -A .opencode/skills/ AGENTS.md
git commit -m "refactor(skills): rename screenshot-to-devbox -> screenshot-to-remote-opencode

The image-injection mechanism is generic to any SSH'd opencode session, not
devbox-specific."
```

---

## Task 6: Rename `using-chatgpt-relay-from-devbox` → `using-chatgpt-relay`

This skill lives under `assets/opencode/skills/` (user-level).

**Step 1: git mv**

```bash
git mv assets/opencode/skills/using-chatgpt-relay-from-devbox assets/opencode/skills/using-chatgpt-relay
```

**Step 2: Update frontmatter**

Change `name:` from `using-chatgpt-relay-from-devbox` to `using-chatgpt-relay`.
Description: drop "from devbox" — say "from any NixOS host" or just describe
what it does without the host name.

**Step 3: Update assets/opencode/AGENTS.md skill table**

Replace the row for `using-chatgpt-relay-from-devbox` with `using-chatgpt-relay`.

**Step 4: Find/update other refs**

```bash
rg "using-chatgpt-relay-from-devbox" -l
```

**Step 5: Commit**

```bash
git add -A assets/opencode/ AGENTS.md
git commit -m "refactor(skills): rename using-chatgpt-relay-from-devbox -> using-chatgpt-relay

The relay is a generic SSH local-port-forward pattern; the 'from-devbox'
suffix was bias, not specificity."
```

---

## Task 7: Generalize `cleaning-disk` description

**Files:**
- Modify: `assets/opencode/skills/cleaning-disk/SKILL.md` (frontmatter only)

**Step 1: Read current frontmatter**

```bash
sed -n '1,5p' assets/opencode/skills/cleaning-disk/SKILL.md
```

**Step 2: Edit description**

Use Edit tool. Replace:
```
description: Reclaim disk space on devbox (NixOS) and macOS. ...
```
with:
```
description: Reclaim disk space on any NixOS host (devbox, cloudbox) or macOS. ...
```

(Preserve the rest of the description verbatim.)

**Step 3: Commit**

```bash
git add assets/opencode/skills/cleaning-disk/SKILL.md
git commit -m "docs(skills): generalize cleaning-disk description to cover cloudbox"
```

---

## Task 8: Verify, push, open PR

**Step 1: Final review**

```bash
git log --oneline origin/main..HEAD                  # expect: 7 commits
git diff --stat origin/main..HEAD                    # expect: ~10 files changed
rg -i "devbox" AGENTS.md assets/opencode/AGENTS.md   # expect: only intentional refs
```

**Step 2: Push**

```bash
git push -u origin host-confusion-fix
```

**Step 3: Open PR using `gh`**

Use the shepherding-pull-requests skill conventions (PR title format,
description template). Title: `fix: reduce host confusion (devbox vs cloudbox bias)`

**Step 4: Wait for CI / merge**

If CI is configured for this repo, watch it. When green and you're confident,
fast-forward merge to main.

**Step 5: Deploy on cloudbox**

```bash
cd ~/projects/workstation       # main checkout
git pull --ff-only
nix run home-manager -- switch --flake .#dev
```

**Step 6: Verify deployment**

In a NEW bash tool call (after home-manager switch):

```bash
echo $OPENCODE_HOSTNAME                                                   # expect: cloudbox
ls -d ~/.config/opencode/skills/troubleshooting-nixos-host                # expect: exists
ls -d ~/.config/opencode/skills/troubleshooting-devbox 2>/dev/null        # expect: not found
ls -d ~/.config/opencode/skills/using-chatgpt-relay                       # expect: exists
```

**Step 7: Clean up worktree**

```bash
cd ~/projects/workstation
git worktree remove .worktrees/host-confusion-fix
git branch -d host-confusion-fix    # may need -D if not merged via FF
```

**Step 8: Close beads epic**

```bash
bd close <epic-id> --reason "Deployed on cloudbox; devbox + macOS will pick up on next manual rebuild"
bd sync
```

---

## Notes for Future-Claude (post-compaction recovery)

If you're reading this after a compaction:

1. `cd /home/dev/projects/workstation/.worktrees/host-confusion-fix && git status` — see where you are.
2. `git log --oneline origin/main..HEAD` — see which tasks already committed.
3. `bd list --json | jq '.[] | select(.title | startswith("Host-confusion"))'` — see which tasks remain.
4. Resume from the next unfinished task in this plan.

Tasks are idempotent-ish: re-running an already-done step (e.g., re-running
`git mv` after the rename committed) will just fail loudly. Read git log first.
