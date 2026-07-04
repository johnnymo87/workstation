---
name: migrating-beads-schema
description: Resolve a beads (bd) schema-migration block across clones — bd "refusing to auto-apply N pending schema migrations (vNN->vMM)" on a remote-backed database (#4259), or writes blocked after a bd version bump. Use when any repo's bd shows that guard, or to migrate all beads DBs on a machine after upgrading bd. Covers single-migrator discipline, the DoltHub-vs-git split-remote trap, adopt-vs-migrate, and fresh-clone verification.
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

## Step 0: Are you the designated migrator or an adopter?

Only ONE machine migrates each remote. **This is a coordination decision — get
explicit human/coordinator sign-off on which machine owns it before migrating.**

- **Designated migrator** (usually the machine with the freshest local work):
  → run **Procedure A** per repo.
- **Every other machine**: → run **Procedure B** (adopt) per repo, AFTER the
  migrator has pushed.

Before deciding, confirm the remote is actually still on the old schema (nobody
migrated it yet) with the fresh-clone probe in "Verification". If a fresh clone
comes down already-migrated (no guard), that remote is done — **adopt, don't
migrate**.

## Procedure A — designated migrator (per repo)

Run from the repo root. `<repo>` = repo name.

```bash
cd ~/projects/<repo>          # or ~/Code/<repo> on macOS
TS=$(date +%Y%m%d-%H%M%S)

# 1. Physical snapshot = instant, complete rollback (DB is small; disk is cheap).
cp -rp .beads/embeddeddolt /tmp/beads-<repo>-pre-$TS

# 2. Logical export as a second safety net (captures issues + memories).
bd export --all --include-memories -o /tmp/beads-<repo>-pre-$TS.jsonl

# 3. Migrate (the env var is the deliberate "I am the sole migrator" opt-in).
BD_ALLOW_REMOTE_MIGRATE=1 bd migrate

# 4. Verify locally: guard gone, count sane, writes work.
bd status
S=$(bd q "scratch (delete)"); bd delete "$S" --force

# 5. Publish to the CANONICAL remote (see the split-remote trap below FIRST).
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

Guard against it:

```bash
# What does each source think the remote is?
grep -i 'sync.remote' .beads/config.yaml
bd dolt remote list
python3 -c "import json;d=json.load(open('.beads/embeddeddolt/*/.dolt/repo_state.json'.replace('*',__import__('os').listdir('.beads/embeddeddolt')[0])));[print(k,'->',v['url']) for k,v in d['remotes'].items()]"
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

Then re-adopt the repo's local via Procedure B (it descends from the remote now).

## Procedure B — adopt a migrated remote (peer machine, per repo)

`bd bootstrap` re-clones from the remote and **replaces the local DB** — any
local-only, unpushed issues are LOST. Preserve them first.

```bash
cd ~/projects/<repo>

# 1. Save current local, then find issues that exist ONLY locally.
bd export --all --include-memories -o /tmp/<repo>-local-$(date +%s).jsonl

# 2. bootstrap won't re-clone while a DB exists → move it aside to force a clone.
mv .beads/embeddeddolt /tmp/<repo>-old-$(date +%s)
bd bootstrap --yes                                # clones the migrated remote
bd status                                         # expect: no guard

# 3. Re-import any local-only ids the remote didn't have (diff old export vs now).
bd export --all --include-memories -o /tmp/<repo>-now.jsonl
# (compare ids; extract the missing lines to a .jsonl; then:)
bd import /tmp/<repo>-missing.jsonl               # upsert; preserves ids
```

Diffing ids (local-only + local-newer-than-remote):

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

**Caveat for repos with no `config.yaml sync.remote`** (remote lives only inside
the dolt dir): moving `embeddeddolt` aside strips the remote and `bd bootstrap`
fails with "No active beads workspace". For those, migrate a pristine clone
(the "no common ancestor" recipe) instead of move-aside bootstrap.

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
- **Always verify via a fresh clone** of the canonical remote before declaring
  a repo done.
- Standalone `dolt` is more reliable than bd's embedded clone if the latter is
  flaky (`nix run nixpkgs#dolt -- clone jmohrbacher/<repo> /tmp/x`).

## Related

- `beads` skill (`~/.config/opencode/skills/beads/SKILL.md`) — DoltHub wiring,
  credentials, git-free/stealth mode, and the git-backed-dolt anti-pattern.
