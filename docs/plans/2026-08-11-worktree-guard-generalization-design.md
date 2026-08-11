# Design: generalizing the worktree guard beyond mono

Status: **RECOMMENDATION — nothing implemented, no guardrail changed.**
Date: 2026-08-11
Bead spine: `workstation-v03j` (epic). This document is the answer to
`workstation-v03j.7` ("Generalize enrollment beyond mono (nix multi-repo list)"),
which has been open at P2 since 2026-07-08.

Read alongside:
- [`2026-07-08-worktree-guard-readonly-main-design.md`](2026-07-08-worktree-guard-readonly-main-design.md) — the original mono v1 design.
- [`2026-08-04-mono-root-freshness-roadmap.md`](2026-08-04-mono-root-freshness-roadmap.md) — the live view of the mono half. Its "Anti-patterns this epic has already paid for" section applies verbatim here.

---

## 0. The incident that reopened this

In `~/projects/pigeon` — the primary checkout — two sessions worked directly in
the shared main worktree on 2026-08-11:

1. One edited 8 files at the root and only moved to a throwaway worktree at
   commit time.
2. Another committed `300304d` ("Unpin Telegram's auto-pin of a new forum topic's
   first message", `pigeon-ud6s`) **directly onto local `main`** — unpushed, no
   branch, no PR. It sat for hours while `origin/main` moved on, and was found
   only because a third session needed to pull for a deploy. Since rescued onto
   `pigeon-ud6s-300304d`.

Pigeon had **13 worktrees in active use** at the time. The convention was not
missing; it was unenforced.

**Pigeon's specific hazard, verified on the host:**

```
$ systemctl cat pigeon-daemon.service | grep -E 'ExecStart|WorkingDirectory'
ExecStart=/nix/store/6wl39xy39g94z16il2w27d3kk7frniwk-pigeon-daemon-start
WorkingDirectory=/home/dev/projects/pigeon/packages/daemon

$ cat /nix/store/6wl39xy39g94z16il2w27d3kk7frniwk-pigeon-daemon-start | tail -1
exec .../node .../tsx/dist/cli.mjs /home/dev/projects/pigeon/packages/daemon/src/index.ts
```

The daemon runs **tsx against the working tree**. Whatever is checked out in
`~/projects/pigeon` at restart time is what gets deployed. The deploy procedure
(`pigeon/.opencode/skills/cross-device-deployment/SKILL.md`) is literally
`cd ~/projects/pigeon && git pull` then restart. A dirty or ahead-of-origin main
checkout in pigeon is a **production deploy hazard**, not untidiness. This is
categorically worse than mono, where the same dirt merely serves stale skills.

---

## 1. Inventory: what exists today

### 1.1 The pre-commit hook — the only control that blocks a write

**Hook body:** `assets/git-hooks/pre-commit` (42 lines). It is already
**repo-agnostic** — it keys on *primary-worktree identity*, not on a repo name or
a branch name:

```bash
common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
...
primary="$(cd "$(dirname "$common")" && pwd -P)"
here="$(git rev-parse --show-toplevel)"
...
if [ "$here" = "$primary" ]; then
  echo "worktree-guard: refusing to commit in the primary root ($primary)." >&2
  echo "Create a fresh worktree and commit there:  work <slug>" >&2
  exit 1
fi
exit 0
```

Note it **fails open** (`exit 0`) on any resolution failure. That is deliberate
and correct.

**File placement:** `users/dev/home.base.nix:1043-1052`, gated `lib.mkIf isCloudbox`:

```nix
  home.file.".config/git-hooks/pre-commit" = lib.mkIf isCloudbox {
    source = "${assetsPath}/git-hooks/pre-commit";
    executable = true;
  };
```

**Enrollment:** `users/dev/home.base.nix:850-870`,
`home.activation.installMonoWorktreeGuardHook`, also `isCloudbox`-gated, and
**hard-coded to one path**:

```nix
  current_hooks_path="$(git -C /home/dev/projects/mono config --get core.hooksPath ...)"
  managed_hooks_dir="$HOME/.config/git-hooks"
  if [ -z "$current_hooks_path" ] || [ "$current_hooks_path" = "$managed_hooks_dir" ]; then
    git -C /home/dev/projects/mono config core.hooksPath "$managed_hooks_dir"
  else
    echo "WARNING: ... Skipping installation to avoid clobbering."
  fi
```

Verified live: `core.hooksPath` is set on **mono and its 4 linked worktrees only**
(worktrees inherit local config). It is **unset on pigeon and on workstation**;
pigeon's `.git/hooks/` contains nothing but the 14 `*.sample` files.

`projects.nix` contains no `hooksPath`, no `worktree`, and no `mono` entry.

**Tests:** `assets/git-hooks/test-pre-commit.sh` (rejects at root, succeeds in a
linked worktree).

### 1.2 `work` — the ergonomic half

`pkgs/git-work/default.nix` (364 lines, binary named `work`), installed for
**all hosts** via `users/dev/home.base.nix:577-578` (`localPkgs.git-work`).

- `work <slug> [branch]` → `git worktree add <root>/.worktrees/<slug> -b <branch> origin/<trunk>`, prints the path.
- Root resolution collapses `~/projects/<P>/.worktrees/<W>` → `~/projects/<P>`.
- Trunk from `git symbolic-ref --short refs/remotes/origin/HEAD`; loud failure if unset.
- Bounded fetch (`WORK_FETCH_TIMEOUT`, default 15s), warn-and-continue.
- `work --prune-merged` sweeps `.worktrees/*`, removing only worktrees that are
  **clean AND fully merged into `origin/<trunk>`**. Never touches the primary
  root or the current worktree.

`work` is already repo-agnostic and already on PATH everywhere. Nothing needs
building here.

### 1.3 `reset-workspace` — nightly, mono-only

`pkgs/reset-workspace/default.nix:985-1005`:

```bash
    MONO_ROOT="${HOME}/projects/mono"
    if command -v work >/dev/null 2>&1 && [ -e "$MONO_ROOT/.git" ]; then
      log "pruning merged launch worktrees under $MONO_ROOT/.worktrees ..."
      if ! ( trap - PIPE; cd "$MONO_ROOT" && exec work --prune-merged ) ...
```

Comment in situ: *"v1 scope: the mono primary root."* Fires 03:00 via
`nightly-restart-background` on both NixOS hosts.

A **broader** sweeper already exists and is not mono-scoped:
`users/dev/disk-cleanup.nix:80-163` `cleanup_worktrees()` walks **every**
`~/projects/*/.worktrees/*`, removing merged-and-clean worktrees and age-expired
abandoned ones. So the *reclamation* side is already generalized; only the
*prune-on-reset* hook is mono-only, and it is redundant with disk-cleanup.

### 1.4 `opencode-launch --worktree` — opt-in, not default

`pkgs/opencode-launch/default.nix:105-116`:

```
  --worktree <slug>              Land the session in a fresh 'work' worktree
                                 under <directory> (a git repo) instead of at
                                 its root. Use for WRITABLE sessions so the
                                 read-only-main guard is bypassed by design.
```

Default is `worktree_slug=""` (`:140`) — i.e. **land at the root**. On `work`
failure it aborts loudly rather than silently launching at the root (`:308-364`),
which is right. A cleanup trap removes the worktree if the launch fails.

### 1.5 Convention-only layers (docs)

| Where | What it says | Binding? |
|---|---|---|
| `assets/opencode/AGENTS.md` §"Git Safety in Shared Worktrees" | Bans *destructive* git verbs in a shared/main worktree; tells you to use a throwaway worktree. | Says nothing about *committing* or *editing* at a primary root. Wrong axis for this incident. |
| `assets/opencode/skills/swarm-shaped-work/SKILL.md:92-122` | "Workers are writable — launch them with `--worktree <slug>` … must NOT start in a repo's primary root". | Strongest statement of the rule. Advisory. Only reaches sessions that load the skill. |
| `assets/opencode/skills/opencode-launch/SKILL.md:181-221` | Same, framed around mono's hook. | Advisory. |
| workstation `AGENTS.md` | **No occurrence of the word "worktree" at all.** | Absent. |
| pigeon `AGENTS.md` (304 lines) + `.opencode/skills/` (20 skills) | **No occurrence of "worktree" at all.** | Absent. |

### 1.6 Permission-layer denies — wrong axis

`assets/opencode/agents/*.md` frontmatter (identical 16-line block in
`code-reviewer`, `spec-reviewer`, `oracle-*`, `adversarial-reviewer-*`):

```yaml
    "git reset*": deny
    "git checkout*": deny
    ...
    "git commit*": deny
    "git push*": deny
```

These are **unconditional** for four *read-only* subagents. They do not apply to
the primary agent, and they are not location-aware. `assets/opencode/opencode.base.json:4-10`
has `"*": "allow"` and no git rules.

### 1.7 What was tried and removed

`users/dev/opencode-config.nix:517-524`:

```nix
  # NOTE: the worktree-guard opencode plugin was removed 2026-07-25. It never
  # loaded on any process (see below), and its path heuristic flagged every
  # relative path as a hit, so it could only ever have produced noise.
  # ... What is no longer enforced is blocking *edits* (as opposed to commits) at a
  # primary root; that is convention-only now.
```

**The edit-blocking layer does not exist.** It was designed, built, found never
to have loaded, and deleted. Failure mode #1 from the incident (8 uncommitted
edits at the root) has **no control against it anywhere**, in any repo, today.

