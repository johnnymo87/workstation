---
name: migrating-beads-schema
description: Resolves a beads (bd) schema-migration block across clones — bd "refusing to auto-apply N pending schema migrations (vNN->vMM)" on a remote-backed database (#4259), or writes blocked after a bd version bump, or post-migration write failures like "Field 'id' doesn't have a default value" (Error 1105). Use when any repo's bd shows that guard, or to migrate all beads DBs on a machine after upgrading bd. Covers single-migrator discipline, the DoltHub-vs-git split-remote trap, adopt-vs-migrate, flaky embedded-clone recovery (standalone-dolt graft), stopping a stale bd daemon, the 0037 stripped-UUID-default repair, and fresh-clone verification.
allowed-tools: [Bash, Read, Edit]
---

# Migrating Beads Schema Across Clones

A `bd` binary upgrade can introduce pending schema migrations. On a
**remote-backed** database `bd` refuses to auto-apply them and blocks all
writes:

```
refusing to auto-apply N pending schema migrations to a remote-backed database
(vNN -> vMM): migrating clones independently forks the schema (#4259)
```

This is a **safeguard, not a bug** (upstream #4259): if two clones migrate
independently, their Dolt histories diverge and `bd dolt pull` breaks silently
and unrecoverably. Exactly **one** clone (machine) may migrate a given remote;
every other clone must **adopt** the migrated result.

**Reads still work** while blocked (bd runs read-only commands on the old
schema). Only writes — `create/update/close`, and `bd dolt push/pull/backup` —
are blocked. So the swarm can keep reading beads; it just can't file new ones.

## Facts about this setup (read before acting)

- **One embedded Dolt DB per repo**, at `<repo>/.beads/embeddeddolt/`. All git
  worktrees of a repo share it (bd walks up to the repo's `.beads`). There is
  **not** one clone per worktree — a whole repo's worktrees = one clone.
- **"Clones" = machines** (devbox / cloudbox / macOS / crostini), each syncing
  to the same remote. The single-migrator rule is per-remote, across machines.
- **A bd upgrade blocks every remote-backed DB on the machine at once** — not
  just one repo. Expect to sweep all of them (`mono`, `workstation`, `pigeon`,
  and the other DoltHub trackers; see the `beads` skill for the full list).
- **Canonical remote is DoltHub** (`https://doltremoteapi.dolthub.com/jmohrbacher/<repo>`)
  for the shared trackers. See the `beads` skill (`~/.config/opencode/skills/beads/SKILL.md`)
  for the wiring, credentials, and the "do NOT use git-backed dolt" anti-pattern.
- Repo path is `~/projects/<repo>` on NixOS/crostini, `~/Code/<repo>` on macOS.
- **A stale `bd` daemon can hold a repo's DB open** and make the move-aside /
  clone in Procedure B fail or corrupt. Stop it first — see "Stop a stale bd
  daemon" below. (This is separate from a project's own daemon, e.g. pigeon's
  *swarm* daemon is a node process, not a `bd` daemon — leave it alone.)
- **bd's embedded clone is flaky for some repos** (seen on pigeon: corrupt
  journal / missing `.dolt` / "table file not found"). Standalone `dolt` is
  reliable — the graft fallback in Procedure B is the workaround.

## Step 0: Are you the designated migrator or an adopter?

Only ONE machine migrates each remote. **This is a coordination decision — get
explicit human/coordinator sign-off on which machine owns it before migrating.**
When a coordinator publishes a list of repos it has migrated, cross-reference
it: a repo that shows the guard but is **not** on that list has no migrator yet,
so it's yours to migrate (Procedure A); a repo **on** the list is already done —
adopt it (Procedure B).

- **Designated migrator** (usually the machine with the freshest local work):
  → run **Procedure A** per repo.
- **Every other machine**: → run **Procedure B** (adopt) per repo, AFTER the
  migrator has pushed.

Before deciding, confirm the remote is actually still on the old schema (nobody
migrated it yet) with the fresh-clone probe in "Verification". If a fresh clone
comes down already-migrated (no guard), that remote is done — **adopt, don't
migrate**.

## Stop a stale bd daemon (before any move-aside / clone)

A leftover `bd` daemon (often an old binary version) can hold the repo's
embedded DB and corrupt a clone-in-place. Find and stop only the one for this
repo; never a broad kill that could hit another repo's daemon or an unrelated
process:

```bash
ls .beads/*.sock 2>/dev/null                 # a socket => a daemon is/was attached
ps aux | grep '[b]d-real daemon'             # find the bd daemon pid(s)
# kill the pid whose --db / cwd is THIS repo; verify it's gone before proceeding.
```

## Procedure A — designated migrator (per repo)

```
Progress:
- [ ] 0. Stop stale bd daemon
- [ ] 1. Physical snapshot + jsonl export (rollback safety)
- [ ] 2. Check the split-remote trap (canonical = DoltHub)
- [ ] 3. BD_ALLOW_REMOTE_MIGRATE=1 bd migrate
- [ ] 4. Repair the stripped UUID defaults (see "Known defect" below)
- [ ] 5. Local verify: guard gone, count sane, scratch write works
- [ ] 6. bd dolt push to the CANONICAL remote
- [ ] 7. Fresh-clone Verification (authoritative, incl. column_default probe)
```

Run from the repo root. `<repo>` = repo name.

```bash
cd ~/projects/<repo>          # or ~/Code/<repo> on macOS
TS=$(date +%Y%m%d-%H%M%S)

# 1. Physical snapshot = instant, complete rollback (DB is small; disk is cheap).
cp -rp .beads/embeddeddolt /tmp/beads-<repo>-pre-$TS

# 2. Logical export as a second safety net (captures issues + memories).
bd export --all -o /tmp/beads-<repo>-pre-$TS.jsonl

# 3. Migrate (the env var is the deliberate "I am the sole migrator" opt-in).
BD_ALLOW_REMOTE_MIGRATE=1 bd migrate

# 4. Repair the UUID defaults that migration 0037 just stripped (see
#    "Known defect" below for why). $DB = metadata.json dolt_database
#    (usually "beads"). No bd daemon may be running.
( cd .beads/embeddeddolt/$DB
  for t in events comments issue_snapshots compaction_snapshots wisp_events wisp_comments; do
    nix run nixpkgs#dolt -- sql -q \
      "ALTER TABLE $t MODIFY COLUMN id CHAR(36) NOT NULL DEFAULT (UUID());"
  done
  nix run nixpkgs#dolt -- add -A
  nix run nixpkgs#dolt -- commit --author "bd repair <dev@$(hostname)>" \
    -m "repair: restore DEFAULT (UUID()) stripped by migration 0037" )

# 5. Verify locally: guard gone, count sane, writes work.
bd status
S=$(bd q "scratch (delete)"); bd delete "$S" --force

# 6. Publish to the CANONICAL remote (see the split-remote trap below FIRST).
bd dolt push
```

Then run the fresh-clone **Verification** to prove the remote actually received
the migrated schema. Do not trust "Push complete" alone.

### ⚠️ Split-remote trap (this is the one that bites)

Some repos have a `config.yaml sync.remote` that disagrees with the Dolt
`origin` in `repo_state.json` (e.g. one says DoltHub, the other git+ssh GitHub).
A plain `bd dolt push` can print **"Configured Dolt remote origin from git
origin"** and push to the **wrong** remote (git `refs/dolt/data`), leaving the
canonical DoltHub remote on the old schema. Symptoms: your push "succeeds" but a
peer's fresh clone still shows the guard.

Guard against it — the two sources must agree (DoltHub):

```bash
grep -i 'sync.remote' .beads/config.yaml               # config's view
bd dolt remote list                                    # bd's view
( cd .beads/embeddeddolt/beads &&                       # dolt's own origin
  nix run nixpkgs#dolt -- remote -v )                  # ("beads" = metadata.json dolt_database)
```

If they disagree, add an explicitly-named DoltHub remote and push to it by name:

```bash
bd dolt remote add dolthub https://doltremoteapi.dolthub.com/jmohrbacher/<repo>
bd dolt push --remote dolthub
```

Then fix `config.yaml sync.remote` to the DoltHub URL (Edit the file) so future
syncs are unambiguous.

### "no common ancestor" on push

If `bd dolt push` fails with **"no common ancestor / histories diverged"**, your
local is orphaned from the remote's lineage (a flaky embedded clone or a
wrong-remote detour). **Do NOT `--force`** — that obliterates the remote and
forks everyone. Instead, migrate a *pristine* clone and push that:

