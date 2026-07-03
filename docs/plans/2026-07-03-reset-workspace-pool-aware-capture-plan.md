# reset-workspace Pool-Aware Capture Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make `reset-workspace`'s session-capture survive a single wedged pool serve, so the nightly morning-recommendation flow doesn't silently produce nothing when serve-0 (4096) is unhealthy.

**Architecture:** Three changes to `pkgs/reset-workspace/default.nix`. (1) Run the strict-attach capture loop *unconditionally* — it reads session ids from `/proc/<pid>/cmdline` and needs no serve. (2) Make the pre-capture health check *pool-aware*: probe every pool member (reusing the existing `pool_health_urls_from_wants` helper) and use the first healthy one to resolve bare-TUI sids; only skip the bare-resolve loop when *no* member is healthy. Because all pool serves share one `opencode.db`, any healthy member can resolve `cwd → sid`. (3) Write the manifest *before* the kill/restart gauntlet, so a restart or health-poll `die` can't discard a successful capture.

**Tech Stack:** Bash (via `pkgs.writeShellApplication`), systemd (user target on devbox, system target on cloudbox; crostini has *no* pool target), Nix, `curl`/`jq`, `pkgs/reset-workspace/test.sh` (pure-helper mirrors + stubbed-systemctl mirrors + source-grep guards).

