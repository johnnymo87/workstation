# Opus-aware teamclaude fork — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (or
> subagent-driven-development) to implement this plan task-by-task. Each task is
> TDD: write the failing test, run it red, implement minimally, run it green,
> commit. Do not batch.

**Goal:** Make the teamclaude proxy aware of Anthropic's per-model *scoped weekly*
limits (Opus in particular) and fail over per-request to an account where the
requested model's scope is healthy — on the base-URL relay only — instead of
streaming the limit through.

**Architecture:** A generic `scopedLimits` map (keyed by model class:
`opus`/`sonnet`) is parsed from the `/api/oauth/usage` `limits[]` array by the
existing background probe, persisted alongside the unified buckets. Per request,
the base-URL relay parses the body's `model`, derives its class, and uses a new
**stateless** `getActiveAccountFor(class)` overlay that diverts the single request
to a class-healthy account without mutating rotation state. A generalized
retry-after and a defensive reactive backstop (structured-signal only) round it
out. Selection state (`currentIndex`, switch logs) stays driven by the existing
class-free machinery.

**Tech Stack:** Node 18+ (ESM, zero runtime deps), `node:test` + `node:assert/strict`,
Nix (`fetchFromGitHub`) for deployment. Two repos (see below).

**Authoritative inputs (read before starting):**
- Design: `docs/plans/2026-06-21-teamclaude-opus-aware-fork-design.md` (R2; §13 maps review items).
- Real payload fixture: `docs/plans/2026-06-21-teamclaude-opus-aware-fork-fixtures/usage-account0-healthy.json`.
- Review that shaped R2: `docs/plans/2026-06-21-teamclaude-opus-aware-fork-fixtures/review-R1-vertex-opus.md`.
- Beads: `workstation-5woc` (this work), `workstation-yuz7` (capture cleanup → supplies the real *limit* fixture for Phase 7).

---

## Repos, working directories & conventions

This plan spans **two** repos:

| Repo | Path (this macOS host) | What changes here |
|------|------------------------|-------------------|
| **fork** of `KarpelesLab/teamclaude` | `~/Code/teamclaude` (created in Phase 0) | all JS + tests (Phases 1–5, 7) |
| **workstation** | `~/Code/workstation` | nix repackage + cloudbox unify + plan/fixtures (Phase 6; docs already committed) |

- **Fork owner:** `johnnymo87` (matches the workstation remote `git@github.com:johnnymo87/teamclaude`). Confirm before Phase 0 if a different account is intended.
- **Upstream baseline:** `KarpelesLab/teamclaude@654ace1`, npm `1.0.7`. A read-only reference clone is at `/tmp/teamclaude-review` (re-clone with `git clone https://github.com/KarpelesLab/teamclaude /tmp/teamclaude-review` if gone).
- **Test runner (in the fork):** `node --test` (all) or `node --test test/<file>.test.js` (one). Lint: `npm run lint` (eslint 9). Node ≥ 18.
- **Commit style (fork):** focused, conventional-ish messages (e.g. `feat: parse limits[] into scopedLimits`), one per task. These commits are what the workstation `fetchFromGitHub` `rev`/`hash` will pin.
- **Scope guard:** the MITM/forward-proxy relay (`src/mitm.js`) is **out of scope** (design §0/§3). Do not add model-awareness there; Phase 6 documents the caveat.

### Naming/data-model contract (used throughout)

`account.quota.scopedLimits` is a map:
```js
// key = model class ("opus" | "sonnet" | …), value:
{ utilization: Number|null, // 0–1
  resetAt:     Number|null, // ms epoch
  severity:    String|null, // "normal" | … (verbatim from limits[].severity)
  isActive:    Boolean }    // limits[].is_active
```
Built only from `limits[]` entries where `group === "weekly"` and `scope?.model` is set. Key is canonicalized via `modelClass(entry.scope.model.display_name)` so `"Opus"→"opus"`, `"Sonnet"→"sonnet"`.

`modelClass(modelId)`: `/opus/i → "opus"`, `/sonnet/i → "sonnet"`, else `null`. Robust to both opencode's provider-prefixed id (`anthropic/claude-opus-4-8`) and the wire value (`claude-opus-4-…`).

---

## Phase 0 — Fork & dev environment

### Task 0.1: Create the fork and dev clone

**Step 1:** Fork + clone (interactive `gh`; confirms owner):
```bash
gh repo fork KarpelesLab/teamclaude --clone=false --org="" 2>/dev/null || true
gh repo fork KarpelesLab/teamclaude --clone --remote
# clone target:
git clone git@github.com:johnnymo87/teamclaude.git ~/Code/teamclaude
cd ~/Code/teamclaude
git remote add upstream https://github.com/KarpelesLab/teamclaude.git 2>/dev/null || true
git fetch upstream
```

**Step 2:** Pin to the baseline and branch:
```bash
cd ~/Code/teamclaude
git checkout 654ace1 -B opus-aware    # branch off the reviewed baseline
git log --oneline -1                  # expect 654ace1
```

**Step 3:** Sanity-run the existing suite (baseline green):
```bash
node --test
```
Expected: all existing tests pass (rotation-priority, quota-probe, server-429, etc.).

**Step 4 (no commit):** Phase 0 produces no code change; the branch exists and the baseline is green.

### Task 0.2: Vendor the real fixture into the fork

**Files:**
- Create: `~/Code/teamclaude/test/fixtures/usage-account0-healthy.json`

**Step 1:** Copy the captured payload from workstation:
```bash
mkdir -p ~/Code/teamclaude/test/fixtures
cp ~/Code/workstation/docs/plans/2026-06-21-teamclaude-opus-aware-fork-fixtures/usage-account0-healthy.json \
   ~/Code/teamclaude/test/fixtures/usage-account0-healthy.json
```

**Step 2:** Commit:
```bash
cd ~/Code/teamclaude
git add test/fixtures/usage-account0-healthy.json
git commit -m "test: add real /api/oauth/usage fixture (account 0, healthy)"
```

---

## Phase 1 — Data model: parse `limits[]` → `scopedLimits` (proactive, high-confidence)

Everything here is fully specified by the captured fixture + existing code. No
evidence gaps.

### Task 1.1: `modelClass()` helper

**Files:**
- Modify: `src/account-manager.js` (add + export `modelClass`)
- Test: `test/model-class.test.js` (create)

**Step 1 — failing test** (`test/model-class.test.js`):
```js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { modelClass } from '../src/account-manager.js';

test('modelClass maps opus/sonnet wire + provider-prefixed ids', () => {
  assert.equal(modelClass('claude-opus-4-8'), 'opus');
  assert.equal(modelClass('anthropic/claude-opus-4-8'), 'opus');
  assert.equal(modelClass('claude-sonnet-4-5'), 'sonnet');
  assert.equal(modelClass('Opus'), 'opus');        // display_name form
  assert.equal(modelClass('Sonnet'), 'sonnet');
  assert.equal(modelClass('claude-haiku-4'), null);
  assert.equal(modelClass(null), null);
  assert.equal(modelClass(''), null);
});
```

**Step 2 — run red:** `node --test test/model-class.test.js` → FAIL (`modelClass` not exported).