---

## 2. Effectiveness: measured, not asserted

### 2.1 The scoreboard

Live survey of every primary clone under `~/projects` (2026-08-11):

| Repo | Branch | Dirty files | Unpushed commits on trunk | Guarded? |
|---|---|---|---|---|
| `mono` | main | **11** | 0 | hook installed |
| `workstation` | main | 0 | **1** (`af6307c`, today 12:05) | no |
| `meridian` | main | 0 | **1** (2026-07-25, 17d) | no |
| `opencode-cached` | main | 0 | **1** (2026-07-25, 17d) | no |
| `k8s-gitops` | main | 0 | **1** (2026-03-24, **140d**) | no |
| `pigeon` | main | 0 | 0 (after today's rescue) | no |

Two findings, both damning:

1. **The hook works exactly as specified and is not sufficient.** mono is the one
   repo with the guard, and it is the *dirtiest* root on the machine — 11
   modified/untracked files. The hook blocks commits; it does not block edits.
   `workstation-faj7` already documents the downstream consequence (untracked
   droppings at the mono root permanently block `ff-mono-root`).

2. **Failure mode #2 is endemic, not a pigeon anomaly.** Four repos are sitting
   on unpushed commits on their trunk right now, one of them for **140 days**,
   and one of them is **workstation itself** — the repo that owns this tooling,
   committed to today. Nobody noticed any of these. The pigeon commit was found
   in hours only because a deploy forced a pull. **The absence of a detector is
   the reason this looks rare.**

### 2.2 Per-control honest assessment

| Control | Blocks a WRITE? | Stops uncommitted edits at root? | Stops a commit onto trunk? | Bypass |
|---|---|---|---|---|
| `pre-commit` hook | **Yes** | **No** | **Yes** (in the enrolled repo) | `--no-verify`, plus the gaps in §2.3 |
| `work` helper | No — ergonomics | No | No | just don't run it |
| `opencode-launch --worktree` | No — placement | **Yes, by construction** (session cwd is a worktree) | **Yes, by construction** | not passing the flag; it is opt-out-by-default |
| `reset-workspace` prune / `disk-cleanup` | No — reclamation | No | No | n/a |
| AGENTS.md / SKILL.md sentences | **No** | No | No | agent doesn't load the skill, or reads it and rationalizes |
| agent `git commit*: deny` | Yes, for 4 read-only subagents | No | Yes, but everywhere, not just at root | doesn't apply to the primary agent |

The difference the task asks about is stark and worth stating flatly: **of the six
layers, exactly one blocks a write, and it blocks only the commit.** Everything
else is placement, cleanup, or prose. The incident's failure mode #1 (8 dirty
files at the root) would have been stopped by *none* of them, including in mono.

