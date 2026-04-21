# Self-Compact Plugin Bundle: Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the working-tree-symlink deployment of the self-compact opencode plugin with a Nix-built, self-contained JavaScript bundle. After this lands, any fresh machine running `home-manager switch` against this flake gets a working `self_compact_and_resume` tool with zero manual `bun install` steps and no network access during activation.

**Architecture:** Two-stage Nix derivation in `pkgs/self-compact-plugin/`. Stage 1 is a fixed-output derivation (FOD) that runs `bun install --frozen-lockfile` and outputs `node_modules/`. Stage 2 is a regular derivation that copies sources + `node_modules`, runs `bun build --target=bun --format=esm`, runs a `checkPhase` that loads the built artifact under `bun --no-install` (matching opencode's runtime exactly), and outputs `$out/self-compact.js` plus a sourcemap. `users/dev/opencode-config.nix` is updated to register the bundled `.js` from the nix store path instead of the `.ts` symlink.

**Tech Stack:** Bun 1.3.3, `Bun.build`, Nix flakes, home-manager, `pkgs.bun` from nixpkgs, FOD pattern.

---

## RESUMPTION CONTEXT (read first if you're picking this up post-compaction)

This plan implements `docs/plans/2026-04-21-self-compact-bundle-design.md` (v3 of the self-compact deployment story). Read the design doc FIRST. It explains why we're doing this and what the alternatives were (Options 1–4 considered, ChatGPT recommended this hybrid).

Prior work on `main`:
- v2 self-compact runtime architecture (idle-triggered summarize) — committed and smoke-tested 2026-04-21. See `docs/plans/2026-04-21-self-compact-idle-trigger-plan.md`.
- v1 design doc with addendum explaining the v2 reversal: `docs/plans/2026-04-20-self-compact-plugin-design.md`.

Today's working state on devbox: plugin still doesn't load (no `node_modules` in working tree). Manual `bun install` in `assets/opencode/plugins/` is the workaround. **This plan eliminates the workaround.**

ChatGPT research (still on disk): `/tmp/research-opencode-plugin-deps-question.md`, `/tmp/research-opencode-plugin-deps-answer.md`. Key recommendations from ChatGPT we MUST honor:
- Move `@opencode-ai/plugin` from devDeps to deps, exact-pin (no `^`).
- Use the modern text `bun.lock` (NOT binary `bun.lockb`). Bun 1.2+ default.
- Force `--linker hoisted` (Bun's default may be `isolated` in some configs, which breaks our resolution model).
- Use `--frozen-lockfile --ignore-scripts` for safety.
- Smoke test by loading the BUILT bundle under `bun --no-install`, not the source with a warmed cache.

Key files of interest:
- `assets/opencode/plugins/self-compact.ts` (entry, 74 lines)
- `assets/opencode/plugins/self-compact-impl.ts` (helpers, 278 lines)
- `assets/opencode/plugins/package.json` (deps + scripts)
- `assets/opencode/plugins/test/self-compact.test.ts` (26 unit tests, untouched by this plan)
- `users/dev/opencode-config.nix` lines ~108-130 (current registration)
- `flake.nix` line ~53-60 (`localPkgsFor` definition)
- `pkgs/beads/default.nix`, `pkgs/dd-cli/default.nix`, `pkgs/gws/default.nix` for derivation conventions

Subagent dispatch (per `.opencode/AGENTS.md`):
- `implementer` — implementation tasks
- `spec-reviewer` — spec compliance review
- `code-reviewer` — code quality review
- `explore` — read-only research

Environment quirks (carry over):
- Branch: `main`. No worktrees per established convention.
- Every commit MUST use `--no-gpg-sign` (gpg-agent unresponsive on cloudbox).
- No `sleep` in bash (hangs); use bounded loops or `timeout`.
- Host is cloudbox; home-manager target is `.#cloudbox` (NOT `.#dev`).
- DO NOT push without explicit user OK.
- Bash: use `setsid nohup ... < /dev/null > /tmp/log 2>&1 & disown` for detached background.

---

## Task 0: Verify environment + bun version + flake state

**Files:** none

**Why:** Sanity check before touching code. If Bun is < 1.2 we need to handle the lockfile differently; if the working tree is dirty we need to know.

**Step 1: Check Bun version (must be ≥ 1.2.0 for text lockfile default)**

Run: `bun --version`
Expected: `1.3.3` or higher.

**Step 2: Check flake builds clean**

Run: `nix flake check --no-build 2>&1 | head -20`
Expected: no errors.

**Step 3: Check working tree clean**

Run: `git status`
Expected: `nothing to commit, working tree clean`.

**Step 4: Check we're on main, in sync with origin**

Run: `git rev-parse --abbrev-ref HEAD && git status -sb`
Expected: `main`, `## main...origin/main` (no `[ahead N]` or `[behind N]`).

**Step 5: No commit. Just record findings in chat.**

If any check fails, STOP and resolve before proceeding.

---

## Task 1: Update package.json — move @opencode-ai/plugin to deps + exact-pin

**Files:**
- Modify: `assets/opencode/plugins/package.json`

**Step 1: Read current package.json**

Run: `cat assets/opencode/plugins/package.json`

Expected current shape:
```json
{
  "name": "workstation-opencode-plugins",
  "private": true,
  "version": "0.1.0",
  "type": "module",
  "scripts": { ... },
  "devDependencies": {
    "@opencode-ai/plugin": "^1.1.19",
    "@opencode-ai/sdk": "^1.1.55",
    "@types/node": "^22.0.0",
    "typescript": "^5.7.3",
    "vitest": "^3.0.0"
  }
}
```

**Step 2: Look up the current installed version of @opencode-ai/plugin**

Run: `cat assets/opencode/plugins/node_modules/@opencode-ai/plugin/package.json | grep '"version"'`
Expected: a specific version string (e.g., `"version": "1.1.19"`). Note this exact value.

If `node_modules` is missing on this machine, run `cd assets/opencode/plugins && bun install` first. Don't commit; this is just to read the version.

**Step 3: Edit package.json**

Move `@opencode-ai/plugin` from `devDependencies` to a new `dependencies` block, and exact-pin to the version observed in Step 2 (NO `^`):

```json
{
  "name": "workstation-opencode-plugins",
  "private": true,
  "version": "0.1.0",
  "type": "module",
  "scripts": {
    "test": "vitest run --passWithNoTests",
    "test:watch": "vitest",
    "typecheck": "npx tsc --noEmit"
  },
  "dependencies": {
    "@opencode-ai/plugin": "<EXACT_VERSION>"
  },
  "devDependencies": {
    "@opencode-ai/sdk": "^1.1.55",
    "@types/node": "^22.0.0",
    "typescript": "^5.7.3",
    "vitest": "^3.0.0"
  }
}
```

**Step 4: Regenerate lockfile**

Run: `cd assets/opencode/plugins && rm -rf node_modules bun.lockb bun.lock package-lock.json && bun install --save-text-lockfile`

Expected: creates a fresh `bun.lock` (text format) and `node_modules/`.

Verify text lockfile created:
Run: `head -5 assets/opencode/plugins/bun.lock`
Expected: starts with `# This file is generated by Bun.` or similar plain-text header (NOT a binary blob).

**Step 5: Run existing vitest suite to verify deps still work**

Run: `cd assets/opencode/plugins && npm test 2>&1 | tail -10`
Expected: `Test Files  1 passed (1)` and `Tests  26 passed (26)`.

**Step 6: Commit**

```bash
git add assets/opencode/plugins/package.json
# Note: bun.lock added in Task 2 after .gitignore update
git commit --no-gpg-sign -m "chore(self-compact): move @opencode-ai/plugin to dependencies, exact-pin

Per ChatGPT research recommendation: a runtime value import (we use
'tool' from this package, not just types) belongs in dependencies, not
devDependencies. Exact pin (no ^) so the Nix derivation's bundle is
reproducible — any version bump is an explicit, reviewable change."
```

---

## Task 2: Update .gitignore + commit bun.lock

**Files:**
- Modify: `assets/opencode/plugins/.gitignore`
- Create: (just adds, file already created in Task 1) `assets/opencode/plugins/bun.lock` (now committed)

**Step 1: Read current .gitignore**

Run: `cat assets/opencode/plugins/.gitignore`

Expected current content:
```
node_modules/
package-lock.json
```

**Step 2: Replace .gitignore**

Write:
```
node_modules/
package-lock.json
dist/
```

The reasoning:
- `node_modules/` stays ignored (we don't want to commit fetched packages).
- `package-lock.json` stays ignored (we use Bun, not npm; this avoids drift if someone accidentally runs `npm install`).
- `dist/` is new (in case a developer locally runs `bun build` for debugging; we don't want to track those outputs).
- `bun.lock` is NOT in .gitignore — it WILL be committed.

**Step 3: Verify bun.lock would be tracked**

Run: `git check-ignore -v assets/opencode/plugins/bun.lock 2>&1; echo "exit: $?"`
Expected: exit code 1 (not ignored).

**Step 4: Stage the lockfile and .gitignore**

```bash
git add assets/opencode/plugins/.gitignore assets/opencode/plugins/bun.lock
```

**Step 5: Commit**

```bash
git commit --no-gpg-sign -m "chore(self-compact): commit bun.lock for reproducible Nix builds

The Nix derivation in pkgs/self-compact-plugin/ (next commit) will use
'bun install --frozen-lockfile' to fetch deps, which requires the
lockfile to be present in the source. Bun 1.2+ default lockfile is the
text 'bun.lock' (NOT binary 'bun.lockb'); diff-friendly and safe to
commit.

Also add dist/ to .gitignore for developers who locally run 'bun build'
to debug the bundle."
```

---

## Task 3: Add bunfig.toml to force hoisted linker

**Files:**
- Create: `assets/opencode/plugins/bunfig.toml`

**Why:** Bun's `install.linker` setting may default to `isolated` in some configurations, which creates a non-standard `node_modules` layout that breaks the upward-walk resolution opencode's runtime relies on. Force `hoisted` explicitly.

**Step 1: Create bunfig.toml**

Write `assets/opencode/plugins/bunfig.toml`:
```toml
# Force the classic Node-style hoisted node_modules layout.
# Our deployment story (and opencode's plugin runtime) relies on the
# standard upward-walk module resolution; the alternative "isolated"
# linker creates a structure that breaks this.
[install]
linker = "hoisted"
```

**Step 2: Verify Bun honors it — re-install fresh with the new bunfig**

Run: `cd assets/opencode/plugins && rm -rf node_modules && bun install --frozen-lockfile`
Expected: `node_modules/` created with `@opencode-ai/plugin` directly accessible at `node_modules/@opencode-ai/plugin/` (not nested under some indirection).

Verify shape:
Run: `ls assets/opencode/plugins/node_modules/@opencode-ai/`
Expected: `plugin` and `sdk` (or just `plugin`; sdk may be in devDeps so absent).

**Step 3: Re-run vitest to confirm nothing regresses**

Run: `cd assets/opencode/plugins && npm test 2>&1 | tail -5`
Expected: `Tests  26 passed (26)`.

**Step 4: Commit**

```bash
git add assets/opencode/plugins/bunfig.toml
git commit --no-gpg-sign -m "chore(self-compact): force hoisted linker via bunfig.toml

Bun's install.linker may default to 'isolated' in some configurations,
which creates a non-standard node_modules layout that breaks opencode's
plugin runtime (which relies on the classic upward-walk module
resolution). Pin to 'hoisted' explicitly so our Nix derivation and any
local 'bun install' produce the same layout regardless of Bun config
elsewhere."
```

---

## Task 4: Write Nix derivation skeleton with placeholder hash

**Files:**
- Create: `pkgs/self-compact-plugin/default.nix`

**Step 1: Read an existing pkgs/* derivation for convention**

Run: `cat pkgs/beads/default.nix`
Read it to see how the workstation packages typically structure a derivation (callPackage args, mkDerivation args, etc.).

**Step 2: Read pkgs/dd-cli/default.nix for a Python equivalent (different language but same pattern)**

Run: `cat pkgs/dd-cli/default.nix | head -40`

**Step 3: Create the derivation file**

Write `pkgs/self-compact-plugin/default.nix`:

```nix
# Builds the self-compact opencode plugin as a self-contained JavaScript
# bundle. See docs/plans/2026-04-21-self-compact-bundle-design.md for full
# design rationale.
#
# Two stages:
#   1. nodeModules — a fixed-output derivation (FOD) that runs
#      `bun install --frozen-lockfile` and outputs node_modules/. Network
#      access requires FOD; the outputHash only changes when bun.lock
#      changes.
#   2. bundle — a regular derivation that copies sources + node_modules,
#      runs `bun build --target=bun --format=esm`, and runs a checkPhase
#      that loads the built artifact under `bun --no-install` (matching
#      opencode's runtime exactly). Outputs $out/self-compact.js (+ map).
{ lib
, stdenvNoCC
, bun
, cacert
}:

let
  pluginSrc = ../../assets/opencode/plugins;

  # Stage 1: fetch deps as an FOD. outputHash MUST be updated when
  # bun.lock changes. To bootstrap or refresh:
  #   1. Set outputHash to lib.fakeHash
  #   2. Run `nix build .#self-compact-plugin` and let it fail
  #   3. Copy the "got: sha256-..." line into outputHash
  nodeModules = stdenvNoCC.mkDerivation {
    pname = "self-compact-plugin-node-modules";
    version = "0.1.0";

    # Only the install-input files matter for the FOD hash; including the
    # source files would make the hash churn on every plugin code change.
    src = lib.cleanSourceWith {
      src = pluginSrc;
      filter = path: type:
        let base = builtins.baseNameOf path;
        in builtins.elem base [ "package.json" "bun.lock" "bunfig.toml" ];
    };

    nativeBuildInputs = [ bun cacert ];

    dontConfigure = true;

    buildPhase = ''
      runHook preBuild

      export HOME=$TMPDIR
      export BUN_INSTALL_CACHE_DIR=$TMPDIR/.bun-cache

      bun install \
        --frozen-lockfile \
        --production \
        --ignore-scripts \
        --no-progress

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp -R node_modules $out/
      runHook postInstall
    '';

    # FOD: hash the entire output tree. Allows network access to bun's
    # registry, but locks the result so subsequent builds are pure.
    outputHashMode = "recursive";
    outputHashAlgo = "sha256";
    outputHash = lib.fakeHash;  # PLACEHOLDER — replace after first build

    dontFixup = true;
  };

  # Stage 2: bundle the plugin as a self-contained .js. Pure derivation
  # (no network); takes nodeModules as a Nix input.
  bundle = stdenvNoCC.mkDerivation {
    pname = "self-compact-plugin";
    version = "0.1.0";

    src = pluginSrc;

    nativeBuildInputs = [ bun ];

    dontConfigure = true;

    buildPhase = ''
      runHook preBuild

      # Bun.build needs node_modules in the build dir to resolve imports.
      ln -s ${nodeModules}/node_modules ./node_modules

      mkdir -p dist

      bun build self-compact.ts \
        --target=bun \
        --format=esm \
        --outfile=dist/self-compact.js \
        --sourcemap=external

      runHook postBuild
    '';

    doCheck = true;

    checkPhase = ''
      runHook preCheck

      # Smoke test: load the bundle exactly the way opencode's runtime
      # does. With --no-install, Bun cannot fall back to auto-install,
      # so any unbundled @opencode-ai/plugin reference would fail here.
      bun --no-install -e "
        const m = await import('$PWD/dist/self-compact.js');
        if (typeof m.default !== 'function') {
          console.error('FAIL: Expected default export to be a plugin factory function, got:', typeof m.default);
          process.exit(1);
        }
        console.log('OK: bundle loads cleanly under --no-install; default export is a function.');
      "

      runHook postCheck
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp dist/self-compact.js $out/
      cp dist/self-compact.js.map $out/ 2>/dev/null || true
      runHook postInstall
    '';

    dontFixup = true;
  };
in
bundle
```

**Step 4: Don't commit yet — derivation incomplete (placeholder hash). Move to Task 5.**

---

## Task 5: Wire derivation into flake.nix as localPkgs.self-compact-plugin

**Files:**
- Modify: `flake.nix` (the `localPkgsFor` block)

**Step 1: Read current localPkgsFor block**

Run: `grep -B1 -A15 "localPkgsFor = system:" flake.nix`

Expected current shape:
```nix
localPkgsFor = system: let p = pkgsFor system; in {
  acli = p.callPackage ./pkgs/acli { };
  beads = p.callPackage ./pkgs/beads { };
  gclpr = p.callPackage ./pkgs/gclpr { };
  gws = p.callPackage ./pkgs/gws { };
  oc-cost = p.callPackage ./pkgs/oc-cost { };
  # ... etc
};
```

**Step 2: Add self-compact-plugin entry**

Insert (alphabetically between `oc-cost` and the next entry, or at the appropriate sorted position):

```nix
  self-compact-plugin = p.callPackage ./pkgs/self-compact-plugin { };
```

**Step 3: Try to build — this WILL fail with the placeholder hash, that's expected**

Run: `nix build .#packages.aarch64-linux.self-compact-plugin 2>&1 | tail -30`

Expected output includes a line like:
```
error: hash mismatch in fixed-output derivation '/nix/store/...-self-compact-plugin-node-modules.drv':
  specified: sha256-AAAA...
       got:    sha256-<REAL_HASH_HERE>
```

**Step 4: Update outputHash with the real hash**

Edit `pkgs/self-compact-plugin/default.nix` and replace `lib.fakeHash` with the real `sha256-...` value from Step 3's output.

**Step 5: Build again — should succeed this time**

Run: `nix build .#packages.aarch64-linux.self-compact-plugin 2>&1 | tail -10`

Expected: build succeeds; the `checkPhase` output shows `OK: bundle loads cleanly under --no-install; default export is a function.`

**Step 6: Verify the output**

Run: `ls -la result/`
Expected: `self-compact.js` (and possibly `self-compact.js.map`).

Run: `head -5 result/self-compact.js`
Expected: starts with bundled JS — likely a comment or `var ...` / `import` etc. NOT TypeScript.

Run: `wc -l result/self-compact.js`
Expected: a couple hundred lines (the bundled output of self-compact.ts + self-compact-impl.ts + @opencode-ai/plugin source + zod source).

Run: `grep -c "@opencode-ai/plugin" result/self-compact.js`
Expected: `0` — the bundler should have inlined and stripped the import string entirely. (If non-zero, investigate; the bundle may still have a runtime reference.)

**Step 7: Run the smoke test manually too as a belt-and-braces check**

Run: `bun --no-install -e "const m = await import('$PWD/result/self-compact.js'); console.log('default type:', typeof m.default);"`
Expected: `default type: function`.

**Step 8: Commit both changes (derivation + flake.nix wiring)**

```bash
git add pkgs/self-compact-plugin/default.nix flake.nix
git commit --no-gpg-sign -m "feat(self-compact): build plugin as self-contained Nix bundle

Two-stage derivation: an FOD for node_modules (network-required, hash
keyed to bun.lock) plus a regular derivation that runs Bun.build
producing dist/self-compact.js (with external sourcemap) and a
checkPhase smoke test that loads the bundle under 'bun --no-install'
(matching opencode's runtime exactly).

This phase only adds the package; the next commit switches the
opencode-config registration to consume it. Verified locally:
'nix build .#self-compact-plugin' succeeds and the checkPhase passes."
```

---

## Task 6: Switch opencode-config.nix registration from .ts symlink to .js bundle

**Files:**
- Modify: `users/dev/opencode-config.nix`

**Step 1: Read current self-compact registration block**

Run: `sed -n '108,135p' users/dev/opencode-config.nix`

Expected: a block including `mkOutOfStoreSymlink` for `opencode/plugins/self-compact.ts`.

**Step 2: Replace the block**

Replace:
```nix
   # OpenCode plugins deployed via out-of-store symlink (path resolved at activation, not eval)
   # self-compact uses runtime value imports from `@opencode-ai/plugin` (the `tool` helper)
   # and needs `zod`, so it must deploy from a path with a co-located `node_modules`.
   # See docs/plans/2026-04-20-self-compact-plugin-design.md for the deferred refactor
   # to a config-dir `package.json` + real-file approach (cleaner long-term).
    xdg.configFile."opencode/plugins/self-compact.ts".source =
      config.lib.file.mkOutOfStoreSymlink (
        if isDarwin
        then "${config.home.homeDirectory}/Code/workstation/assets/opencode/plugins/self-compact.ts"
        else "${config.home.homeDirectory}/projects/workstation/assets/opencode/plugins/self-compact.ts"
      );
```

With:
```nix
    # self-compact deployed as a Nix-built self-contained JS bundle.
    # See docs/plans/2026-04-21-self-compact-bundle-design.md.
    # The bundle inlines @opencode-ai/plugin and zod, so no node_modules
    # is needed at runtime; opencode loads the .js directly.
    xdg.configFile."opencode/plugins/self-compact.js".source =
      "${localPkgs.self-compact-plugin}/self-compact.js";
    # Sourcemap deployed alongside the bundle for stack-trace readability.
    xdg.configFile."opencode/plugins/self-compact.js.map".source =
      "${localPkgs.self-compact-plugin}/self-compact.js.map";
```

**Step 3: Verify localPkgs is available in scope**

Run: `grep -n "localPkgs" users/dev/opencode-config.nix | head -5`

Expected: at least one existing reference (e.g., for atlassian-mcp helpers). If `localPkgs` is in the function args at the top of the file (line 4 area), we're good. Otherwise add it.

**Step 4: Build the home-manager config to validate Nix evaluation**

Run: `nix build .#homeConfigurations.\"dev@cloudbox\".activationPackage 2>&1 | tail -10`

(Adjust `dev@cloudbox` to whichever target is appropriate; check `flake.nix` for the actual attribute names if unsure.)

Expected: build succeeds.

**Step 5: Apply (optional in this task — final verification is Task 8)**

Don't apply yet. We'll apply once everything is committed and we want to test end-to-end.

**Step 6: Commit**

```bash
git add users/dev/opencode-config.nix
git commit --no-gpg-sign -m "feat(self-compact): switch deployment to Nix-built bundle

Replace the mkOutOfStoreSymlink for self-compact.ts (which needed a
working-tree node_modules to resolve @opencode-ai/plugin at runtime)
with a static .source registration that points at the bundled .js
output of pkgs/self-compact-plugin/. The bundle is self-contained,
so opencode can load it without any sibling node_modules.

This eliminates the per-machine 'remember to run bun install' footgun
that bit us on devbox earlier today."
```

---

## Task 7: Clean up obsolete files in assets/opencode/plugins/

**Files:**
- (no edits — just verifying state and possibly removing the stale .ts symlink target)

**Step 1: Verify the source .ts file is still in the repo (we still need it for vitest)**

Run: `ls assets/opencode/plugins/self-compact.ts assets/opencode/plugins/self-compact-impl.ts`
Expected: both present.

These ARE still needed — they're the source the Nix derivation builds from, and vitest uses them for unit tests. Don't delete.

**Step 2: Check for any stale references to the old .ts deployment**

Run: `git grep "opencode/plugins/self-compact.ts" -- 'users/' 'docs/' 'assets/' 2>&1 | head`
Expected: only references in design docs (which describe the OLD approach and are correct historically). If there's a reference in `users/` other than `opencode-config.nix`, investigate.

**Step 3: No commit needed for this task.**

If anything surprising surfaces, surface it to the user before continuing.

---

## Task 8: Apply home-manager and verify deployment end-to-end

**Files:** none (deployment + verification)

**Step 1: Confirm uncommitted state is clean**

Run: `git status`
Expected: `nothing to commit, working tree clean` (or only the ChatGPT research files in /tmp, which aren't tracked).

**Step 2: Apply home-manager**

Run: `home-manager switch --flake .#cloudbox 2>&1 | tail -15`

Expected: succeeds. Look for `Activating onFilesChange` and similar standard activations. The `pkgs.self-compact-plugin` derivation should already be cached in the Nix store from Task 5.

**Step 3: Verify the deployed file is the bundled .js**

Run:
```bash
ls -la ~/.config/opencode/plugins/self-compact.js \
       ~/.config/opencode/plugins/self-compact.js.map \
       ~/.config/opencode/plugins/self-compact.ts 2>&1
```

Expected:
- `self-compact.js` exists, is a symlink into the nix store.
- `self-compact.js.map` exists, is a symlink into the nix store.
- `self-compact.ts` does NOT exist (or is removed). If it's still present, it means `home-manager switch` left a stale file behind from the prior generation; verify with `readlink -f` to see if it's pointing at a stale store path or absent.

**Step 4: Verify the deployed bundle loads under bun --no-install**

Run:
```bash
bun --no-install -e "
  const m = await import(process.env.HOME + '/.config/opencode/plugins/self-compact.js');
  console.log('default export type:', typeof m.default);
"
```

Expected: `default export type: function`.

If it FAILS with `Cannot find module '@opencode-ai/plugin'`, the bundle is incomplete — investigate what wasn't bundled.

**Step 5: Live smoke test in a new opencode session**

Open a new opencode session in this directory, in a separate terminal. Then in that session, ask it: "what's the result of typing /tools or running tools? specifically, is `self_compact_and_resume` available?"

(Or, more directly: instruct that session to invoke `preparing-for-compaction`. If the tool is available, the new session should be able to call `self_compact_and_resume`. If unavailable, the agent will report that.)

Expected: tool is available. Skill invocation completes the v2 self-compact flow successfully.

**Step 6: Check the new session's log for plugin load**

Run: `ls -lt ~/.local/share/opencode/log/ | head -3` to find the newest log.

Run: `grep -E "self-compact|loading plugin.*self-compact|failed to load plugin" ~/.local/share/opencode/log/<NEWEST_LOG>`

Expected: a `loading plugin` line for self-compact.js, NO `failed to load plugin` errors related to self-compact.

**Step 7: If smoke test fails, STOP and investigate; do not push.**

If smoke test passes, proceed to Task 9.

**Step 8: No commit in this task** (Task 8 is verification, not code change).

---

## Task 9: Update v1 design doc with v3 supersession addendum

**Files:**
- Modify: `docs/plans/2026-04-20-self-compact-plugin-design.md`

**Step 1: Read the existing addendum**

Run: `grep -n "Status of original architecture" docs/plans/2026-04-20-self-compact-plugin-design.md`

There should be one or more "Status" lines from prior addenda.

**Step 2: Append a v3 status note at the end of the file**

Append:

```markdown

## Addendum 2026-04-21: v3 Deployment Refactor (Nix-Built Bundle)

The "deferred refactor" mentioned in this doc's body — a config-dir
`package.json` plus real-file deployment that lets opencode handle the
node_modules — has been superseded by a different approach: a Nix
derivation that produces a self-contained JavaScript bundle, deployed
directly from the nix store. The bundle inlines `@opencode-ai/plugin`
and zod, so opencode can load it without any sibling `node_modules`.

This eliminates the "did someone run `bun install` here" class of
footguns entirely. Detail in
`docs/plans/2026-04-21-self-compact-bundle-design.md`. Implementation
plan at `docs/plans/2026-04-21-self-compact-bundle-plan.md`.

Status of v3: COMPLETED 2026-04-21. Live-verified on cloudbox (and
devbox after merge). The smoke test in the Nix `checkPhase` ensures the
bundle loads cleanly under `bun --no-install` (matching opencode's
runtime exactly), making the "tool unavailable" regression that
prompted this work impossible to recreate without the build also failing.
```

**Step 3: Commit**

```bash
git add docs/plans/2026-04-20-self-compact-plugin-design.md
git commit --no-gpg-sign -m "docs(self-compact): mark v3 bundle deployment complete

Append addendum noting the v1-deferred refactor has been superseded by
the Nix-built bundle approach (v3). Smoke test in checkPhase makes the
'tool unavailable' regression impossible without the build also failing."
```

---

## Task 10: (Optional) Push when user OKs

**Files:** none (push)

**Step 1: Confirm clean state**

Run: `git status && git log --oneline -10`
Expected: working tree clean, commits ahead of origin.

**Step 2: Wait for explicit user OK to push.**

DO NOT push without it.

**Step 3: When user OKs:**

```bash
git pull --rebase
git push
git status   # should show "up to date with origin"
```

---

## Wrap-up checklist

- [ ] All Task 0–9 commits on `main`
- [ ] `home-manager switch` applied on cloudbox; succeeds
- [ ] `~/.config/opencode/plugins/self-compact.js` exists and loads under `bun --no-install`
- [ ] New opencode session reports `self_compact_and_resume` tool available
- [ ] No `failed to load plugin` errors in the latest opencode log for self-compact
- [ ] v1 design doc has v3 addendum marking work COMPLETED
- [ ] All commits pushed to `origin/main` (post user-OK)

## Risks and mitigations

| Risk | Mitigation |
|------|------------|
| FOD hash differs between aarch64-linux and aarch64-darwin | Test on both during initial bootstrap. If they differ, use `system`-conditional `outputHash`. |
| `bun build` produces ESM that opencode can't load | The `checkPhase` catches this immediately at build time. |
| `tool.schema = z` (zod) somehow lost during bundling | Smoke test in Task 8 Step 4 specifically loads via `await import` and checks the default export type. Doesn't catch broken schema-attached property, but a runtime call from opencode would. Could add a deeper smoke test asserting `m.default(...).then(out => out.tool.self_compact_and_resume.args.prompt instanceof z.ZodString)` if we want to be paranoid. (Out of scope for v3 unless a problem manifests.) |
| Bun version drift between machines (different nixpkgs pins) | nixpkgs is pinned in `flake.lock`; same flake = same Bun version. Cross-machine differences impossible. |
| Bun lockfile drift if developer runs `bun install` outside `--frozen-lockfile` | The Nix build always uses `--frozen-lockfile`, so any drift is caught at build time. Document the expected workflow (`bun install --save-text-lockfile` to update, then commit). |