**Step 3 — implement** (top of `src/account-manager.js`, after imports):
```js
/**
 * Map a model id (wire value `claude-opus-4-…`, opencode's provider-prefixed
 * `anthropic/claude-opus-4-8`, or a usage `scope.model.display_name` like
 * "Opus") to a coarse model class used for scoped-quota tracking. Returns null
 * for anything we don't gate on.
 */
export function modelClass(modelId) {
  if (typeof modelId !== 'string' || !modelId) return null;
  if (/opus/i.test(modelId)) return 'opus';
  if (/sonnet/i.test(modelId)) return 'sonnet';
  return null;
}
```

**Step 4 — run green:** `node --test test/model-class.test.js` → PASS.

**Step 5 — commit:**
```bash
git add src/account-manager.js test/model-class.test.js
git commit -m "feat: add modelClass() helper for scoped-quota classification"
```

### Task 1.2: `parseUsagePayload()` parses `limits[]` into `scopedLimits`

Extract the payload parsing out of `fetchUsage` (which does network I/O) into a
pure, fixture-testable function.

**Files:**
- Modify: `src/oauth.js` (add+export `parseUsagePayload`; `fetchUsage` delegates)
- Test: `test/usage-payload.test.js` (create)

**Step 1 — failing test** (`test/usage-payload.test.js`):
```js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { parseUsagePayload } from '../src/oauth.js';

const fixture = JSON.parse(readFileSync(
  fileURLToPath(new URL('./fixtures/usage-account0-healthy.json', import.meta.url)), 'utf8'));

test('parses the real healthy payload: unified buckets + sonnet scope, no opus', () => {
  const u = parseUsagePayload(fixture);
  assert.equal(u.fiveHour.utilization, 0.03);
  assert.equal(u.sevenDay.utilization, 0.11);
  assert.equal(u.sevenDaySonnet.utilization, 0.04);
  // scopedLimits: sonnet present (is_active false), opus absent (no entry)
  assert.ok(u.scopedLimits);
  assert.equal(u.scopedLimits.opus, undefined);
  assert.equal(u.scopedLimits.sonnet.isActive, false);
  assert.equal(u.scopedLimits.sonnet.severity, 'normal');
  assert.equal(u.scopedLimits.sonnet.utilization, 0.04);
  assert.equal(u.scopedLimits.sonnet.resetAt, Date.parse('2026-06-26T04:00:00.128531+00:00'));
});

test('parses a synthetic ACTIVE opus weekly_scoped entry', () => {
  const payload = { limits: [
    { kind: 'weekly_scoped', group: 'weekly', percent: 97, severity: 'high',
      resets_at: '2026-06-26T04:00:00Z', scope: { model: { display_name: 'Opus' } }, is_active: true },
  ]};
  const u = parseUsagePayload(payload);
  assert.equal(u.scopedLimits.opus.isActive, true);
  assert.equal(u.scopedLimits.opus.severity, 'high');
  assert.equal(u.scopedLimits.opus.utilization, 0.97);
  assert.equal(u.scopedLimits.opus.resetAt, Date.parse('2026-06-26T04:00:00Z'));
});

test('ignores session/non-weekly and unscoped limits; tolerates missing limits[]', () => {
  // NOTE: payload percents are 0–100; normalizeUsageBucket only divides when >1,
  // so use an unambiguous value (50 → 0.5), never exactly 1 (1% vs 100% is ambiguous).
  const u = parseUsagePayload({ five_hour: { utilization: 50 } });
  assert.deepEqual(u.scopedLimits, {});
  assert.equal(u.fiveHour.utilization, 0.5);
});
```

**Step 2 — run red:** `node --test test/usage-payload.test.js` → FAIL (`parseUsagePayload` not exported).

**Step 3 — implement** in `src/oauth.js`. Add `import { modelClass } from './account-manager.js';` at top, then:
```js
/**
 * Parse a /api/oauth/usage payload into normalized buckets plus a generic
 * scopedLimits map (per-model weekly limits) derived from limits[]. Pure — no
 * I/O — so it is unit-tested against a captured fixture.
 */
export function parseUsagePayload(data) {
  const scopedLimits = {};
  if (Array.isArray(data?.limits)) {
    for (const lim of data.limits) {
      if (lim?.group !== 'weekly') continue;
      const display = lim?.scope?.model?.display_name;
      if (!display) continue;               // unscoped weekly (weekly_all) → handled by sevenDay
      const cls = modelClass(display) || String(display).toLowerCase();
      const norm = normalizeUsageBucket({ utilization: lim.percent, resets_at: lim.resets_at });
      scopedLimits[cls] = {
        utilization: norm ? norm.utilization : null,
        resetAt: norm ? norm.resetAt : null,
        severity: lim.severity ?? null,
        isActive: !!lim.is_active,
      };
    }
  }
  return {
    fiveHour: normalizeUsageBucket(data?.five_hour),
    sevenDay: normalizeUsageBucket(data?.seven_day),
    sevenDaySonnet: normalizeUsageBucket(data?.seven_day_sonnet),
    scopedLimits,
  };
}
```
Then make `fetchUsage` delegate — replace its success branch (`src/oauth.js:201-206`):
```js
    const data = await res.json();
    return parseUsagePayload(data);
```