### 2.3 Measured bypass surface of the hook

I ran the shipped hook against a throwaway repo in `/tmp/opencode` rather than
reasoning about it:

| Operation at the primary root | Result |
|---|---|
| `git commit` | **blocked** ✓ |
| `git commit --no-verify` | bypass — *this is the intended escape hatch* |
| `git cherry-pick <sha>` | **bypass** — silently lands a commit on trunk |
| `git merge --no-ff` | **bypass** — `pre-commit` does not run for merge commits |
| `git revert` | blocked ✓ |
| `git rebase` (replay onto trunk) | **bypass** — no `pre-commit` per replayed commit |
| `git commit` in a linked worktree | allowed ✓ (`core.hooksPath` is inherited) |

The `merge` bypass is **load-bearing, not a defect**: `git pull` at the root must
keep working for deploys. The `cherry-pick` and `rebase` bypasses are genuine
holes, and `cherry-pick` is precisely the verb a session would reach for when
"rescuing" or "replaying" a commit — the same neighbourhood as the pigeon
incident. A `pre-merge-commit` hook would close the merge case; it should
**not** be added, for the deploy reason.

### 2.4 The claim not to make

Do not claim this generalization prevents the pigeon incident class. It prevents
**half** of it (the commit onto `main`) and leaves the other half (dirty root)
addressed only by a detector. The original design was already honest about this
(`2026-07-08-...-design.md:138-151`, "Honest limits"): realistic containment was
estimated at 80–90% *with* the plugin layer that has since been deleted.

