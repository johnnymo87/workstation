# The throwaway-serve database footgun (incident 2026-08-14) and its fix

**Status:** fixed. opencode-patched PR #42 (`db-isolation-guard.patch`) +
`pkgs/oc-throwaway-serve` + doc corrections in this repo.

## Root cause: a precedence bug that turns isolation into a no-op

opencode resolves its SQLite database in `packages/core/src/database/database.ts`:

```ts
export function path() {
  if (Flag.OPENCODE_DB) {
    if (Flag.OPENCODE_DB === ":memory:" || isAbsolute(Flag.OPENCODE_DB)) return Flag.OPENCODE_DB
    return join(Global.Path.data, Flag.OPENCODE_DB)
  }
  // ...channel-suffixed default under Global.Path.data
}
```

`OPENCODE_DB` is consulted **first**, and an absolute value is returned
**verbatim** — before `Global.Path.data`, which is the only thing `XDG_DATA_HOME`
feeds, is ever read. Therefore:

> **`XDG_DATA_HOME` does not redirect the database whenever `OPENCODE_DB` is set.**

On devbox/cloudbox/macOS, `users/dev/home.base.nix` exports `OPENCODE_DB` as a
**session variable** — deliberately, to pin every writer to one file and defeat
the channel-suffixed `opencode-<channel>.db` default that a from-source build
would otherwise use (a stale `opencode-local.db` on cloudbox is the scar from
that). Session variables are inherited by every shell and every child process.

So the standard "validate a build without touching production" recipe —

```bash
XDG_DATA_HOME=$(mktemp -d) opencode serve --port <scratch>
```

— isolates logs, config, state and storage, and leaves the **database pointed at
production**.

### Why nobody caught it

1. **The log path DID honour `XDG_DATA_HOME`.** A scratch logfile appeared
   exactly where expected, so the isolation looked like it was working. The
   observable that was easiest to check was the one that was working.
2. **The verification assertion was a false green.** It queried the *copy* for
   assistant rows and found 0 — which reads as PASS, when in fact the copy had
   never been opened and the prompt had gone to production.

### What it cost, and what it nearly cost

Two operations believed to be hitting a copy hit production: a model switch and
a test prompt against a real session, producing three unwanted mutations in the
live DB (since cleaned up; live verified identical to the pre-test snapshot).

It stayed cheap only by luck: the target session was mute due to an unrelated
bug, so the turn never ran. Had it run, an opus turn would have executed a real
backlog of pending instructions, with tool access, against a real project
directory.

### The asymmetry that made this the priority

`serve.ts` (our `registry-port-fence` patch) already refuses to start when a
throwaway serve inherits `OPENCODE_SERVE_ID` / `OPENCODE_ROUTING_DB` from a
parent opencode session, with a specific, actionable FATAL. That guard fired
correctly in this same session and stopped an earlier mistake. There was no
equivalent guard for `OPENCODE_DB`. The routing hazard corrupts a routing table;
the database hazard writes the production database. **The more dangerous of the
two was the unguarded one.**

## The fix

### 1. Guard in opencode itself (opencode-patched PR #42)

`packages/core/src/database/isolation.ts` + one call at the top of `path()`:

* **Armed** only when `XDG_DATA_HOME` is explicitly set **and** an absolute
  `OPENCODE_DB` resolves outside it (symlinks/trailing slashes normalized on
  both sides, so a symlinked data dir cannot produce a false FATAL).
* On arm-and-fail: FATAL naming both variables, the consequence and the exact
  fix; `process.exit(22)` **before any handle is opened**.
* Escape hatch `OPENCODE_DB_ALLOW_FOREIGN_XDG=1` ⇒ once-per-process WARNING.

`path()` is the single resolver for serve, run, TUI, `opencode db`, stats and
import, so one call site covers every consumer.

**Why a guard rather than making the isolation work.** Deriving the DB path from
`XDG_DATA_HOME` when the two disagree would fix the recipe, but it silently
repoints the database of *any* process that sets `XDG_DATA_HOME` for unrelated
reasons — reintroducing exactly the split-brain that pinning `OPENCODE_DB`
exists to prevent. Trading a silent write to the wrong DB for a silent write to
a *different* wrong DB is not an improvement. Fail loud, print the one-line fix,
and make the correct invocation easy (below).