> Note: `oauth.js` ↔ `account-manager.js` now import each other. `modelClass` is a
> pure top-level export with no module-load side effects, so the ESM cycle is
> benign. If lint/load complains, move `modelClass` into a tiny `src/model-class.js`
> and import it from both (update Task 1.1's path accordingly).

**Step 4 — run green:** `node --test test/usage-payload.test.js test/quota-probe.test.js` → PASS (quota-probe still green: `normalizeUsageBucket` unchanged, `fetchUsage` shape is a superset).

**Step 5 — commit:**
```bash
git add src/oauth.js test/usage-payload.test.js
git commit -m "feat: parse limits[] into a generic scopedLimits map"
```

### Task 1.3: Store `scopedLimits` on quota + persist it

**Files:**
- Modify: `src/account-manager.js` (`emptyQuota`, `PERSISTED_QUOTA_FIELDS`, `applyUsageData`)
- Test: `test/scoped-limits.test.js` (create)

**Step 1 — failing test** (`test/scoped-limits.test.js`):
```js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { AccountManager } from '../src/account-manager.js';

const oauth = (name, extra = {}) => ({ name, type: 'oauth', accessToken: 't-' + name, expiresAt: Date.now() + 3600_000, ...extra });

test('applyUsageData stores scopedLimits and round-trips through persistence', () => {
  const am = new AccountManager([oauth('a', { accountUuid: 'p1' })], 0.98);
  am.applyUsageData(0, {
    sevenDay: { utilization: 0.4, resetAt: 222 },
    scopedLimits: { opus: { utilization: 0.96, resetAt: 999, severity: 'high', isActive: true } },
  });
  assert.equal(am.accounts[0].quota.scopedLimits.opus.isActive, true);

  const am2 = new AccountManager([oauth('a', { accountUuid: 'p1' })], 0.98);
  am2.restoreQuotaState(am.exportQuotaState());
  assert.equal(am2.accounts[0].quota.scopedLimits.opus.utilization, 0.96);
  assert.equal(am2.accounts[0].quota.scopedLimits.opus.resetAt, 999);
});

test('applyUsageData with no scopedLimits leaves the map untouched', () => {
  const am = new AccountManager([oauth('a')], 0.98);
  am.applyUsageData(0, { scopedLimits: { sonnet: { utilization: 0.1, resetAt: 1, severity: 'normal', isActive: false } } });
  am.applyUsageData(0, { sevenDay: { utilization: 0.2, resetAt: 2 } }); // probe w/o limits[]
  assert.equal(am.accounts[0].quota.scopedLimits.sonnet.utilization, 0.1);
});
```

**Step 2 — run red:** `node --test test/scoped-limits.test.js` → FAIL.

**Step 3 — implement** in `src/account-manager.js`:
- `emptyQuota()` — add `scopedLimits: {},` (after `unifiedStatus`/`resetsAt`).
- `PERSISTED_QUOTA_FIELDS` — append `'scopedLimits'`.
- `applyUsageData(accountIndex, usage)` — after the existing sonnet block, before the probing/requalify block:
```js
    if (usage.scopedLimits && typeof usage.scopedLimits === 'object') {
      q.scopedLimits = { ...q.scopedLimits, ...usage.scopedLimits };
    }
```

> `exportQuotaState` copies fields by reference and `restoreQuotaState` assigns
> `match.quota[f]` when non-null; an object value works as-is (it survives the
> JSON persist/parse round-trip in index.js). No change needed there.

**Step 4 — run green:** `node --test test/scoped-limits.test.js test/quota-persistence.test.js` → PASS.

**Step 5 — commit:**
```bash
git add src/account-manager.js test/scoped-limits.test.js
git commit -m "feat: persist per-account scopedLimits quota map"
```

### Task 1.4: Expire stale scoped entries

**Files:**
- Modify: `src/account-manager.js` (`_clearExpiredQuotas`)
- Test: add to `test/scoped-limits.test.js`

**Step 1 — failing test** (append):
```js
test('_clearExpiredQuotas drops a scoped entry whose reset passed', () => {
  const am = new AccountManager([oauth('a')], 0.98);
  am.applyUsageData(0, { scopedLimits: {
    opus:   { utilization: 1, resetAt: Date.now() - 1000, severity: 'high', isActive: true },
    sonnet: { utilization: 0.1, resetAt: Date.now() + 3600_000, severity: 'normal', isActive: false },
  }});
  am._clearExpiredQuotas(am.accounts[0]);
  assert.equal(am.accounts[0].quota.scopedLimits.opus, undefined);   // expired → removed
  assert.ok(am.accounts[0].quota.scopedLimits.sonnet);               // future → kept
});
```

**Step 2 — run red:** `node --test test/scoped-limits.test.js` → FAIL.

**Step 3 — implement** in `_clearExpiredQuotas`, before `return { changed, session };`:
```js
    if (q.scopedLimits) {
      for (const [cls, sl] of Object.entries(q.scopedLimits)) {
        if (sl?.resetAt && now >= sl.resetAt) {
          delete q.scopedLimits[cls];
          changed = true;
        }
      }
    }
```

**Step 4 — run green:** `node --test test/scoped-limits.test.js` → PASS.

**Step 5 — commit:**
```bash
git add src/account-manager.js test/scoped-limits.test.js
git commit -m "feat: expire scopedLimits entries past their reset"
```

---

## Phase 2 — Model-aware selection (stateless overlay)

### Task 2.1: `_isNearQuota(account, modelClass)` gates on an active scope

**Files:**
- Modify: `src/account-manager.js` (ctor `scopedThreshold`, `_isNearQuota`)
- Test: `test/scoped-selection.test.js` (create)

**Step 1 — failing test** (`test/scoped-selection.test.js`):
```js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { AccountManager } from '../src/account-manager.js';

const oauth = (name, extra = {}) => ({ name, type: 'oauth', accessToken: 't-' + name, expiresAt: Date.now() + 3600_000, ...extra });
const future = () => Date.now() + 3600_000;

test('_isNearQuota(acct,"opus") trips on an active opus scope while unified is low', () => {
  const am = new AccountManager([oauth('a')], 0.98, 0.90);
  const a = am.accounts[0];
  a.quota.unified5h = 0.10; a.quota.unified7d = 0.10;
  a.quota.scopedLimits = { opus: { utilization: 0.95, resetAt: future(), severity: 'normal', isActive: true } };
  assert.equal(am._isNearQuota(a), false);          // class-free: unified low → fine
  assert.equal(am._isNearQuota(a, 'opus'), true);   // opus: 0.95 ≥ 0.90 scoped threshold
  assert.equal(am._isNearQuota(a, 'sonnet'), false);// other class unaffected
});

test('severity alone (any non-normal) trips even below the scoped threshold', () => {
  const am = new AccountManager([oauth('a')], 0.98, 0.90);
  const a = am.accounts[0];
  a.quota.scopedLimits = { opus: { utilization: 0.10, resetAt: future(), severity: 'warning', isActive: true } };
  assert.equal(am._isNearQuota(a, 'opus'), true);
});

test('an INACTIVE scope never gates', () => {
  const am = new AccountManager([oauth('a')], 0.98, 0.90);
  const a = am.accounts[0];
  a.quota.scopedLimits = { opus: { utilization: 1, resetAt: future(), severity: 'high', isActive: false } };
  assert.equal(am._isNearQuota(a, 'opus'), false);
});
```

**Step 2 — run red:** `node --test test/scoped-selection.test.js` → FAIL.

**Step 3 — implement:**
- ctor: `constructor(accounts, switchThreshold = 0.98, scopedThreshold = 0.90)` and store `this.scopedThreshold = scopedThreshold;`.
- `_isNearQuota(account, modelClass = null)` — after the existing unified/standard checks, before `return false;`:
```js
    if (modelClass && account.quota.scopedLimits) {
      const sl = account.quota.scopedLimits[modelClass];
      if (sl && sl.isActive) {
        if (sl.severity && sl.severity !== 'normal') return true;
        if (sl.utilization != null && sl.utilization >= this.scopedThreshold) return true;
      }
    }
```

**Step 4 — run green:** `node --test test/scoped-selection.test.js` → PASS.

**Step 5 — commit:**
```bash
git add src/account-manager.js test/scoped-selection.test.js
git commit -m "feat: scoped-limit gating in _isNearQuota (severity/threshold-driven)"
```

### Task 2.2: Thread `modelClass` through `_isAvailable` / `_pickBestAvailable`

**Files:**
- Modify: `src/account-manager.js` (`_isAvailable`, `_pickBestAvailable`)
- Test: add to `test/scoped-selection.test.js`

**Step 1 — failing test** (append):
```js
test('_pickBestAvailable(class) skips the account constrained for that class', () => {
  const am = new AccountManager([oauth('a'), oauth('b')], 0.98, 0.90);
  const [a, b] = am.accounts;
  a.quota.unified7dReset = Date.now() + 86_400_000;          // known weekly → available
  b.quota.unified7dReset = Date.now() + 2 * 86_400_000;
  a.quota.scopedLimits = { opus: { utilization: 0.99, resetAt: Date.now() + 3600_000, severity: 'normal', isActive: true } };
  assert.equal(am._pickBestAvailable('opus').name, 'b');     // a is opus-near → pick b
  assert.equal(am._pickBestAvailable('sonnet').name, 'a');   // sonnet unconstrained → a (sooner reset)
  assert.equal(am._pickBestAvailable().name, 'a');           // class-free unchanged
});
```

**Step 2 — run red:** `node --test test/scoped-selection.test.js` → FAIL.

**Step 3 — implement:**
- `_isAvailable(account, modelClass = null)` — change the near-quota line:
  `if (this._isNearQuota(account, modelClass)) return false;`
- `_pickBestAvailable(modelClass = null)` — change the filter line:
  `if (!this._isAvailable(account, modelClass)) continue;`

**Step 4 — run green:** `node --test test/scoped-selection.test.js test/rotation-priority.test.js` → PASS (defaults keep class-free behavior identical).

**Step 5 — commit:**
```bash
git add src/account-manager.js test/scoped-selection.test.js
git commit -m "feat: thread optional modelClass through availability/selection"
```

### Task 2.3: Stateless `getActiveAccountFor(modelClass)` overlay

**Files:**
- Modify: `src/account-manager.js` (add `getActiveAccountFor`)
- Test: add to `test/scoped-selection.test.js`

**Step 1 — failing test** (append):
```js
test('getActiveAccountFor diverts an opus request without moving currentIndex', () => {
  const am = new AccountManager([oauth('a'), oauth('b')], 0.98, 0.90);
  const [a, b] = am.accounts;
  a.quota.unified7dReset = Date.now() + 86_400_000; a.probing = false;
  b.quota.unified7dReset = Date.now() + 86_400_000; b.probing = false;
  am.currentIndex = 0;
  a.quota.scopedLimits = { opus: { utilization: 0.99, resetAt: Date.now() + 3600_000, severity: 'high', isActive: true } };

  const picked = am.getActiveAccountFor('opus');
  assert.equal(picked.name, 'b');          // diverted to a class-healthy account
  assert.equal(am.currentIndex, 0);        // primary pointer unchanged (no thrash)

  // A sonnet request (unconstrained) stays on the primary.
  assert.equal(am.getActiveAccountFor('sonnet').name, 'a');
  assert.equal(am.currentIndex, 0);
});

test('getActiveAccountFor(null) is exactly getActiveAccount()', () => {
  const am = new AccountManager([oauth('a')], 0.98, 0.90);
  am.accounts[0].quota.unified7dReset = Date.now() + 86_400_000;
  assert.equal(am.getActiveAccountFor(null)?.name, 'a');
});

test('getActiveAccountFor returns null when every account is constrained for the class', () => {
  const am = new AccountManager([oauth('a'), oauth('b')], 0.98, 0.90);
  for (const a of am.accounts) {
    a.quota.unified7dReset = Date.now() + 86_400_000; a.probing = false;
    a.quota.scopedLimits = { opus: { utilization: 1, resetAt: Date.now() + 3600_000, severity: 'high', isActive: true } };
  }
  assert.equal(am.getActiveAccountFor('opus'), null);
});
```

**Step 2 — run red:** `node --test test/scoped-selection.test.js` → FAIL.

**Step 3 — implement** (after `getActiveAccount`):
```js
  /**
   * Per-request, model-aware account pick. Reuses the existing class-free
   * getActiveAccount() to maintain the *primary* (currentIndex, requalify,
   * preemption, switch logs) exactly as today, then statelessly DIVERTS the
   * single request to a class-healthy account when the primary is constrained
   * for this model class. Never mutates currentIndex/logs on the divert path,
   * so a mixed Opus/Sonnet workload can't thrash the pointer. Returns null only
   * when no account is available for the class (caller → 429).
   */
  getActiveAccountFor(modelClass) {
    const primary = this.getActiveAccount();
    if (!modelClass || !primary) return primary;
    if (this._isAvailable(primary, modelClass)) {
      const betterExists = this.accounts.some(a =>
        this._isAvailable(a, modelClass) && (a.priority || 0) < (primary.priority || 0));
      if (!betterExists) return primary;
    }
    return this._pickBestAvailable(modelClass);
  }
```

**Step 4 — run green:** `node --test test/scoped-selection.test.js` → PASS.

**Step 5 — commit:**
```bash
git add src/account-manager.js test/scoped-selection.test.js
git commit -m "feat: stateless getActiveAccountFor(modelClass) request overlay"
```

### Task 2.4: Wire the request body's `model` into selection (server.js)

**Files:**
- Modify: `src/server.js` (`requestHandler` body parse → class; `forwardRequest` signature + selection call)
- Test: `test/server-model-routing.test.js` (create)

**Step 1 — failing test** (`test/server-model-routing.test.js`): an upstream that records the inbound `authorization` bearer per account; account `a` has an active opus scope, `b` is healthy; an Opus request must land on `b`, a Sonnet request on `a`.
```js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { AccountManager } from '../src/account-manager.js';
import { createProxyServer } from '../src/server.js';

const listen = (s) => new Promise(r => s.listen(0, '127.0.0.1', () => r(s.address().port)));

test('an Opus request routes to the account whose opus scope is healthy', async () => {
  const seen = [];
  const upstream = http.createServer((req, res) => {
    seen.push(req.headers['authorization']);
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ ok: true }));
  });
  const upstreamPort = await listen(upstream);

  const am = new AccountManager([
    { name: 'a', type: 'oauth', accessToken: 'tok-a', expiresAt: Date.now() + 3600_000 },
    { name: 'b', type: 'oauth', accessToken: 'tok-b', expiresAt: Date.now() + 3600_000 },
  ], 0.98, 0.90);
  for (const acc of am.accounts) { acc.quota.unified7dReset = Date.now() + 86_400_000; acc.probing = false; }
  am.currentIndex = 0;
  am.accounts[0].quota.scopedLimits = { opus: { utilization: 0.99, resetAt: Date.now() + 3600_000, severity: 'high', isActive: true } };

  const proxy = createProxyServer(am, { proxy: { apiKey: 'k' }, upstream: `http://127.0.0.1:${upstreamPort}` });
  const proxyPort = await listen(proxy);
  try {
    await (await fetch(`http://127.0.0.1:${proxyPort}/v1/messages`, {
      method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ model: 'claude-opus-4-8', messages: [] }) })).text();
    assert.equal(seen.at(-1), 'Bearer tok-b');     // diverted to b

    await (await fetch(`http://127.0.0.1:${proxyPort}/v1/messages`, {
      method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ model: 'claude-sonnet-4-5', messages: [] }) })).text();
    assert.equal(seen.at(-1), 'Bearer tok-a');     // stays on primary
  } finally { proxy.close(); upstream.close(); }
});