```bash
t=/tmp/<repo>-migrator; rm -rf "$t"; mkdir -p "$t/.beads"; chmod 700 "$t/.beads"
echo 'sync.remote: "https://doltremoteapi.dolthub.com/jmohrbacher/<repo>"' > "$t/.beads/config.yaml"
bd -C "$t" bootstrap --yes                       # clean clone of the remote
BD_ALLOW_REMOTE_MIGRATE=1 bd -C "$t" migrate     # migrate on the remote's own lineage
bd -C "$t" dolt push                             # clean fast-forward
```

(If `bd -C "$t" bootstrap` is itself flaky, use the standalone-dolt clone from
Procedure B's graft fallback to build `$t` instead.) Then re-adopt the repo's
local via Procedure B (it descends from the remote now).

## Procedure B — adopt a migrated remote (peer machine, per repo)

`bd bootstrap` re-clones from the remote and **replaces the local DB** — any
local-only, unpushed issues are LOST. Preserve them first.

```
Progress:
- [ ] 0. Stop stale bd daemon
- [ ] 1. Export current local (safety + local-only diff source)
- [ ] 2. Move embeddeddolt aside; bd bootstrap (or graft fallback)
- [ ] 3. Verify: no guard, count sane
- [ ] 4. Probe UUID defaults; repair locally if stripped ("Known defect")
- [ ] 5. Re-import ONLY the local-only ids (never a blind full import)
- [ ] 6. Scratch write, then bd dolt push
```

```bash
cd ~/projects/<repo>

# 1. Save current local, then find issues that exist ONLY locally.
bd export --all -o /tmp/<repo>-local-$(date +%s).jsonl

# 2. bootstrap won't re-clone while a DB exists → move it aside to force a clone.
#    Use a UNIQUE timestamped target; a fixed name collides on retry and nests dirs.
mv .beads/embeddeddolt /tmp/<repo>-old-$(date +%s)
bd bootstrap --yes                                # clones the migrated remote
bd status                                         # expect: no guard

# 3. Re-import any local-only ids the remote didn't have (diff old export vs now).
bd export --all -o /tmp/<repo>-now.jsonl
# (compare ids; extract the missing lines to a .jsonl; then:)
bd import /tmp/<repo>-missing.jsonl               # upsert; preserves ids
```

**Do NOT blind-import the whole pre-adopt export.** Import is an upsert keyed by
id, so replaying your old v49 copies would revert issues the remote legitimately
updated. Re-import only the ids that are local-only (or local-newer) — diff
first (below).

### Fallback: bd's embedded clone failed → graft a standalone dolt clone

If `bd bootstrap` errors mid-clone (**corrupt journal**, **"can no longer find
.dolt dir"**, **"table file not found"**), bd's embedded clone is the problem,
not the remote. Standalone `dolt` is reliable. Clone with it and graft into bd's
expected path:

```bash
rm -rf /tmp/<repo>-v /home/$USER/projects/<repo>/.beads/embeddeddolt   # drop the partial
nix run nixpkgs#dolt -- clone jmohrbacher/<repo> /tmp/<repo>-v          # reliable clone
mkdir -p .beads/embeddeddolt
cp -a /tmp/<repo>-v .beads/embeddeddolt/beads        # "beads" = metadata.json dolt_database
bd status                                            # bd now reads the grafted DB; expect no guard
```

If a `bd bootstrap` attempt died partway, **`rm -rf .beads/embeddeddolt` (the
partial) before retrying or grafting** — do not re-run the move-aside on top of a
half-written dir, or you'll nest `embeddeddolt/embeddeddolt` and tangle the
backups.

### Diffing ids (local-only + local-newer-than-remote)

```bash
python3 - <<'PY'
import json
def load(p):
    d={}
    for line in open(p):
        line=line.strip()
        if not line: continue
        try: o=json.loads(line)
        except: continue
        if o.get('id'): d[o['id']]=o.get('updated_at','')
    return d
old=load("/tmp/<repo>-local-XXXX.jsonl"); new=load("/tmp/<repo>-now.jsonl")
print("local-only:", sorted(set(old)-set(new)))
print("local-newer:", [i for i in old if i in new and old[i]>new[i]])
PY
```

**Caveat — `sync.remote` presence can differ per machine.** Some repos keep the
remote only inside the dolt dir (no `config.yaml sync.remote`); moving
`embeddeddolt` aside then strips the remote and `bd bootstrap` fails with "No
active beads workspace". But whether a given repo has `config.yaml sync.remote`
can differ **per clone** — don't assume from a peer's report; `grep -i
sync.remote .beads/config.yaml` locally. If it's absent, either write a
`config.yaml` with the DoltHub `sync.remote` first (as in the graft fallback /
"no common ancestor" recipe) or bootstrap a pristine clone instead of
move-aside.

## Known defect: migration 0037 strips `DEFAULT (UUID())` (Error 1105)

**Symptom** (fleet-verified 2026-07-04): after a v49→v53 migration — or on any
clone of a migrated-but-unrepaired remote — every write on **bd ≤ 1.0.5** fails
and rolls back:

```
failed to record event for <id>: record event in events: Error 1105:
Field 'id' doesn't have a default value
```

**Root cause** (verified, refined from the original report): migration
`0037_uuid_primary_keys` rebuilds PKs via `ADD COLUMN uuid_id … DEFAULT (UUID())`
+ rename, and Dolt **drops the expression default through that ALTER/rename —
at migration time, on the migrator's own local**. It is NOT a DoltHub transfer
bug: a restored default survives push→clone round-trips fine (verified on
comptes). Every migrated DB — local and remote — is stripped unless repaired.

**Why some machines never notice:** bd ≥ 1.1.0 generates event/comment ids
app-side (UUIDv7) and doesn't rely on the column default. bd 1.0.4/1.0.5 rely
on it and break. The schema is broken either way — repair it regardless, so
older binaries and future tools aren't landmined.

**Repair** (migrator, or any machine holding an unrepaired clone): the ALTERs
in Procedure A step 4. Six tables locally; only four (`events`, `comments`,
`issue_snapshots`, `compaction_snapshots`) exist on the remote — the `wisp_*`
tables (plus `local_metadata`, `repo_mtimes`) are **local-only, never pushed**,
so every clone must repair its own wisp tables (or recreate via bd).
After repairing the remote's owner pushes; peers pick it up with
`bd dolt pull` (or re-adopt).

**Probe** (works on any standalone clone; expect `uuid()`, not NULL):

```bash
nix run nixpkgs#dolt -- sql -q "SELECT table_name, column_default
  FROM information_schema.columns WHERE column_name='id' AND table_name IN
  ('events','comments','issue_snapshots','compaction_snapshots')
  ORDER BY table_name;"
```

## Verification (the authoritative check — always do this)

"Push complete" is not proof. Clone the **canonical remote** fresh and confirm
it's migrated. This is the same probe that catches a wrong-remote push:

```bash
t=/tmp/verify-<repo>; rm -rf "$t"; mkdir -p "$t/.beads"; chmod 700 "$t/.beads"
echo 'sync.remote: "https://doltremoteapi.dolthub.com/jmohrbacher/<repo>"' > "$t/.beads/config.yaml"
bd -C "$t" bootstrap --yes
bd -C "$t" status                      # expect: NO "refusing" guard, sane count
S=$(bd -C "$t" q "verify (delete)"); bd -C "$t" delete "$S" --force   # write proves unforked
```

For a schema-level check that doesn't depend on bd, read the migration table
straight from a standalone clone (`max(version)` should be the new `vMM`):

```bash
nix run nixpkgs#dolt -- clone jmohrbacher/<repo> /tmp/<repo>-probe
( cd /tmp/<repo>-probe && nix run nixpkgs#dolt -- sql -q \
  "select max(version) v, count(*) n from schema_migrations" )
```

Also run the `column_default` probe from "Known defect" on the same fresh clone
— a remote can be on the right schema version yet still write-broken for
bd ≤ 1.0.5 if the UUID defaults weren't repaired before the push.

### Standalone-dolt probe compatibility (nixpkgs dolt vs newer bd)

nixpkgs `dolt` (1.59.10) lags bd's embedded dolt. Where that bites
(fleet-verified 2026-07-04):

- **Fresh clones of a remote: all probes work.** Local-only tables never get
  pushed, so a fresh clone contains only the portable tables — verified against
  remotes written and repaired by bd 1.1.0-era tooling.
- **A live workspace's embedded DB** (`.beads/embeddeddolt/<db>`) may fail
  *whole-DB introspection* — `information_schema.columns` errors with
  `table has unknown fields` when any local-only table (wisps etc.) uses a
  newer schema feature. Per-table queries still work: use
  `SHOW CREATE TABLE <t>` instead, or plain selects.
- If some future format bump breaks even `dolt clone`/basic reads, verify
  through bd itself: `bd -C <tmpdir> bootstrap --yes` + scratch write
  (the first block of this section), or a version-matched standalone dolt.

If the fresh clone still shows the guard → the remote did NOT get the migration
(usually the split-remote trap). Fix and re-push.

## Cleanup: orphaned git-based dolt refs

A wrong-remote push can leave a stray `refs/dolt/data` (and
`refs/heads/__dolt_remote_info__`) on a **code** git remote. Back it up, then
delete it (this touches only a remote ref, never a working tree):

```bash
git ls-remote git@github.com:<org>/<repo>.git 'refs/dolt/*'          # inspect
git init --bare -q /tmp/<repo>-dolt-ref-backup.git                    # backup objects
git -C /tmp/<repo>-dolt-ref-backup.git fetch -q git@github.com:<org>/<repo>.git 'refs/dolt/data:refs/dolt/data'
git push git@github.com:<org>/<repo>.git --delete refs/dolt/data \
                                                  refs/heads/__dolt_remote_info__
```

## Safety rules

- **Never `bd migrate` on more than one clone per remote.** `BD_ALLOW_REMOTE_MIGRATE=1`
  is the sole-migrator opt-in, not a "make it work" flag.
- **Never `bd dolt push --force`** to resolve divergence — re-clone/migrate/push
  instead. Force forks the schema for every machine.
- **Always take the physical snapshot** (`cp -rp .beads/embeddeddolt`) before
  migrating — it's an instant, complete rollback.
- **Stop a stale bd daemon** before replacing a DB in place.
- **Never blind-import** a pre-adopt export over a freshly-adopted DB — re-import
  only local-only/local-newer ids.
- **Always verify via a fresh clone** of the canonical remote before declaring
  a repo done.
- Standalone `dolt` is more reliable than bd's embedded clone if the latter is
  flaky (`nix run nixpkgs#dolt -- clone jmohrbacher/<repo> /tmp/x`).

## Related

- `beads` skill (`~/.config/opencode/skills/beads/SKILL.md`) — DoltHub wiring,
  credentials, git-free/stealth mode, and the git-backed-dolt anti-pattern.
