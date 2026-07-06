# Beads git-free / stealth-mode audit + reconciliation

Date: 2026-07-06
Author: opencode autonomous research session (fire-and-forget)
Trigger: We want our use of `bd` (beads) to be **entirely git-free**. In
`~/projects/eternal-machinery` the `.beads/*.jsonl` are already gitignored and
`bd sync` is no longer a valid subcommand, yet stale git-committed-`.beads` /
`bd sync` guidance still litters repos, docs, skills, and hooks.

Companion to `docs/notes/2026-05-18-bd-1.0-upgrade-study.md` (the 0.x→1.0
upgrade study), which first documented that `bd sync` was removed. This report
goes further: it establishes the **git-free / stealth model** from upstream
source, inventories every stale reference by project, and gives a concrete
migration checklist for eternal-machinery.

Upstream sources cloned/read for this report:
- `~/projects/beads` = `gastownhall/beads` @ `fe12a44ca` (cloned fresh
  2026-07-06). (`steveyegge/beads` redirects here; the Go module path is still
  `github.com/steveyegge/beads`.)
- `~/projects/opencode-beads-jdt` = `joshuadavidthomas/opencode-beads` @
  `d8d6773` ("sync: beads v1.0.5"). NB: the pre-existing `~/projects/opencode-beads`
  is a *different* fork (`simonwjackson/opencode-beads`) with local uncommitted
  changes — left untouched.

---

## TL;DR

1. **The fleet is ~75% migrated already.** Six of our eight beads-using repos
   are fully git-free (`no-git-ops: true` + a DoltHub `sync.remote` +
   `.beads/*.jsonl` gitignored + nothing under `.beads/` tracked):
   **comptes, eternal-machinery, my-podcasts, pigeon, tec-codex, workstation.**

2. **Two laggards still commit beads state to git:** **chatgpt-relay** and
   **citadels** track `.beads/issues.jsonl` + `.beads/interactions.jsonl` +
   config in git, have no `no-git-ops`, and no `sync.remote`. These are the
   only repos where the stale guidance is *actively wrong AND actively used*.

3. **The correct git-free model is "stealth mode":** `bd config set no-git-ops
   true` (bd routes ignore patterns into `.git/info/exclude`, never stages,
   never runs git in its session-close protocol), Dolt is the source of truth,
   and cross-machine sync is `bd dolt push` / `bd dolt pull` against a DoltHub
   remote. `.beads/issues.jsonl` is a **local export only** — not a sync channel.
   `bd sync` was removed in v0.56.0 and is a no-op / unknown command in 1.0.

4. **eternal-machinery has vestigial, now-contradictory git-hook machinery.**
   `scripts/git-hooks/{pre-commit,pre-push,install.sh}` + its test suite + two
   AGENTS.md paragraphs implement a "flush-but-don't-auto-stage the committed
   JSONL, and block push when JSONL is git-dirty" policy (beads `o2wl`, `6d6d`).
   That policy assumed the JSONL is git-tracked. It no longer is (`.beads/` is
   fully gitignored, `no-git-ops: true`), so:
   - the **pre-push guard is dead** — `.beads/` is gitignored, so `git diff`
     never reports the JSONL dirty; the "loud safety net" is now a silent no-op.
   - the **pre-commit hook still runs `bd export` on every commit** in the repo
     — harmless but pointless work, plus 25 lines of comments documenting a
     defunct git-committed-JSONL policy.

5. **The highest-leverage doc fix is the workstation `beads` skill.** Its
   `SKILL.md` is already modern (documents git-free, `no-git-ops`, `bd dolt
   push`), but its `references/CLI_REFERENCE.md` and `references/WORKFLOWS.md`
   still present `bd sync` (with `--flush-only`, `--merge`, `--from-main`, …) as
   a live command. That skill deploys to every host, so it is the most-read
   stale surface.

---

## RESOLUTION — executed 2026-07-06 (all items done)

After the audit below was written, the user green-lit applying the fixes. All
of it was executed and pushed the same day:

- **eternal-machinery** — removed `scripts/git-hooks/{pre-commit,pre-push,install.sh}`,
  `test/scripts/test_git-hooks.sh`, and the per-clone `.git/hooks/{pre-commit,
  pre-push,pre-commit.bak,post-merge}`; fixed AGENTS.md (dropped the install
  step + paragraph, `bd sync` → `bd dolt push` in quick-ref and Landing the
  Plane). Filed bead `eternal-machinery-386i`. Commit `b399761f`, pushed.
- **comptes, my-podcasts** — `bd sync` → `bd dolt push` in Landing the Plane.
  Pushed (`0caceb2`, `5f204be`).
- **citadels** — was pre-Dolt with 138 issues in committed JSONL. Imported the
  138 into embedded Dolt, **created the DoltHub repo** `jmohrbacher/citadels`
  (via the DoltHub GraphQL `createRepo` mutation using `DOLTHUB_API_TOKEN`) and
  `bd dolt push`ed; set `no-git-ops: true`; gitignored all of `.beads/`;
  `git rm --cached` the tracked beads state; removed dead SQLite/daemon cruft;
  `bd sync` → `bd dolt push` in AGENTS.md. Commit `3064657`, pushed.
- **chatgpt-relay** — the devbox clone was stale: `origin/main` had already been
  migrated to git-free by a peer, and DoltHub `jmohrbacher/chatgpt-relay` already
  held the authoritative **52 issues**. Bootstrap-cloned those 52 into local Dolt;
  removed the stale bd `pre-commit`/`post-merge` hooks; fixed the last `bd sync`
  in origin's AGENTS.md via a **throwaway worktree** → commit `7e8f118`, pushed.
  Then reconciled the diverged local clone to `origin/main` (verified no
  uncommitted/untracked peer content first; the 52-issue Dolt DB is gitignored
  and survived).
- **workstation `beads` skill** — rewrote the `bd sync` surface in
  `references/CLI_REFERENCE.md` (TOC, quick-ref table, `## Sync Commands` →
  `bd dolt push/pull` + a "`bd sync` (removed)" deprecation table, End-of-Session
  example, approve-list) and `references/WORKFLOWS.md`. All remaining `bd sync`
  strings are intentional deprecation docs.

**Post-state:** all 8 beads-using repos are now git-free (`no-git-ops: true`,
`.beads/` gitignored, nothing under `.beads/` tracked, DoltHub Dolt sync). No
live `bd sync` guidance remains in any AGENTS.md/SKILL.md/README/hook. The only
`bd sync` strings left anywhere are (a) intentional deprecation notes and
(b) historical `docs/plans/*` records (deliberately preserved, §3.F).

**DoltHub note for a future session:** repo creation is automatable headless via
`POST https://www.dolthub.com/graphql`, header `authorization: token
$DOLTHUB_API_TOKEN`, mutation `createRepo(ownerName, repoName,
description:String!, visibility: Private){_id}` (enum value is capitalized
`Private`). Push/pull auth uses the dolt cred JWK in `~/.dolt/creds/`. There is
no standalone `dolt` binary on devbox; `bd dolt push/pull/bootstrap` drive the
embedded engine.

The section numbers below are the **original audit** (pre-execution); §5's
"why not auto-applied" caveat is now moot — it was applied.

---

## 1. The correct git-free / stealth model (from upstream source)

### 1.1 Dolt is the source of truth; JSONL is a local export

> "Beads issue data lives in Dolt. The local Dolt database is the source of
> truth for `bd list`, `bd show`, `bd ready`, and every write command."
> — `~/projects/beads/docs/SYNC_CONCEPTS.md:1-5`

> "`.beads/issues.jsonl` is an export. It exists for viewers, interchange,
> migration, and backup. It is **not** the canonical cross-machine sync
> channel. Do not use routine `bd import .beads/issues.jsonl` as a replacement
> for `bd dolt pull`. JSONL import is upsert-only; it cannot infer that records
> absent from an export were deleted…"
> — `~/projects/beads/docs/SYNC_CONCEPTS.md:26-32`

