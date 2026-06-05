# Retry-cap deploy — THE CURE (Fix 1) for the Vertex/Gemini retry runaway

Worker: `ses_166faf734ffen83FtybOn5O5Y0` (opus, retry-cap deploy / "worker 4").
Date: 2026-06-05. Host: **cloudbox** (aarch64-linux).
Root cause: this dir's `lgtm-retry-rootcause.md` (uncapped per-step LLM retry).

**Status: DEPLOYED to the home-manager profile + verified. The detached
`opencode-serve` restart is the final step (see §8).** The running serve picks up
the capped binary on that restart.

---

## 0. TL;DR

- **The bug:** `packages/opencode/src/session/retry.ts` `policy()` had no attempt
  ceiling. A step on a persistently-retryable condition re-issued the **entire
  billable model stream** every ≤30s **forever** → ~35× amplification of successful
  gemini-3.5-flash Vertex calls (~$1.5–2.5k/overnight).
- **The cure (this deploy):** cap per-step retries at **`MAX_RETRIES = 8`** (1 initial
  + 8 retries = at most 9 stream issues) **+ downward jitter** on the no-header 30s
  backoff to break the thundering herd. Shipped as a new `patches/retry-cap.patch`.
- **Built + deployed:** locally built **`opencode-patched-1.15.13.3`** for aarch64,
  wired into the workstation Nix config, activated via home-manager. Cap confirmed
  present in the built binary.
- **VERSION SAFETY honored:** deployed on the **same 1.15.13 base** that was running.
  Did **not** ship the 1.16.2 base bump (see §2 — a concurrent auto-update had drifted
  the config to an *uncapped* 1.16.2; this deploy reverts that locally).

| | store path | retry cap? |
|---|---|---|
| OLD (running until restart) | `/nix/store/k775j7vkyvnsrzshrysbfl906nwcl0yh-opencode-patched-1.15.13.2` | ❌ no |
| NEW (deployed, profile now) | `/nix/store/wmf3lc23s0avsf2n3311dn0l4bngk1hm-opencode-patched-1.15.13.3` | ✅ yes |
| (accidental drift, rejected) | `/nix/store/nisvz7qiik1vm0h59g2ak4hd75s7zflz-opencode-patched-1.16.2` | ❌ no |

---

## 1. The fix

Two edits to `packages/opencode/src/session/retry.ts` (production), plus tests.

### Production diff (identical on the deployed v1.15.13 base AND the committed v1.16.2 base)

```diff
@@ constants @@
+export const MAX_RETRIES = 8
+export const RETRY_JITTER_RATIO = 0.2
+
 function cap(ms: number) { return Math.min(ms, RETRY_MAX_DELAY) }
+
+// Downward jitter: break the 30s thundering herd; never exceed the ceiling.
+function jitter(ms: number) {
+  return Math.round(ms * (1 - Math.random() * RETRY_JITTER_RATIO))
+}

@@ delay() — no-header exponential path only @@
-  return cap(Math.min(RETRY_INITIAL_DELAY * Math.pow(RETRY_BACKOFF_FACTOR, attempt - 1), RETRY_MAX_DELAY_NO_HEADERS))
+  return cap(jitter(Math.min(RETRY_INITIAL_DELAY * Math.pow(RETRY_BACKOFF_FACTOR, attempt - 1), RETRY_MAX_DELAY_NO_HEADERS)))

@@ policy() — the attempt cap @@
-      if (!retry) return Cause.done(meta.attempt)
+      // meta.attempt is 1-based → `> MAX_RETRIES` allows exactly MAX_RETRIES retries.
+      if (!retry || meta.attempt > MAX_RETRIES) return Cause.done(meta.attempt)
```

### Design choices

- **Cap inside `policy()`** (not `Schedule.recurs` at the processor site): keeps the
  fix in one self-contained, unit-testable function. `meta.attempt` is **1-based**
  (verified empirically; the pre-existing test asserts 2 steps → `attempt: 2`), so
  `meta.attempt > MAX_RETRIES` permits exactly 8 retries → **≤ 9 total billable stream
  issues** per step (was unbounded).
- **Jitter only on the no-header path** (`delay()` line that caps at
  `RETRY_MAX_DELAY_NO_HEADERS = 30_000`): that is precisely the "every 30s forever"
  surface called out in the RCA. **Downward-only** (`× (1 − rand×0.2)` → 80–100% of
  base) so the 30s value stays a true ceiling and decorrelates *at* the ceiling.
  Explicit `retry-after` / `retry-after-ms` header values are **honored exactly** and
  never jittered (the header paths are untouched).

### Patch file

`~/projects/opencode-patched/patches/retry-cap.patch` (156 lines), wired into
`patches/apply.sh` as **Patch 9** and documented in `README.md` §9 + Patch Ownership.

