# Durable capped 1.15 + 1.16 hold — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Publish a pure, capped `opencode-patched` release `v1.15.13-patched.3`, pin it on all hosts, make the 1.15 line the active workstream, and make the auto-bump cron hold-aware so we stay on 1.15 until upstream fixes the 1.16 DB corruption.

**Architecture:** Two repos. (1) `~/projects/opencode-patched`: cut a durable `release/v1.15` branch off `c122c58` (the `v1.15.13-patched.2` stack), re-derive `retry-cap.patch` against v1.15.13 (`MessageV2` namespace, not 1.16's `SessionV1`), build `v1.15.13-patched.3` via `build-release.yml`. (2) `~/projects/workstation`: pin the new release in `users/dev/home.base.nix`, add an `opencodePatchedHold` marker, teach `update-opencode-patched.yml` to honor it, deploy, document.

**Tech Stack:** Upstream opencode (TypeScript, Bun, Effect), git, gh CLI, Nix / home-manager, GitHub Actions, bash.

**Design:** `docs/plans/2026-06-06-durable-capped-1.15-hold-design.md`

**Companion (do NOT block on):** upstream DB-corruption research session `ses_15fe27082ffe8lANCIdYmfi7TT`.

---

## Phase 1 — opencode-patched: durable 1.15 workstream + capped release

### Task 1: Cut the durable `release/v1.15` workstream branch

**Files:** none (git branch only)

**Step 1:** From `~/projects/opencode-patched`, confirm clean tree:
```bash
git -C ~/projects/opencode-patched status --short   # expect empty
git -C ~/projects/opencode-patched fetch origin --tags
```
**Step 2:** Create the branch off the proven 1.15.13 stack (`c122c58` = `v1.15.13-patched.2`):
```bash
git -C ~/projects/opencode-patched switch -c release/v1.15 c122c58
```
**Step 3:** Verify `apply.sh` already targets v1.15.13 here:
```bash
grep -n "TARGET UPSTREAM" ~/projects/opencode-patched/patches/apply.sh
# Expect: opencode v1.15.12  (header text; retargeted to .13 in Task 4 if needed)
```
**Step 4:** Confirm `retry-cap.patch` is NOT yet present on this branch (it's new):
```bash
ls ~/projects/opencode-patched/patches/retry-cap.patch 2>&1   # expect: No such file
```

### Task 2: Re-derive `retry-cap.patch` against upstream v1.15.13

Generate the patch from a pristine v1.15.13 checkout of the two target files. `retry.ts`/`retry.test.ts` are not touched by any other patch in the stack, so a 2-file diff against pristine v1.15.13 is self-contained.

**Files:**
- Create: `~/projects/opencode-patched/patches/retry-cap.patch`
- Source of truth for edits: upstream `packages/opencode/src/session/retry.ts` + `test/session/retry.test.ts` @ `v1.15.13`

**Step 1:** In the upstream clone, create a scratch worktree at v1.15.13 (keeps your main checkout untouched):
```bash
git -C ~/projects/opencode fetch origin --tags
git -C ~/projects/opencode worktree add /tmp/oc-1513 v1.15.13
```

**Step 2: Edit `retry.ts`** — `/tmp/oc-1513/packages/opencode/src/session/retry.ts`. Four edits (namespace stays `MessageV2`):

(a) After `export const RETRY_MAX_DELAY = 2_147_483_647 ...` add:
```ts
// Cap on the number of per-step stream re-issues. Each retry re-runs the entire
// model stream (a fresh, billable provider request), so an UNCAPPED schedule
// turns any persistently-retryable condition (overloaded/exhausted/flapping
// stream) into an unbounded burst of successful provider calls — the runaway
// behind the 2026-06 Vertex/Gemini surge. Stop after this many retries.
export const MAX_RETRIES = 8

// Fraction by which the no-header backoff is randomly reduced (see `jitter`).
export const RETRY_JITTER_RATIO = 0.2
```

(b) After the `cap()` function add:
```ts
// Apply downward jitter to a computed backoff so concurrent sessions stuck on
// the same retryable condition don't re-issue their (full, billable) streams in
// lockstep against a shared provider quota (thundering herd). Downward-only so
// the 30s no-header ceiling stays a true upper bound. Explicit retry-after /
// retry-after-ms hints are honored exactly and never jittered.
function jitter(ms: number) {
  return Math.round(ms * (1 - Math.random() * RETRY_JITTER_RATIO))
}
```

(c) The final return of `delay()`:
```ts
  return cap(Math.min(RETRY_INITIAL_DELAY * Math.pow(RETRY_BACKOFF_FACTOR, attempt - 1), RETRY_MAX_DELAY_NO_HEADERS))
```
becomes:
```ts
  return cap(jitter(Math.min(RETRY_INITIAL_DELAY * Math.pow(RETRY_BACKOFF_FACTOR, attempt - 1), RETRY_MAX_DELAY_NO_HEADERS)))
```

(d) In `policy()`:
```ts
      if (!retry) return Cause.done(meta.attempt)
```
becomes:
```ts
      // Stop when the error is no longer retryable OR the attempt ceiling is
      // reached. `meta.attempt` is 1-based, so `> MAX_RETRIES` allows exactly
      // MAX_RETRIES retries (MAX_RETRIES + 1 total stream issues) before the
      // schedule completes and the error propagates.
      if (!retry || meta.attempt > MAX_RETRIES) return Cause.done(meta.attempt)
```

**Step 3: Edit `retry.test.ts`** — `/tmp/oc-1513/packages/opencode/test/session/retry.test.ts`:

(a) Add `Exit` to the effect import:
```ts
import { Effect, Exit, Layer, Schedule, Schema } from "effect"
```

(b) Replace the `test("caps delay at 30 seconds when headers missing", ...)` block with the jittered version (from `main`'s `retry-cap.patch` lines 74-98), unchanged — it references `SessionRetry.RETRY_JITTER_RATIO`, no namespace.

(c) After the `describe("session.retry.delay", ...)` block, add a `describe("session.retry.policy", ...)` block identical to `main`'s `retry-cap.patch` lines 105-152, EXCEPT the decode line uses `MessageV2` (v1.15.13 namespace):
```ts
  const decode = Schema.decodeUnknownSync(MessageV2.APIError.Schema)
```
(`MessageV2` is already imported in this file; no `SessionV1` import is added.)

**Step 4: Build + test in the worktree** (proves the cap compiles and the tests pass):
```bash
cd /tmp/oc-1513 && bun install
bun test packages/opencode/test/session/retry.test.ts
```
Expected: PASS, including "halts after MAX_RETRIES attempts…" and "re-runs…at most MAX_RETRIES + 1 times".

**Step 5: Generate the patch** (a/ b/ prefixed, 2 files):
```bash
cd /tmp/oc-1513
git diff -- packages/opencode/src/session/retry.ts packages/opencode/test/session/retry.test.ts \
  > ~/projects/opencode-patched/patches/retry-cap.patch
```

**Step 6: Tear down the scratch worktree:**
```bash
git -C ~/projects/opencode worktree remove /tmp/oc-1513 --force
```

### Task 3: Wire `retry-cap.patch` into this branch's `apply.sh`

**Files:** Modify `~/projects/opencode-patched/patches/apply.sh`

**Step 1:** Mirror an existing patch's path-variable definition (near the top, where other `*_PATCH` vars are set) to add `RETRY_CAP_PATCH="$SCRIPT_DIR/retry-cap.patch"` (match the exact `SCRIPT_DIR` idiom used by the neighbors).

**Step 2:** Append the apply block (mirror `main`'s `apply.sh:290-317`) after the last existing patch, before the "Summary" section:
```bash
# --- Patch: Per-step retry attempt cap + backoff jitter (local) ---
echo "Applying retry-cap.patch..."
if ! git apply --check "$RETRY_CAP_PATCH" 2>/dev/null; then
  echo "❌ RETRY CAP PATCH FAILED TO APPLY (targets session/retry.ts policy()/delay())"
  git apply "$RETRY_CAP_PATCH" 2>&1 || true
  exit 1
fi
git apply "$RETRY_CAP_PATCH"
echo "✓ Retry cap patch applied"
```

**Step 3:** Update the `# TARGET UPSTREAM` header comment to `opencode v1.15.13` and note retry-cap is included on this 1.15 workstream branch.

### Task 4: Full local validation via the real CI path

**Step 1:** Fresh upstream checkout at v1.15.13 + run apply.sh exactly as CI does:
```bash
git -C ~/projects/opencode worktree add /tmp/oc-ci v1.15.13
cd /tmp/oc-ci && ~/projects/opencode-patched/patches/apply.sh .
```
Expected: "✓ All patches applied successfully" (every patch, incl. retry-cap, clean).

**Step 2:** Build + targeted test:
```bash
cd /tmp/oc-ci && bun install && bun run script/build.ts
bun test packages/opencode/test/session/retry.test.ts
```
Expected: build succeeds; retry tests PASS.

**Step 3:** Tear down:
```bash
git -C ~/projects/opencode worktree remove /tmp/oc-ci --force
```

### Task 5: Commit + push the branch

**Step 1:**
```bash
cd ~/projects/opencode-patched
git add patches/retry-cap.patch patches/apply.sh
git commit -m "feat(retry-cap): 1.15.13 workstream — cap per-step retries (MAX_RETRIES=8) + jitter"
git push -u origin release/v1.15
```

### Task 6: Build the release via GitHub Actions

**Step 1:** Dispatch the build from the workstream branch:
```bash
gh workflow run build-release.yml -R johnnymo87/opencode-patched \
  --ref release/v1.15 -f version=1.15.13 -f revision=3
```
**Step 2:** Watch to green:
```bash
gh run list -R johnnymo87/opencode-patched --workflow build-release.yml -L 1
gh run watch -R johnnymo87/opencode-patched <run-id>
```
**Step 3:** Confirm the release + 4 assets:
```bash
gh release view v1.15.13-patched.3 -R johnnymo87/opencode-patched
```
Expected assets: `opencode-linux-arm64.tar.gz`, `opencode-darwin-arm64.zip`, `opencode-linux-x64.tar.gz`, `opencode-darwin-x64.zip`.
**Step 4:** Do NOT mark it "latest" (leave `v1.16.2-patched.1` as latest; the hold marker drives tracking).

### Task 7: Verify cap markers in the published asset

**Step 1:**
```bash
cd /tmp && curl -sL https://github.com/johnnymo87/opencode-patched/releases/download/v1.15.13-patched.3/opencode-linux-x64.tar.gz | tar xz
./bin/opencode --version    # expect 1.15.13
rg -ac 'RETRY_JITTER_RATIO|MAX_RETRIES' ./bin/opencode   # expect >=1
rm -rf /tmp/bin
```

---

## Phase 2 — workstation: pin, hold the cron, deploy, document

### Task 8: Pin `v1.15.13-patched.3` in `home.base.nix`

**Files:** Modify `~/projects/workstation/users/dev/home.base.nix`

**Step 1:** Compute the 4 SRI hashes:
```bash
base="https://github.com/johnnymo87/opencode-patched/releases/download/v1.15.13-patched.3"
for a in opencode-linux-arm64.tar.gz opencode-darwin-arm64.zip opencode-linux-x64.tar.gz opencode-darwin-x64.zip; do
  h=$(nix-prefetch-url "$base/$a" 2>/dev/null); echo "$a -> $(nix hash convert --hash-algo sha256 --to sri "$h")"; done
```
**Step 2:** Edit the version vars (lines ~297-298): `upstreamVersion = "1.15.13";`, `patchedRevision = "3";`.
**Step 3:** Replace the 4 `hash = "sha256-…"` values in `opencode-platforms` (lines 256/261/266/271) with the matching SRI hashes from Step 1.
**Step 4:** Refresh the rationale comment block (lines ~285-296): durable pure cure on `v1.15.13-patched.3`; 1.15 is the active workstream; 1.16 held pending upstream DB-corruption fix; rollback = prior generation.

### Task 9: Add the `opencodePatchedHold` marker

**Files:** Modify `~/projects/workstation/users/dev/home.base.nix`

**Step 1:** Next to the version vars add:
```nix
    # Version hold: while non-empty, the update-opencode-patched cron tracks the
    # latest "v<hold>-patched.N" release instead of releases/latest, so we stay on
    # this upstream line. Set to "" to resume tracking the newest release.
    # Held at 1.15.13 (2026-06-06) pending an upstream fix for the 1.16 DB
    # corruption (research session ses_15fe27082ffe8lANCIdYmfi7TT).
    opencodePatchedHold = "1.15.13";
```
(Nix `let` binding; it just needs to be greppable by the workflow. It does not need to feed the derivation.)

### Task 10: Make `update-opencode-patched.yml` hold-aware

**Files:** Modify `~/projects/workstation/.github/workflows/update-opencode-patched.yml`

**Step 1:** In the "Check for new release" step, after parsing `current_ver`/`current_rev`, read the hold and compute the effective target tag:
```bash
hold=$(grep 'opencodePatchedHold = ' "$file" | head -1 | sed 's/.*"\([^"]*\)".*/\1/')
echo "hold=$hold" >> "$GITHUB_OUTPUT"

if [ -n "$hold" ]; then
  # Track the highest revision on the held upstream line, not releases/latest.
  latest_tag=$(gh api repos/johnnymo87/opencode-patched/releases --paginate \
    --jq ".[].tag_name | select(startswith(\"v${hold}-patched\"))" \
    | sort -t. -k4 -n | tail -1)
  if [ -z "$latest_tag" ]; then
    echo "No release found for held line v${hold}-patched*; nothing to do."; exit 0
  fi
else
  latest_tag=$(gh api repos/johnnymo87/opencode-patched/releases/latest --jq '.tag_name')
fi
latest_ver=$(echo "$latest_tag" | sed 's/^v//;s/-patched.*//')
latest_rev=$(echo "$latest_tag" | sed -n 's/.*-patched\.\([0-9][0-9]*\)$/\1/p')
```
**Step 2:** Add a guard before the bump: while held, never bump off the line:
```bash
if [ -n "$hold" ] && [ "$latest_ver" != "$hold" ]; then
  echo "Held at $hold; refusing to bump to $latest_ver."; exit 0
fi
```
**Step 3:** Leave the hash + PR steps unchanged (they consume `latest_tag`/`latest_ver`/`latest_rev`). When `hold=""`, behavior is byte-identical to today.

### Task 11: Deploy on cloudbox (pure switch + serve restart)

**Step 1:** Pure build (must succeed WITHOUT `--impure`):
```bash
cd ~/projects/workstation && home-manager build --flake .#dev@cloudbox 2>&1 | tail -20
```
(Use the host's normal switch invocation; confirm the flake attr first with `nix flake show` if unsure.)
**Step 2:** Switch:
```bash
home-manager switch --flake .#dev@cloudbox
```
**Step 3:** Restart serve onto the new binary:
```bash
sudo systemctl restart opencode-serve && systemctl status opencode-serve --no-pager | head -5
```

### Task 12: Verify the deploy (evidence before "done")

**Step 1:** Interactive binary:
```bash
readlink -f "$(which opencode)"   # expect a NEW pure store path, NOT wmf3lc23…
opencode --version                # expect 1.15.13
```
**Step 2:** Serve binary + cap markers:
```bash
PID=$(systemctl show opencode-serve -p MainPID --value)
exe=$(sudo readlink -f /proc/$PID/exe); echo "$exe"
rg -ac 'RETRY_JITTER_RATIO|MAX_RETRIES' "$exe"   # expect >=1
```
**Step 3:** Health:
```bash
curl -s http://localhost:4096/global/health
```

### Task 13: Verify the cron honors the hold (no bump PR)

**Step 1:** Commit Phase-2 changes first (see Task 14), push, then dry-run:
```bash
gh workflow run update-opencode-patched.yml -R <workstation-owner>/workstation
gh run watch -R <workstation-owner>/workstation <run-id>
```
**Step 2:** Confirm the run log shows it selected `v1.15.13-patched.3` and opened **no** PR (`git diff --quiet` path / "Held at 1.15.13" or "Identity unchanged").
**Step 3:** Confirm no `auto/update-opencode-patched` PR was opened:
```bash
gh pr list -R <workstation-owner>/workstation --head auto/update-opencode-patched
```

### Task 14: Documentation + commits

**Files:**
- Modify: `~/projects/workstation/docs/investigations/2026-06-05-vertex-gemini-surge/HANDOFF.md`
- (design + plan already written this session)

**Step 1:** Append a HANDOFF.md update superseding "INCIDENT CLOSED on 1.16.2.1": held on capped `v1.15.13-patched.3`; 1.16 deferred pending upstream DB-corruption fix (research `ses_15fe27082ffe8lANCIdYmfi7TT`); record the lift-hold steps (set `opencodePatchedHold=""`, refresh main onto fixed 1.16.x, cut capped release, bump, switch).
**Step 2:** Commit workstation changes:
```bash
cd ~/projects/workstation
git add users/dev/home.base.nix .github/workflows/update-opencode-patched.yml \
  docs/plans/2026-06-06-durable-capped-1.15-hold*.md \
  docs/investigations/2026-06-05-vertex-gemini-surge/HANDOFF.md
git commit -m "deploy(opencode): hold on capped v1.15.13-patched.3; cron hold-aware; defer 1.16"
```
**Step 3:** Push (only if/when the user asks).

---

## Lift-hold (future)

When `ses_15fe27082ffe8lANCIdYmfi7TT` confirms an upstream DB-corruption fix in a 1.16.x: refresh `opencode-patched@main` onto it, cut a capped release, set `opencodePatchedHold = ""` in `home.base.nix`, bump + `home-manager switch`. The cron resumes tracking `releases/latest` automatically.

## Notes
- DRY/YAGNI: retry.ts cap edits are namespace-identical across versions; only the test's `decode` line + `Exit` import differ from `main`'s patch.
- No tag collision: `v1.15.13-patched.3` does not exist (tags stop at `.2`).
- Rollback during deploy: re-activate the prior generation (currently gen 384 / store `3v2q6ir2…` = the `--impure` 1.15.13.3) and `sudo systemctl restart opencode-serve`.
