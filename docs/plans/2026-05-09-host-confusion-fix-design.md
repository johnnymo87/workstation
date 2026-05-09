# Host Confusion Fix — Design Doc

**Date:** 2026-05-09
**Author:** Jonathan + Claude (cloudbox session)
**Status:** Approved, in progress

## Problem

Recurring failure mode: an OpenCode agent (Claude) running on `cloudbox` confidently
asserts it is on `devbox`, or applies devbox-specific guidance (Hetzner host keys,
devbox-flake target, devbox-only skill names) when the user is actually on cloudbox.
Same problem in reverse is plausible but less observed.

Confirmed example (this session, 2026-05-09): asked to investigate a stuck
`opencode attach`, agent loaded the `resetting-workspace` skill and only then
realized the skill is cloudbox-specific. Earlier in the same investigation it
referred to "your devbox" while user was clearly on cloudbox.

## Root Causes

Investigated and confirmed by grepping `AGENTS.md` files and the `<env>` block
of the system prompt:

1. **Tagline bias** — `/home/dev/projects/workstation/AGENTS.md:3` reads
   *"NixOS devbox + nix-darwin macOS configuration with standalone home-manager."*
   The two hosts framed as first-class are devbox + macOS; cloudbox is footnoted.
   This is the first thing an LLM scans when establishing context.

2. **Quick Start asymmetry** — `AGENTS.md:7-16` shows `nixos-rebuild --flake .#devbox`
   and `darwin-rebuild`, but no `nixos-rebuild --flake .#cloudbox`. Cloudbox feels
   like a documented-but-secondary host.

3. **No host-detection guidance** — Nothing in either `AGENTS.md` (root or
   user-level `assets/opencode/AGENTS.md`) tells the agent to run `hostname` at
   session start. The OpenCode `<env>` block in the system prompt does not
   include the hostname (only `Working directory`, `Platform: linux`, etc.). So
   the agent has no first-order signal which NixOS host it is on, and falls back
   to the bias from #1 and #2.