Because issue data lives under Dolt's `refs/dolt/data` (separate from git
branches), **beads does not commit to any git branch**:

> "Beads data is stored in Dolt under `refs/dolt/data`, separate from standard
> Git refs. This means beads does not commit to any Git branch, so protected
> branch workflows are not affected."
> — `~/projects/beads/docs/GIT_INTEGRATION.md:35`

### 1.2 Cross-machine sync = `bd dolt push` / `bd dolt pull`

```bash
bd dolt push    # publish local Dolt history to the remote
bd dolt pull    # pull remote Dolt history
bd bootstrap    # fresh clone: clone the Dolt history from the remote
```
— `~/projects/beads/docs/SYNC_CONCEPTS.md:8-23`, `GIT_INTEGRATION.md:37-43`

The remote is a Dolt remote. Ours is DoltHub
(`https://doltremoteapi.dolthub.com/jmohrbacher/<repo>`), persisted as
`sync.remote` in `.beads/config.yaml`. `bd dolt push`/`pull` need the `dolt`
binary available. `bd sync` is explicitly a deprecated no-op:

> "`bd sync` is **deprecated** and is now a no-op. Use Dolt commands instead:
> Push to remote: `bd dolt push` … Most users should rely on the Dolt server's
> automatic sync (with `dolt.auto-commit` enabled) instead of running manual
> sync commands."
> — `~/projects/opencode-beads-jdt/vendor/commands/sync.md:6-17`

### 1.3 STEALTH MODE (`no-git-ops: true`) — the git-free switch

Stealth mode is the config that makes beads leave **zero** git footprint. Two
ways in:

- `bd init --stealth` — full invisible init (also skips hooks + agents).
  — `~/projects/beads/docs/GIT_INTEGRATION.md:106`, `cmd/bd/init.go:50-53`