**Why it cannot break the pool.** Measured on cloudbox: all four pool serves run
with `XDG_DATA_HOME` **unset** (`/proc/<pid>/environ` shows `OPENCODE_DB` +
`OPENCODE_DISABLE_CHANNEL_DB` and nothing XDG). Unset XDG ⇒ unarmed ⇒ zero
behaviour change. `env -u OPENCODE_DB` scratch serves
(`pkgs/opencode-frontdoor/route-gate.nix`, `test.sh`) are likewise unarmed; they
were already isolated.

### 2. `oc-throwaway-serve` (this repo)

The ergonomic half, because "remember one more variable" is not a fix. It builds
the scratch environment (own `HOME`/XDG dirs, explicit `OPENCODE_DB` under them,
routing vars scrubbed), optionally seeds the DB with `VACUUM INTO` (consistent,
read-only against the live pool — unlike `cp`, which can capture a torn page
set), and then **proves the isolation by measurement**: it reads
`/proc/<pid>/fd` and refuses to hand you a URL unless the serve holds *no*
handle on the protected database (`.db`, `-wal` and `-shm`) *and* does hold one
on the scratch database — so a vacuous green is impossible. A violation is
`kill -9` plus exit 3, not a warning.

Measurement rather than reasoning is the point: the incident happened because
everyone reasoned that the isolation held, and the only thing that settled it
was `/proc/<pid>/fd`.

### 3. Documentation corrections

The broken recipe was written down and was being followed:

* `docs/plans/2026-08-01-plugin-loader-hardening-roadmap.md` printed it verbatim
  (`XDG_DATA_HOME="$(mktemp -d)"` with no `OPENCODE_DB` handling) — corrected in
  place, with the wrapper as the recommended path.
* `docs/plans/2026-06-11-opencode-1.17-cutover-runbook.md` describes its
  evidence as gathered "isolated under `/tmp`", which is where the practice
  came from — a correction box now says what that does and does not isolate.
* `users/dev/home.base.nix` — the `OPENCODE_DB` pin now documents its own
  footgun next to the reason it exists, so the next reader meets both.

## Evidence

Guard, end-to-end against a real v1.18.18 build (every "production" path in an
executed command was a throwaway `/tmp` path; the live DB was never named):

| case | environment | result |
|---|---|---|
| incident shape, patched | scratch `XDG_DATA_HOME`, `OPENCODE_DB` outside it | FATAL, exit 22, nothing listening |
| incident shape, **unpatched control** | same | resolved the outside path, exit 0 — the bug |
| correctly isolated | `OPENCODE_DB` inside the scratch XDG | exit 0, scratch DB |
| **pool shape** | `XDG_DATA_HOME` unset, absolute `OPENCODE_DB` | serve booted; `/proc/<pid>/fd` held only the scratch DB |
| escape hatch | `OPENCODE_DB_ALLOW_FOREIGN_XDG=1` | one WARNING, continues |

14 unit tests (`packages/core/test/database/isolation.test.ts`), named by
`build-release.yml` so they are not inert.

Wrapper: 15 assertions in `pkgs/oc-throwaway-serve/test.sh` (behavioural fd
measurement incl. a `-wal`-only handle and a negative control, plus source
guards on every env var that must be set or scrubbed), wired as flake check
`oc-throwaway-serve-tests`. Live run against the deployed (unpatched) opencode:
`VERIFIED isolated`, and an independent `/proc/<pid>/fd` read showed 0 handles on
`~/.local/share/opencode/opencode.db`. Fault injection (protected DB pointed at
the DB the serve does open) killed the serve and exited 3.

## Residual risks

* The guard cannot help a process that sets **neither** `XDG_DATA_HOME` nor a
  scratch `OPENCODE_DB` — there is no signal of intent to isolate, and the
  operator has asked for the live DB. This is by design.
* The guard ships **with a build**. A validation run of an *older* candidate
  binary is unguarded, which is precisely why the wrapper measures rather than
  trusting the binary.
* The escape hatch exists and can be pasted. It prints a warning naming the
  hazard; it is not silent.