---

## 3. Recommendation

### 3.1 The shape: enrollment list, not a global setting

**Do NOT set `core.hooksPath` globally.** Measured reason:

```
=== repos with REAL (non-sample) hooks in .git/hooks ===
culinary-operations-server: commit-msg overcommit-hook post-checkout post-commit
                            post-merge post-rewrite pre-commit pre-commit.legacy
                            prepare-commit-msg pre-push pre-rebase
lgtm: post-merge

=== repos with their own core.hooksPath ===
opencode: .husky/_
```

A global `core.hooksPath` **silently disables** all eleven of
`culinary-operations-server`'s overcommit hooks and `lgtm`'s `post-merge`, and
fights `opencode`'s husky. `core.hooksPath` is winner-take-all — there is no
merge. This is the single strongest argument for the enrollment list that
`workstation-v03j.7` already calls for, and against the tempting one-liner.

Second reason, also measured: `~/projects/wms-pss-dish-fix` is a **separate
clone**, not a linked worktree. Under a global hook it becomes its own "primary
root" and every commit in it is rejected — a pure false positive. Sibling clones
used as worktree substitutes are a real pattern here (`mono-*` and
`pigeon-qdcb12` happen to be genuine linked worktrees; `wms-pss-dish-fix` is not).
An explicit list makes that a decision instead of an accident.

### 3.2 Keep keying on "is the primary worktree", not on a branch name

The shipped hook already does this and it is correct. Branch-name keying
(`refuse if branch == main`) fails both ways:

- **False negative:** the pigeon incident's sibling failure — a session parks the
  root on a feature branch and commits there. Still a dirty shared tree, still a
  deploy hazard for pigeon, but a branch check waves it through.
- **False positive:** a linked worktree legitimately checked out on `main`
  (`git worktree add ../deploy main`) gets blocked for no reason.

Primary-worktree identity is the invariant that actually matters. No change.

### 3.3 Concrete changes

#### R1 — Generalize the enrollment activation script *(closes `workstation-v03j.7`)*

**File:** `users/dev/home.base.nix:850-870`.

