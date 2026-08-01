# Plugin-Loader Hardening Roadmap

**Bead:** `workstation-5yox` (P1) · **Started:** 2026-08-01 · **Status:** step 0 shipped

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

**Scratch serves must scrub routing env**, or our own guard kills them:

```bash
env -u OPENCODE_SERVE_ID -u OPENCODE_ROUTING_DB opencode serve --port <scratch>
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

1. **Compact** — `preparing-for-compaction`. Persist to `workstation-5yox` and
   update this file *before* compacting, not after.
2. **Consult `oracle-fable`** *(optional)* — when the design is genuinely open.
   Skip for mechanical steps.
3. **SDD** *(if applicable)* — `subagent-driven-development` when the step
   splits into independent tasks; dispatch `implementer`, then `spec-reviewer`.
   Skip for single-file changes.
4. **`adversarial-reviewer-fable`** — **mandatory, before writing code.** Every
   time this was skipped in this bead's history, the result was wrong. Fable
   caught the broken remediation that shipped to production.
5. **PR** *(if applicable)* — throwaway worktree off `origin/main`, never the
   shared checkout. Body states what was verified *and how*.
6. **Update roadmap** — tick the step here, file new beads for anything
   discovered, note what the next step inherits.

> Steps 2 and 4 both name the `fable` variants, which are otherwise
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

**Files:** `compaction-context.ts`, `session-header.ts`, `subagent-routing.ts`.

They are safe *today* only because they happen to have zero named runtime
exports. Any future helper export is an outage. Migrate each to
`export default { id: "<name>", server: plugin }` so the property holds by
construction.

- Spine: skip 2 and 3 (mechanical); **4 still applies**.
- Watch: each plugin's own tests reach the hook via the default export and will
  need `pluginModule.server(...)`, as `shell-env.test.ts` did.
- Exit: all four repo plugins on the v1 shape; `plugin-loader-contract` green;
  real-process check shows 0 load failures.

## Step 2 — E2 canary log-watch

Cheapest real detection, and the highest-value step. **A health check would not
have caught this**: `/config/providers` returned `200` throughout the entire
shell-env breakage. Three for three, the evidence was in a log nobody read.

- Have the serve canary grep the serve log after each restart, using the
  anchored pattern above; add an `OPENCODE_HOSTNAME` probe as a positive signal.
- Spine: consider 2 (where alerts route is open); **4 applies**.
- Exit: a deliberately broken plugin in a scratch dir raises the alert; a clean
  restart does not. Both controls, or it does not count.

## Step 3 — D patch the loader

Validate the awaited result before `hooks.push` (`index.ts:119`); prefer
**throw** over silent-skip, consistent with upstream's existing shape-throw.
Land in `opencode-patched` (`patches/`, ~20 existing; none touch the loader) and
open an upstream PR — fable judges it genuinely upstreamable.

Only step that protects plugins we do not author (`superpowers.js`,
`opencode-pigeon.ts`) and cannot lint. **This is the class-killer — do not let
the bead decay into "add more tests."**

- Spine: 2 **recommended**; 3 if it splits fork/upstream; 4 mandatory.
- Exit: patched loader rejects a non-hook return with a named error; upstream PR
  open.

## Step 4 — B loader replica vs deployed artifacts in CI

Promote `plugin-loader-contract.test.ts` to run against the **nix-store
artifacts** resolved from `opencode-config.nix`, not repo sources. Closes G1/G2:
build-time export injection, and the plugins built elsewhere.

- Must stay pinned to the upstream tag or the replica drifts into fiction.
- Exit: CI fails on a deliberately broken deployed artifact.

---

## Known residual (not scheduled)

A factory returning a **valid-looking** hooks object whose hook throws at
trigger time. `trigger` uses `Effect.promise`, not `tryPromise`, so there is no
per-hook catch and the request 500s. Neither step 3 nor step 4 catches this.
Filed here so it is not rediscovered as a surprise.

## Out of scope

`global-ro` / anchor-serve is owned by the frontdoor session. Do not start it.
