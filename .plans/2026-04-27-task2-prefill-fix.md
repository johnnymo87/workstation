# Task 2: Ship the prefill fix into opencode-patched

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Land the multi-cwd `prompt_async` race fix as a patch in
`~/projects/opencode-patched/patches/`, so the prefill 400 errors stop
happening on this devbox (and any other host running our patched
opencode binary).

**Architecture:** Wrap every `/session/:sessionID/*` route handler in
opencode's REST server with a helper that reads the session row's stored
`directory`, then re-enters the `Instance` matching THAT directory before
running the route's session-scoped work. This forces every request
touching a specific session to land in the same Instance, sharing the
same `SessionRunState.runners` map (the per-session busy guard). Pigeon
already does this at the client layer; the patch closes the same hole at
the server layer for non-pigeon callers (TUI, scripts, multi-attached
clients).

**Tech Stack:** TypeScript + Effect + Hono (opencode); git apply
(patch stack); GitHub Actions (build/release).

---

## Why this plan exists

A previous brainstorming session in late April 2026 wrote
`docs/plans/2026-04-21-opencode-prefill-fix-design.md` which fully
diagnosed the bug, proposed the fix, and listed the routes that need
wrapping. **That doc is the source of truth for the fix design — read it
first.** This plan only adds:

1. A confirmed reproduction (the prior design relied on field reports;
   we now have a deterministic 4-line shell repro).
2. The execution sequence to actually land the patch in our local
   `opencode-patched` fork (rather than upstream).
3. A test that runs the repro against the patched binary to verify the
   fix.

If you skipped the prior design doc, **stop and read it** before doing
anything in this plan. The relevant sections are:
- "Problem (one-paragraph recap)"
- "Fix"
- "Implementation sketch (v1.14.19 layout)" — note: refresh to v1.14.25
  layout when implementing; the routes file is at the same path but
  some line numbers will have shifted.

---

## Confirmed reproduction (added by this plan)

Run from any directory (the script creates and tears down its own
session). Requires `nix-shell -p sqlite` for the inspect step.

```bash
SID=$(curl -sf -X POST "http://127.0.0.1:4096/session" \
  -H "x-opencode-directory: /tmp/repro-prefill" 2>/dev/null | jq -r '.id')
mkdir -p /tmp/repro-prefill

# Fire 4 concurrent prompt_async POSTs from 4 distinct cwd headers.
for cwd in /tmp/repro-prefill /home/dev /home/dev/projects/mono /home/dev/projects/pigeon; do
  curl -sf -X POST "http://127.0.0.1:4096/session/$SID/prompt_async" \
    -H "Content-Type: application/json" \
    -H "x-opencode-directory: $cwd" \
    --data "{\"parts\":[{\"type\":\"text\",\"text\":\"From cwd $cwd: count to 3 and stop.\"}]}" \
    -o /dev/null -w "POST $cwd status=%{http_code}\n" &
done
wait
sleep 15

# Inspect: with the bug, you'll see multiple assistant messages per user
# (1 per cwd) and at least one assistant whose error.data.message contains
# "does not support assistant message prefill". With the fix, you should
# see ONE assistant child per user message and zero prefill errors.
nix-shell -p sqlite --run "sqlite3 -readonly /home/dev/.local/share/opencode/opencode.db \"SELECT json_extract(data, '\\\$.role') as role, json_extract(data, '\\\$.path.cwd') as cwd, COALESCE(substr(json_extract(data, '\\\$.error.data.message'),1,40),'') as err FROM message WHERE session_id='$SID' ORDER BY time_created;\""

# Cleanup
curl -sf -X DELETE "http://127.0.0.1:4096/session/$SID"
```

**Expected output BEFORE fix** (with bug present):

```
user||
user||
user||
assistant|/home/dev/projects/mono|
assistant|/tmp/repro-prefill|
assistant|/home/dev|
user||
assistant|/home/dev/projects/pigeon|
assistant|/tmp/repro-prefill|
assistant|/home/dev/projects/mono|
assistant|/home/dev|
assistant|/tmp/repro-prefill|This model does not support assistant
assistant|/home/dev/projects/pigeon|This model does not support assistant
assistant|/home/dev|This model does not support assistant
assistant|/home/dev/projects/mono|This model does not support assistant
```

(Different `cwd` values per assistant = different Instances ran. Multiple
assistant children per user = busy guard bypassed. 4 prefill errors =
Anthropic rejected the racing requests.)

