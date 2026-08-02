# Plugin-Loader Hardening Roadmap

**Bead:** `workstation-5yox` (P1) · **Started:** 2026-08-01 · **Status:** step 0 shipped

> **Revision 2.** The first draft of this file (PR #242) was written and merged
> *without* the adversarial review it makes mandatory. Review afterwards found
> three HIGH defects, each of which rebuilt the failure family this roadmap
> exists to kill: the spine's numbered order contradicted its own "before code"
> rule, the E2 log-watch would have been unconditionally red against ~2500
> historical matches while its own negative control polluted the log it reads,
> and the `LOADER_VERSION` pin rotted on an 8-hourly auto-merge timer with only a
> comment guarding it. All are fixed below. Recorded rather than quietly
> corrected, because "the process document skipped the process" is the single
> most useful datum in this file.

Kills the bug class that took devbox down on 2026-07-30 and then silently
disabled `shell-env.ts` for ~32 hours. Four steps, each with the same spine.

---

## Facts that must survive compaction

Everything below was verified at source or in a live process. Do not re-derive
from memory, and do not trust a summary of it — including this one — over a
fresh check.

**Loader semantics** (opencode `v1.17.13`, `packages/opencode/src/plugin/`):

| Site | Behaviour |
|---|---|
| `index.ts:99-105` `getLegacyPlugins` | iterates `Object.values(mod)`; anything not a function and not `{ server: fn }` hits `throw new TypeError("Plugin export is not a function")` at **:103** → **whole file rejected** |
| `index.ts:110-121` `applyPlugin` | v1 branch pushes `plugin.server(...)` and **returns at :115**; only the fallthrough reaches `getLegacyPlugins` at :118 |
| `shared.ts:272-283` `readV1Plugin` | in `"detect"` mode returns `mod.default` when it is a record carrying `id`/`server`/`tui` |
| `shared.ts:306-316` `resolvePluginId` | `source === "file" && !id` → throws `Path plugin ... must export id`. **`id` is mandatory for our plugins.** |

**The three failure shapes:**

```
export function foo          -> invoked as a plugin factory; return value pushed
                                into hooks unvalidated. undefined poisons the
                                array -> /config/providers 500s, no prompt runs.
                                (LOUD - the devbox outage)
export const foo = {...}     -> throws at index.ts:103 -> file rejected, one
                                ERROR line, serve otherwise healthy.
                                (QUIET - shell-env, 2026-07-30..08-01)
export default {id, server}  -> v1 branch; named exports never inspected. SAFE.
export interface / type      -> erased at compile time. SAFE.
```

**Grepping the serve log** — `~/.local/share/opencode/log/opencode.log`, *not*
the systemd journal (serve stdout does not go there; `journalctl -u
opencode-serve@4096` is a false-negative trap).

```bash
# CORRECT - anchors the field
grep -E '^timestamp=\S+ level=ERROR .*failed to load plugin' "$LOG"
```

A naive `grep level=ERROR` also matches INFO permission-audit lines that *quote*
command text, so any session merely discussing the error string produces false
positives. This bit the author of this document twice, once after having
explicitly warned about it. **Step E2 depends on getting this right.**

**The log is shared, append-only, and full of history.** One ~633MB file for the
whole host — every TUI, headless session, and scratch serve appends to it, and it
holds entries back to June including **~2500 historical `failed to load plugin`
matches** from the 07-30..08-01 incident itself. So the anchored pattern above is
necessary but *not sufficient*: an unwindowed grep is unconditionally red.

Any consumer must scope to the current process, by either:

- **`run=<id>`** — the per-process field on every line, and the only true
  discriminator available; or
- **byte offset captured at restart**, reading only what was appended after.

**Scratch serves must scrub routing env AND redirect their data dir.** The first
or our own routing guard kills them; the second because a scratch serve otherwise
writes real `ERROR` lines into the very log the production canary reads — the
negative control poisons the detector:

```bash
env -u OPENCODE_SERVE_ID -u OPENCODE_ROUTING_DB \
    XDG_DATA_HOME="$(mktemp -d)" XDG_CONFIG_HOME="$scratch/config" \
    opencode serve --port <scratch-port>
```

**Deploy ordering.** `git pull` **before** `home-manager switch`. Doing it the
other way round silently deploys the pre-merge tree — this cost a full day on
step 0. Existing serves keep their in-memory module, so a pool restart is
required before any verification means anything.

**The lesson the whole bead exists for:** verify in the *role the code actually
plays*. #202 was tested exhaustively as a module under vitest and never once as
a plugin, which is the only role in which it broke. The guard written afterward
repeated the error — it asserted a rule *about* the loader instead of exercising
it, passed on a file opencode was rejecting, and its failure message recommended
the very pattern that was breaking production. Three instances in one week.

---

## Per-step spine

Every step below runs this sequence. It is the point of the roadmap: the spine
survives even if the step's details are lost.

1. **Compact** *(only if context is long)* — `preparing-for-compaction`. Persist
   to `workstation-5yox` and update this file *before* compacting, not after. A
   fresh session has nothing to compact and should skip straight to 2; a
   mid-flight session should not compact away the context the step still needs.
   This is a conditional, not a ritual.
2. **Consult `oracle-fable`** *(optional)* — when the design is genuinely open.
   Skip for mechanical steps.
3. **`adversarial-reviewer-fable` on the DESIGN** — **mandatory, and it comes
   before any code exists.** Every time this was skipped in this bead's history
   the result was wrong: fable caught the broken remediation that had already
   shipped to production, and caught three HIGH defects in the first draft of
   this very document, which was written and merged without it.
4. **SDD / implement** *(if applicable)* — `subagent-driven-development` when the
   step splits into independent tasks; dispatch `implementer`, then
   `spec-reviewer` to check the diff against the reviewed design. Skip the
   subagents for single-file changes; do not skip the review in 3.
5. **PR** *(if applicable)* — throwaway worktree off `origin/main`, never the
   shared checkout. Body states what was verified *and how*.
6. **Update roadmap** — tick the step here, file new beads for anything
   discovered, note what the next step inherits.

> **Why review precedes implementation.** Earlier drafts of this list numbered
> SDD *before* the review while annotating the review "before writing code" — a
> contradiction that a post-compaction reader, following the list literally,
> resolves by implementing first and reviewing the diff. That is the `9eb5b0e`
> pattern reconstructed inside the process meant to prevent it. Every failure in
> this bead was a *wrong-approach* failure — wrong export shape, wrong rule,
> wrong role — not an implementation typo. Design review is the only place those
> get caught.

> Steps 2 and 3 both name the `fable` variants, which are otherwise
> use-only-when-explicitly-asked. The user asked for them in this roadmap; that
> standing request applies to these steps only.

---

## Step 0 — Repair `shell-env.ts` · **DONE** (PR #225, `55a6b51`)

Adopted the v1 shape; replaced `no-function-exports.test.ts` with
`test/plugin-loader-contract.test.ts`, a loader replica pinned via
`LOADER_VERSION`. Verified by three mutations (all caught; the first was
*passing* the old guard) and by a real `opencode serve` on a scratch
`XDG_CONFIG_HOME` with both controls — 0 errors with the fix, exactly the
production error with the pre-fix file.

Deployed 2026-08-01 18:11 (gen 528). Confirmed live: `OPENCODE_HOSTNAME` set,
per-session `KUBECONFIG` injected, sops secrets restored, **0** load failures
since restart. Per-session kube isolation (`workstation-ev9n`) became real for
the first time at that moment — it was inert from merge until then.

---

## Step 1 — E1 across the remaining plugins

**Six repo-authored plugins, not four.** Deployed directly as `.ts`:
`compaction-context.ts`, `session-header.ts`, `subagent-routing.ts`. Deployed as
Nix-built `.js` bundles: `self-compact.ts`, `session-state.ts`.
(`shell-env.ts` was step 0.)

All are safe *today* only because they happen to have zero named runtime
exports. Any future helper export is an outage. Migrate each to
`export default { id: "<name>", server: plugin }` so the property holds by
construction.

The two bundled ones matter more than they look: `plugin-loader-contract` skips
them (its `existsSync` filter only sees sources deployed verbatim), and step 4 —
the only thing that would cover their *artifacts* — is last. Until then a helper
export added to either source ships completely unchecked. Migrating the **source**
is enough: bundlers preserve the entry module's exports, so the artifact inherits
the v1 shape.

- Spine: skip 2 (mechanical); **3 still applies** — `9eb5b0e` was also
  "mechanical."
- Watch: each plugin's own tests reach the hook via the default export and will
  need `pluginModule.server(...)`, as `shell-env.test.ts` did.
- Exit: **all six** repo plugins on the v1 shape; `plugin-loader-contract` green;
  real-process check shows 0 load failures.

## Step 2 — E2 canary log-watch

Cheapest real detection, and it runs **before** the loader patch on purpose.

**Why E2 gates D, rather than merely being cheaper.** D's validate-and-throw
converts the LOUD shape into the QUIET one: a factory returning garbage stops
poisoning the hooks array (visible — 500s, no prompts) and instead gets the file
rejected with a single log line (invisible). *D without E2 manufactures more
32-hour silent failures.* E2 is D's prerequisite.

The weaker argument, which the first draft of this document leaned on: "a health
check would not have caught this." True of the QUIET shape only —
`/config/providers` returned `200` throughout the shell-env breakage — but a
health check *would* have caught the LOUD devbox outage. Do not lead with it.

Upstream reinforces the point: the user-visible event for a plugin load failure
is **commented out** in `index.ts` ("TODO: make proper events"), so the log line
is quite literally the only signal that exists.

- **Positive signal is primary, and it must be BEHAVIOURAL, not log-derived.**
  Assert an observable *effect* of each plugin having loaded — e.g. a probe bash
  call through the door returning `OPENCODE_HOSTNAME`, which is exactly what
  shell-env's absence removed. Do **not** try to assert "plugin X loaded" by
  grepping: upstream emits no per-plugin success line at all (`report.start` is
  a no-op, the loader logs nothing on success), so there is nothing to match.
  An earlier revision of this file specified the log-derived version; it is
  unimplementable, and it replaced a probe that already worked.
  Rationale for keeping positive signal primary: matching known-bad strings
  cannot see failure shapes we have not met yet, and "assert about known-bad" is
  the guard class that already failed here twice. Keep the anchored ERROR grep
  as the secondary, windowed by `run=` or restart offset (see Facts).
- Coverage gap to state plainly: this is a devbox/cloudbox canary, but **macOS
  deploys these same plugins** and has no canary. D is the only macOS cover.
- Spine: consider 2 (alert routing is an open design); **3 applies**.
- Exit: three controls, not two — (a) clean restart is silent; (b) a deliberately
  broken plugin raises the alert; (c) an **import-time** throw also raises it
  (different upstream message, see Residual). Scratch serve must use the
  `XDG_DATA_HOME` recipe in Facts, or the test contaminates the detector.

## Step 3 — D patch the loader

Validate the awaited result before `hooks.push` (`index.ts:119`); prefer
**throw** over silent-skip, consistent with upstream's existing shape-throw.
Land in `opencode-patched` (`patches/`, ~20 existing; none touch the loader) and
open an upstream PR — fable judges it genuinely upstreamable.

Only step that protects plugins we do not author (`superpowers.js`,
`opencode-pigeon.ts`) and cannot lint. **This is the class-killer — do not let
the bead decay into "add more tests."**

- Spine: 2 **recommended** (design is genuinely open); **3 mandatory**; 4 if
  the work splits into fork-patch and upstream-PR tracks.
- Exit: patched loader rejects a non-hook return with a named error; upstream PR
  open; **and the pin guard re-pointed at the fork** — see below.
- **This step breaks the loader pin, by design.** The patch lands in
  `opencode-patched` as a `patched.N` cut, which does not move
  `upstreamVersion`. So the deployed loader diverges from the replica, the
  fixtures, and the `curl`-from-`sst/opencode` recipe in the guard's failure
  message — while `test-loader-pin.sh` stays green. Before this step is done:
  extend the guard to couple `patchedRevision` as well, and re-point the
  fixtures at the fork's patched sources. A pin that cannot see our own patch is
  the same silent-rot failure in a new costume.

## Step 4 — B loader replica vs deployed artifacts in CI

Promote `plugin-loader-contract.test.ts` to run against the **nix-store
artifacts** resolved from `opencode-config.nix`, not repo sources. Closes G2
(build-time export injection) for the artifacts we build: `self-compact.js`,
`session-state.js`, `caveman`.

**It does not close G1, contrary to the first draft.** `superpowers.js` and
`opencode-pigeon.ts` are `mkOutOfStoreSymlink`s into live checkouts of other
repos: they mutate on any `git pull` there, are not nix-store artifacts, and are
invisible to workstation CI by construction. That remainder of G1 belongs to
**D + E2**, and to nothing else.

- Pin drift is now handled mechanically by the `LOADER_VERSION` coupling test —
  no longer a manual "must stay pinned" note.
- **Reassess after D lands.** If the patched loader validates results, this step
  is the one most at risk of being the "add more tests" outcome the bead warns
  against. Do not cut it yet — the upstream PR may stall, and until it lands this
  is the only CI-side cover — but cut it honestly if D makes it redundant.
- Exit: CI fails on a deliberately broken deployed artifact.

---

## Known residual (not scheduled)

**Trigger-time hook throw.** A factory returning a *valid-looking* hooks object
whose hook throws when triggered. `trigger` uses `Effect.promise`, not
`tryPromise`, so there is no per-hook catch and the request 500s. Neither step 3
nor step 4 catches this.

**Import-time throw** (bead gap G4, dropped from the first draft of this file).
A module that throws while being imported fails earlier, in `loadExternal`'s
`entry` stage, which calls `publishPluginError` — **an event, with no
`logError`**. So the likely answer is that *no line reaches the log at all*,
making this invisible to any log-watching detector including step 2's secondary
grep. This is the strongest single argument for the behavioural positive signal
above: it is the only proposed mechanism that would notice. Step 2 must test
this shape as its third control and record what it observes.

Both are filed here so they are not rediscovered as surprises.

## Out of scope

`global-ro` / anchor-serve is owned by the frontdoor session. Do not start it.