- `bd config set no-git-ops true` — the persisted flag stealth keys off.
  — `~/projects/beads/cmd/bd/info.go:1041` ("NEW: no-git-ops config … for
  manual git control")

What the flag actually does, from source:

- **Routes ignore patterns into `.git/info/exclude`, never a tracked
  `.gitignore`.** In stealth mode bd must keep its footprint out of tracked git
  files so collaborators never see beads. `setupStealthMode` writes `.beads/`
  and `.claude/settings.local.json` into `.git/info/exclude`
  (`cmd/bd/init_stealth.go:16-63`); project Dolt patterns (`.dolt/`, `*.db`, …)
  likewise go to `.git/info/exclude` under the header
  `"# Beads: Dolt files kept local via .git/info/exclude (stealth / no-git-ops)"`
  (`cmd/bd/init_stealth.go:143-162`). `.git/info/exclude` is chosen over global
  gitignore because global gitignore doesn't support the needed paths (GH#704)
  and `.git/info/exclude` is per-repo and worktree-shared (`init_stealth.go:19-22`,
  `65-91`).
- **Never `git add`s the export.** `export.git-add` is skipped when
  `no-git-ops` is set: `cmd/bd/hooks.go:1431-1436`
  ("Stage the exported file if configured. Skip when no-git-ops is set") and
  `cmd/bd/export_auto.go:148-150` (GH#3314).
- **Never runs git in the session-close protocol.** `bd prime` emits a
  stealth (no-git-command) session-close protocol when `no-git-ops` is true:
  `cmd/bd/prime.go:93-95, 138` and `internal/config/yaml_config.go:37`
  ("Disable git ops in bd prime session close protocol (GH#593)").
- **`bd init --stealth` persists `no-git-ops: true`** so `bd prime` uses the
  stealth protocol automatically: `cmd/bd/init.go:1264-1268` (GH#2159), and
  detection is via that flag: `isStealthRepo()` in
  `cmd/bd/init_stealth.go:226-234`.
- **`bd doctor --fix` respects stealth.** On a stealth repo it will not create
  a tracked `.gitignore`; it routes patterns into `.git/info/exclude` and even
  warns/cleans up if a prior non-stealth run *leaked* the beads section into a
  tracked `.gitignore` (`cmd/bd/init_stealth.go:248-300`, `doctor_fix.go:275`).

**Note on our implementation vs. upstream's default:** upstream stealth prefers
`.git/info/exclude` (invisible even in the tracked `.gitignore`). Our migrated
repos instead put `.beads/` in the *tracked* root `.gitignore` (e.g.
`eternal-machinery/.gitignore:69-70` `# beads tracker (git-free/stealth dolt)` /
`.beads/`). That is a deliberate, equivalent choice for **our own** repos (we
don't care that our own `.gitignore` reveals we use beads); it is not a "leak"
in the fork-PR sense upstream guards against. It still achieves git-free: the
whole `.beads/` dir (Dolt DB + JSONL exports) is untracked.

### 1.4 What works without hooks / without AGENTS.md

All core beads functionality works with **no git hooks at all** — `bd
create/update/close/ready/list/show`, `bd dolt push/pull`, `bd onboard`, `bd
doctor` (`~/projects/beads/docs/GIT_INTEGRATION.md:81-98`). Hooks only add
optional niceties (agent-identity commit trailers, hook chaining). To stay
hook-free: `bd init --skip-hooks` (or our wrapper, which injects it) and never
run `bd hooks install` / `bd doctor --fix`-installs-hooks. This matches the
workstation `beads` skill's existing "Git Hook Policy" section
(`assets/opencode/skills/beads/SKILL.md:80-112`).

### 1.5 The canonical git-free recipe

```bash
# One-time per repo (or bd init --stealth on a fresh repo):
bd config set no-git-ops true
bd dolt remote add origin <dolt-remote-url>   # e.g. DoltHub
# ensure .beads/ (or at minimum .beads/*.jsonl + embeddeddolt/ + backup/) is gitignored
# ensure no .git/hooks/{pre-commit,pre-push,post-merge} beads hooks are installed

# Daily (agents): just use bd normally — Dolt auto-commits on every write.
bd create / bd update / bd close / bd ready ...

# Session close / cross-machine: push Dolt history (NOT git):
bd dolt push        # and `bd dolt pull` / `bd bootstrap` on other machines
```

No `bd sync`. No `git add .beads/…`. No pre-commit/pre-push beads hooks.

---

## 2. Fleet posture (measured 2026-07-06)

| Project | `.beads` tracked in git? | `*.jsonl` gitignored? | `no-git-ops` | `sync.remote` | Git-free? |
|---|---|---|---|---|---|
| comptes | none | yes | `true` | DoltHub | ✅ done |
| eternal-machinery | none | yes | `true` | DoltHub | ✅ done (but vestigial hooks — §3) |
| my-podcasts | none | yes | `true` | DoltHub | ✅ done |
| pigeon | none | yes | `true` | DoltHub | ✅ done |
| tec-codex | none | yes | `true` | DoltHub | ✅ done |
| workstation | none | yes | `true` | DoltHub | ✅ done |
| **chatgpt-relay** | **`.gitignore .gitkeep README.md config.yaml interactions.jsonl issues.jsonl metadata.json`** | **NO** | unset | unset | ❌ **git-committed** |
| **citadels** | **`.gitignore README.md config.yaml interactions.jsonl issues.jsonl metadata.json`** | **NO** | unset | unset | ❌ **git-committed** |

The migrated six still carry stale *docs* (below), but their mechanics are
correct. chatgpt-relay and citadels need the full migration (§4.C).

---

## 3. Stale-reference inventory (what to remove/rewrite)

Grouped by "fix priority". File:line references are as of 2026-07-06.

### 3.A eternal-machinery — vestigial git-hook machinery (HIGH; design reversal, needs owner sign-off)

This is deliberate, tested machinery (beads `o2wl`, `6d6d`) built for a
git-committed-JSONL world that no longer exists. Everything here should be
**removed** now that `.beads/` is fully gitignored and `no-git-ops: true`:

- `scripts/git-hooks/pre-commit` — runs `bd export -o .beads/issues.jsonl` on
  **every** commit (pointless now; JSONL is untracked). Header comments
  (lines 1-24, 62-63) document the "don't auto-stage the committed JSONL"
  policy. **Remove file.**
- `scripts/git-hooks/pre-push` — refuses push when `.beads/issues.jsonl` is
  git-dirty. **Dead:** `.beads/` is gitignored so `git diff --quiet --
  .beads/issues.jsonl` (lines 44, 50) always succeeds → hook always exits 0.
  **Remove file.**
- `scripts/git-hooks/install.sh` — installs the two symlinks above; its header
  (lines 3-9) explains it replaces bd's auto-staging upstream hook. **Remove
  file.**
- `test/scripts/test_git-hooks.sh` — 8-case suite for the above (references
  `bd sync --flush-only` at line 72, stages `.beads/issues.jsonl` at 55-56,
  asserts pre-push refusal at 248/269). **Remove file** (and drop it from any
  test runner/manifest that enumerates it).
- `.git/hooks/` on each clone (local, not tracked): `pre-commit` → symlink,
  `pre-push` → symlink, `pre-commit.bak` (the backed-up upstream bd hook), and
  `post-merge` (a bd-installed legacy hook, dated Jan 17, that does JSONL-import
  fallback). Under `sync.remote` configured, post-merge skips import
  (`SYNC_CONCEPTS.md:39-41`), but all four should be removed for cleanliness.
  Remove with plain `rm` (these are per-clone, untracked — not a shared-worktree
  git op): `rm -f .git/hooks/pre-commit .git/hooks/pre-push .git/hooks/pre-commit.bak .git/hooks/post-merge`.
- `AGENTS.md:35` — `./scripts/git-hooks/install.sh  # Install our pre-commit +
  pre-push (bead o2wl)` in the Setup block. **Remove the line.**
- `AGENTS.md:38` — the paragraph "The git-hooks installer replaces bd's
  upstream pre-commit hook … refuses to push when the JSONL has uncommitted
  changes…". **Remove the paragraph** (replace with nothing, or one line: "Beads
  runs git-free (`no-git-ops: true`) with DoltHub sync — no beads git hooks.").

### 3.B eternal-machinery — stale `bd sync` in agent guidance (HIGH; safe rewrite)

- `AGENTS.md:167` — `bd sync               # Sync with git` in the Quick
  Reference block → replace with `bd dolt push        # Sync Dolt DB to DoltHub`.
- `AGENTS.md:182` — `bd sync` inside the "Landing the Plane" MANDATORY
  WORKFLOW step 4 → replace with `bd dolt push  # push beads DB to DoltHub
  (git-free; not git)`. (Compare workstation's already-fixed AGENTS.md:170:
  "# If a Dolt remote is configured, sync it explicitly with bd dolt pull/push.")
- `.beads/config.yaml:40-45` — commented boilerplate about
  `sync-branch`/"bd sync will commit to this branch". bd-generated; local-only
  (whole `.beads/` gitignored). Low urgency but misleading; can be deleted.
- `.beads/README.md:30` — `bd sync`. bd-generated boilerplate; local-only. Low.

### 3.C Other migrated repos — stale `bd sync` in live AGENTS.md (MEDIUM; safe rewrite)

These repos are already git-free mechanically; only their docs lie:

- `comptes/AGENTS.md:58` — `bd sync` in Landing the Plane → `bd dolt push`.
- `my-podcasts/AGENTS.md:236` — `bd sync` in Landing the Plane → `bd dolt push`.
- (`pigeon/AGENTS.md:214` already uses `bd dolt push` — reference model.)
- (`tec-codex` has no `bd sync` in live guidance — only in historical
  `docs/plans/*` — leave those.)
- Each of these repos also has bd-generated `.beads/README.md:30` (`bd sync`)
  and `.beads/config.yaml:40-45` boilerplate — local-only, low priority.

### 3.D chatgpt-relay & citadels — NOT git-free yet (HIGH; needs migration, not just doc edits)

Doc hits:
- `chatgpt-relay/AGENTS.md:12` (`bd sync  # Sync with git`) and `:27`
  (`bd sync` in Landing the Plane).
- `citadels/AGENTS.md:10` (`bd sync  # Sync with git`), `:103` (`bd sync` in
  Landing the plane).

But doc edits alone are insufficient — these repos still **track** beads state
in git and lack `no-git-ops`/`sync.remote`. They need the full migration (§4.C)
before their AGENTS.md should claim `bd dolt push`. Until migrated, their
`bd sync` lines are genuinely broken (the subcommand errors), so at minimum the
Landing-the-Plane step should be corrected to `bd dolt push` **after** a
`sync.remote` is configured, or dropped if we decide these repos don't need
cross-machine sync.

### 3.E workstation `beads` skill references (HIGH; deploys everywhere)

- `assets/opencode/skills/beads/references/CLI_REFERENCE.md` — presents
  `bd sync` as a live command: TOC line 29, table line 67, section 336-346
  (`bd sync`, `--status`, `--dry-run`, `--merge`, `--flush-only`,
  `--import-only`), plus example usages at 355, 529, 653. **Rewrite** the
  `bd sync` entry to a deprecation note pointing at `bd dolt push`/`pull`
  (mirror `opencode-beads-jdt/vendor/commands/sync.md`).
- `assets/opencode/skills/beads/references/WORKFLOWS.md:257,262` — a "run
  `bd sync` before you leave" step with a stale "30-second debounce" rationale.
  **Rewrite** to `bd dolt push` (and drop the daemon-debounce language — there
  is no daemon under embedded Dolt).
- `assets/opencode/skills/beads/SKILL.md:90-92` — **already correct** (states
  `bd sync` was removed in v0.56.0 and errors with `unknown command`). Keep;
  use as the canonical wording for the rewrites above.

### 3.F Historical plan docs (NO ACTION — leave as-is)

`bd sync` appears in many `docs/plans/*.md` and session-handoff files across
tec-codex, citadels, my-podcasts, opencode-patched, opencode-cached, and
eternal-machinery (`docs/plans/2026-04-14-session-handoff-12.md:242,252`,
`docs/plans/2026-04-15-session-handoff-13.md:141`, etc.). These are dated
historical records of what was true at the time. Rewriting them would falsify
the record. **Leave them.** (They are also mostly in gitignored-nothing repos,
i.e. committed history.) The `.gitattributes` `merge=beads` references are
already annotated as defunct where relevant
(`eternal-machinery/.gitattributes:3` "no longer used in git-free mode").

---

## 4. Migration checklists

### 4.A eternal-machinery (the prompt's primary target)

Already git-free at the config/gitignore level. Remaining work is removing the
vestigial hook machinery and correcting docs. **State to KEEP:**
- `.beads/config.yaml`: `no-git-ops: true` + `sync.remote:
  https://doltremoteapi.dolthub.com/jmohrbacher/eternal-machinery` — keep.
- `.gitignore:69-70` (`.beads/` ignored) — keep.
- `.beads/.gitignore` (embeddeddolt/, backup/, *.jsonl, etc.) — keep (belt &
  suspenders; harmless).
- `.beads/metadata.json` — already v1.0 shape
  (`{"backend":"dolt","dolt_mode":"embedded","dolt_database":"beads"}`) — keep.

**Changes to MAKE (recommend; not executed this session — design reversal of
beads `o2wl`/`6d6d`, wants owner confirmation):**
1. Remove `scripts/git-hooks/pre-commit`, `scripts/git-hooks/pre-push`,
   `scripts/git-hooks/install.sh`.
2. Remove `test/scripts/test_git-hooks.sh` and any runner entry that enumerates
   it.
3. Uninstall the per-clone hooks: `rm -f .git/hooks/{pre-commit,pre-push,pre-commit.bak,post-merge}`.
   (Plain `rm` of untracked per-clone files — NOT a shared-worktree git op.)
4. `AGENTS.md`: delete line 35 (`install.sh` step) and the paragraph at line 38;
   fix `bd sync` at lines 167 and 182 → `bd dolt push`.
5. (Optional) Trim the stale `bd sync` boilerplate in `.beads/config.yaml:40-45`
   and `.beads/README.md:30`.
6. File a bead documenting the reversal (supersedes `o2wl`, `6d6d`).

### 4.B Migrated repos with stale docs (comptes, my-podcasts; eternal-machinery covered above)

Doc-only: fix the `bd sync` line in each `AGENTS.md` "Landing the Plane" to
`bd dolt push`. No mechanical change needed (already `no-git-ops: true` +
DoltHub). Safe, obviously-correct edits.

### 4.C chatgpt-relay & citadels (still git-committed — full migration)

Per repo, one-time (mirrors the six already-migrated repos). **Requires care:
these track beads state in git today, so decide the cutover deliberately.**
1. Pick the machine with the authoritative local Dolt DB.
2. `bd config set no-git-ops true`.
3. `bd dolt remote add origin https://doltremoteapi.dolthub.com/jmohrbacher/<repo>`
   (create the DoltHub repo first), then `bd dolt push`.
4. `git rm --cached .beads/issues.jsonl .beads/interactions.jsonl
   .beads/metadata.json .beads/config.yaml .beads/README.md .beads/.gitkeep`
   (stop tracking beads state) and add `.beads/` (or at least `.beads/*.jsonl`)
   to `.gitignore` — matching `eternal-machinery/.gitignore:69-70`. Commit that
   as an explicit, reviewed change (this is a normal tracked-file change, safe).
5. Fix `AGENTS.md` `bd sync` lines → `bd dolt push`.
6. Verify: fresh clone → `bd bootstrap` → `bd ready` returns the issues.

*(Alternative if we decide these repos don't need cross-machine beads sync:
skip the DoltHub remote, just `no-git-ops: true` + gitignore `.beads/`, and drop
the `bd sync`/push line from Landing-the-Plane entirely. Dolt still
auto-commits locally.)*

### 4.D workstation beads skill (doc-only, high leverage)

Rewrite `references/CLI_REFERENCE.md` and `references/WORKFLOWS.md` `bd sync`
content to the deprecation note (source of truth:
`opencode-beads-jdt/vendor/commands/sync.md` and workstation
`SKILL.md:90-92`). After editing the source under `assets/opencode/skills/`,
redeploy via home-manager so `~/.config/opencode/skills/beads/` picks it up.

---

## 5. Why this session did NOT auto-apply the edits

Per the fire-and-forget constraints: the doc-only `bd sync → bd dolt push`
rewrites (§3.B/C, §4.B/D) are trivially safe, but the eternal-machinery hook
removal (§3.A/4.A) is a **reversal of a deliberate, tested design** (beads
`o2wl`/`6d6d`) and the chatgpt-relay/citadels work is a **git-history cutover**
— both want the owner's explicit go-ahead. All eternal-machinery/citadels/
chatgpt-relay repos are shared worktrees; no destructive git ops were run in
any of them. This report is the deliverable; edits are left for a follow-up
with sign-off.

## Appendix: source material

- `~/projects/beads` @ `fe12a44ca` — `docs/SYNC_CONCEPTS.md`,
  `docs/GIT_INTEGRATION.md`, `cmd/bd/init_stealth.go`, `cmd/bd/init.go`,
  `cmd/bd/prime.go`, `cmd/bd/hooks.go`, `cmd/bd/export_auto.go`,
  `cmd/bd/info.go`, `internal/config/yaml_config.go`.
- `~/projects/opencode-beads-jdt` @ `d8d6773` — `README.md`,
  `vendor/commands/sync.md`, `CHANGELOG.md:64`.
- Per-repo `.beads/config.yaml`, `.gitignore`, `git ls-files .beads`,
  `git check-ignore` (measured 2026-07-06).
- eternal-machinery: `scripts/git-hooks/{pre-commit,pre-push,install.sh}`,
  `test/scripts/test_git-hooks.sh`, `AGENTS.md`, `.beads/.gitignore`,
  `.git/hooks/` listing, `.beads/metadata.json`, `.gitattributes`.
- Prior study: `docs/notes/2026-05-18-bd-1.0-upgrade-study.md`.
