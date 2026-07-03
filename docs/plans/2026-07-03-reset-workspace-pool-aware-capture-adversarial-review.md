# Adversarial Review: reset-workspace Pool-Aware Capture Plan

**Plan:** `docs/plans/2026-07-03-reset-workspace-pool-aware-capture-plan.md`
**Beads:** workstation-3smg (this fix), workstation-7sbo (gate it narrows), workstation-94g8 (wedge root cause)
**Reviewed against:** `pkgs/reset-workspace/default.nix`, `pkgs/reset-workspace/test.sh`, `users/dev/serve-pool.nix`, `users/dev/home.devbox.nix`, `users/dev/home.crostini.nix`, `hosts/cloudbox/configuration.nix:987-1030`, `hosts/devbox/configuration.nix:316-361`

## VERDICT: ship-with-changes — core design is sound and verified, but the acceptance procedure can kill itself mid-run, two test guards are false-green as written, and the `pool_scope` comment enshrines a false claim about crostini.

---

## What checks out (verified against source, not the plan's quotes)

- **Axis 1 — strict-attach truly needs no serve: TRUE.** Traced `default.nix:242-275` line by line: `pgrep` (243), `readlink /proc/$pid/exe` (253), `basename` (254), `grep` on exe name (255), `MAIN_PIDS` case match (261), `tr`/`sed` on `/proc/$pid/cmdline` (263), bash regex (266), `readlink /proc/$pid/cwd` (268), counters + manifest append (270-271). Zero network calls. Ungating it (Task 4) is safe and is exactly what would have saved devbox 2026-07-03.
- **Plan line numbers are accurate.** `pool_health_urls_from_wants` ends at :75; `SERVE_HEALTHY` block is :215-219; strict gate :240-246; bare gate :285-291; resolution curl :325; restart branch :396-413; poll discovery :420-425. All confirmed.
- **Axis 2 — degradation of `discover_pool_urls`: correct.** `systemctl show -p Wants --value <nonexistent>` exits **0 with empty output** (verified live), and a failed/`missing sudo` exec inside `$( ... 2>/dev/null || true)` is silent (the redirect is applied before the exec-failure message). Empty wants → `pool_health_urls_from_wants` prints the `$OPENCODE_URL` fallback, so `capture_pool_urls` is never empty.
- **Axis 2 — probe→use race: bounded.** A member that passes `/global/health` then wedges is caught by the retained `--max-time 5 --connect-timeout 3` on the resolution curl (`default.nix:325`, kept by Task 5). Worst case is 5s per bare TUI, logged + counted as skipped. Worst-case all-K-wedged capture overhead is K×3s (12s on cloudbox K=4) — the workstation-7sbo "bounded time to restart" invariant holds.
- **First-healthy pick is correct.** `discover_pool_urls` preserves `Wants=` port order, so serve-0 (4096, the anchor) is preferred when healthy — happy path is byte-identical behavior. Any member can resolve `cwd→sid`: the `/session?directory=` query is a pure read of the shared `opencode.db` (`OPENCODE_DB` pinned identically for every instance, `home.devbox.nix:494`).
- **Axis 4 — no-healthy path: ends cleanly.** SERVE_HEALTHY=0 → warning → strict loop still captures → bare loop no-ops (`OC_ALL_PIDS=""`) → restart via `POOL_SCOPE` → post-restart poll on freshly restarted serves → manifest write → recommendation launches if count > 0. The recommendation prompt's hardcoded `http://127.0.0.1:4096` (`default.nix:480`) is fine because the poll at :449-451 dies unless 4096 is back.
- **Axis 6 — bash/Nix mechanics: clean.** Ran the exact Task 1-3 snippets through shellcheck 0.11: pass (relevant because `writeShellApplication` runs shellcheck at build time). Bash is 5.3; `"${arr[@]}"` on an empty array under `nounset` is fine ≥4.4, and the array is provably non-empty anyway. The plan's `''${...}` escaping in the .nix snippets is correct throughout; all proposed test-guard strings avoid `${`/`''${` entirely, so the source-vs-rendered escaping trap does not bite them.
- **Axis 3 — cloudbox capture-time sudo: works.** `POOL_SCOPE=system` on cloudbox (no user pool target; `systemctl --user` from the nightly system service has no `XDG_RUNTIME_DIR` → is-active fails → "system"). `dev` is in wheel with `wheelNeedsPassword=false` (`hosts/cloudbox/configuration.nix:1283`), and the nightly script already sudo-restarts pigeon from the same context (:1018). Same on devbox (`hosts/devbox/configuration.nix:689,698`).
- **Live evidence the fix behaves as intended:** while executing the plan's Task-3 snippet on this devbox during review, the 4096 probe transiently failed (>3s) and the loop correctly selected 4097 as `CAPTURE_URL`; both members probed healthy seconds later. The pool-aware fallback triggers under real, non-catastrophic slowness — the old code would have discarded the entire capture in that moment.