Replace `installMonoWorktreeGuardHook` with `installWorktreeGuardHooks`, driven
by a list. Keep the existing non-clobbering check verbatim — it is what protects
`culinary-operations-server` and `opencode` if they are ever added by mistake.

```nix
  # Repos whose primary root is protected by the worktree-guard pre-commit hook.
  # Enrollment is explicit, NOT global: core.hooksPath is winner-take-all, so a
  # global setting would silently disable culinary-operations-server's 11
  # overcommit hooks and opencode's husky. See
  # docs/plans/2026-08-11-worktree-guard-generalization-design.md §3.1.
  worktreeGuardRepos = [
    "mono"        # work trunk; .agents/skills served from the tree
    "pigeon"      # pigeon-daemon runs tsx against the working tree = prod
    "workstation" # this repo; had an unpushed commit on main on 2026-08-11
  ];

  home.activation.installWorktreeGuardHooks = lib.mkIf isCloudbox (
    lib.hm.dag.entryAfter [ "writeBoundary" ] (
      lib.concatMapStringsSep "\n" (repo: ''
        _wg_repo="${config.home.homeDirectory}/projects/${repo}"
        if [ ! -e "$_wg_repo/.git" ]; then
          echo "worktree-guard: $_wg_repo is not a git repo, skipping"
        else
          _wg_cur="$(${pkgs.git}/bin/git -C "$_wg_repo" config --get core.hooksPath 2>/dev/null || true)"
          _wg_managed="$HOME/.config/git-hooks"
          if [ -z "$_wg_cur" ] || [ "$_wg_cur" = "$_wg_managed" ]; then
            ${pkgs.git}/bin/git -C "$_wg_repo" config core.hooksPath "$_wg_managed"
            echo "worktree-guard: ${repo} core.hooksPath set to $_wg_managed"
          else
            echo "WARNING: worktree-guard: ${repo} core.hooksPath is '$_wg_cur', not '$_wg_managed'. Skipping to avoid clobbering."
          fi
          if [ -n "$(ls -A "$_wg_repo/.git/hooks" 2>/dev/null | ${pkgs.gnugrep}/bin/grep -v '\.sample$' || true)" ]; then
            echo "WARNING: worktree-guard: ${repo} has real hooks in .git/hooks that core.hooksPath will now bypass."
          fi
        fi
      '') worktreeGuardRepos
    )
  );
```

The second warning is new and matters: enrolling a repo that *already* had real
hooks is exactly the `culinary-operations-server` footgun, and today nothing
would tell you.

**Preconditions verified for all three repos:** `origin/HEAD` is set
(`origin/main` for all three, so `work` functions), and `.worktrees` is
gitignored in all three.

**Also update** `assets/git-hooks/pre-commit:2` — the comment still says
"(mono root)". It is repo-agnostic; fix the comment or the next reader will
believe it is mono-specific and re-derive this whole document.

**Test:** extend `assets/git-hooks/test-pre-commit.sh` with the §2.3 matrix, so
the `cherry-pick`/`merge`/`rebase` bypasses are *pinned as known* rather than
rediscovered as surprises.

**Cost:** ~1 hour. **Benefit:** closes failure mode #2 for the three repos that
matter. **Rank: 1.**

#### R2 — A dirty-or-ahead detector across all primary roots

This is the highest-value *new* item, because §2.1 shows the real problem is not
that these states occur — it is that **nothing looks**. A commit sat unpushed on
`k8s-gitops` main for 140 days.

**File:** new `assets/scripts/trunk-drift-detector` + a cloudbox user timer, modelled
directly on `users/dev/em-drift-detector.nix` (which already does this shape for
`~/projects/eternal-machinery`) and on `assets/scripts/ff-mono-root`.

**The exact check**, per primary root under `~/projects/*` (skip linked worktrees
by testing that `.git` is a directory, not a file):

```bash
root_is_primary() { [ -d "$1/.git" ]; }
ahead=$(git -C "$r" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)
dirty=$(git -C "$r" status --porcelain 2>/dev/null | wc -l)
branch=$(git -C "$r" rev-parse --abbrev-ref HEAD)
trunk=$(git -C "$r" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')
# report when: ahead > 0  (commit stranded on a local branch)
#          or: branch = trunk AND dirty > 0  (writable work in the shared root)
```

