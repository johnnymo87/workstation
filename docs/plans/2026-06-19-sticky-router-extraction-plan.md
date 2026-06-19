# StickyRouter Extraction Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (or
> superpowers:subagent-driven-development) to implement this plan task-by-task.

**Goal:** Extract `claude-failover-proxy`'s pure `SessionRouter` into a standalone
private `sticky-router` package generalized to `StickyRouter<Key, Target>`, and
refactor the proxy to consume it — with zero behavior change.

**Architecture:** Pure, deterministic, zero-dependency TS library exposing a
`route(key, nowMs, desired)` + `sweep(nowMs, ttlMs)` stickiness state machine.
The caller computes `desired`; the library only does pin / idle-migrate / sweep.
Consumed by both `claude-failover-proxy` (egress) and the future pigeon ingress
router (`zao4`) as a tagged git dependency.

**Tech Stack:** TypeScript, bun (`bun test`), biome 2.4.15, `tsc` for the dist
build. Git-dependency distribution (committed `dist/` so consumers need no build).

**Design doc:** `docs/plans/2026-06-19-sticky-router-extraction-design.md`

**Conventions to mirror (from `claude-failover-proxy`):** biome — space/2,
`semicolons: asNeeded`, `quoteStyle: single`, `trailingCommas: all`; tsconfig
extends `@tsconfig/bun`, `strict: true`, `noUncheckedIndexedAccess: true`.

---

## Task 1: Scaffold the `sticky-router` repo

**Files:**
- Create: `~/projects/sticky-router/package.json`
- Create: `~/projects/sticky-router/tsconfig.json`
- Create: `~/projects/sticky-router/tsconfig.build.json`
- Create: `~/projects/sticky-router/biome.json`
- Create: `~/projects/sticky-router/.gitignore`
- Create: `~/projects/sticky-router/README.md`

**Step 1: Create dir and init**

```bash
mkdir -p ~/projects/sticky-router/src
cd ~/projects/sticky-router && git init -q
```

**Step 2: Write `package.json`**

```json
{
  "name": "sticky-router",
  "version": "0.1.0",
  "type": "module",
  "main": "dist/index.js",
  "types": "dist/index.d.ts",
  "exports": {
    ".": {
      "types": "./dist/index.d.ts",
      "default": "./dist/index.js"
    }
  },
  "files": ["dist", "src"],
  "scripts": {
    "build": "tsc -p tsconfig.build.json",
    "prepare": "tsc -p tsconfig.build.json",
    "test": "bun test",
    "typecheck": "tsc --noEmit",
    "format": "biome check --write .",
    "lint": "biome lint ."
  },
  "devDependencies": {
    "@biomejs/biome": "2.4.15",
    "@tsconfig/bun": "^1.0.10",
    "@types/bun": "latest",
    "typescript": "^5.7.3"
  }
}
```

**Step 3: Write `tsconfig.json` (editor/typecheck — includes tests)**

```json
{
  "extends": "@tsconfig/bun/tsconfig.json",
  "compilerOptions": {
    "strict": true,
    "noUncheckedIndexedAccess": true
  }
}
```

**Step 4: Write `tsconfig.build.json` (emit dist from src only)**

```json
{
  "extends": "@tsconfig/bun/tsconfig.json",
  "compilerOptions": {
    "strict": true,
    "noUncheckedIndexedAccess": true,
    "declaration": true,
    "outDir": "dist",
    "rootDir": "src",
    "noEmit": false,
    "module": "ESNext",
    "moduleResolution": "Bundler",
    "skipLibCheck": true
  },
  "include": ["src/index.ts"]
}
```

**Step 5: Write `biome.json`** (copy of cfp's, minus the bun-specific bits — keep
the test override)