---

## BLOCKING issues

### B1. Task 8's acceptance run uses `RESET_WORKSPACE_NO_DETACH=1` — it can kill itself mid-flight

The script's own comment calls NO_DETACH **"for debugging only — known-broken in production-like invocation contexts"** (`default.nix:94-95`). The hazard is concrete: the plan is headed `For Claude: use executing-plans`, so an agent will run Task 8 **from an opencode bash tool**, whose process tree lives inside an `opencode-serve@<port>.service` cgroup. With detach suppressed, Step 5's `systemctl --user restart opencode-serve-pool.target` (PartOf fan-out, `home.devbox.nix:465`) kills the whole cgroup — **including the running reset-workspace** — before the manifest write (:459-466) and recommendation launch. Result: half-reset workspace (nvims already SIGKILLed at :374), no manifest, a "failed" acceptance that says nothing about the change under test.

NO_DETACH buys nothing here: in `--scope` mode the re-exec'd script inherits stdin/stdout/stderr (`default.nix:103-107`), so `2>&1 | tee /tmp/rw-accept.log` captures output fine through the detach.

**Fix:** drop `RESET_WORKSPACE_NO_DETACH=1` from Task 8 Step 3:

```bash
systemctl --user stop opencode-serve@4096.service
reset-workspace --yes 2>&1 | tee /tmp/rw-accept.log
```

and add an explicit note: *if running from inside an opencode session, the detach re-exec is what keeps this run alive across the pool restart — do not disable it.*

### B2. Task 7 guards: one is false-green on day one, one is unspecified, and the actual bug has no regression guard

1. **False-green:** `want_grep "capture probes each pool member health" '"$u/global/health"'` matches the **existing post-restart poll** at `default.nix:439` (`curl -sf --max-time 3 "$u/global/health"`). It passes today, before any capture change, and would keep passing if the capture block were later reverted. Same (weaker) problem for `'discover_pool_urls "$POOL_SCOPE"'`, which matches the Task 6 post-restart call site alone.
2. **Unspecified:** Task 7 Step 1 says to "change" the `'$OPENCODE_URL/global/health'` guard but never says what to change it **to** — an implementer following the plan literally will either delete it or substitute the false-green string from (1).
3. **Missing negative guard:** the 2026-07-03 bug *was* the `OC_ATTACH_PIDS=""` gate. The plan removes that guard but adds nothing asserting the gate stays gone. Nothing stops a future "defense-in-depth" patch from re-adding it.

**Fix:** use capture-unique strings and add an absence check:

```bash
# distinctive: capture_pool_urls appears ONLY in the capture block
want_grep "capture discovers the whole pool" \
  'mapfile -t capture_pool_urls < <(discover_pool_urls "$POOL_SCOPE")'

refuse_grep() { # refuse_grep <desc> <fixed-string>  — must NOT appear
  if grep -qF -- "$2" "$default_nix"; then
    echo "FAIL: $1"; echo "  found in default.nix (must be absent): $2"; fail=1
  else echo "ok: $1"; fi
}
refuse_grep "strict-attach capture is ungated (workstation-3smg)" 'OC_ATTACH_PIDS=""'
```

`'CAPTURE_URL="$u"'`, `'"$CAPTURE_URL/session"'`, `'POOL_SCOPE="$(pool_scope)"'`, and `'serve_health_urls < <(discover_pool_urls "$POOL_SCOPE")'` are genuinely distinctive — keep those as proposed.

### B3. `pool_scope`'s comment is factually wrong about crostini