4. **Skill naming bias** — Three skills are explicitly devbox-named even though
   the underlying tech is identical on cloudbox:
   - `troubleshooting-devbox` (covers SSH issues, sops, host keys — all generic)
   - `screenshot-to-devbox` (mechanism is generic for any SSH'd opencode)
   - `using-chatgpt-relay-from-devbox` (relay is a generic local-port-forward)
   These create a long-tail "this is a devbox-shaped repo" gestalt across the
   `available_skills` list in the system prompt.

5. **`cleaning-disk` description bias** — Skill description says "Reclaim disk
   on devbox/macOS" but the skill body is generic; cloudbox is invisible to
   anyone scanning the skill index.

## Design

Five fixes, batched into one PR. All deploy via `home-manager switch` on each
NixOS host (devbox, cloudbox) and `darwin-rebuild switch` on macOS.

### Fix 1 — `OPENCODE_HOSTNAME` env injection

Modify `assets/opencode/plugins/shell-env.ts` to add one line:

```typescript
import * as os from "node:os"
// existing env injections...
output.env.OPENCODE_HOSTNAME = os.hostname()
```

The `shell.env` hook fires on every bash tool invocation (already injects
`OPENCODE_SESSION_ID`, `GIT_EDITOR`, etc.). Adding `OPENCODE_HOSTNAME` is
synchronous, zero IO, fully backward-compatible.

After this lands, agents can read `$OPENCODE_HOSTNAME` from any bash call
without spawning a subprocess. Combined with the AGENTS.md preamble (Fix 2),
this kills the failure mode at the root.

### Fix 2 — Add "Host Identification" preamble to root `AGENTS.md`

Insert a new section *before* "Quick Start" with a host-disambiguation table:

```markdown
## Host Identification (READ FIRST)

**Always check `$OPENCODE_HOSTNAME` (injected into every bash call) or run
`hostname` at the start of any session.** This repo configures four
first-class hosts; do NOT assume "devbox" — `cloudbox` and `devbox` are both
NixOS, both run on `dev@`, and look superficially identical from inside an
opencode session.

| `hostname` returns | Host kind | Flake target | System rebuild |
|---|---|---|---|
| `devbox` | NixOS on Hetzner | `.#devbox` | `sudo nixos-rebuild switch --flake .#devbox` |
| `cloudbox` | NixOS on GCP ARM | `.#cloudbox` | `sudo nixos-rebuild switch --flake .#cloudbox` |
| `Y0FMQX93RR-2` (or similar) | macOS (nix-darwin) | `.#Y0FMQX93RR-2` | `sudo darwin-rebuild switch --flake .#Y0FMQX93RR-2` |
| anything in a `penguin` container | Crostini (Chromebook) | (home-manager only) | `nix run home-manager -- switch --flake .#dev-crostini` |
```

### Fix 3 — Rewrite tagline and Quick Start

Tagline (line 3) becomes:
> NixOS hosts (devbox on Hetzner, cloudbox on GCP) + nix-darwin (macOS) + Crostini (Chromebook), all sharing standalone home-manager.

Quick Start adds a cloudbox-aware example:
```markdown
**NixOS hosts (devbox or cloudbox):**
sudo nixos-rebuild switch --flake .#$(hostname)   # System changes
nix run home-manager -- switch --flake .#dev      # User changes (fast, no sudo)
```

Using `$(hostname)` makes the same command work on both hosts.

### Fix 4 — Skill renames

Rename three skills (`git mv` + frontmatter `name:` update + cross-ref grep):

| Current | New | Notes |
|---|---|---|
| `troubleshooting-devbox` | `troubleshooting-nixos-host` | Generalize content; mark Hetzner-specific bits inline as `(devbox-only)` |
| `screenshot-to-devbox` | `screenshot-to-remote-opencode` | Mechanism is generic |
| `using-chatgpt-relay-from-devbox` | `using-chatgpt-relay` | Relay pattern is generic |

Skill renames cascade to:
- `assets/opencode/AGENTS.md` skill table
- Root `AGENTS.md` skill table (only `troubleshooting-devbox` and
  `screenshot-to-devbox` listed there)
- Cross-references inside other skills (`Related:` sections, body text)
- Beads issues that mention them by name (search and update)

**Accepted risk:** anyone with muscle memory for the old names will get
"no such skill" errors. One-shot friction in exchange for permanent removal
of the bias. (User-approved option (a) in the brainstorm.)

### Fix 5 — `cleaning-disk` description

Edit only the `description:` frontmatter in
`assets/opencode/skills/cleaning-disk/SKILL.md`:

> Before: "Reclaim disk space on devbox (NixOS) and macOS. ..."
> After:  "Reclaim disk space on any NixOS host (devbox, cloudbox) or macOS. ..."

## Rollout

Branch: `host-confusion-fix` off `origin/main`, in worktree at
`.worktrees/host-confusion-fix`.

Commit order (one PR, multiple commits for clean revert):
1. `feat(opencode): inject OPENCODE_HOSTNAME into bash env`
2. `docs(agents): add host identification preamble + cloudbox quick start`
3. `docs(agents): mention OPENCODE_HOSTNAME in user-level AGENTS.md`
4. `refactor(skills): rename troubleshooting-devbox -> troubleshooting-nixos-host`
5. `refactor(skills): rename screenshot-to-devbox -> screenshot-to-remote-opencode`
6. `refactor(skills): rename using-chatgpt-relay-from-devbox -> using-chatgpt-relay`
7. `docs(skills): generalize cleaning-disk description`

Then push, open PR, fast-forward merge, and `home-manager switch` on cloudbox
(this host) to deploy. Devbox + macOS will pick up changes on their next
manual rebuild.

## Verification

After deploy on cloudbox:

```bash
# Fresh bash tool call should expose hostname
echo $OPENCODE_HOSTNAME    # expect: cloudbox

# Renamed skill dirs should exist, old should not
ls -d ~/.config/opencode/skills/troubleshooting-nixos-host
! ls -d ~/.config/opencode/skills/troubleshooting-devbox 2>/dev/null

# OpenCode skill discovery should list new names
# (verified by checking the system prompt's available_skills block in a fresh
# session)
```

## Out of Scope (deferred)

- A linter that fails CI if any new file in the repo references "devbox"
  outside the `hosts/devbox/` and `users/dev/home.devbox.nix` paths. Useful
  but premature; revisit if the bias re-creeps.
- Renaming `home.devbox.nix` / `home.cloudbox.nix` / `hosts/devbox/`. These
  ARE host-specific (not bias). Leave alone.
- `setting-up-hetzner` skill — Hetzner is the devbox provisioner; not bias.
- Touching dotfiles repo or other repos.

## Compaction Survival

This design doc + the corresponding plan
(`docs/plans/2026-05-09-host-confusion-fix-plan.md`) + beads issues are the
durable artifacts. If the session compacts mid-execution, future-Claude can
recover by:

1. Reading this design doc.
2. Reading the plan.
3. Running `bd ready` to see remaining tasks under the parent epic.
4. Resuming from the worktree at `.worktrees/host-confusion-fix`.