Report, do not act. **Never** `reset`/`stash`/`clean` — that line has already
cost a peer session's uncommitted database
(`assets/opencode/AGENTS.md:104`), and `ff-mono-root` is deliberately written
not to cross it.

Two known-noisy cases must be allowlisted or the report becomes wallpaper: mono
is *permanently* dirty (8+ untracked entries — see the freshness roadmap's
"dirty-check trap"), and `salmon-of-knowledge` shows 46 dirty files.

**Delivery:** this inherits `workstation-yb4b`'s "assumes something looks"
problem if it only signals through systemd failure state. Route it to the daily
morning recommendation agent (Telegram-reachable), which the roadmap already
names as the cheapest fix.

**Cost:** ~3 hours. **Benefit:** the only layer that catches failure mode #1
(dirty root) at all, and the only one that works on the 20+ repos that will never
be enrolled. **Rank: 2 — and arguably 1 on benefit alone; ranked below R1 only
because R1 is an hour.**

#### R3 — State the rule where agents actually read it

Currently: workstation `AGENTS.md` never says "worktree"; pigeon `AGENTS.md`
never says "worktree". The rule lives only in two skills that a session may never
load.

- Add a short §"Work in a worktree, not the primary root" to workstation
  `AGENTS.md` and to `~/projects/pigeon/AGENTS.md`, naming `work <slug>`, and —
  for pigeon — the tsx-runs-the-working-tree deploy hazard, since that is the
  argument that makes the rule stick rather than get rationalized away.
- Add the recovery path explicitly (see §3.4). **An agent blocked without an
  obvious escape hatch will invent a worse one** — most likely `--no-verify`,
  which is precisely the outcome to avoid.

**Cost:** ~30 min. **Benefit:** low on its own (it is convention — that is the
whole finding of this document), but it is the prerequisite that makes R1's block
message survivable. **Rank: 3.** Note the pigeon edit is in *another* repo and
must go through pigeon's own PR flow.

#### R4 — Do not extend `reset-workspace`'s prune to more repos

`users/dev/disk-cleanup.nix:80-163` already sweeps **every**
`~/projects/*/.worktrees/*` nightly with the same clean-and-merged safety gates.
Extending `reset-workspace`'s mono-only block would duplicate it. Instead, delete
that block and let `disk-cleanup` own worktree reclamation — but only after
confirming the two units' schedules don't leave a gap. **Rank: 5 (cleanup, not
protection).**

### 3.4 The escape hatch — must be explicit, or agents invent a worse one

Ranked, and this ordering must be stated in both the hook message and AGENTS.md:

1. **Move the work.** `work <slug>`, then `git -C <root> stash`… **no.** Never
   stash in a shared root. Instead: `work <slug> && git -C <root> diff > /tmp/p.diff && git -C <wt> apply /tmp/p.diff` — copy forward, leave the root untouched, clean up the root only once the worktree commit exists.
2. **Genuine hotfix / deploy-time commit at the root:** `git commit --no-verify`,
   and say so in the commit message. It is a supported operation, not a
   transgression; pretending otherwise is what breeds silent workarounds.
3. **Deploy operations** (`git pull`, `git merge --ff-only`) need no hatch — they
   are already unaffected (§2.3).
4. **`reset-workspace` itself** never commits; unaffected.

The current hook message says only `work <slug>`, which is a dead end for someone
who already has uncommitted work at the root — the exact state of incident #1.
**Amend the hook message** to name option 1 and option 2.

---

## 4. Non-hook layers: verdicts

