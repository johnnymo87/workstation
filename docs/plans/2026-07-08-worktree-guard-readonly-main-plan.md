# Impl plan: read-only `main` + enforced fresh-worktree work (mono v1)

Status: **APPROVED SCOPE (rev.3) — NOT implemented.**
Date: 2026-07-08
Companion design: `2026-07-08-worktree-guard-readonly-main-design.md`
Sibling: `2026-07-02-subagent-destructive-git-guard-plugin-design.md`

Execution model: nix-home-manager on cloudbox/devbox; artifacts live in
`workstation`, deploy via `home-manager switch`. Conservative git: no
commit/push without operator go-ahead. Do the work in a worktree off
`origin/main` (`git worktree add .worktrees/worktree-guard -b nojira-worktree-guard origin/main`),
not the root checkout.

**v1 = mono only. No ff-only timer, no nix multi-repo list** (both deferred).

## Phase 0 — prep + spike (no shipped code)

- [ ] **Clean the mono root** (operator action; root mutation, do NOT automate).
      Inspect `git -C ~/projects/mono log origin/main..main`; branch/cherry-pick
      the stray commit or drop it. Triage the 26 untracked files. End state:
      `git -C ~/projects/mono rev-list --left-right --count origin/main...main`
      ⇒ `0 0`, `git status --porcelain` empty.
- [ ] **Spike opencode 1.17.x tool + hook facts** (~30 min), record inline:
  - built-in tool ids and arg fields: `edit`/`write` take `filePath`;
    **`apply_patch` takes `patchText`** (targets = `hunk.path`, resolved against
    the session dir); there is **no `patch`** tool.
  - `usePatch = modelID.includes("gpt-")` — GPT models get `apply_patch` only,
    Claude/opus get `edit`+`write` only.
  - a thrown `tool.execute.before` hook is contained per-tool (Effect *defect*
    caught by the tool path's `catchCause`). Re-verify on every opencode upgrade.
  - what cwd the hook can see (`PluginInput.directory`/`worktree`) for relative
    `filePath` resolution.

## Phase 1 — `work` helper (additive, zero enforcement)

- [ ] `pkgs/git-work/default.nix` (`writeShellApplication` `work`):
  - `work <slug> [branch]`; branch defaults to sanitized `<slug>`.
  - root via the `oc-auto-attach` collapse rule; trunk via config else
    `git symbolic-ref --short refs/remotes/origin/HEAD` (loud error if unset).
  - `git -C <root> fetch origin <trunk>` →
    `git -C <root> worktree add <root>/.worktrees/<slug> -b <branch> origin/<trunk>`;
    print path; `--cd` emits a `cd` for `eval`.
  - fail loudly on slug/branch collision (no `-B`).
- [ ] `pkgs/git-work/test.sh`: temp repo + fake `origin`; assert a fresh worktree
      off trunk HEAD under `.worktrees/`.
- [ ] register in `flake.nix`/overlay + user package list.
- [ ] verify: `home-manager switch`; `cd ~/projects/mono && work smoke`; confirm
      `.worktrees/smoke` off `origin/main`; remove it.

## Phase 2 — guard plugin, WARN mode (mono only)

- [ ] `assets/opencode/plugins/worktree-guard.ts`:
  - init: read minimal config (one entry: mono root + trunk + `enforce`);
    try/catch ⇒ no-op.
  - `tool.execute.before`, tool set **`{edit, write, apply_patch, bash}`**:
    - `edit`/`write`: `p = output.args.filePath`; **resolve relative `p` against
      the session dir** before any cheap-reject; else `toplevel =
      gitToplevel(dirnameOfNearestExisting(p))`; block if `== root`.
    - `apply_patch`: parse `output.args.patchText`; block if any `hunk.path`
      (resolved) toplevel `== root`.
    - `bash`: flag `git commit`/redirection into root (secondary).
  - `warn` ⇒ log + rate-limited system note; **never fail-closed** (any
    resolution error ⇒ allow).
- [ ] `assets/opencode/plugins/test/worktree-guard.test.ts` (vitest), temp repo +
      real `.worktrees/child`:
  - edit tracked file at root ⇒ blocked (block mode).
  - edit under `.worktrees/child` ⇒ allowed (prefix-vs-toplevel trap).
  - edit outside any enrolled repo ⇒ allowed.
  - **`apply_patch` targeting a root file ⇒ blocked** (model-coupled path).
  - **relative `filePath` resolving into root ⇒ blocked**.
  - resolution error / non-git path ⇒ allowed (fail-open).
  - `warn` never throws.
  - a blocked `implementer` recovers via the printed `work` hint (no thrash).
  - **snapshot test** of built-in tool ids + arg field names (fail loudly on a
    future rename).
- [ ] deploy: `xdg.configFile."opencode/plugins/worktree-guard.ts".source =
      "${assetsPath}/opencode/plugins/worktree-guard.ts";` in
      `users/dev/opencode-config.nix` (+ the minimal config file), `enforce =
      "warn"`.
- [ ] verify: new session in `~/projects/mono` → edit tracked file ⇒ warn note,
      edit proceeds; edit in a `.worktrees/*` session ⇒ allowed.

## Phase 3 — flip mono to BLOCK + pre-commit backstop

- [ ] bake in warn mode a few real sessions; grep log for false positives
      (expected: none).
- [ ] set `enforce = "block"`.
- [ ] add the **local** `core.hooksPath` for mono via a home-manager
      activation-script `git config` (do NOT commit hooks into shared mono); the
      `pre-commit` rejects when toplevel == root.
- [ ] verify (matrix below).

## Phase 3.5 — default writable sessions into a worktree (root cause)

- [ ] at `opencode-launch`/`reset-workspace`/`oc-auto-attach`: a *writable*
      session in the mono root defaults to opening a fresh worktree (pair with
      `work`); read-only/coordinator/monitor sessions stay at the root.
- [ ] verify: launching a writable session lands in a worktree; a read-only
      session still opens at the root.

## Deferred (NOT v1 — separate follow-up beads)

- ff-only systemd **timer** (fetch + `merge --ff-only`, log+skip; only if reads
  off root prove stale often).
- nix **multi-repo enrollment list** (`worktreeGuard.repos` → plugin JSON +
  per-repo timers + owned-vs-shared hook split); generalize after mono proves out.

## Verification matrix (mono)

- **Guard, block mode:** root session edits tracked file ⇒ blocked with `work`
  hint; `.worktrees/foo` edits ⇒ allowed; `implementer` subagent editing root ⇒
  blocked; `apply_patch` at root ⇒ blocked. (All encoded as vitest cases.)
- **No swarm regression:** 2-worker swarm ⇒ workers create `.worktrees/*`
  unblocked; coordinator reads root fine.
- **Standing metric:** over a week, mono root `git status --porcelain` stays
  empty (modulo untracked bash residue) and no new commits land on local `main`.

## Rollback

- plugin: remove `xdg.configFile` line + re-switch (or empty config ⇒ no-op).
- helper: drop `pkgs/git-work` from the package list.
- hook: `git config --unset core.hooksPath`.
- launch default: revert the choke-point change.
- No shared-repo content mutated.

## Size

`worktree-guard.ts` ~120 LOC + ~180 LOC tests; `git-work` ~80 LOC + test;
opencode-config/launch wiring ~20 LOC. Small, reviewable, independently
revertible.