```json
{
  "$schema": "https://biomejs.dev/schemas/2.4.15/schema.json",
  "formatter": { "indentStyle": "space", "indentWidth": 2 },
  "javascript": {
    "formatter": {
      "semicolons": "asNeeded",
      "trailingCommas": "all",
      "quoteStyle": "single"
    }
  },
  "linter": { "enabled": true },
  "files": { "ignoreUnknown": true, "includes": ["src/**", "*.json"] },
  "overrides": [
    {
      "includes": ["**/*.test.ts"],
      "linter": {
        "rules": {
          "suspicious": { "noExplicitAny": "off" },
          "style": { "noNonNullAssertion": "off" },
          "correctness": { "noUnusedFunctionParameters": "off" }
        }
      }
    }
  ]
}
```

**Step 6: Write `.gitignore`** (note: `dist/` is intentionally NOT ignored — it
is committed so git-dep consumers need no install-time build)

```
node_modules/
*.log
```

**Step 7: Write minimal `README.md`**

```markdown
# sticky-router

Pure, deterministic `StickyRouter<Key, Target>`: a sticky + idle-migration
routing state machine. Caller supplies the desired target; the router pins new
keys, migrates only after a key has been idle >= `idleMigrateMs`, and sweeps
stale entries. No IO, no deps. See
`workstation/docs/plans/2026-06-19-sticky-router-extraction-design.md`.

## Usage

\`\`\`ts
import { StickyRouter } from 'sticky-router'
const r = new StickyRouter<string, string>(300_000)
r.route('session-1', Date.now(), 'serve-a') // => 'serve-a'
r.sweep(Date.now(), 3_600_000)
\`\`\`
```

**Step 8: Install dev deps and commit**

```bash
cd ~/projects/sticky-router && bun install
git add -A && git commit -q -m "chore: scaffold sticky-router package"
```
Expected: `bun install` succeeds; commit created.

---

## Task 2: TDD the `StickyRouter` state machine

**Files:**
- Create: `~/projects/sticky-router/src/index.ts`
- Test: `~/projects/sticky-router/src/index.test.ts`

**Step 1: Write the failing test file** (ports the seed's full branch coverage,
generalized; `desired` is computed by a local helper to mirror the egress proxy,
plus a generic non-backend `Target` test to prove genericity)