| Layer | Verdict | Why |
|---|---|---|
| **`opencode-launch` defaults to `--worktree` for writable sessions** | **Do it, eventually — but it is not the cheap win it looks like.** | Strongest control by far: it is prevention by construction, not enforcement, and it is the only thing that stops *edits*. But "writable" is not a property `opencode-launch` currently knows — there is no writable/read-only flag, and the skills explicitly launch coordinators read-only at the root *on purpose*. Inverting the default requires a `--no-worktree` (or `--read-only`) flag plus auditing every caller (`reset-workspace`, `oc-auto-attach`, the swarm skills, lgtm). **Rank 4**, medium cost, highest ceiling. This is `workstation-v03j`'s original item 4, still unshipped. |
| **opencode permission deny-rules for git in a primary worktree** | **No.** | Permission globs match on *command text*, not on cwd. `"git commit*": deny` cannot be conditioned on "am I at a primary root", so the only implementable version is a blanket deny for the primary agent — which breaks all legitimate committing. The location-aware version needs a plugin, and **that plugin was already built, never loaded, and deleted** (`opencode-config.nix:517`). Do not rebuild it without first fixing whatever made plugins not load. |
| **Shell/CLI wrapper around `git`** | **No.** | Interposing on `git` would have to be a PATH shim, and `assets/opencode/AGENTS.md` documents that the `agent-scope` plugin *deliberately* leaves `git` commands unscoped so the deny globs keep matching. Adding a second interposition layer on the same binary is asking for the class of bug that took weeks to find last time. The hook is the supported interposition point; use it. |
| **Periodic dirty-or-ahead detector** | **Yes — R2.** | See above. Cheap, no blast radius, covers the repos that will never be enrolled, and is the only thing that would have caught `k8s-gitops` at day 1 instead of day 140. |
| **`pre-merge-commit` hook to close the merge bypass** | **No.** | Would break `git pull` at the root, which is the documented pigeon deploy step. The bypass is load-bearing. |
| **Filesystem read-only perms / bare-repo relayout** | **No.** | Already rejected in the 2026-07-08 design (`:58-59`): high blast radius, breaks builds. Nothing has changed. |

---

## 5. What I would NOT do, and why

- **A global `core.hooksPath`.** Silently disables 11 real hooks in
  `culinary-operations-server`, one in `lgtm`, and fights husky in `opencode`.
  Measured, not hypothetical. (§3.1)
- **Rebuild the edit-blocking opencode plugin.** It is the layer whose absence
  hurts most, and I still would not rebuild it yet: the last one *never loaded on
  any process* and nobody noticed until it was deleted. Fix plugin-load
  observability first, or the replacement is indistinguishable from doing nothing.
- **A branch-name check.** Wrong invariant in both directions. (§3.2)
- **Anything that auto-cleans a shared root.** `reset`, `stash`, `clean`,
  auto-quarantine of colliding files. Already cost one peer session's uncommitted
  database.
- **Enrolling all ~40 repos under `~/projects`.** Most are read-only reference
  clones or short-lived; the hook's value scales with how many sessions write to
  the repo. Three repos cover the actual traffic. Add more when a fourth
  misbehaves.
- **Extending the mono-only prune in `reset-workspace`.** Duplicates
  `disk-cleanup.nix`. (R4)

---

## 6. Summary table

| # | Item | Cost | Benefit | Stops fm#1 (dirty root) | Stops fm#2 (commit on trunk) |
|---|---|---|---|---|---|
| R1 | Generalize hook enrollment to `{mono, pigeon, workstation}` | 1h | High | No | **Yes** |
| R2 | Dirty-or-ahead trunk detector + Telegram delivery | 3h | High | **Detects** | **Detects** |
| R3 | State the rule in workstation + pigeon `AGENTS.md`; fix hook message | 30m | Low alone, enabling | No | No |
| R4 | `opencode-launch` writable-by-default `--worktree` | Medium | Highest ceiling | **Yes, by construction** | **Yes, by construction** |
| R5 | Retire `reset-workspace`'s mono-only prune in favour of `disk-cleanup` | 1h | Cleanup | No | No |

Do R1 + R3 together (they are one PR's worth of work and R3 makes R1 humane),
then R2. R4 is the real fix and deserves its own design pass.