> **Revision 2 (2026-07-03),** after the adversarial review at
> `docs/plans/2026-07-03-reset-workspace-pool-aware-capture-adversarial-review.md`:
> - **B1:** acceptance no longer sets `RESET_WORKSPACE_NO_DETACH=1` (self-kill hazard when run from an opencode bash tool); added a wedge-realistic SIGSTOP variant.
> - **B2:** test guards made capture-distinctive (`capture_pool_urls`, not the false-green `"$u/global/health"` which matches the post-restart poll at `default.nix:439`); added a `refuse_grep` negative guard asserting the old `OC_ATTACH_PIDS=""` gate stays gone.
> - **B3:** `pool_scope` comment corrected — crostini has **no** pool target (`home.crostini.nix:135` defines plain `opencode-serve.service`), so it takes the "system" branch and degrades to the `$OPENCODE_URL` fallback.
> - **A1:** manifest write hoisted to before the restart (new Task 7).
> - **A2:** pool discovery reads `Wants=` unprivileged-first (`systemctl show` needs no root — verified on devbox as uid 1000), with a `sudo -n` fallback that can never prompt-hang.
> - **A3:** `pool_scope`/`discover_pool_urls` get real mirror tests via a shell-function `systemctl` stub, not just grep guards.
> - **N1:** test.sh guard edits are folded into the same commit as each code change, so `bash pkgs/reset-workspace/test.sh` is green at every commit (no bisect hazard).
> - **N2:** per-task gate upgraded from `nix-instantiate --parse` (misses eval-time escaping bugs and shellcheck) to `nix build --no-link .#reset-workspace` (verified: builds standalone in seconds, runs `writeShellApplication`'s shellcheck).

---

## Background (root cause this fixes)

On devbox 2026-07-03 the morning restore produced nothing. At 03:00 the nightly `reset-workspace` ran while serve-0 (`opencode-serve@4096`) was **wedged** — heap had grown toward `MemoryHigh=4G`, the resulting swap thrash stalled the JS event loop, so `/global/health` didn't answer within the 3s probe (the process took 90s to SIGTERM → SIGKILL). The capture pre-check (`SERVE_HEALTHY` gate, workstation-7sbo, `default.nix:215-219`) probes **only** the hardcoded `$OPENCODE_URL` (4096); on failure it sets `SERVE_HEALTHY=0`, which skips **both** capture loops → empty manifest → `no sessions to recommend` → no recommendation session → no Telegram, no reopened tabs. cloudbox's 4096 was healthy that morning, so it captured 28 sessions and launched normally — that is the *entire* difference between the two hosts.

Two design gaps made a single wedged serve nuke the whole restore:

1. **The gate is broader than necessary.** Only the **bare-resolve** loop (`default.nix:287-339`) calls the serve (a `curl` to resolve `cwd → sid`). The **strict-attach** loop (`default.nix:247-275`) reads sids straight from `/proc/<pid>/cmdline` and needs no serve at all (verified line-by-line in the adversarial review: zero network calls). Historically captures are almost entirely strict-attach (`bare-resolved` was 0 on 6 of the last 7 devbox mornings, and 0/28 on cloudbox this morning), so an argv-only capture would have preserved the morning restore even with 4096 wedged.
2. **The pre-check is not pool-aware.** It probes only 4096 even though devbox's pool is `[4096 4097]` (4097 was healthy at 03:00) and all serves share one `opencode.db`, so any healthy member can resolve `cwd → sid`. The helper to enumerate pool members from the target's `Wants=` already exists (`pool_health_urls_from_wants`, `default.nix:58`) but is used only by the *post-restart* readiness poll (`default.nix:425`).

A third gap (found in review): the manifest write (`default.nix:459-466`) sits *after* two `die` sites — restart failure (:401/:411) and the 30s post-restart health poll (:449-451) — so even a perfect capture is discarded if the pool doesn't come back within 30s. On a swap-thrashing box at 03:00 (the workstation-94g8 regime) that is plausible.

Related tracking: **workstation-3smg** (this fix) and **workstation-94g8** (the serve-wedge root cause; out of scope here — a serve bloating over 24h is the expected degradation the reset exists to clear).

## Files touched

- Modify: `pkgs/reset-workspace/default.nix`
  - Add two helpers after `pool_health_urls_from_wants` (currently ends `default.nix:75`).
  - Compute `POOL_SCOPE` once, before capture (after the `main` allowlist is built, `default.nix:188`).
  - Replace the pre-capture health probe *and its stale comment* (`default.nix:202-219`).
  - Ungate the strict-attach loop (`default.nix:240-246`).
  - Point the bare-resolve resolution `curl` at `CAPTURE_URL` (`default.nix:325`); keep its `SERVE_HEALTHY` gate (`default.nix:285-291`).
  - Refactor the restart scope branch (`default.nix:386-413`) and post-restart poll discovery (`default.nix:420-425`) to reuse `POOL_SCOPE` / `discover_pool_urls`.
  - Move the manifest write (`default.nix:459-466`) to before the nvim kill (after the confirm at `default.nix:368`).
- Modify: `pkgs/reset-workspace/test.sh` — **in the same commit as each code change it guards** (mirrors + stub + guards; details per task).

## Design decisions

- **`CAPTURE_URL` (not reusing `$OPENCODE_URL`)** so the bare-resolve `curl` targets whichever member answered `/global/health`, not always 4096. Falls back to `$OPENCODE_URL` if discovery yields nothing (pre-pool behavior preserved).
- **`SERVE_HEALTHY` now gates only the bare-resolve loop.** Its meaning narrows from "serve-0 is up" to "at least one pool member is up (and we picked it as `CAPTURE_URL`)".
- **Hoist `POOL_SCOPE` to a single early computation** via a new `pool_scope()` helper, reused by (a) pre-capture discovery, (b) the restart command, (c) the post-restart poll — eliminating the duplicated `systemctl --user is-active` / scope-branch logic and guaranteeing capture and restart agree on scope. (Review-verified: nothing between the early computation and the restart mutates target active-state, and flock prevents concurrent resets.)
- **Discovery reads are unprivileged-first.** `systemctl show -p Wants --value <system-target>` works as uid 1000 (unit properties are world-readable over the system bus; verified on devbox). Fall back to `/run/wrappers/bin/sudo -n` only if the unprivileged read yields nothing — `-n` never prompts, so the capture path can never hang on a password. On crostini (non-NixOS, no `/run/wrappers`, no pool target) both reads fail silently and discovery degrades to `$OPENCODE_URL` — which matches crostini's single 4096 serve.
- **Keep both timeouts** on the bare-resolve `curl` (`--max-time 5 --connect-timeout 3`) as belt-and-suspenders against a member that passes `/global/health` but hangs on `/session` (workstation-7sbo rationale still holds). Worst-case capture overhead with all K members wedged-but-accepting: K x 3s probes (12s on cloudbox K=4) — bounded, then straight to the restart.
- **Manifest write moves before the kill/restart gauntlet** (after the `[y/N]` confirm, so an aborted interactive run doesn't clobber the previous reset's manifest; before the nvim kill, so no later `die` can discard the capture). The recommendation *launch* stays post-restart — it genuinely needs a healthy serve.
- **No behavior change on the happy path:** when 4096 is healthy, `discover_pool_urls` returns `[4096 4097 …]` in port order, the loop picks 4096 first (`CAPTURE_URL=4096`), `SERVE_HEALTHY=1`, and both loops run exactly as before.
- **Test guards must be capture-distinctive.** `'"$u/global/health"'` already appears in the post-restart poll (`default.nix:439`) and would be false-green; guard on `capture_pool_urls` (appears only in the capture block) and `CAPTURE_URL` instead. The removed gate gets a *negative* guard (`refuse_grep 'OC_ATTACH_PIDS=""'`) so it can't silently come back.

## Per-task verification (run after EVERY task, before its commit)

```bash
nix build --no-link .#reset-workspace     # Nix eval + shellcheck (writeShellApplication) + build; ~seconds
bash pkgs/reset-workspace/test.sh          # ALL PASS — must be green at every commit
```

`nix-instantiate --parse` alone is NOT sufficient: a mis-escaped `${VAR}` that parses as a valid Nix identifier only fails at eval (or worse, silently interpolates), and parse never runs shellcheck.

---

## Task 1: Add `pool_scope` + `discover_pool_urls` helpers (with mirror tests)

**Files:**
- Modify: `pkgs/reset-workspace/test.sh` (stub + mirrors + unit checks + source guards)
- Modify: `pkgs/reset-workspace/default.nix` (insert after `pool_health_urls_from_wants`, which ends at line 75)

**Step 1: Write the failing tests**

In `test.sh`, insert this block after the existing pure-helper checks (after line 73, before the `# ---- source guards` section):

```bash
# ---- scope + discovery mirrors (stubbed systemctl) ---------------------------
# pool_scope / discover_pool_urls mirrors (lockstep with default.nix). A shell
# function named `systemctl` shadows the real binary for the rest of this
# script, so these run hermetically on any host. NOTE: the system branch's
# empty-wants -> sudo-fallback path is NOT exercised here (the absolute
# /run/wrappers/bin/sudo path is not stub-able, and calling it for real would
# make the test host-dependent — on cloudbox it would return the REAL pool).
# Empty-wants -> $OPENCODE_URL fallback is covered by the pure
# pool_health_urls_from_wants checks above.
systemctl() { # test stub; cases match the exact "$*" of each source call site
  case "$*" in
    "--user is-active --quiet opencode-serve-pool.target") return "${STUB_USER_ACTIVE_RC:-1}" ;;
    "--user show -p Wants --value opencode-serve-pool.target") printf '%s\n' "${STUB_USER_WANTS:-}" ;;
    "show -p Wants --value opencode-serve-pool.target") printf '%s\n' "${STUB_SYS_WANTS:-}" ;;
    *) echo "unexpected systemctl call in test: $*" >&2; return 1 ;;
  esac
}

pool_scope() {
  if systemctl --user is-active --quiet opencode-serve-pool.target 2>/dev/null; then
    printf 'user\n'
  else
    printf 'system\n'
  fi
}

discover_pool_urls() {
  local scope="$1" wants
  if [ "$scope" = "user" ]; then
    wants="$(systemctl --user show -p Wants --value opencode-serve-pool.target 2>/dev/null || true)"
  else
    wants="$(systemctl show -p Wants --value opencode-serve-pool.target 2>/dev/null || true)"
    if [ -z "$wants" ]; then
      wants="$(/run/wrappers/bin/sudo -n systemctl show -p Wants --value opencode-serve-pool.target 2>/dev/null || true)"
    fi
  fi
  pool_health_urls_from_wants "$wants" "$OPENCODE_URL"
}

OPENCODE_URL="$fb"  # discover_pool_urls reads this global, same as the source

check "pool_scope: active user target -> user"   "user"   "$(STUB_USER_ACTIVE_RC=0 pool_scope)"
check "pool_scope: no user target -> system"     "system" "$(STUB_USER_ACTIVE_RC=1 pool_scope)"
check "discover: user scope K=2 (devbox)" \
  "http://127.0.0.1:4096 http://127.0.0.1:4097" \
  "$(STUB_USER_WANTS='opencode-serve@4096.service opencode-serve@4097.service' discover_pool_urls user | tr '\n' ' ' | sed 's/ $//')"
check "discover: system scope K=4 (cloudbox, unprivileged read)" \
  "http://127.0.0.1:4096 http://127.0.0.1:4097 http://127.0.0.1:4098 http://127.0.0.1:4099" \
  "$(STUB_SYS_WANTS='opencode-serve@4096.service opencode-serve@4097.service opencode-serve@4098.service opencode-serve@4099.service' discover_pool_urls system | tr '\n' ' ' | sed 's/ $//')"
```

And add these source guards inside the existing `if [ -f "$default_nix" ]` block:

```bash
  want_grep "source defines pool_scope"                    'pool_scope() {'
  want_grep "source defines discover_pool_urls"            'discover_pool_urls() {'
  want_grep "pool discovery reads Wants unprivileged first" 'wants="$(systemctl show -p Wants --value opencode-serve-pool.target 2>/dev/null || true)"'
  want_grep "pool discovery sudo fallback never prompts"    'sudo -n systemctl show'
```

**Step 2: Run tests to verify the new guards fail**

Run: `bash pkgs/reset-workspace/test.sh`
Expected: the 4 mirror checks PASS (they test the mirror), the 4 new source guards FAIL (helpers not in `default.nix` yet), exit 1.

**Step 3: Add the helpers to `default.nix`**

Insert immediately after the closing `}` of `pool_health_urls_from_wants` (line 75). Note the `''${...}` escapes are NOT needed here — none of these lines contain bash `${...}`:

```bash
    # pool_scope: echo "user" when the per-user pool target is active on this
    # host (devbox), else "system" (cloudbox, where the pool is a system
    # target). Crostini has NO pool target at all (plain opencode-serve.service,
    # home.crostini.nix) -- it lands in the "system" branch and
    # discover_pool_urls degrades to the $OPENCODE_URL fallback there.
    # Single source of truth for which systemctl scope owns
    # opencode-serve-pool.target, so capture and restart can never disagree.
    # `systemctl --user` needs XDG_RUNTIME_DIR; the detach re-exec above
    # guarantees it. If the detach fell back to in-place, misdetecting "system"
    # on devbox dies at restart exactly as the old inline detection did.
    pool_scope() {
      if systemctl --user is-active --quiet opencode-serve-pool.target 2>/dev/null; then
        printf 'user\n'
      else
        printf 'system\n'
      fi
    }

    # discover_pool_urls <scope>: print one http://127.0.0.1:<port> health URL
    # per pool serve, in port order, by reading the target's Wants= via the
    # given systemctl scope and parsing it with pool_health_urls_from_wants.
    # Degrades to $OPENCODE_URL when discovery yields nothing (pre-pool
    # behavior; also crostini, which has no pool target). Reading unit
    # properties needs no privilege on stock systemd, so try unprivileged
    # first; fall back to passwordless sudo (-n: never prompt -- this runs in
    # the capture path, which must never hang) in case a D-Bus policy
    # restricts the read. /run/wrappers/bin/sudo is NixOS's setuid sudo
    # (/run/current-system/sw/bin/sudo is a non-setuid symlink sudo refuses to
    # exec from); on non-NixOS hosts it's absent and the fallback fails
    # silently.
    discover_pool_urls() {
      local scope="$1" wants
      if [ "$scope" = "user" ]; then
        wants="$(systemctl --user show -p Wants --value opencode-serve-pool.target 2>/dev/null || true)"
      else
        wants="$(systemctl show -p Wants --value opencode-serve-pool.target 2>/dev/null || true)"
        if [ -z "$wants" ]; then
          wants="$(/run/wrappers/bin/sudo -n systemctl show -p Wants --value opencode-serve-pool.target 2>/dev/null || true)"
        fi
      fi
      pool_health_urls_from_wants "$wants" "$OPENCODE_URL"
    }
```

**Step 4: Verify build + tests pass**

```bash
nix build --no-link .#reset-workspace
bash pkgs/reset-workspace/test.sh
```
Expected: build succeeds; `ALL PASS`.

**Step 5: Commit**

```bash
git add pkgs/reset-workspace/default.nix pkgs/reset-workspace/test.sh
git commit -m "refactor(reset-workspace): add pool_scope + discover_pool_urls helpers (workstation-3smg)"
```

---

## Task 2: Compute `POOL_SCOPE` once, before capture

**Files:**
- Modify: `pkgs/reset-workspace/test.sh` (one guard)
- Modify: `pkgs/reset-workspace/default.nix` (after the `main` allowlist block's closing `fi`, line 188, just before `# ---- Step 2: Snapshot ...`)

**Step 1: Add the failing guard**

```bash
  want_grep "capture computes the pool scope once" 'POOL_SCOPE="$(pool_scope)"'
```

Run: `bash pkgs/reset-workspace/test.sh` — expected: that guard FAILs, exit 1.

**Step 2: Insert the single scope computation**

```bash
    # Determine the pool's systemd scope ONCE (workstation-3smg). Reused by the
    # pool-aware capture probe below and the restart + readiness poll later, so
    # capture and restart can't drift onto different scopes.
    POOL_SCOPE="$(pool_scope)"
    log "pool scope: $POOL_SCOPE"
```

**Step 3: Verify** — `nix build --no-link .#reset-workspace && bash pkgs/reset-workspace/test.sh` → `ALL PASS`.

**Step 4: Commit**

```bash
git add pkgs/reset-workspace/default.nix pkgs/reset-workspace/test.sh
git commit -m "refactor(reset-workspace): compute POOL_SCOPE once before capture (workstation-3smg)"
```

---

## Task 3: Make the pre-capture health check pool-aware

**Files:**
- Modify: `pkgs/reset-workspace/test.sh` (swap one stale guard, add two)
- Modify: `pkgs/reset-workspace/default.nix:202-219` (the workstation-7sbo comment block AND the `SERVE_HEALTHY=1` probe — replace both together; the old comment says a failed probe "skips capture entirely … both loops below no-op", which stops being true here)

**Step 1: Update the guards (one stale, two new)**

In `test.sh`, REPLACE the stale guard

```bash
  want_grep "source probes serve health before capture"    '$OPENCODE_URL/global/health'
```

with these three. Do NOT guard on `'"$u/global/health"'` — that string already appears in the post-restart poll (`default.nix:439`) and would pass even if the capture change were reverted (false-green):

```bash
  want_grep "capture discovers the whole pool"             'mapfile -t capture_pool_urls < <(discover_pool_urls "$POOL_SCOPE")'
  want_grep "capture picks a healthy member as CAPTURE_URL" 'CAPTURE_URL="$u"'
  want_grep "no-healthy-pool still runs strict-attach"      'strict-attach capture will still run'
```

Run: `bash pkgs/reset-workspace/test.sh` — expected: the three new guards FAIL (and the old one is gone), exit 1.

**Step 2: Replace the comment + probe block**

Replace `default.nix:202-219` (from `# Defense-in-depth health gate (workstation-7sbo):` through the `fi` of the `SERVE_HEALTHY` probe) with — note the `''${...}` escapes on the two array expansions, required in the Nix source:

```bash
    # Pool-aware capture health (workstation-3smg, narrowing workstation-7sbo).
    # The bare-TUI sid resolution below queries a serve over HTTP; a wedged
    # serve (event loop blocked, kernel still completing TCP handshakes)
    # accepts the connection and then blocks the read forever -- and this
    # capture runs *before* the Step-5 restart that clears the wedge, so it
    # must never hang on a possibly-wedged serve. Any healthy pool member can
    # resolve cwd->sid (all serves share one opencode.db), so probe the WHOLE
    # pool -- not just serve-0 -- with a hard per-probe timeout, and use the
    # first healthy member as CAPTURE_URL for the bare-resolve loop.
    # SERVE_HEALTHY now gates ONLY that loop; the strict-attach loop reads
    # sids from /proc and runs unconditionally (it needs no serve). Worst case
    # all K members are wedged-but-accepting: K x 3s, bounded, then straight
    # to the restart. The --max-time on the resolution curl is the belt; this
    # probe is the suspenders. See
    # docs/investigations/2026-06-17-opencode-1.17.7-orphan-session-wedge.md Q3.
    SERVE_HEALTHY=0
    CAPTURE_URL="$OPENCODE_URL"
    mapfile -t capture_pool_urls < <(discover_pool_urls "$POOL_SCOPE")
    for u in "''${capture_pool_urls[@]}"; do
      if curl -sf --max-time 3 --connect-timeout 3 "$u/global/health" >/dev/null 2>&1; then
        SERVE_HEALTHY=1
        CAPTURE_URL="$u"
        log "capture: resolving bare-TUI sids via healthy pool serve $u"
        break
      fi
    done
    if [ "$SERVE_HEALTHY" -eq 0 ]; then
      log "WARNING: no healthy opencode-serve in pool (''${capture_pool_urls[*]}); strict-attach capture will still run, bare-resolve capture skipped"
    fi
```

(`capture_pool_urls` is never empty: `pool_health_urls_from_wants` always falls back to `$OPENCODE_URL`. Bash here is 5.x, so even an empty `"''${arr[@]}"` under `nounset` would be safe.)

**Step 3: Verify** — `nix build --no-link .#reset-workspace && bash pkgs/reset-workspace/test.sh` → `ALL PASS`. (The existing `'SERVE_HEALTHY=0'` guard still matches the new init line.)

**Step 4: Commit**

```bash
git add pkgs/reset-workspace/default.nix pkgs/reset-workspace/test.sh
git commit -m "fix(reset-workspace): pool-aware pre-capture health probe (workstation-3smg)"
```

---

## Task 4: Run strict-attach capture unconditionally

**Files:**
- Modify: `pkgs/reset-workspace/test.sh` (remove one guard, add `refuse_grep` + negative guard)
- Modify: `pkgs/reset-workspace/default.nix:240-246` (the strict-attach `SERVE_HEALTHY` gate, including its 2-line comment)

**Step 1: Update the guards**

In `test.sh`, REMOVE:

```bash
  want_grep "unhealthy serve skips attach capture"         'OC_ATTACH_PIDS=""'
```

Add the negative-guard helper next to `want_grep` (test.sh:78-81):

```bash
refuse_grep() { # refuse_grep <desc> <fixed-string> — string must NOT appear
  if grep -qF -- "$2" "$default_nix"; then
    echo "FAIL: $1"; echo "  found in default.nix (must be absent): $2"; fail=1
  else echo "ok: $1"; fi
}
```

And inside the `if [ -f "$default_nix" ]` block:

```bash
  # workstation-3smg: the 2026-07-03 empty-manifest bug WAS this gate. The
  # strict-attach loop reads /proc only and must never be re-gated on serve
  # health.
  refuse_grep "strict-attach capture is ungated" 'OC_ATTACH_PIDS=""'
```

Run: `bash pkgs/reset-workspace/test.sh` — expected: `refuse_grep` FAILs (the gate string is still present), exit 1.

**Step 2: Ungate the strict-attach loop**

Replace `default.nix:240-246`:

```bash
    # SERVE_HEALTHY gate (workstation-7sbo): on an unhealthy serve, leave the
    # pid list empty so this loop no-ops and we fall through to the restart.
    if [ "$SERVE_HEALTHY" -eq 1 ]; then
      OC_ATTACH_PIDS=$(pgrep -u dev -f 'opencode attach' 2>/dev/null || true)
    else
      OC_ATTACH_PIDS=""
    fi
```

with:

```bash
    # workstation-3smg: strict-attach capture reads sids straight from
    # /proc/<pid>/cmdline and touches NO serve, so it runs unconditionally --
    # even when every pool serve is wedged. (Previously gated on SERVE_HEALTHY,
    # which discarded the entire manifest when serve-0 alone was unhealthy, e.g.
    # devbox 2026-07-03.)
    OC_ATTACH_PIDS=$(pgrep -u dev -f 'opencode attach' 2>/dev/null || true)
```

**Step 3: Verify** — `nix build --no-link .#reset-workspace && bash pkgs/reset-workspace/test.sh` → `ALL PASS`.

**Step 4: Commit**

```bash
git add pkgs/reset-workspace/default.nix pkgs/reset-workspace/test.sh
git commit -m "fix(reset-workspace): run strict-attach capture unconditionally (workstation-3smg)"
```

---

## Task 5: Point the bare-resolve curl at `CAPTURE_URL`

**Files:**
- Modify: `pkgs/reset-workspace/test.sh` (two guards)
- Modify: `pkgs/reset-workspace/default.nix:285-291` (bare-resolve gate comment) and `default.nix:325` (resolution `curl`)

**Step 1: Add the failing guards**

```bash
  want_grep "bare-resolution uses the healthy capture url" '"$CAPTURE_URL/session"'
  want_grep "bare-resolve loop still serve-gated"          'OC_ALL_PIDS=""'
```

Run: `bash pkgs/reset-workspace/test.sh` — expected: the `CAPTURE_URL/session` guard FAILs (the `OC_ALL_PIDS=""` one already passes — it pins existing behavior), exit 1.

**Step 2: Keep the bare-resolve gate, refresh its comment**

The `if [ "$SERVE_HEALTHY" -eq 1 ]; then OC_ALL_PIDS=... else OC_ALL_PIDS="" fi` block stays (this loop *does* need a serve). Replace the gate comment at `default.nix:285-286`:

```bash
    # SERVE_HEALTHY gate (workstation-3smg): this loop resolves cwd->sid over
    # HTTP, so it runs only when at least one pool member answered
    # /global/health (CAPTURE_URL points at it). An empty pid list makes the
    # loop no-op.
```

**Step 3: Retarget the resolution curl**

At `default.nix:325`, change `"$OPENCODE_URL/session"` to `"$CAPTURE_URL/session"` (keep both timeouts — they cover a member that wedges *between* the health probe and this call):

```bash
      resolved_sid=$(curl -fsS --max-time 5 --connect-timeout 3 --get "$CAPTURE_URL/session" \
        --data-urlencode "directory=$cwd" \
        --data-urlencode "roots=true" \
        --data-urlencode "limit=1" 2>/dev/null \
        | jq -r '.[0].id // empty' 2>/dev/null || true)
```

**Step 4: Verify** — `nix build --no-link .#reset-workspace && bash pkgs/reset-workspace/test.sh` → `ALL PASS`.

**Step 5: Commit**

```bash
git add pkgs/reset-workspace/default.nix pkgs/reset-workspace/test.sh
git commit -m "fix(reset-workspace): bare-resolve uses first healthy pool member (workstation-3smg)"
```

---

## Task 6: Reuse `POOL_SCOPE` / `discover_pool_urls` in the restart path

**Files:**
- Modify: `pkgs/reset-workspace/test.sh` (two guards)
- Modify: `pkgs/reset-workspace/default.nix:386-413` (host-aware comment + restart scope branch) and `default.nix:420-425` (post-restart poll discovery)

**Step 1: Add the failing guards**

```bash
  want_grep "restart reuses the precomputed scope"        '[ "$POOL_SCOPE" = "user" ]'
  want_grep "post-restart poll reuses discover_pool_urls" 'serve_health_urls < <(discover_pool_urls "$POOL_SCOPE")'
```

Run: `bash pkgs/reset-workspace/test.sh` — expected: both FAIL, exit 1. (The old code reads `[ "''${POOL_SCOPE:-system}" = "user" ]` in the source, which doesn't match the first fixed string.)

**Step 2: Replace the restart comment + scope branch**

Replace `default.nix:386-413` (from `# Host-aware restart.` through the closing `fi` of the scope branch; the `log "restarting..."` line is inside this range). Preserve the sudo-path rationale comment — `discover_pool_urls` documents it for reads; this is the only *write* still requiring it:

```bash
    # Host-aware restart. Scope was computed ONCE as POOL_SCOPE before capture
    # (see pool_scope), so capture and restart cannot disagree. The pool target
    # runs as a USER target on devbox (~/.config/systemd/user/; restart via
    # `systemctl --user`, no sudo) and as a SYSTEM target on cloudbox
    # (hosts/cloudbox/configuration.nix; restart via passwordless sudo). The
    # target's PartOf= linkage makes the restart propagate to every
    # opencode-serve@<port>.service instance (a target's Wants= alone would
    # NOT).
    log "restarting opencode-serve-pool.target..."
    if [ "$POOL_SCOPE" = "user" ]; then
      log "  opencode-serve-pool is a user target; restarting via systemctl --user"
      if ! systemctl --user restart opencode-serve-pool.target; then
        die "failed to restart opencode-serve-pool (user target)"
      fi
    else
      # Passwordless sudo works via wheel group + security.sudo.wheelNeedsPassword=false.
      # Use absolute path /run/wrappers/bin/sudo because NixOS ships the working
      # setuid sudo there; /run/current-system/sw/bin/sudo is a non-setuid symlink
      # sudo refuses to exec from.
      log "  opencode-serve-pool is a system target; restarting via sudo"
      if ! /run/wrappers/bin/sudo systemctl restart opencode-serve-pool.target; then
        die "failed to restart opencode-serve-pool (system target)"
      fi
    fi
```

**Step 3: Replace the post-restart poll discovery**

Replace `default.nix:420-425` (the `if [ "''${POOL_SCOPE:-system}" = "user" ] … fi` + `mapfile … pool_health_urls_from_wants` block; keep the mn9r M7 comment above it — it remains accurate) with:

```bash
    mapfile -t serve_health_urls < <(discover_pool_urls "$POOL_SCOPE")
```

**Step 4: Verify** — `nix build --no-link .#reset-workspace && bash pkgs/reset-workspace/test.sh` → `ALL PASS`. (The pre-existing `'show -p Wants --value opencode-serve-pool.target'` and `'serve_health_urls'` guards still match via `discover_pool_urls` / the poll.)

**Step 5: Commit**

```bash
git add pkgs/reset-workspace/default.nix pkgs/reset-workspace/test.sh
git commit -m "refactor(reset-workspace): reuse POOL_SCOPE/discover_pool_urls in restart path (workstation-3smg)"
```

---

## Task 7: Write the manifest before the kill/restart gauntlet

**Files:**
- Modify: `pkgs/reset-workspace/test.sh` (ordering check)
- Modify: `pkgs/reset-workspace/default.nix` — move the manifest block (`default.nix:459-466`) to just after the confirm block's closing `fi` (`default.nix:368`), before `# ---- Step 3: Kill all nvims ----`

**Why:** today the manifest write sits after two `die` sites — restart failure and the 30s post-restart health poll — so a perfect capture is discarded if the pool doesn't come back within 30s (plausible on a swap-thrashing box at 03:00, exactly the workstation-94g8 regime). Placed *after* the `[y/N]` confirm so an aborted interactive run doesn't clobber the previous reset's manifest.

**Step 1: Add the failing ordering check**

In `test.sh`, inside the `if [ -f "$default_nix" ]` block (this is plain bash in test.sh — no Nix escaping):

```bash
  # workstation-3smg: the manifest write must precede the pool restart, so a
  # restart/health-poll die can't discard a successful capture.
  manifest_line=$(grep -n 'MANIFEST_PATH="/tmp/reset-workspace-last-manifest.txt"' "$default_nix" | head -1 | cut -d: -f1)
  restart_line=$(grep -n 'restarting opencode-serve-pool.target' "$default_nix" | head -1 | cut -d: -f1)
  if [ -n "$manifest_line" ] && [ -n "$restart_line" ] && [ "$manifest_line" -lt "$restart_line" ]; then
    echo "ok: manifest is written before the pool restart"
  else
    echo "FAIL: manifest write must precede the pool restart (manifest at ${manifest_line:-?}, restart at ${restart_line:-?})"; fail=1
  fi
```

Run: `bash pkgs/reset-workspace/test.sh` — expected: this check FAILs (write is currently after the restart), exit 1.

**Step 2: Move the manifest block**

Delete the `MANIFEST_PATH=…` block from Step 6 (`default.nix:459-466`) and insert after the confirm block's closing `fi` (line 368), with a new step header (keep the `''$` escapes exactly as in the original block):

```bash
    # ---- Step 2.5: Persist the manifest (workstation-3smg) ----
    # Write the manifest BEFORE the kill/restart gauntlet: the restart branch
    # and the post-restart health poll both die on failure, and a die there
    # must not discard a successful capture (the manifest is the whole point
    # of the morning-recommendation flow). After the [y/N] confirm so an
    # aborted run doesn't clobber the previous reset's manifest.
    MANIFEST_PATH="/tmp/reset-workspace-last-manifest.txt"
    if [ -n "''$OPENCODE_MANIFEST" ]; then
      printf '%s\n' "''$OPENCODE_MANIFEST" > "''$MANIFEST_PATH"
      log "wrote ''$OPENCODE_COUNT sid(s) to ''$MANIFEST_PATH"
    else
      : > "''$MANIFEST_PATH"
      log "wrote empty ''$MANIFEST_PATH (no captured sids)"
    fi
```

Trim the old Step 6 header comment to reflect the move:

```bash
    # ---- Step 6: Launch recommendation session ----
    # The manifest was already written (Step 2.5, before the kill/restart
    # gauntlet). The recommendation session reads it, enriches each sid via
    # opencode-serve, messages the user via Telegram with conversational
    # recommendations, and re-opens only the chosen sessions on reply.
    # Design: docs/plans/2026-05-16-recommendation-driven-reset-design.md
```

**Step 3: Verify** — `nix build --no-link .#reset-workspace && bash pkgs/reset-workspace/test.sh` → `ALL PASS`.

**Step 4: Commit**

```bash
git add pkgs/reset-workspace/default.nix pkgs/reset-workspace/test.sh
git commit -m "fix(reset-workspace): write manifest before the restart gauntlet (workstation-3smg)"
```

---

## Task 8: Build + deploy + live acceptance on devbox

**Step 1: Full gate**

```bash
bash pkgs/reset-workspace/test.sh                # ALL PASS
nix build --no-link .#reset-workspace
nix build --no-link --print-out-paths .#homeConfigurations.dev.activationPackage
```

**Step 2: Deploy**

```bash
nix run home-manager -- switch --flake .#dev
```

**Step 3: Live acceptance — the exact failure mode**

Reproduce a down serve-0: stop serve-0 only, leave serve-1 healthy, and confirm capture still works and a recommendation launches.

> **Do NOT set `RESET_WORKSPACE_NO_DETACH=1`.** If this is run from an opencode
> bash tool, the tool's process tree lives inside an
> `opencode-serve@<port>.service` cgroup; the detach re-exec
> (`default.nix:97-115`) is the only thing that keeps the run alive across the
> Step-5 pool restart (PartOf= kills the whole cgroup). The detach preserves
> stdio, so `tee` captures output fine through it. This run also SIGKILLs all
> nvims and briefly downs serve-0's sessions — do it at a low-stakes moment;
> expect the Telegram recommendation to fire.

```bash
# With at least one live opencode TUI in the `main` tmux session:
systemctl --user stop opencode-serve@4096.service      # serve-0 down; 4097 stays up
reset-workspace --yes 2>&1 | tee /tmp/rw-accept.log
```

Expected in the log, in order:
- `pool scope: user`
- `capture: resolving bare-TUI sids via healthy pool serve http://127.0.0.1:4097`
- `captured N restorable session(s)` with `N > 0` (strict-attach at minimum)
- `wrote N sid(s) to /tmp/reset-workspace-last-manifest.txt` — **before** `restarting opencode-serve-pool.target...`
- `launching recommendation session in ~ ...` (NOT `no sessions to recommend`)
- the pool comes back healthy and the run ends `reset-workspace complete`

**Step 4 (optional but recommended): wedge-realistic variant**

`systemctl stop` produces connection-refused (fast-fail) — the *easy* case. The 2026-07-03 wedge was wedged-but-TCP-accepting, which exercises the `--max-time 3` timeout path. Simulate with SIGSTOP (the kernel still completes handshakes for a stopped process):

```bash
kill -STOP "$(systemctl --user show -p MainPID --value opencode-serve@4096.service)"
reset-workspace --yes 2>&1 | tee /tmp/rw-accept-stop.log
```

Expected: the 4096 probe consumes the full ~3s then falls to 4097 (same log lines as Step 3). The pool restart clears the stopped process via SIGTERM→(TimeoutStopSec≈90s)→SIGKILL, so expect the restart step to take ~90s longer. If you abort the test instead, `kill -CONT` the pid to restore it.

(Alternative fully-wedged check: stop *both* serves → expect the `WARNING: no healthy opencode-serve in pool` line, `bare-resolved 0`, but strict-attach still captures argv-based TUIs, the manifest is written, and a recommendation still launches if any were live.)

**Step 5: Land the plane**

```bash
bd close workstation-3smg --reason "pool-aware capture + ungated strict-attach + early manifest write; verified serve-0-down still captures and launches recommendation"
git pull --rebase
git push
git status   # MUST show "up to date with origin"
```

**Step 6 (follow-up, next cloudbox switch):** after cloudbox picks this up via its own `home-manager switch --flake .#cloudbox`, spot-check the unprivileged read there: `systemctl show -p Wants --value opencode-serve-pool.target` as `dev` should print the 4 `opencode-serve@409{6,7,8,9}.service` units. If it unexpectedly prints nothing, the `sudo -n` fallback in `discover_pool_urls` covers it (wheel + NOPASSWD, `hosts/cloudbox/configuration.nix:1283`) — but note the finding on workstation-3smg.

## Out of scope

- **workstation-94g8** (serve wedges at `MemoryHigh=4G` instead of auto-restarting). A serve bloating over 24h is the expected degradation the nightly reset clears; mitigations (tighter `MemoryMax`, a health watchdog, or a heap ceiling that crash-restarts) are tracked separately.
- **reset-workspace on crostini** remains broken at the restart step (no pool target, no `/run/wrappers/bin/sudo`) — pre-existing, unchanged by this plan; capture there degrades safely to the `$OPENCODE_URL` fallback.
- Changing the recommendation prompt, the `main`-allowlist scoping, or the detachment/flock machinery.