**Expected output AFTER fix:**

```
user||
user||
user||
user||
assistant|/tmp/repro-prefill|
assistant|/tmp/repro-prefill|
assistant|/tmp/repro-prefill|
assistant|/tmp/repro-prefill|
```

(Single cwd everywhere = single Instance. One assistant per user = busy
guard held. Zero errors.)

---

## Reference reading

These files explain the bug. Read them first.

- `docs/plans/2026-04-21-opencode-prefill-fix-design.md` — full design
  (you are extending this plan, not replacing it).
- `~/projects/opencode/packages/opencode/src/session/run-state.ts` —
  the per-session busy guard. The `runners` Map is created via
  `InstanceState.make`, so it's keyed per Instance. Two Instances → two
  runners maps → busy guard bypassed.
- `~/projects/opencode/packages/opencode/src/effect/instance-state.ts`
  — `ScopedCache.get(self.cache, yield* directory)` confirms keying is
  by `directory`.
- `~/projects/opencode/packages/opencode/src/server/middleware.ts:90`
  — the line that derives Instance from `x-opencode-directory` per
  request.
- `~/projects/opencode/packages/opencode/src/server/routes/instance/session.ts`
  — the routes that need wrapping. See line 891 for `prompt_async` as
  the canonical example.
- `~/projects/opencode-patched/patches/apply.sh` — how the patch stack
  is applied to a fresh checkout of `anomalyco/opencode` during
  release builds.
- `~/projects/opencode-patched/.github/workflows/build-release.yml` —
  the CI workflow that consumes the patch stack and publishes the
  binary.

---

## Task 1: Verify the bug still exists in current `opencode-patched`

**Files:**
- Read-only: `~/projects/opencode/packages/opencode/src/server/routes/instance/session.ts`
- Read-only: `~/.local/share/opencode/opencode.db` (via sqlite)

**Step 1: Confirm running version**

```bash
~/.nix-profile/bin/opencode --version
# expected: 1.14.25 (or whatever opencode-patched currently builds against)
```

**Step 2: Run the reproduction script (above)**

Save the output to `/tmp/repro-before-fix.txt`. Confirm at least one
prefill error in the output. If you see ZERO errors, the bug may have
been worked around by something else and the design needs revisiting.
**Do not proceed to write the patch if you can't reproduce — file a bd
issue describing what you saw and stop.**

**Step 3: Identify the actual upstream version the patched binary is
built against**

```bash
cat ~/projects/opencode-patched/.github/workflows/build-release.yml | grep -A2 "checkout\|version" | head -20
```

The workflow checks out `anomalyco/opencode` at a tag matching the
patched version. Verify by:

```bash
cd ~/projects/opencode && git log --oneline -1
# the SHA your local opencode checkout points at — should match what
# build-release.yml fetches.
```

If your local `~/projects/opencode` is on a different commit than what
CI uses, fetch + checkout the matching tag before reading line numbers
in the next step:

```bash
cd ~/projects/opencode && git fetch --tags && git checkout v1.14.25
```

---

## Task 2: Write the patch

**Files:**
- Create: `~/projects/opencode-patched/patches/prefill-fix.patch`
- Modify: `~/projects/opencode-patched/patches/apply.sh`

**Step 1: Identify exact line numbers in the current upstream**

```bash
cd ~/projects/opencode
grep -n "/:sessionID" packages/opencode/src/server/routes/instance/session.ts | head -30
```

You'll get a list of route definitions like
`.get("/:sessionID", ...)`, `.post("/:sessionID/prompt_async", ...)`, etc.
Note the line numbers. The full list of routes that need wrapping is in
`docs/plans/2026-04-21-opencode-prefill-fix-design.md` under section "B.
Wrap every `/:sessionID/...` route's handler body."

**Step 2: Implement the helper in `session.ts`**

Following the design doc's "A. New helper" sketch, add a
`withSessionInstance` helper near the top of `SessionRoutes`'s file (or
in a new file `~/projects/opencode/packages/opencode/src/server/routes/instance/session-instance-helper.ts`
if the diff is cleaner that way).

The helper:
1. Takes a `sessionID` and a thunk.
2. Reads `Session.Service.get(sessionID)` to get the row's `directory`.
3. Calls `Instance.provide({ directory, init: ..., fn: thunk })`.
4. Returns the result.

If the session doesn't exist, throw 404 (preserve current behavior).