> **Two renderings of the identical fix** (patch-stack is mid-migration):
> - **Committed to the repo:** rendered against **v1.16.2** (repo HEAD target), so
>   `apply.sh` stays green for the repo's current upstream. Validated end-to-end.
> - **As deployed (this host):** rendered against **v1.15.13** (the running base).
>   The **production `retry.ts` hunks are byte-identical** between the two; they differ
>   only in `retry.test.ts` namespace imports (`MessageV2` on 1.15.13 →
>   `SessionV1`/`ProviderV2.ID`/`it.instance` on 1.16.2 — the v1.16.0 namespace
>   migration). Confirmed identical prod hunks via diff.

---

## 2. ⚠️ Critical finding: concurrent 1.16.2 drift (handled, not shipped)

Mid-session the workstation config and home-manager **profile** drifted to an
**uncapped 1.16.2**, independent of this deploy:

- `workstation` commit **`0fab4cc` "chore(deps): update opencode-patched to 1.16.2"**
  (14:28, from `update-opencode-patched.yml` tracking the published v1.16.2-patched
  release) bumped `upstreamVersion 1.15.13→1.16.2`.
- A `home-manager switch` (generation **378**, 14:29) activated
  `opencode-patched-1.16.2` into the profile.
- The published **v1.16.2-patched release has NO retry cap** (it predates this fix).

So at the moment I checked, **restarting `opencode-serve` would have launched an
uncapped 1.16.2** — still buggy *and* an unreviewed base bump the task explicitly
forbids ("DO NOT ship 1.15.13 → 1.16.2"). The running serve itself was still the
original uncapped **1.15.13.2** (confirmed via `/proc/<MainPID>/exe`).

**Resolution:** treated the 1.16.2 bump as automation interference (the orchestrator's
HANDOFF "POST-RESTART RESUME PLAN" consistently treats 1.15.13.2 as the deployed base
with rollback to it). This deploy **reverts the opencode block to the 1.15.13 base
locally** and pins `patchedRevision = "3"` → the locally-built **capped 1.15.13.3**.
The `0fab4cc` commit stays in git history; a local commit supersedes it. A capped
1.16.2 can be shipped later via the normal release pipeline (the patch is already in
the repo, validated against v1.16.2).

---

## 3. Reproducing the deployed base (clean)

- Deployed binary `opencode-patched-1.15.13.2` was built from upstream **opencode
  v1.15.13** + opencode-patched patches at commit **`c122c58`** ("Merge PR #15", the
  release that produced `v1.15.13-patched.2`). The two newer repo commits (`2206498`,
  `a7014c2`) retarget to v1.16.x and are **not** what's deployed.
- `git clone --branch v1.15.13` + `c122c58`'s `apply.sh` → **all 8 patches apply
  cleanly** (exit 0), `session/retry.ts` untouched by the stack, **zero
  `Schedule.recurs`** (matches the deployed binary). Base cleanly reproduced.

## 4. Tests (TDD)

`packages/opencode/test/session/retry.test.ts`:

- Updated the delay test (was exact `[2000,4000,...,30000]`) to assert the **jittered
  band** (`floor(base×0.8) ≤ d ≤ base`) and that samples actually vary.
- Added `describe("session.retry.policy")`:
  - **direct-step**: `Schedule.toStepWithMetadata` schedules exactly `MAX_RETRIES`
    retries then halts (the step fails with the `Cause.done`).
  - **behavioral**: `Effect.retry` of a persistently-failing effect runs exactly
    **`MAX_RETRIES + 1`** times (with a `timeout` guard so an *uncapped* policy fails
    by timeout instead of hanging).

RED → GREEN observed: pre-fix, both new tests failed (the behavioral one timed out —
demonstrating the infinite loop); post-fix all green.

| tree | `bun test test/session/retry.test.ts` |
|---|---|
| v1.15.13 (deployed rendering) | **35 pass / 0 fail** |
| v1.16.2 (committed rendering) | **35 pass / 0 fail** |

`tsc --noEmit` clean for the retry files on both. `apply.sh` (full 9-patch stack)
applies cleanly to a fresh v1.16.2 clone (exit 0, "Retry cap patch applied").

## 5. Build (faithful reproduction)

- Tooling: **bun 1.3.14** (matches `packageManager` pin; cloudbox's default bun 1.3.3
  fails the build's `^1.3.14` gate). Target **aarch64** (cloudbox is aarch64-linux →
  deployed asset is `opencode-linux-arm64.tar.gz`).
- `OPENCODE_VERSION=1.15.13 bun run script/build.ts --single` (current-platform target;
  byte-for-byte the same target config the CI `--all` uses for arm64). Build exit 0,
  **smoke test: `1.15.13`**.