test('a body without a model falls back to unified-only selection (no throw)', async () => {
  const upstream = http.createServer((_req, res) => { res.writeHead(200); res.end('{}'); });
  const upstreamPort = await listen(upstream);
  const am = new AccountManager([{ name: 'a', type: 'oauth', accessToken: 't', expiresAt: Date.now() + 3600_000 }], 0.98, 0.90);
  am.accounts[0].quota.unified7dReset = Date.now() + 86_400_000; am.accounts[0].probing = false;
  const proxy = createProxyServer(am, { proxy: { apiKey: 'k' }, upstream: `http://127.0.0.1:${upstreamPort}` });
  const proxyPort = await listen(proxy);
  try {
    const res = await fetch(`http://127.0.0.1:${proxyPort}/v1/messages`, {
      method: 'POST', headers: { 'content-type': 'application/json' }, body: 'not json' });
    await res.text();
    assert.equal(res.status, 200);
  } finally { proxy.close(); upstream.close(); }
});
```

**Step 2 — run red:** `node --test test/server-model-routing.test.js` → FAIL (request lands on `a`, the primary, because model isn't consulted yet).

**Step 3 — implement** in `src/server.js`:
- Add a small helper near the top (after `HOP_BY_HOP_HEADERS`):
```js
import { modelClass } from './account-manager.js';