**Step 3: Wrap each `/:sessionID/...` handler**

For each route in the design doc's list, change:

```ts
async (c) => {
  const sessionID = c.req.valid("param").sessionID
  // ... existing body ...
}
```

to:

```ts
async (c) => {
  const sessionID = c.req.valid("param").sessionID
  return withSessionInstance(sessionID, async () => {
    // ... existing body ...
  })
}
```

For `prompt_async` specifically, the wrapper goes around the `void
runRequest(...)` block, NOT around the `return c.body(null, 204)` —
otherwise the wrapper waits for the run to finish before returning 204.
The detached pattern is:

```ts
async (c) => {
  const sessionID = c.req.valid("param").sessionID
  const body = c.req.valid("json")
  // Don't await — fire-and-forget under the session's own Instance.
  void withSessionInstance(sessionID, () =>
    runRequest(
      "SessionRoutes.prompt_async", c,
      SessionPrompt.Service.use((svc) => svc.prompt({ ...body, sessionID })),
    ),
  ).catch((err) => {
    log.error("prompt_async failed", { sessionID, error: err })
    void Bus.publish(Session.Event.Error, { sessionID, error: ... })
  })
  return c.body(null, 204)
}
```

DO NOT wrap the listing routes (`GET /` for list, `POST /` for create) —
they don't operate on a specific session id. The design doc explicitly
calls this out in "NOT to be wrapped".

**Step 4: Generate the patch**

```bash
cd ~/projects/opencode
git diff > ~/projects/opencode-patched/patches/prefill-fix.patch
git checkout -- .  # clean up so the patch can be re-applied later
```

Inspect the patch:

```bash
wc -l ~/projects/opencode-patched/patches/prefill-fix.patch
head -50 ~/projects/opencode-patched/patches/prefill-fix.patch
```

Expected: ~150-300 lines depending on how many routes you wrapped.

**Step 5: Add the patch to `apply.sh`**

Edit `~/projects/opencode-patched/patches/apply.sh`. Insert a new patch
application block AFTER `eager-input-streaming.patch` and before the
`# --- Summary ---` block. Mirror the existing pattern:

```bash
# --- Patch 6: Prefill race fix (rebind session routes to session.directory) ---

PREFILL_FIX_PATCH="$SCRIPT_DIR/prefill-fix.patch"

if [ ! -f "$PREFILL_FIX_PATCH" ]; then
  echo "Error: Prefill fix patch not found: $PREFILL_FIX_PATCH"
  exit 1
fi

echo "Applying prefill-fix.patch..."
if ! git apply --check "$PREFILL_FIX_PATCH" 2>/dev/null; then
  echo ""
  echo "❌ PREFILL FIX PATCH FAILED TO APPLY"
  echo ""
  echo "Attempting to apply for diagnostics..."
  git apply "$PREFILL_FIX_PATCH" 2>&1 || true
  echo ""
  echo "Failed files:"
  find . -name "*.rej" -type f 2>/dev/null || echo "  None found"
  echo ""
  echo "The prefill fix patch may need updating for this upstream version."
  echo "Refs: docs/plans/2026-04-21-opencode-prefill-fix-design.md"
  exit 1
fi

git apply "$PREFILL_FIX_PATCH"
echo "✓ Prefill fix patch applied"
```

Also add the file existence check near the top of the script, mirroring
the others:

```bash
PREFILL_FIX_PATCH="$SCRIPT_DIR/prefill-fix.patch"
# ... add to the existing list of "if [ ! -f ... ]" checks
```

**Step 6: Smoke-test apply.sh against a fresh opencode checkout**

```bash
cd /tmp
rm -rf opencode-test
git clone --depth 1 --branch v1.14.25 https://github.com/anomalyco/opencode.git opencode-test
cd opencode-test
~/projects/opencode-patched/patches/apply.sh "$PWD"
# expected: "✓ All patches applied successfully"
```

If the script exits with "PREFILL FIX PATCH FAILED TO APPLY", the patch
context doesn't match. Refresh the patch by re-doing Step 4 against the
current checkout, then retry.

**Step 7: Commit the patch and apply.sh changes**

```bash
cd ~/projects/opencode-patched
git add patches/prefill-fix.patch patches/apply.sh
git commit -m "fix(prompt_async): rebind session routes to session.directory

Closes the multi-cwd Instance race that produces 400 'does not support
assistant message prefill' from Anthropic when concurrent prompt_async
requests arrive with different x-opencode-directory headers. See
docs/plans/2026-04-21-opencode-prefill-fix-design.md for the full root
cause; reproduction in workstation/.plans/2026-04-27-task2-prefill-fix.md."
git push
```