```ts
import { expect, test } from 'bun:test'
import { StickyRouter } from './index'

const IDLE = 300_000 // ms
const t0 = 1_000_000

// Mirror the egress proxy's desired calc so ported tests read like the seed.
type Backend = 'vertex' | 'max'
const desired = (overBudget: boolean, maxAvailable: boolean): Backend =>
  overBudget && maxAvailable ? 'max' : 'vertex'

const mk = () => new StickyRouter<string, Backend>(IDLE)

test('new key -> pins to desired (vertex)', () => {
  expect(mk().route('s1', t0, desired(false, true))).toBe('vertex')
})

test('new key -> pins to desired (max)', () => {
  expect(mk().route('s1', t0, desired(true, true))).toBe('max')
})

test('warm key stays put even when desired changes', () => {
  const r = mk()
  r.route('s1', t0, desired(false, true)) // pin vertex
  expect(r.route('s1', t0 + 60_000, desired(true, true))).toBe('vertex')
})

test('idle key migrates to new desired', () => {
  const r = mk()
  r.route('s1', t0, desired(false, true))
  expect(r.route('s1', t0 + IDLE, desired(true, true))).toBe('max')
})

test('warm key already on desired keeps it', () => {
  const r = mk()
  r.route('s1', t0, desired(true, true)) // pin max
  expect(r.route('s1', t0 + 60_000, desired(false, true))).toBe('max')
})

test('undefined key => return desired, persist nothing', () => {
  const r = mk()
  expect(r.route(undefined, t0, desired(true, true))).toBe('max')
  // A subsequent real key is treated as brand new (nothing was stored).
  expect(r.route('s1', t0, desired(false, true))).toBe('vertex')
})

test('continuously active key never cold-flips, then migrates after idle', () => {
  const r = mk()
  expect(r.route('s1', t0, desired(false, true))).toBe('vertex')
  expect(r.route('s1', t0 + 60_000, desired(true, true))).toBe('vertex')
  expect(r.route('s1', t0 + 120_000, desired(true, true))).toBe('vertex')
  expect(r.route('s1', t0 + 180_000, desired(true, true))).toBe('vertex')
  expect(r.route('s1', t0 + 180_000 + IDLE, desired(true, true))).toBe('max')
})

test('exact boundary: idle === IDLE-1 stays, idle === IDLE migrates', () => {
  const r1 = mk()
  r1.route('s1', t0, desired(false, true))
  expect(r1.route('s1', t0 + IDLE - 1, desired(true, true))).toBe('vertex')

  const r2 = mk()
  r2.route('s1', t0, desired(false, true))
  expect(r2.route('s1', t0 + IDLE, desired(true, true))).toBe('max')
})

test('two keys are independent', () => {
  const r = mk()
  expect(r.route('s1', t0, desired(false, true))).toBe('vertex')
  expect(r.route('s2', t0, desired(true, true))).toBe('max')
  expect(r.route('s1', t0 + 60_000, desired(true, true))).toBe('vertex')
  expect(r.route('s2', t0 + 60_000, desired(false, true))).toBe('max')
})

test('sweep evicts only entries idle longer than ttl', () => {
  const r = mk()
  r.route('s1', t0, desired(false, true))
  r.route('s2', t0, desired(false, true))
  r.route('s2', t0 + 60_000, desired(false, true)) // keep s2 warm
  r.sweep(t0 + 100_000, 50_000) // s1 idle 100s > 50s evicted; s2 idle 40s kept
  // s1 evicted -> behaves new -> pins to max
  expect(r.route('s1', t0 + 100_000, desired(true, true))).toBe('max')
  // s2 still warm -> stays vertex
  expect(r.route('s2', t0 + 100_000, desired(true, true))).toBe('vertex')
})

test('generic over Target: works with arbitrary serve-id strings', () => {
  const r = new StickyRouter<string, string>(IDLE)
  expect(r.route('sess', t0, 'serve-a')).toBe('serve-a')
  // warm: stays on serve-a even though desired changed
  expect(r.route('sess', t0 + 60_000, 'serve-b')).toBe('serve-a')
  // idle: migrates to serve-b
  expect(r.route('sess', t0 + 60_000 + IDLE, 'serve-b')).toBe('serve-b')
})
```

**Step 2: Run the tests to confirm they fail**

Run: `cd ~/projects/sticky-router && bun test`
Expected: FAIL — `StickyRouter` not exported / module has no implementation.

**Step 3: Write the minimal implementation** (`src/index.ts`)

```ts
/**
 * Sticky + idle-migration routing state machine (pure, deterministic).
 *
 * Time is injected (`nowMs`); nothing is read from the clock or filesystem, so
 * every branch is unit-testable. The CALLER computes the `desired` target
 * (budget/backend for egress, rendezvous-hash over healthy serves for ingress);
 * this class only enforces stickiness: a key stays pinned to its current target
 * and migrates to `desired` only after it has been IDLE for at least
 * `idleMigrateMs`. Because `lastActivity` advances on every call, a continuously
 * active key never cold-flips mid-conversation.
 *
 * `Key` must be a valid Map key (use a primitive; both consumers use the
 * session-id string). `Target` is compared with `===`, so use a stable
 * primitive (backend name, serve id).
 */
export class StickyRouter<Key, Target> {
  /** Minimum idle gap (ms) before a pinned key migrates to its desired target. */
  private idleMigrateMs: number
  private entries = new Map<Key, { target: Target; lastActivity: number }>()

  constructor(idleMigrateMs: number) {
    this.idleMigrateMs = idleMigrateMs
  }

  /**
   * Decide which target serves this key and update its stickiness.
   *
   * @param key stickiness key; `undefined` => return `desired`, store nothing.
   * @param nowMs current epoch ms (injected for determinism).
   * @param desired the target the caller wants this key on right now.
   */
  route(key: Key | undefined, nowMs: number, desired: Target): Target {
    if (key === undefined) {
      return desired
    }

    const entry = this.entries.get(key)

    if (!entry) {
      this.entries.set(key, { target: desired, lastActivity: nowMs })
      return desired
    }

    // Decide against the PREVIOUS lastActivity, then advance it once below so the
    // "advance on every call" invariant is impossible to half-apply.
    let result: Target
    if (entry.target === desired) {
      result = entry.target
    } else if (nowMs - entry.lastActivity >= this.idleMigrateMs) {
      entry.target = desired
      result = desired
    } else {
      result = entry.target
    }

    entry.lastActivity = nowMs
    return result
  }

  /** Evict keys idle longer than `ttlMs` so the map doesn't grow unbounded. */
  sweep(nowMs: number, ttlMs: number): void {
    for (const [key, entry] of this.entries.entries()) {
      if (nowMs - entry.lastActivity > ttlMs) {
        this.entries.delete(key)
      }
    }
  }
}
```