// Best-effort extraction of the request's model class from a buffered JSON body.
// Returns null on any failure (non-JSON, missing model, GET) → unified-only.
function requestModelClass(method, body) {
  if (method === 'GET' || method === 'HEAD' || !body || !body.length) return null;
  try { return modelClass(JSON.parse(body.toString('utf8'))?.model); } catch { return null; }
}
```
- In `requestHandler`, after `const body = Buffer.concat(bodyChunks);` (server.js:84):
```js
      const reqModelClass = requestModelClass(req.method, body);
```
- Pass it into `forwardRequest`:
```js
        await forwardRequest(req, res, body, accountManager, upstream, 0, hooks, reqId, ctx, logDir, reqModelClass);
```
- `forwardRequest(...)` — add `modelClass = null` as the final param; **thread it through every recursive call** (the 4 self-calls at :234, :318, :325, :390 must pass `modelClass`).
- Replace the selection call (server.js:207):
```js
  const account = accountManager.getActiveAccountFor(modelClass);
```

**Step 4 — run green:** `node --test test/server-model-routing.test.js test/server-429.test.js` → PASS.

**Step 5 — commit:**
```bash
git add src/server.js test/server-model-routing.test.js
git commit -m "feat: route requests by model class via getActiveAccountFor"
```

---

## Phase 3 — Generalized retry-after (unify the two "soonest reset" computations)

### Task 3.1: `_soonestResetMs(account)` + reuse in `_selectNext`

**Files:**
- Modify: `src/account-manager.js` (add `_soonestResetMs`, refactor `_selectNext` fallback)
- Test: `test/retry-after.test.js` (create)

**Step 1 — failing test** (`test/retry-after.test.js`):
```js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { AccountManager } from '../src/account-manager.js';

const oauth = (name) => ({ name, type: 'oauth', accessToken: 't', expiresAt: Date.now() + 3600_000 });

test('_soonestResetMs takes the min across all reset fields incl scoped', () => {
  const am = new AccountManager([oauth('a')], 0.98, 0.90);
  const a = am.accounts[0];
  const t = Date.now();
  a.quota.unified5hReset = t + 50_000;
  a.quota.unified7dReset = t + 90_000;
  a.quota.scopedLimits = { opus: { utilization: 1, resetAt: t + 20_000, severity: 'high', isActive: true } };
  assert.equal(am._soonestResetMs(a), t + 20_000);   // scoped is soonest
});
```

**Step 2 — run red:** `node --test test/retry-after.test.js` → FAIL.

**Step 3 — implement** in `src/account-manager.js`:
```js
  /** Soonest future reset across every known window for one account (ms epoch),
   *  or null. Single source of truth for "when could this account come back". */
  _soonestResetMs(account) {
    const q = account.quota;
    const candidates = [
      account.rateLimitedUntil,
      q.unified5hReset, q.unified7dReset, q.unified7dSonnetReset,
      q.resetsAt ? new Date(q.resetsAt).getTime() : null,
    ];
    if (q.scopedLimits) for (const sl of Object.values(q.scopedLimits)) candidates.push(sl?.resetAt ?? null);
    let soonest = null;
    for (const c of candidates) {
      if (c == null || !Number.isFinite(c)) continue;
      if (soonest == null || c < soonest) soonest = c;
    }
    return soonest;
  }
```
Refactor `_selectNext`'s all-unavailable fallback (account-manager.js:306-319) to use it:
```js
    let soonestAccount = null;
    let soonestTime = Infinity;
    for (const account of this.accounts) {
      const resetTime = this._soonestResetMs(account);
      if (resetTime != null && resetTime < soonestTime) {
        soonestTime = resetTime;
        soonestAccount = account;
      }
    }
```
(Leave the `soonestTime <= Date.now()` reactivation block below it unchanged.)

**Step 4 — run green:** `node --test test/retry-after.test.js test/rotation-priority.test.js` → PASS.

**Step 5 — commit:**
```bash
git add src/account-manager.js test/retry-after.test.js
git commit -m "feat: _soonestResetMs across all windows; reuse in _selectNext"
```

### Task 3.2: `computeRetryAfterSeconds()` and server wiring

**Files:**
- Modify: `src/account-manager.js` (add `computeRetryAfterSeconds`)
- Modify: `src/server.js` (use it; drop the local `computeRetryAfter`)
- Test: add to `test/retry-after.test.js`

**Step 1 — failing test** (append):
```js
test('computeRetryAfterSeconds = soonest future reset across accounts (≥1s), default 60', () => {
  const am = new AccountManager([oauth('a'), oauth('b')], 0.98, 0.90);
  assert.equal(am.computeRetryAfterSeconds(), 60);                 // nothing known
  am.accounts[0].quota.unified7dReset = Date.now() + 30_000;
  am.accounts[1].quota.unified7dReset = Date.now() + 120_000;
  const s = am.computeRetryAfterSeconds();
  assert.ok(s >= 25 && s <= 31, `got ${s}`);                      // ~30s, the soonest
});
```

**Step 2 — run red:** `node --test test/retry-after.test.js` → FAIL.

**Step 3 — implement:**
- `src/account-manager.js`:
```js
  /** Seconds until the soonest account reset (min 1), or 60 if nothing known. */
  computeRetryAfterSeconds() {
    let soonest = Infinity;
    for (const a of this.accounts) {
      const r = this._soonestResetMs(a);
      if (r != null && r < soonest) soonest = r;
    }
    if (soonest === Infinity) return 60;
    return Math.max(1, Math.ceil((soonest - Date.now()) / 1000));
  }
```
- `src/server.js`: in `forwardRequest`'s no-account branch (server.js:211-212) replace:
```js
    const retryAfter = accountManager.computeRetryAfterSeconds();
```
  (remove the now-unused `const status = accountManager.getStatus();` on that line) and **delete** the module-private `computeRetryAfter` function (server.js:486-495).

**Step 4 — run green:** `node --test test/retry-after.test.js test/server-429.test.js` → PASS.

**Step 5 — commit:**
```bash
git add src/account-manager.js src/server.js test/retry-after.test.js
git commit -m "feat: generalized retry-after across all reset windows"
```

---

## Phase 4 — Status surfacing (Opus/Sonnet visible everywhere)

`/teamclaude/status` is free (`getStatus` spreads `quota`, so `scopedLimits`
appears automatically — assert it). Add the CLI printer + TUI bar.

### Task 4.1: `/teamclaude/status` exposes scopedLimits (assert-only) + CLI printer

**Files:**
- Modify: `src/index.js` (status CLI printer, index.js:497-507)
- Test: `test/status-scoped.test.js` (create) — asserts `getStatus()` includes scopedLimits

**Step 1 — failing test** (`test/status-scoped.test.js`):
```js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { AccountManager } from '../src/account-manager.js';