---

## Task 3: Build, install, and verify

The build-release workflow on `opencode-patched` runs on push and
publishes a binary. The workstation auto-update workflow
(`.github/workflows/update-opencode-patched.yml`) polls every 8 hours
and opens a PR to `home.base.nix`.

**Step 1: Wait for the patched binary to publish**

```bash
gh -R johnnymo87/opencode-patched run list --limit 5
gh -R johnnymo87/opencode-patched release list --limit 3
```

When the new release tag appears, it's safe to bump.

**Step 2: Bump workstation manually (don't wait for the auto-PR)**

```bash
cd ~/projects/workstation
# Look up the new release URL + sha256 — the auto-update workflow does
# this with `nix-prefetch-url`. Run that script manually:
.github/scripts/update-opencode-patched.sh 2>&1 | tee /tmp/update.log
# OR if there's no script and the workflow does it inline, copy the
# relevant nix-prefetch invocation out of the workflow file and run it.
```

If a PR opens itself in parallel, just close one of them.

**Step 3: Apply the bump**

```bash
nix run home-manager -- switch --flake /home/dev/projects/workstation#dev
```

**Step 4: Restart `opencode serve`**

```bash
# Find and kill the existing serve
pgrep -fa "opencode serve" | head
# kill <pid>; opencode-serve restarts via systemd or the next session
# spawn — check whichever applies on this host (see workstation README
# for the serve unit name if there is one).
```

**Step 5: Re-run the reproduction script**

```bash
# Same script as Task 1, Step 2. Redirect output to /tmp/repro-after-fix.txt.
```

**Step 6: Verify zero prefill errors**

```bash
diff /tmp/repro-before-fix.txt /tmp/repro-after-fix.txt
# expected: many differences — before had multiple cwds + prefill
# errors; after should have one cwd everywhere and zero error rows.
```

If errors persist:
1. Confirm the binary is the new one: `~/.nix-profile/bin/opencode --version`
   should show the new patched version.
2. Confirm the patch landed in the running binary: this is harder —
   the simplest check is to read
   `~/.nix-profile/share/opencode/.../session.ts` (path varies) and
   grep for `withSessionInstance`.
3. If the patch is in the binary but errors persist, the design is
   wrong somewhere. Reopen `docs/plans/2026-04-21-opencode-prefill-fix-design.md`
   and find the gap.

**Step 7: Commit the bump (if not already merged via auto-PR) and push**

```bash
cd ~/projects/workstation
git add users/dev/home.base.nix
git commit -m "feat(opencode-patched): bump to <version> with prefill-fix.patch"
git pull --rebase
git push
git status  # MUST show "up to date with origin"
```

---

## Out of scope

- **Pigeon-side defensive arbitration** (wait for "session idle and
  last-message-is-assistant" before delivering). Once the upstream fix
  lands, pigeon's single-writer-per-target arbiter combined with the
  session-pinned Instance is sufficient. Adding a state-poll on top
  would burn 100ms+ per delivery for no win. YAGNI.
- **Backporting the fix to vanilla `opencode` upstream.** The prior
  design suggested filing an issue against `anomalyco/opencode` (Step 3
  of the 2026-04-21 design's "outstanding work"). The user explicitly
  scoped this plan to our fork; an upstream PR can be a follow-up.
- **Telemetry / observability** (counting prefill errors over time).
  Useful but separate concern; can be a follow-up bd issue.

## Risk and rollback

- **Risk: the patch breaks a route that legitimately needs the
  caller-supplied directory.** The design doc's "Open questions" #3
  flagged this. None are known today, but if a route fails after the
  patch lands, the fix is to remove that route from the wrapped list.
  Rollback path: revert the `apply.sh` change to skip the patch + bump
  workstation again.
- **Risk: pinning Instance per session breaks `Permission.containsPath`
  for tools that need to write outside `session.directory`.** The
  design doc's "Knock-on benefits" section argues this is correct
  behavior, not a regression. If a real complaint surfaces, revisit.
- **Risk: the patch context shifts as upstream evolves.** The patch
  stack already handles this for `vim.patch` etc. — context drift gets
  caught by the `git apply --check` step in `apply.sh` at next build.
  Refresh the patch as needed.