The Task 1 comment says *"echo 'user' when the per-user pool target is active on this host (devbox/crostini)"*. **Crostini has no pool target at all** — it runs a plain, non-templated `systemd.user.services.opencode-serve` (`home.crostini.nix:135-171`); nothing named `opencode-serve-pool.target` exists there. On crostini `pool_scope` returns `"system"`, and `discover_pool_urls` then execs `/run/wrappers/bin/sudo` — a **NixOS-ism that does not exist on crostini** (Debian container + Nix). The behavior happens to degrade safely (silent exec failure → `|| true` → empty wants → `$OPENCODE_URL` fallback, which matches crostini's single 4096 serve), and the restart path dies on crostini exactly as it does today (pre-existing breakage, `default.nix:397-413`) — but shipping a "single source of truth for scope" helper whose contract comment is wrong on one of the three Linux hosts will actively mislead the next incident responder.

**Fix (one line):** correct the comment — `"user" when the per-user pool target is active (devbox); else "system" (cloudbox; also crostini, which has no pool target and degrades to the $OPENCODE_URL fallback)`. Optionally note that reset-workspace's restart path has never worked on crostini.

---

## NON-BLOCKING concerns / nits

1. **Red tests between the Task 3 and Task 7 commits.** Once Task 3 lands, `test.sh:94`'s `'$OPENCODE_URL/global/health'` guard fails (the string's only occurrence is the block being replaced), so `bash pkgs/reset-workspace/test.sh` is red for four commits — a bisect hazard. Fold the guard edits into the Task 3 commit (and the `OC_ATTACH_PIDS=""` guard removal into Task 4's), or accept and note it.
2. **`nix-instantiate --parse` is too weak as the per-task gate.** It catches malformed interpolations (`''${x[@]}` mistyped as `${x[@]}` fails to parse) but **passes** a plain `${VAR}` mis-escape when `VAR` parses as a Nix identifier — that only explodes at eval ("undefined variable"), or worse, silently interpolates if the name exists in Nix scope. It also never runs `writeShellApplication`'s shellcheck. Cheap upgrade: run Task 8's `nix build --no-link .#homeConfigurations.dev.activationPackage` (or at minimum `nix-instantiate` *without* `--parse` on an expression importing the package) per task instead of only at the end.
3. **Capture-time sudo has no `-n`.** `discover_pool_urls`'s system branch (`/run/wrappers/bin/sudo systemctl show ...`) can, under sudo misconfiguration on a TTY, block on a password prompt — in the exact code path whose whole design goal is "never hang before the restart". Both NixOS hosts have `wheelNeedsPassword=false` today, so this is theoretical, but `-n` is free insurance (the repo already uses `sudo -n` for exactly this reason in `opencode-config.nix:448`). See also Better Alternative A2, which removes the sudo entirely.
4. **Stale comments left behind.** The big workstation-7sbo comment at `default.nix:202-214` still says a failed probe will "skip capture entirely (leave the pid lists empty so both loops below no-op)" — false after Tasks 3/4. Task 6's replacement snippet also drops the `/run/wrappers/bin/sudo`-vs-`/run/current-system/sw/bin/sudo` rationale comment (:404-407); that knowledge should move to `discover_pool_urls`, which now also depends on it. In a codebase this comment-load-bearing, ship the comment updates with the code.
5. **POOL_SCOPE hoisting: verified safe, one residual note.** Nothing between the early computation (~:188) and the restart (:397) mutates target active-state, and flock (:136-146) prevents concurrent resets, so capture and restart cannot disagree — the hoist is an improvement. The one asymmetry: if the detach re-exec falls back to in-place (`default.nix:110-114`), `systemctl --user` may lack `XDG_RUNTIME_DIR` in the nightly context → `pool_scope` mis-answers "system" on devbox → capture degrades to the 4096 fallback and restart dies — which is byte-identical to the old code's behavior in the same failure mode (its restart-time `is-active` failed identically). No regression; worth one comment line.
6. **Acceptance test realism.** `systemctl --user stop opencode-serve@4096.service` produces connection-refused — the *easy* failure (curl fails in milliseconds). The 2026-07-03 wedge was wedged-but-TCP-accepting, which exercises the `--max-time 3` timeout path. Optional stronger variant: `kill -STOP` serve-0's PID (kernel still completes handshakes → probe consumes the full 3s → falls to 4097), then let the pool restart clear it (SIGKILL works on stopped processes; expect +90s from `TimeoutStopSec`). The stop-based test is still valid for the code-path change — this is an addition, not a replacement. Residual risk of the stop-based test is acceptable: serve-0 hosts live headless sessions that go dark until the restart ~a minute later, and all nvims die — but that is what reset-workspace does; just run it at a low-stakes moment and expect the Telegram recommendation to fire.
7. **Transient-degradation footnote.** If `systemctl show` transiently fails on devbox at capture, discovery collapses to `[$OPENCODE_URL]` and the probe is 4096-only again — the original bug's shape, in a much rarer failure mode. Acceptable; not worth code.

---

## BETTER ALTERNATIVES

### A1. Write the manifest immediately after capture, not after the restart gauntlet (strongly recommended, ~5 lines)

Today the manifest write (:459-466) sits **after** two `die` sites: restart failure (:401, :411) and the 30s post-restart health poll (:449-451). Under this plan a perfect capture is still discarded if the pool doesn't come back within 30s — plausible at 03:00 on a swap-thrashing box, which is precisely the workstation-94g8 regime this fix responds to (the wedged serve took 90s just to die). Move the `MANIFEST_PATH` write to right after the dedupe (:342-349); keep the recommendation launch where it is (it genuinely needs a healthy serve). Then no post-capture failure can erase the capture, and a human (or the next run) can recover from `/tmp/reset-workspace-last-manifest.txt`. This is the single cheapest change that serves the plan's own stated goal.

### A2. Drop sudo from `discover_pool_urls` entirely — `systemctl show` doesn't need root

Verified on devbox as uid 1000: `systemctl show -p Wants --value <system-target>` succeeds unprivileged (systemd unit properties are world-readable over the system bus). So the helper can be scope-branchless for reads:

```bash
discover_pool_urls() {
  local scope="$1" wants
  if [ "$scope" = "user" ]; then
    wants="$(systemctl --user show -p Wants --value opencode-serve-pool.target 2>/dev/null || true)"
  else
    wants="$(systemctl show -p Wants --value opencode-serve-pool.target 2>/dev/null || true)"
  fi
  pool_health_urls_from_wants "$wants" "$OPENCODE_URL"
}
```

This eliminates the sudo-prompt hang vector (nit 3), the crostini missing-`/run/wrappers` path (B3), and makes **both** branches PATH-mockable for tests (A3). Sudo stays where it's actually required: the restart. (Verify once on cloudbox before relying on it; the D-Bus read policy is systemd-default.)

### A3. Real tests for the new helpers via a shell-function `systemctl` stub

The plan covers `pool_scope`/`discover_pool_urls` only with grep guards. Mirror them into `test.sh` (same convention as the existing `pool_health_urls_from_wants` mirror, which remains valid and untouched) and stub systemctl with a function — functions shadow binary lookup, no PATH games needed:

```bash
systemctl() {  # test stub
  case "$*" in
    "--user is-active --quiet opencode-serve-pool.target") return "${STUB_USER_ACTIVE_RC:-1}" ;;
    "--user show -p Wants --value opencode-serve-pool.target") printf '%s\n' "${STUB_USER_WANTS:-}" ;;
    "show -p Wants --value opencode-serve-pool.target") printf '%s\n' "${STUB_SYS_WANTS:-}" ;;
  esac
}
check "scope: user target active -> user"  "user"  "$(STUB_USER_ACTIVE_RC=0 pool_scope)"
check "scope: no user target -> system"    "system" "$(STUB_USER_ACTIVE_RC=1 pool_scope)"
```

As written in the plan, the system branch is **not** stub-able because it invokes sudo by absolute path — a further argument for A2. If A2 is rejected, keep grep guards for the sudo branch and function-stub only the user branch; that still beats guards-only.

### A4. Specify the exact wording swap for the `SERVE_HEALTHY` narrowing in the 202-214 comment block

Small, but the plan claims comment hygiene as a design value (Task 5 Step 1 refreshes one comment) while leaving the larger, now-false one. Include the replacement text in Task 3 so the implementer doesn't improvise.

---

## Summary of required changes before implementation

| # | Change | Task |
|---|--------|------|
| B1 | Drop `RESET_WORKSPACE_NO_DETACH=1` from acceptance; warn against opencode-bash invocation | 8 |
| B2 | Replace false-green guard with `capture_pool_urls`-based one; specify the changed-guard replacement; add `refuse_grep 'OC_ATTACH_PIDS=""'` | 7 |
| B3 | Fix `pool_scope`'s crostini claim | 1 |
| A1 | Manifest write moved before restart (recommended; directly serves the goal) | new |
| A2 | Un-sudo `discover_pool_urls` reads (or minimally add `-n`) | 1 |