test('getStatus surfaces scopedLimits for each account', () => {
  const am = new AccountManager([{ name: 'a', type: 'oauth', accessToken: 't', expiresAt: Date.now() + 1e7 }], 0.98, 0.90);
  am.accounts[0].quota.scopedLimits = { opus: { utilization: 0.5, resetAt: 1, severity: 'normal', isActive: true } };
  const st = am.getStatus();
  assert.equal(st.accounts[0].quota.scopedLimits.opus.utilization, 0.5);
});
```

**Step 2 — run red:** `node --test test/status-scoped.test.js` → (likely PASS already, since `quota: {...a.quota}` spreads it — this is a guard test. If it passes, keep it as a regression guard and proceed; the printer change below is verified manually.)

**Step 3 — implement** the CLI printer (`src/index.js:500-502`) — append an Opus/Sonnet summary derived from `scopedLimits`:
```js
        let line = `    Session:  ${ses} used    Weekly: ${wk} used`;
        if (q.unified7dSonnet != null) line += `    Sonnet7d: ${(q.unified7dSonnet * 100).toFixed(1)}% used`;
        const sl = q.scopedLimits || {};
        for (const cls of Object.keys(sl)) {
          const s = sl[cls];
          if (s && s.utilization != null) {
            line += `    ${cls[0].toUpperCase()}${cls.slice(1)}(scoped): ${(s.utilization * 100).toFixed(1)}%${s.isActive ? '*' : ''}`;
          }
        }
        console.log(line);
```

**Step 4 — verify:** `node --test test/status-scoped.test.js` → PASS. Manual: `node src/index.js status` against a running server shows the scoped line (deferred to Phase 6 deploy smoke-test).

**Step 5 — commit:**
```bash
git add src/index.js test/status-scoped.test.js
git commit -m "feat: surface scopedLimits in /status and the status CLI printer"
```

### Task 4.2: TUI scoped bar

**Files:**
- Modify: `src/tui.js` (the account line, tui.js:548-554)

**Step 1:** No new unit test (TUI rendering is not unit-tested upstream; the
`showBoth`/`bar` path is render-only). Change is mechanical and verified in the
Phase 6 smoke-test.

**Step 2 — implement** (`src/tui.js`, inside `if (showBoth) { … }`, after the Sonnet `S7` bar):
```js
      const sl = q.scopedLimits || {};
      if (sl.opus && sl.opus.utilization != null) {
        line += `  O7  ${bar(sl.opus.utilization, bw, sl.opus.resetAt)}`;
      }
```

**Step 3 — verify:** `node --test` (full suite stays green; no test targets the TUI string).

**Step 4 — commit:**
```bash
git add src/tui.js
git commit -m "feat: TUI scoped Opus weekly bar (O7)"
```

---

## Phase 5 — Reactive scoped backstop (defensive; structured-signal only)

> **Evidence gate:** the exact wire-shape of a real scoped-limit response is
> **not yet captured** (design §6/§12 B2; beads `workstation-yuz7`). This phase
> implements the *mechanism* with a **conservative, structured** classifier that
> marks a scope ONLY on an unambiguous per-account usage-limit signal and
> **defaults to the existing back-off** on anything unrecognized — so it can
> never reproduce the issue-#5 IP-throttle misclassification. Phase 7 tightens
> the predicate against the real capture. Ship Phases 1–4 first; this phase is
> additive and lower-confidence.

### Task 5.1: `classifyLimitResponse(status, headers, bodyJson)` (pure, conservative)

**Files:**
- Create: `src/limit-classify.js`
- Test: `test/limit-classify.test.js` (create)

**Step 1 — failing test** (`test/limit-classify.test.js`):
```js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { classifyLimitResponse } from '../src/limit-classify.js';

test('IP-throttle 429 is NOT a usage limit (back off, never mark scope)', () => {
  const r = classifyLimitResponse(429,
    { 'retry-after': '30' },
    { type: 'error', error: { type: 'rate_limit_error', message: 'Server is temporarily limiting requests (not your usage limit)' } });
  assert.equal(r.kind, 'throttle');
});

test('a structured per-account usage limit is recognized', () => {
  const r = classifyLimitResponse(429,
    {},
    { type: 'error', error: { type: 'usage_limit_error', message: 'The usage limit has been reached' } });
  assert.equal(r.kind, 'usage_limit');
});

test('unrecognized → unknown (caller backs off, never marks a scope)', () => {
  assert.equal(classifyLimitResponse(200, {}, { type: 'message_start' }).kind, 'unknown');
  assert.equal(classifyLimitResponse(500, {}, null).kind, 'unknown');
});
```

**Step 2 — run red:** `node --test test/limit-classify.test.js` → FAIL.

**Step 3 — implement** (`src/limit-classify.js`). Predicate is intentionally
narrow and **TODO-marked for Phase 7 refinement against the real capture**:
```js
// Conservative classifier for a possible upstream usage-limit response.
// Returns { kind: 'usage_limit'|'throttle'|'unknown', scope?: 'opus'|'sonnet'|null }.
// HARD RULE: only 'usage_limit' may mark a scope exhausted. Everything else
// (incl. the IP-keyed "temporarily limiting requests" throttle) → back off.
// TODO(workstation-yuz7): tighten error.type/scope extraction against the real
// captured limit response before relying on the proactive path being bypassed.
const THROTTLE_RE = /temporarily limiting requests|not your usage limit/i;

export function classifyLimitResponse(status, headers = {}, bodyJson = null) {
  const err = bodyJson?.error || bodyJson;
  const type = err?.type;
  const msg = typeof err?.message === 'string' ? err.message : '';

  // The IP-keyed throttle must always be treated as back-off, never failover.
  if (THROTTLE_RE.test(msg)) return { kind: 'throttle' };

  // Structured per-account usage limit (primary predicate). 'rate_limit_error'
  // is ambiguous (also the throttle's type), so require a usage-limit signal
  // that the throttle does NOT carry.
  const isUsageLimit =
    type === 'usage_limit_error' ||
    (status === 429 && /usage limit has been reached/i.test(msg));
  if (isUsageLimit) {
    return { kind: 'usage_limit', scope: scopeFromBody(err) };
  }
  return { kind: 'unknown' };
}