- Packaged exactly like the CI asset: `tar czf ... .` from `dist/opencode-linux-arm64/`
  → `./bin/opencode` at root.
  - `/home/dev/.cache/opencode-retry-cap-deploy/opencode-linux-arm64.tar.gz`
  - sha256 `5a17fa10bd76a34e9565382d3d25ca4f993ea8a01111f838caaa5189fd447179`

## 6. Deploy (workstation Nix) + verification

`users/dev/home.base.nix` opencode block edited: revert to `upstreamVersion =
"1.15.13"`, `patchedRevision = "3"`, restore the four 1.15.13.2 platform hashes, and
for **aarch64-linux** point `src` at the local tarball (other platforms keep the
released `fetchurl`, unused on cloudbox).

- Built + activated via `nix build --impure .#homeConfigurations.cloudbox.activationPackage`
  + the generation's `activate` (exactly what `home-manager switch` runs post-build).
  `--impure` is required because the deploy injects a local build artifact (a `/home`
  path literal is forbidden in pure flake eval).
- New home-manager generation **id 379**
  (`/nix/store/mwljsvypsc1cnb0hz1m2x1bg212dfi39-home-manager-generation`).

**Verification of the deployed binary** (the path the serve wrapper execs,
`/home/dev/.nix-profile/bin/opencode`):

- Resolves to **`/nix/store/wmf3lc23s0avsf2n3311dn0l4bngk1hm-opencode-patched-1.15.13.3`**
  — **differs from the old k775 path** ✅. `--version` → `1.15.13`.
- Cap present in the built (minified) JS:
  - attempt cap: `if(!e||j.attempt>Ob)` with `Ob=8` (i.e. `meta.attempt > MAX_RETRIES`)
  - jitter: `Math.round(A*(1-Math.random()*yb))` with `yb` = `RETRY_JITTER_RATIO` (`0.2`)
  - `MAX_RETRIES`/`RETRY_JITTER_RATIO` present in the `SessionRetry` export map
  - (the OLD k775 binary has **zero** of the jitter marker — confirmed discriminator)

The serve wrapper (`exec /home/dev/.nix-profile/bin/opencode serve --port 4096 ...`)
will launch this capped binary on its next (re)start. Until restart, the running
serve (MainPID, `/proc/.../exe`) is still the old uncapped k775 1.15.13.2.

## 7. ROLLBACK

The deploy is fully reversible. Pick either:

**A. Activate the prior known-good generation (fastest, recommended):**
generation **377** holds the original uncapped-but-stable
`opencode-patched-1.15.13.2` (k775):
```bash
/nix/store/pw2xp5nl1ssvzncmf5l8srlvg6wy2png-home-manager-generation/activate
sudo systemctl restart opencode-serve.service   # to swap the running process
```
(Do NOT roll back to generation **378** — that is the *uncapped 1.16.2* drift.)

**B. Revert the config commit + re-switch:**
```bash
cd ~/projects/workstation
git revert <this-deploy-commit>        # or: git checkout HEAD~1 -- users/dev/home.base.nix
nix run home-manager -- switch --flake ~/projects/workstation#cloudbox   # (real release; no --impure needed)
sudo systemctl restart opencode-serve.service
```

Old store path (rollback reference):
`/nix/store/k775j7vkyvnsrzshrysbfl906nwcl0yh-opencode-patched-1.15.13.2`.

## 8. Restart (final step — issued AFTER this report + commits)

Restarting `opencode-serve` kills this worker's own session (and the aigateway
worker `ses_1670df706ffeIwMdzaEcSoTaGA` — accepted; orchestrator resumes it via the
HANDOFF resume plan). So it is fired detached, last:

```bash
setsid nohup bash -c 'sleep 5; /run/wrappers/bin/sudo -n /run/current-system/sw/bin/systemctl restart opencode-serve.service' </dev/null >/tmp/retry-cap-deploy.log 2>&1 & disown
```

After restart, confirm: `systemctl status opencode-serve` active (just started);
`readlink -f /proc/$(systemctl show opencode-serve.service -p MainPID --value)/exe`
→ `...wmf3lc23...-opencode-patched-1.15.13.3...`; `/tmp/retry-cap-deploy.log` for output.

## 9. Commits (local only — NOT pushed)

- `opencode-patched`: add `patches/retry-cap.patch` (v1.16.2-rendered) + wire into
  `apply.sh` (Patch 9) + `README.md`.
- `workstation`: `users/dev/home.base.nix` — revert accidental 1.16.2 auto-bump; pin
  local capped `1.15.13.3` build for aarch64 (this is a local-deploy override, not a
  publishable change).

## 10. Follow-ups (not in scope here)

- Publish a proper capped release (e.g. `v1.16.2-patched.1` built **with**
  retry-cap.patch) via the normal pipeline, then bump workstation off the local pin.
- Fix 2 (config hardening): non-gemini `compaction`/default model to shrink blast radius.
- Watch the next overnight cycle (forward-capture log + BQ) to confirm the cap holds.