**Step 4: Run tests to confirm they pass**

Run: `cd ~/projects/sticky-router && bun test`
Expected: PASS — all tests green (11 tests).

**Step 5: Typecheck + format/lint**

Run: `cd ~/projects/sticky-router && bun run typecheck && bun run format && bun run lint`
Expected: typecheck clean; biome formats with no remaining errors.

**Step 6: Commit**

```bash
cd ~/projects/sticky-router
git add -A && git commit -q -m "feat: StickyRouter<Key,Target> pin/migrate/sweep state machine"
```

---

## Task 3: Build dist, create the private repo, tag & push

**Files:**
- Create (build output, committed): `~/projects/sticky-router/dist/index.js`, `dist/index.d.ts`

**Step 1: Build dist**

Run: `cd ~/projects/sticky-router && bun run build`
Expected: `dist/index.js` and `dist/index.d.ts` produced.

**Step 2: Verify the built artifact imports cleanly**

Run: `cd ~/projects/sticky-router && bun -e "import('./dist/index.js').then(m => console.log(typeof m.StickyRouter))"`
Expected: prints `function`.

**Step 3: Commit dist**

```bash
cd ~/projects/sticky-router
git add -A && git commit -q -m "build: commit dist for git-dependency consumption"
```

**Step 4: Create the private GitHub repo and push**

```bash
cd ~/projects/sticky-router
gh repo create johnnymo87/sticky-router --private --source=. --remote=origin --push
```
Expected: repo created private; `main` pushed. (If `gh` default branch differs,
ensure the branch is `main` and pushed.)

**Step 5: Tag v0.1.0 and push the tag**

```bash
cd ~/projects/sticky-router
git tag v0.1.0
git push origin v0.1.0
```
Expected: tag `v0.1.0` on origin.

---

## Task 4: Declare `sticky-router` in workstation `projects.nix`

**Files:**
- Modify: `~/projects/workstation/projects.nix`

**Step 1: Add the entry** (in the patch-carrier / tools area; default platforms =
all, so it is available wherever consumers are developed)

```nix
  sticky-router = {
    url = "git@github.com:johnnymo87/sticky-router.git";
  };
```

**Step 2: Commit (workstation is USER-pushed — do NOT push)**

```bash
cd ~/projects/workstation
git add projects.nix && git commit -q -m "chore: declare sticky-router project"
```
Expected: commit created locally; leave pushing to the user.

---

## Task 5: Refactor `claude-failover-proxy` to consume the library

**Files:**
- Modify: `~/projects/claude-failover-proxy/package.json` (add dep)
- Modify: `~/projects/claude-failover-proxy/src/router.ts` (wrapper)
- Unchanged: `~/projects/claude-failover-proxy/src/router.test.ts` (regression net)

**Step 1: Add the git dependency**

```bash
cd ~/projects/claude-failover-proxy
bun add 'git+ssh://git@github.com/johnnymo87/sticky-router.git#v0.1.0'
```
Expected: `package.json` gains `"sticky-router"` dep; `bun.lock` updated;
`node_modules/sticky-router` present with `dist/`.

**Step 2: Verify the dep resolves before refactoring**