// Best-effort scope extraction; null when absent → caller marks no specific
// scope (falls back to unified back-off). Refined in Phase 7.
function scopeFromBody(err) {
  const s = err?.scope?.model?.display_name || err?.model || '';
  if (/opus/i.test(s)) return 'opus';
  if (/sonnet/i.test(s)) return 'sonnet';
  return null;
}
```

**Step 4 — run green:** `node --test test/limit-classify.test.js` → PASS.

**Step 5 — commit:**
```bash
git add src/limit-classify.js test/limit-classify.test.js
git commit -m "feat: conservative usage-limit vs IP-throttle classifier"
```

### Task 5.2: `markScopeExhausted` + mid-stream SSE error arm

**Files:**
- Modify: `src/account-manager.js` (add `markScopeExhausted`)
- Modify: `src/server.js` (`parseSSEUsage` error arm + observability)
- Test: add to `test/scoped-limits.test.js`

**Step 1 — failing test** (append to `test/scoped-limits.test.js`):
```js
test('markScopeExhausted sets the class exhausted with a reset', () => {
  const am = new AccountManager([oauth('a')], 0.98, 0.90);
  const reset = Date.now() + 3600_000;
  am.markScopeExhausted(0, 'opus', reset);
  const sl = am.accounts[0].quota.scopedLimits.opus;
  assert.equal(sl.utilization, 1);
  assert.equal(sl.isActive, true);
  assert.equal(sl.resetAt, reset);
});
```

**Step 2 — run red:** `node --test test/scoped-limits.test.js` → FAIL.

**Step 3 — implement:**
- `src/account-manager.js`:
```js
  /** Reactively mark a model class exhausted for an account (backstop path). */
  markScopeExhausted(accountIndex, modelClass, resetAtMs = null) {
    const account = this.accounts[accountIndex];
    if (!account || !modelClass) return;
    account.quota.scopedLimits ||= {};
    account.quota.scopedLimits[modelClass] = {
      utilization: 1, resetAt: resetAtMs ?? account.quota.unified7dReset ?? null,
      severity: 'high', isActive: true,
    };
    console.log(`[TeamClaude] Marked "${account.name}" ${modelClass} scope exhausted (reactive backstop)`);
  }
```
- `src/server.js` `parseSSEUsage` — needs the account's model class to mark the right scope. Thread `modelClass` into `streamResponse`/`parseSSEUsage` (add param), then add the error arm:
```js
    } else if (data.type === 'error' && modelClass) {
      const { classifyLimitResponse } = await importClassifier();   // or static import at top
      const c = classifyLimitResponse(200, {}, data);
      if (c.kind === 'usage_limit') {
        accountManager.markScopeExhausted(accountIndex, c.scope || modelClass, null);
      }
    }
```
  (Prefer a static `import { classifyLimitResponse } from './limit-classify.js';` at the top of server.js; make `parseSSEUsage` synchronous as today and call it directly.) The client already received the error mid-stream; opencode's retry re-dispatches and now routes to a fresh account.

**Step 4 — run green:** `node --test test/scoped-limits.test.js` → PASS. Add an integration test in `test/server-model-routing.test.js` that streams an SSE `data: {"type":"error","error":{"type":"usage_limit_error",...}}` and asserts the scope is marked (mock upstream emitting `text/event-stream`).

**Step 5 — commit:**
```bash
git add src/account-manager.js src/server.js test/scoped-limits.test.js test/server-model-routing.test.js
git commit -m "feat: mid-stream SSE usage-limit backstop marks the scope"
```

### Task 5.3: Pre-stream 429 backstop (buffer terminal body, classify, mark, re-dispatch)

**Files:**
- Modify: `src/server.js` (429 handling, terminal branch only)
- Test: add to `test/server-model-routing.test.js` (and ensure `test/server-429.test.js` stays green)

**Step 1 — failing test:** an upstream that 429s with a structured
`usage_limit_error` body for account `a`'s opus but 200s for `b`; assert the Opus
request ends up served by `b` (re-dispatched) and `a`'s opus scope is marked.
Also assert the existing IP-throttle 429 test (`server-429.test.js`) is unchanged
(those bodies are `rate_limit_error` / no usage-limit signal → back-off path).

**Step 2 — run red:** new test FAIL; `server-429.test.js` must stay PASS.

**Step 3 — implement** in `forwardRequest`'s 429 block (server.js:299-326). Today
the body is `cancel()`ed unread. Change **only the terminal (retryCount >=
maxRetries) path** to buffer+classify before throttling:
```js
      // Terminal: buffer the body once to distinguish a per-account usage limit
      // (→ mark scope, re-dispatch) from the IP-keyed throttle (→ back off).
      if (retryCount >= maxRetries) {
        let bodyJson = null;
        try { bodyJson = JSON.parse(await upstreamRes.text()); } catch { bodyJson = null; }
        const headers = Object.fromEntries(upstreamRes.headers.entries());
        const c = classifyLimitResponse(429, headers, bodyJson);
        if (c.kind === 'usage_limit' && modelClass) {
          const resetMs = scopedResetFromHeaders(headers);   // limits[].resets_at unavailable here; see below
          accountManager.markScopeExhausted(account.index, c.scope || modelClass, resetMs);
          console.log(`[TeamClaude] Usage-limit on "${account.name}" (${c.scope || modelClass}) — re-dispatching`);
          return forwardRequest(req, res, body, accountManager, upstream, retryCount + 1, hooks, reqId, ctx, logDir, modelClass);
        }
        // Not a usage limit (or no class) → existing throttle/back-off behavior.
        console.log(`[TeamClaude] Persistent 429 on "${account.name}" — throttling ${retryAfter}s and re-dispatching`);
        accountManager.markRateLimited(account.index, retryAfter);
        return forwardRequest(req, res, body, accountManager, upstream, retryCount + 1, hooks, reqId, ctx, logDir, modelClass);
      }
      // Non-terminal: keep the blind cancel + wait-and-retry (unchanged).
      await upstreamRes.body?.cancel();
```
  where `scopedResetFromHeaders(headers)` reads `anthropic-ratelimit-unified-7d-reset` (×1000) as an **approximate** fallback (design §6 m2), or null. (Note: the earlier non-terminal path keeps `cancel()`; only the terminal branch reads the body.) Reorder so the `cancel()` only runs on the non-terminal path.

**Step 4 — run green:** `node --test test/server-model-routing.test.js test/server-429.test.js` → PASS.

**Step 5 — commit:**
```bash
git add src/server.js test/server-model-routing.test.js
git commit -m "feat: pre-stream terminal-429 usage-limit backstop with re-dispatch"
```

### Task 5.4: Full fork suite green + lint

**Step 1:** `node --test` → all pass.
**Step 2:** `npm run lint` → clean (fix any eslint issues; commit `chore: lint`).
**Step 3:** Push the fork branch:
```bash
git push -u origin opus-aware
```

---

## Phase 6 — Deployment (workstation repo)

All steps in `~/Code/workstation`. The fork branch must be pushed (Phase 5.4)
and a commit chosen to pin.

### Task 6.1: Repackage `pkgs/teamclaude` via `fetchFromGitHub`

**Files:**
- Modify: `pkgs/teamclaude/default.nix`

**Step 1:** Pick the rev (tip of `opus-aware`) and compute the hash:
```bash
REV=$(git -C ~/Code/teamclaude rev-parse opus-aware)
nix store prefetch-file --json --unpack \
  "https://github.com/johnnymo87/teamclaude/archive/$REV.tar.gz" | jq -r .hash