Run: `cd ~/projects/claude-failover-proxy && bun -e "import('sticky-router').then(m => console.log(typeof m.StickyRouter))"`
Expected: prints `function`.

**Step 3: Rewrite `src/router.ts` as a thin wrapper** (preserves the public
`SessionRouter` API exactly so `index.ts`/`server.ts` are untouched)

```ts
import { StickyRouter } from 'sticky-router'
import type { Backend } from './types'

export interface RouteInputs {
  overBudget: boolean
  maxAvailable: boolean
}

/**
 * Egress backend router: thin wrapper over the shared StickyRouter.
 *
 * Computes the desired backend (Max only when over budget AND Max is available;
 * otherwise Vertex) and delegates stickiness/idle-migration to StickyRouter.
 */
export class SessionRouter {
  private inner: StickyRouter<string, Backend>

  constructor(idleMigrateMs: number) {
    this.inner = new StickyRouter<string, Backend>(idleMigrateMs)
  }

  route(
    sessionId: string | undefined,
    nowMs: number,
    inputs: RouteInputs,
  ): Backend {
    const desired: Backend =
      inputs.overBudget && inputs.maxAvailable ? 'max' : 'vertex'
    return this.inner.route(sessionId, nowMs, desired)
  }

  sweep(nowMs: number, ttlMs: number): void {
    this.inner.sweep(nowMs, ttlMs)
  }
}
```

**Step 4: Run the proxy's existing test suite (regression)**

Run: `cd ~/projects/claude-failover-proxy && bun test`
Expected: PASS — `src/router.test.ts` (and all others) green, unchanged.

**Step 5: Typecheck + lint**

Run: `cd ~/projects/claude-failover-proxy && bun run lint`
Expected: clean. (If a `typecheck` script exists, run it too; otherwise
`bunx tsc --noEmit`.)

**Step 6: Commit and push** (cfp is a normal repo; origin is **https** — if push
prompts for credentials and none are configured, STOP and report)

```bash
cd ~/projects/claude-failover-proxy
git add package.json bun.lock src/router.ts
git commit -q -m "refactor: consume shared sticky-router for backend stickiness"
git pull --rebase && git push
git status   # expect: up to date with origin
```

---

## Task 6: Final verification & close the bead

**Step 1: Re-run both repos' suites**

Run: `cd ~/projects/sticky-router && bun test`
Run: `cd ~/projects/claude-failover-proxy && bun test`
Expected: both fully green.

**Step 2: Confirm pushes** (sticky-router main + v0.1.0 tag; cfp main)

```bash
cd ~/projects/sticky-router && git status && git ls-remote --tags origin | grep v0.1.0
cd ~/projects/claude-failover-proxy && git status
```
Expected: sticky-router pushed with tag; cfp up to date with origin.

**Step 3: Close the bead**

```bash
cd ~/projects/workstation
bd close workstation-bkdw --reason "Extracted pure StickyRouter<Key,Target> to private johnnymo87/sticky-router (v0.1.0); claude-failover-proxy refactored to consume it with behavior preserved (existing router.test.ts green)."
bd dolt push
```

**Step 4: Report** the workstation commits that remain user-pushed (design doc,
plan, projects.nix entry) and hand off.

---

## Notes / gotchas

- **Committed `dist/`** is deliberate: git-dep consumers (bun + npm/vitest) get
  prebuilt JS + `.d.ts` with no install-time build dependency. `prepare` keeps it
  regenerable. When bumping the lib, rebuild dist, commit, re-tag, bump both
  consumer specs.
- **Private repo => SSH git spec** (`git+ssh://git@github.com/...`). The https
  tarball path is auth-gated and will fail in CI/offline.
- **No behavior change** is the acceptance bar for the proxy: its existing
  `router.test.ts` must pass untouched. If any test needs editing to pass, that
  is a signal the wrapper diverged — stop and reconcile.
- **`zao4` is out of scope.** This plan ships the lib and the egress refactor
  only; pigeon's ingress consumption comes later.