# (or: nix-prefetch-github johnnymo87 teamclaude --rev "$REV")
```

**Step 2 — implement** — swap `fetchurl` → `fetchFromGitHub`, keep the zero-dep
vendoring `installPhase`. Replace the `version`/`src` block and the function args
(`fetchurl` → `fetchFromGitHub`):
```nix
{ lib, stdenvNoCC, fetchFromGitHub, nodejs, makeWrapper }:
stdenvNoCC.mkDerivation rec {
  pname = "teamclaude";
  version = "0-unstable-2026-06-21";          # fork; bump per pinned commit
  src = fetchFromGitHub {
    owner = "johnnymo87";
    repo = "teamclaude";
    rev = "REPLACE_WITH_REV";
    hash = "REPLACE_WITH_HASH";
  };
  nativeBuildInputs = [ makeWrapper ];
  # fetchFromGitHub yields the repo root (not ./package); src/ + package.json
  # are at the top level already, so vendor the whole tree.
  installPhase = ''
    runHook preInstall
    dest="$out/lib/teamclaude"
    mkdir -p "$dest"
    cp -r . "$dest/"
    makeWrapper ${nodejs}/bin/node "$out/bin/teamclaude" --add-flags "$dest/src/index.js"
    runHook postInstall
  '';
  meta = { /* unchanged */ };
}
```
> The npm tarball unpacked into `./package`; `fetchFromGitHub` unpacks to the
> repo root, so the old `sourceRoot` assumption is gone — `cp -r .` is correct.
> Header comment must be updated (the "bump via npm prefetch" note no longer
> applies; document the `fetchFromGitHub` rev/hash bump instead).

**Step 3 — verify build:**
```bash
nix build .#teamclaude 2>&1 | tail -5      # or the flake attr path for this host
ls -l result/bin/teamclaude
./result/bin/teamclaude --help             # smoke: binary runs
```

**Step 4 — commit:**
```bash
git add pkgs/teamclaude/default.nix
git commit -m "teamclaude: build opus-aware fork from fetchFromGitHub"
```

### Task 6.2: Unify cloudbox on the nix package

**Files:**
- Modify: `hosts/cloudbox/configuration.nix` (the `systemd.services.teamclaude` `ExecStart`, ~lines 744-771)

**Step 1 — implement** — replace the `~/projects/teamclaude/src/index.js` checkout
launch with the packaged binary (mirroring devbox's `home.devbox.nix:615`):
```nix
      ExecStart = "${pkgs.writeShellScript "teamclaude-start" ''
        set -euo pipefail
        if [ ! -f /home/dev/.config/teamclaude.json ]; then
          echo "teamclaude config missing at ~/.config/teamclaude.json (seed + login first)" >&2
          exit 1
        fi
        exec ${localPkgs.teamclaude}/bin/teamclaude server --headless
      ''}";
```
(Confirm how `localPkgs`/the teamclaude package is in scope in this module — devbox uses `localPkgs.teamclaude`; wire the same overlay/arg into `hosts/cloudbox/configuration.nix`. Drop the now-obsolete `~/projects/teamclaude` comment block and the checkout existence check.)

**Step 2 — verify:** `nixos-rebuild build --flake .#cloudbox` (dry build on macOS may
not be possible; if so, defer the actual switch to a cloudbox session and just
ensure `nix flake check`/eval succeeds here). Note `login` runs from the packaged
binary (needs TTY+browser), not the checkout (design §11 / review Q4).

**Step 3 — commit:**
```bash
git add hosts/cloudbox/configuration.nix
git commit -m "cloudbox: run teamclaude from the nix package (drop checkout)"
```

### Task 6.3: Deploy to devbox + smoke-test

**Step 1:** Push workstation; apply on devbox (home-manager owns the user service):
```bash
git push
ssh devbox 'cd ~/projects/workstation && git pull --rebase && nix run home-manager -- switch --flake .#dev'
ssh devbox 'systemctl --user restart teamclaude && sleep 2 && teamclaude status'
```

**Step 2 — smoke checks (devbox):**
- `teamclaude status` shows the new scoped line (no crash).
- Enable the probe in the **deploy config** (fork-default-on is config, not code):
  `ssh devbox 'teamclaude probe 90 && sleep 95 && teamclaude status'` → scoped
  Sonnet appears (Opus only if an Opus scope is active for the account).
- Drive a real Opus request through `127.0.0.1:3456` and confirm no regression.

**Step 3:** (cloudbox switch performed from a cloudbox session later; note in `workstation-5woc`.)

**Step 4 — commit:** none (deploy only). Record outcomes in the bead.

---

## Phase 7 — Capture-driven refinement (depends on `workstation-yuz7`)

> Only do this once the `--log-to` capture on devbox records a **real** scoped
> limit event (beads `workstation-yuz7`). Until then Phases 1–4 carry the load
> proactively and Phase 5 backs off safely on anything unrecognized.

### Task 7.1: Commit the real limit fixture + tighten predicates

**Step 1:** Pull the captured limit response from `~/.cache/teamclaude-logs` on
devbox; sanitize (it's already auth-masked) and add as
`~/Code/teamclaude/test/fixtures/usage-limit-<shape>.json` (and the matching
HTTP status/headers as a small companion fixture).

**Step 2:** Update `test/limit-classify.test.js` to assert against the real
`error.type`/headers; tighten `classifyLimitResponse`/`scopeFromBody` to the
observed structure (remove the message-string fallback if a structured
discriminator exists). TDD: failing test against the real fixture first.

**Step 3:** Confirm open question §12.2 (does an Opus scope appear in `limits[]`
only when active?) — adjust the "absence ⇒ available" assumption if the capture
contradicts it.

**Step 4 — commit + redeploy** (Phases 6.1/6.3 hash bump + switch). Then close
`workstation-yuz7`: remove `logDir` from devbox `teamclaude.json`, clean
`~/.cache/teamclaude-logs` + the `.bak` files.

---

## Done / acceptance (maps `workstation-5woc`)

- [ ] Fork created, baseline green, fixture vendored (Phase 0).
- [ ] `limits[]` → `scopedLimits` parsed (real-fixture test) + persisted (Phase 1).
- [ ] Model-aware **stateless** selection diverts per request without thrash (Phase 2).
- [ ] Generalized retry-after across all windows; `_selectNext` unified (Phase 3).
- [ ] Opus/Sonnet surfaced in `/status`, CLI, TUI (Phase 4).
- [ ] Defensive reactive backstop: structured-only, IP-throttle untouched (Phase 5).
- [ ] `pkgs/teamclaude` builds the fork via `fetchFromGitHub`; cloudbox unified; devbox deployed + smoke-tested (Phase 6).
- [ ] Real limit fixture captured → predicates tightened; `workstation-yuz7` closed (Phase 7).

## Risk register (carried from design §6/§12)

1. **Reactive wire-shape unconfirmed** (B2) → Phase 5 conservative + Phase 7 gate. Mitigation: never mark a scope on an unrecognized signal.
2. **ESM cycle** oauth↔account-manager via `modelClass` → if it bites, extract `src/model-class.js` (Task 1.2 note).
3. **Concurrency window** → up to in-flight-count Opus requests can pass before headers/poll/backstop mark the bucket (design §9; documented bound, not fixed).
4. **`fetchFromGitHub` hash churn** → every fork commit changes the hash (review n3); Phase 6.1 documents the bump.
5. **MITM path** unaffected by all of the above (scoped out, design §3) — `--mitm`/`HTTPS_PROXY` traffic gets unified-only failover.
</content>
</invoke>
