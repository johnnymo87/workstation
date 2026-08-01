# Step 1 — Make the opacity guard TRUE, then ENFORCED

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (or
> subagent-driven-development) to implement this plan task-by-task.

**Goal:** `bash users/dev/test-frontdoor-opacity.sh` exits 0 on a correct tree, exits 1 on
every laundering shape it currently blesses, and gates every PR via `nix flake check`.

**Architecture:** Three moves, in this order, one PR. (1a) Fix the TABLE, which is what is
actually wrong — `#217` put a door on devbox, falsifying row D1's "no door on devbox", so
two legitimate devbox sites have no row to cite. (Harden) Close four holes in the guard,
each driven by a perturbation meta-test that FAILS FIRST. (1b) Arm it in
`checks.${devboxSystem}`. Arming before the tree is green would block every PR including
the auto-merge bot, so 1a lands first *within the same PR*.

**Tech stack:** bash (`set -o errexit -o nounset -o pipefail`), nix flake checks,
`runCommand` + `shellcheck`.

**Non-negotiable verification rule:** capture guard output to a FILE and grep the file.
`cmd | grep -q FAIL` under `pipefail` inverts its own result. Every task asserts an exit
code AND a message.

---

## Context the implementer needs

**The guard** (`users/dev/test-frontdoor-opacity.sh`, not executable — invoke via `bash`)
scans a fixed list of shipped consumer files for "serve-addressing sites" (`SITE_RE`) and
requires each to carry `frontdoor-exempt(<ROW>)` within `MARKER_LOOKBACK=3` lines above it,
citing a C*/D* row of `docs/plans/2026-07-26-phase9-consumer-disposition.md`.

**Current state on `origin/main` — RED, reproduce this first:**

```
--- 16 serve-addressing site(s); 14 carry a valid exemption row
FAIL: users/dev/home.devbox.nix:1058 addresses a serve with no frontdoor-exempt marker
FAIL: users/dev/home.devbox.nix:1251 addresses a serve with no frontdoor-exempt marker
FAIL: users/dev/home.devbox.nix: 2 serve-addressing site(s) but 0 marker(s) -- not 1:1
FAIL: expected exactly 14 serve-addressing site(s), found 16
```

**Line numbers drift — the spine says 1050/1179, the tree says 1058/1251.** Never cite
line numbers in this work; grep for the anchors below.

- Site 1: grep `OPENCODE_ANCHOR_URL=http://127.0.0.1:4096` in `users/dev/home.devbox.nix`
  — the devbox door's own upstream, inside `systemd.user.services.opencode-frontdoor`.
  **Devbox analogue of C3.**
- Site 2: grep `ANCHOR_CODE=` in `users/dev/home.devbox.nix` — the devbox frontdoor
  canary's `:4096/global/health` cross-probe, under the comment
  `# 3. HTTP 503 -> cross-probe the anchor (:4096) directly`. **Devbox analogue of C4.**

Both are legitimate. Do not "fix" them by routing through the door — C3 is tautological
(the door's own upstream) and C4 must bypass the door to distinguish *door down* from
*pool down*.

**The four holes to close** (all verified 2026-07-31, all in the spine):

1. `SITE_RE` ends `:409[0-9]` → matches non-pool ports 4090-4095. Tighten to `409[6-9]`.
2. Per-file 1:1 check is gated on `fsites -gt 0`, so a file that keeps markers while its
   sites rot out of the pattern is invisible.
3. Scalar `EXPECTED_SITES` **merges wrong rather than conflicting**: two PRs each bump
   14→15, identical edit ⇒ clean merge ⇒ main red at 16≠15, blocking everyone after the
   fact.
4. **The laundering hole.** `row_exists()` checks the row ID exists; `row_is_exemption()`
   checks it is C*/D*. **Nothing checks the cited row's path list contains the citing
   file.** On 2026-07-31 a peer's implementer subagent "fixed" this exact red guard by
   putting `frontdoor-exempt(C3)`/`(C4)` on the devbox sites — rows that describe
   *cloudbox* — plus the count bump. It was caught and reverted. **Once armed, that is the
   path of least resistance for anyone the gate blocks.** Close it in the same PR.

---

## Task 1: Perturbation meta-test harness

A gate that cannot fail is a defect. Every hardening task below needs to prove the guard
goes RED on the shape it targets, so build the harness first.

**Files:** Create `users/dev/test-frontdoor-opacity-guard.sh`.

**Step 1: Write the harness with its first case — a case that PASSES today**, so a broken
harness is visible immediately (an always-red harness proves nothing).

```bash
#!/usr/bin/env bash
# Meta-test: perturbation tests for test-frontdoor-opacity.sh.
#
# The guard's whole value is failing CLOSED on a new direct-to-serve call. A guard
# that cannot fail is a defect, and this project has shipped three "fixes" that
# reported healthy while doing nothing. So: copy the guard's universe into a
# fixture, perturb it, and assert the guard goes RED with the RIGHT message.
#
# Run: bash users/dev/test-frontdoor-opacity-guard.sh
set -o errexit -o nounset -o pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
guard="users/dev/test-frontdoor-opacity.sh"
table="docs/plans/2026-07-26-phase9-consumer-disposition.md"

fail=0
pass_() { printf 'ok: %s\n' "$1"; }
bad()   { printf 'FAIL: %s\n' "$1"; fail=1; }

# A fixture is a minimal copy of everything the guard reads: itself, the table,
# and every governed file. Copied with --parents so relative paths survive.
new_fixture() {
  local fix; fix="$(mktemp -d)"
  ( cd "$repo_root" \
    && cp --parents "$guard" "$table" $(printf '%s\n' \
         pkgs/*/default.nix \
         users/dev/home.base.nix users/dev/home.darwin.nix \
         users/dev/home.devbox.nix users/dev/home.cloudbox.nix \
         hosts/cloudbox/configuration.nix hosts/devbox/configuration.nix \
         2>/dev/null | while read -r f; do [ -f "$f" ] && echo "$f"; done) \
         "$fix/" )
  printf '%s' "$fix"
}

# Run the guard in a fixture. Output goes to a FILE; never pipe into grep -q,
# which under pipefail inverts its own result.
run_guard() {
  local fix="$1" out="$2"
  set +o errexit
  ( cd "$fix" && bash "$guard" ) > "$out" 2>&1
  local rc=$?
  set -o errexit
  return $rc
}

# Assert the guard is GREEN on an unperturbed fixture. If this fails, every
# perturbation case below is meaningless.
fix="$(new_fixture)"; out="$(mktemp)"
if run_guard "$fix" "$out"; then
  pass_ "baseline: guard is green on an unperturbed tree"
else
  bad "baseline: guard is RED on an unperturbed tree -- fix the tree before trusting any case below"
  sed 's/^/      /' "$out"
fi
rm -rf "$fix" "$out"

[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "SOME TESTS FAILED"; exit 1; }
```

**Step 2: Run it. Expected: FAIL** ("guard is RED on an unperturbed tree") — because
`main` is red. This is the harness working correctly.

```bash
bash users/dev/test-frontdoor-opacity-guard.sh > /tmp/meta.txt 2>&1; echo "exit=$?"; cat /tmp/meta.txt
```

**Step 3: Commit.** `git add users/dev/test-frontdoor-opacity-guard.sh && git commit -m
"test: perturbation harness for the frontdoor opacity guard"`

---

## Task 2 (1a): Fix the TABLE, then mark the two devbox sites

This is the task that turns the baseline green. **Do it before any hardening**, so the
hardening tasks have a green baseline to perturb.

**Files:** Modify `docs/plans/2026-07-26-phase9-consumer-disposition.md`, then
`users/dev/home.devbox.nix`.

**Step 1: Correct row D1.** It currently reads:

```
| D1 | `hosts/devbox/configuration.nix:290` | `host-scoped` — no door on devbox; `:4096` is the only endpoint. |
```

`#217` (devbox convergence) falsified "no door on devbox". Rewrite the rationale to say
devbox now runs its own door and pigeon; this row covers pigeon's fan-out on devbox, and
the devbox door's own two sites are C10/C11. Keep the row ID stable.

**Step 2: Add rows C10 and C11** immediately after C9, matching the existing column
format. Cite **paths, not line numbers** (the guard will start requiring the path, and this
file has already drifted its cites twice):

```
| C10 | `users/dev/home.devbox.nix` (devbox door `OPENCODE_ANCHOR_URL`) | `exempt-infra` | Devbox analogue of C3: the door's **own** upstream, tautologically not through itself. Arrived with the devbox door in #217, which is also what falsified D1's "no door on devbox". |
| C11 | `users/dev/home.devbox.nix` (devbox frontdoor canary anchor cross-probe) | `exempt-infra` | Devbox analogue of C4: probes `:4096/global/health` directly so a door `503` can be told apart from a genuinely sick pool. Through the door the canary could not distinguish *door down* from *pool down*, which is the one thing it exists to do. |
```

**Step 3: Add the two markers** in `users/dev/home.devbox.nix`. Marker must be within 3
lines above the site and must NOT sit inside a shell line-continuation (the guard checks
this; SC2215 is how a broken `opencode-launch` once reached a deploy).

At the `OPENCODE_ANCHOR_URL=http://127.0.0.1:4096` line inside the door's `Environment`
list — note this is a Nix string list, so the marker is a Nix `#` comment on its own line:

```nix
        # frontdoor-exempt(C10): the door's own upstream anchor -- it cannot route through itself.
        "OPENCODE_ANCHOR_URL=http://127.0.0.1:4096"
```

At the canary's cross-probe (grep `ANCHOR_CODE=`), inside a bash heredoc-ish script body:

```bash
          # frontdoor-exempt(C11): cross-probe the anchor directly, so a door 503 can be
          # distinguished from a genuinely sick pool.
          ANCHOR_CODE=$(curl -s --max-time 5 --connect-timeout 3 -o /dev/null -w "%{http_code}" "http://127.0.0.1:4096/global/health")
```

**Step 4: Bump `EXPECTED_SITES` 14 → 16** in the guard. (Task 5 replaces this scalar
entirely; bump it now so the baseline is green in between.)

**Step 5: Run both. Expected: guard exit 0, meta exit 0.**

```bash
bash users/dev/test-frontdoor-opacity.sh > /tmp/g.txt 2>&1; echo "guard=$?"; tail -3 /tmp/g.txt
bash users/dev/test-frontdoor-opacity-guard.sh > /tmp/m.txt 2>&1; echo "meta=$?"; tail -2 /tmp/m.txt
```

Both must print `ALL PASS`. The guard must report `16 serve-addressing site(s); 16 carry a
valid exemption row`.

**Step 6: Commit.** `git commit -m "fix(opacity): give the devbox door rows to cite (C10/C11), correct D1"`

---

## Task 3: Close the laundering hole — a marker must cite a row that names its file

The highest-value task in this plan. **TDD: the meta-test must fail first.**

**Files:** Modify `users/dev/test-frontdoor-opacity-guard.sh`, then
`users/dev/test-frontdoor-opacity.sh`.

**Step 1: Add the failing case** to the meta-test, before the final tally:

```bash
# Case: a marker citing a row that does NOT name the citing file must be rejected.
# This is the exact shape a peer's subagent shipped on 2026-07-31 -- C3/C4 (cloudbox
# rows) cited from home.devbox.nix -- and the guard blessed it. Once the gate is
# armed this becomes the path of least resistance for anyone it blocks, so it must
# fail CLOSED.
fix="$(new_fixture)"; out="$(mktemp)"
sed -i 's/frontdoor-exempt(C10)/frontdoor-exempt(C3)/' "$fix/users/dev/home.devbox.nix"
if run_guard "$fix" "$out"; then
  bad "laundering: guard PASSED a marker citing C3, a row that does not name home.devbox.nix"
else
  if grep -q 'does not name' "$out"; then
    pass_ "laundering: marker citing a row that does not name its file is rejected"
  else
    bad "laundering: guard failed, but not with the path-mismatch message (masked by another failure?)"
    sed 's/^/      /' "$out"
  fi
fi
rm -rf "$fix" "$out"
```

**Step 2: Run. Expected: FAIL** — `guard PASSED a marker citing C3`. That is the hole,
demonstrated.

**Step 3: Implement `row_names_file()`** in the guard. Add near `row_is_exemption()`:

```bash
# A row's path list is column 2 of its table line. A marker may only cite a row
# whose path list actually names the citing file (or a glob covering it).
#
# WHY: row_exists() checked only that the id was in the table and
# row_is_exemption() only that it was C*/D*. Nothing tied the row to the file, so
# `frontdoor-exempt(C3)` -- the CLOUDBOX door's upstream -- passed on a
# home.devbox.nix site. That is not hypothetical: it is what a peer session's
# implementer subagent shipped on 2026-07-31 to turn this very guard green, and it
# was caught in review, not by the guard. An armed gate that blesses the wrong fix
# is worse than no gate, because it teaches laundering.
row_names_file() {
  local r="$1" f="$2" row_line
  row_line="$(grep -E "^\| $r \|" "$table" | head -1)"
  [ -n "$row_line" ] || return 1
  # Column 2 only: everything between the first and second unescaped pipe after the id.
  local paths; paths="$(printf '%s' "$row_line" | awk -F'|' '{print $3}')"
  # Exact path, or a directory/glob prefix that covers it (e.g. `pkgs/foo/` or `pkgs/*/`).
  case "$paths" in
    *"$f"*) return 0 ;;
  esac
  local d; d="$(dirname "$f")"
  case "$paths" in
    *"$d/"*) return 0 ;;
  esac
  return 1
}
```

**Step 4: Call it**, immediately after the `row_is_exemption` check:

```bash
    if ! row_names_file "$row" "$f"; then
      bad "$f:$lineno cites frontdoor-exempt($row), but row $row does not name $f -- cite a row that describes THIS file, or add one; do not borrow another host's row"
      continue
    fi
```

**Step 5: Run meta + guard. Expected: meta ALL PASS (exit 0), guard ALL PASS (exit 0).**

The guard must still be green: C10/C11 name `users/dev/home.devbox.nix`, and every
pre-existing marker cites a row that names its own file. **If any pre-existing marker now
fails, do not weaken the check — fix that row's path list**, which means the table was
lying about that file too.

**Step 6: Commit.**

---

## Task 4: Tighten `SITE_RE`, and catch markers-without-sites

Two small holes, one commit.

**Files:** Modify the meta-test, then the guard.

**Step 1: Add two failing cases.**

```bash
# Case: a non-pool port (4090-4095) is not a serve and must not be flagged. The
# pool is :4096-4099. A peer adding a :4091 harness would otherwise be blocked with
# no legitimate row to cite -- the guard would be demanding a lie.
fix="$(new_fixture)"; out="$(mktemp)"
printf '\n  # harness, not a serve\n  TEST_HARNESS_URL = "http://127.0.0.1:4091/health";\n' >> "$fix/users/dev/home.base.nix"
if run_guard "$fix" "$out"; then
  pass_ "site-re: a non-pool port (:4091) is not treated as a serve-addressing site"
else
  bad "site-re: :4091 was flagged as a serve site (SITE_RE still matches 409[0-9])"
  sed 's/^/      /' "$out"
fi
rm -rf "$fix" "$out"

# Case: a file whose sites all rot out of the pattern, but which keeps its markers,
# must FAIL rather than silently pass. The per-file 1:1 check was gated on
# `fsites -gt 0`, so total rot in one file was invisible -- the exact shape of the
# [^\n] bug that once let 10 of 11 sites stop matching.
fix="$(new_fixture)"; out="$(mktemp)"
sed -i 's|127\.0\.0\.1:4096|127.0.0.1:9999|g; s|\${serve_url}/|${serve_url}_ROTTED/|g; s|\$serve_url/|$serve_url_ROTTED/|g' \
  "$fix/users/dev/home.devbox.nix"
if run_guard "$fix" "$out"; then
  bad "rot: a file kept its markers while all its sites stopped matching, and the guard passed"
else
  pass_ "rot: markers with zero matching sites is a failure"
fi
rm -rf "$fix" "$out"
```

**Step 2: Run. Expected: both FAIL.**

**Step 3: Implement.** In `SITE_RE`, change the final alternative
`(127\.0\.0\.1|localhost):409[0-9]` → `(127\.0\.0\.1|localhost):409[6-9]`, and add a
comment saying the pool is `:4096-4099` and matching 4090-4095 demanded a marker for
things that are not serves.

Replace the per-file 1:1 gate:

```bash
  if [ "$fmarks" -gt 0 ] && [ "$fsites" -eq 0 ]; then
    bad "$f: $fmarks frontdoor-exempt marker(s) but ZERO matching sites -- either the markers are stale, or SITE_RE has rotted and stopped seeing this file's sites"
  elif [ "$fsites" -gt 0 ] && [ "$fmarks" != "$fsites" ]; then
    bad "$f: $fsites serve-addressing site(s) but $fmarks marker(s) -- not 1:1, so a site may be laundering a neighbour's exemption"
  fi
```

**Step 4: Run meta + guard. Expected: both ALL PASS.** Note the rot case may now report
the count-mismatch failure instead; either message is acceptable as long as it is RED.

**Step 5: Commit.**

---

## Task 5: Replace the scalar `EXPECTED_SITES` with a per-file manifest

**Files:** Modify the meta-test, then the guard.

**Why:** two concurrent PRs each adding one site both bump 14→15. Identical edit ⇒ **git
merges it clean** ⇒ both green ⇒ `main` red at 16≠15, blocking everyone after the fact. A
per-file manifest makes different-file additions merge clean *and correct*, and same-file
additions conflict *textually*, forcing a human resolution.

**Step 1: Add the failing case.**

```bash
# Case: a NEW site in a file that already has sites, citing an EXISTING valid row,
# passes every per-site check. Only a count-shaped invariant catches it. This is why
# the manifest cannot be dropped in favour of per-site markers alone.
fix="$(new_fixture)"; out="$(mktemp)"
cat >> "$fix/users/dev/home.devbox.nix" <<'PERTURB'
  # frontdoor-exempt(C10): smuggled extra site citing a real, file-naming row
  extraProbe = "http://127.0.0.1:4096/global/health";
PERTURB
if run_guard "$fix" "$out"; then
  bad "manifest: an extra site citing an existing valid row passed -- no count-shaped invariant"
else
  pass_ "manifest: an extra site is caught by the per-file count"
fi
rm -rf "$fix" "$out"
```

Note this case may already pass via the scalar total. Run it before and after; the point of
Step 3 is that it keeps passing while gaining merge-correctness.

**Step 2: Implement the manifest.** Replace the `EXPECTED_SITES=14` block with a sorted,
one-line-per-file manifest. Keep it INLINE so the guard stays self-contained:

```bash
# Per-file expected site counts. SORTED BY PATH, one file per line.
#
# WHY NOT A SINGLE SCALAR: `EXPECTED_SITES=14` merged WRONG rather than
# conflicting. Two concurrent PRs each adding one site both write 15; git sees an
# identical edit and merges it clean; both are green in isolation; main lands at 16
# and goes red, blocking everyone *after the fact*. Per-file lines make
# different-file additions merge clean AND correct, and same-file additions collide
# textually so a human must resolve them.
#
# WHY KEEP A COUNT AT ALL, given per-site markers: a NEW site citing an EXISTING
# valid row passes every per-site check silently. Only a count catches that.
#
# To change a number here you must also add the marker and the table row, in the
# same PR. That is the protocol, and it is documented in AGENTS.md.
read -r -d '' EXPECTED_MANIFEST <<'MANIFEST' || true
hosts/cloudbox/configuration.nix 5
hosts/devbox/configuration.nix 1
pkgs/oc-auto-attach/default.nix 1
pkgs/opencode-launch/default.nix 2
pkgs/reset-workspace/default.nix 2
users/dev/home.base.nix 1
users/dev/home.cloudbox.nix 0
users/dev/home.darwin.nix 1
users/dev/home.devbox.nix 2
MANIFEST
```

**The numbers above are a starting sketch — DERIVE THE REAL ONES** from the green tree and
paste them in. Print them with:

```bash
bash -c 'source /dev/stdin <<< "$(sed -n "/^SITE_RE=/,/^$/p" users/dev/test-frontdoor-opacity.sh)"; :' 2>/dev/null || true
# simplest: add a temporary `printf "%s %s\n" "$f" "${sites_per_file[$f]:-0}"` loop
# to the guard, run it, paste the sorted output, then remove the loop.
```

Then enforce, replacing the scalar check:

```bash
while read -r mfile mcount; do
  [ -z "${mfile:-}" ] && continue
  actual="${sites_per_file[$mfile]:-0}"
  if [ "$actual" -ne "$mcount" ]; then
    bad "$mfile: manifest expects $mcount serve-addressing site(s), found $actual -- if intentional, update the manifest, add the frontdoor-exempt marker, and add/extend the disposition-table row, all in the same PR"
  fi
done <<< "$EXPECTED_MANIFEST"

# A governed file missing from the manifest is a hole: sites there would be
# counted by no one.
for f in "${files[@]}"; do
  case "$EXPECTED_MANIFEST" in
    *"$f "*) ;;
    *) bad "$f is governed but absent from EXPECTED_MANIFEST -- add a line for it (0 is a valid count)" ;;
  esac
done
```

**Step 3: Run meta + guard. Expected: both ALL PASS.**

**Step 4: Add one more meta case** proving a manifest hole is caught:

```bash
# Case: a governed file absent from the manifest must fail, not pass silently.
fix="$(new_fixture)"; out="$(mktemp)"
sed -i '/^users\/dev\/home\.darwin\.nix /d' "$fix/$guard"
if run_guard "$fix" "$out"; then
  bad "manifest: a governed file missing from the manifest passed"
else
  pass_ "manifest: a governed file missing from the manifest is caught"
fi
rm -rf "$fix" "$out"
```

**Step 5: Run. Expected: ALL PASS. Commit.**

---

## Task 6 (1b): Arm the guard in `nix flake check`

**Only now.** The tree is green and the guard is hard.

**Files:** Modify `flake.nix`.

**Step 1:** Extend `checks.${devboxSystem}` (grep `checks.${devboxSystem}`), keeping the
existing three entries:

```nix
    checks.${devboxSystem} = {
      home-dev = self.homeConfigurations.dev.activationPackage;
      home-cloudbox = self.homeConfigurations.cloudbox.activationPackage;
      nixos-devbox = self.nixosConfigurations.devbox.config.system.build.toplevel;

      # Phase 9.2 opacity guard. Bash-only, so it adds seconds to the ARM leg that
      # already spends ~3 min realising the three configurations above.
      #
      # WHY THIS EXISTS: the guard was written in Phase 9.2 and then enforced
      # NOWHERE -- no flake check, no CI step, no canary. It sat red on main from
      # #217 (which added a devbox door, and with it two unmarked sites) until
      # 2026-08-01 and nothing noticed. A guard nothing runs is documentation with
      # a shebang.
      frontdoor-opacity = devboxPkgs.runCommand "frontdoor-opacity-guard" {
        nativeBuildInputs = [ devboxPkgs.bash ];
      } ''
        cd ${self}
        bash users/dev/test-frontdoor-opacity.sh
        bash users/dev/test-frontdoor-opacity-guard.sh
        touch $out
      '';
    };
```

**Step 2: Verify by mechanism, then PERTURB.** A check that cannot fail is the defect this
whole task exists to prevent.

```bash
nix flake check --print-build-logs --keep-going 2>&1 | tee /tmp/flake-green.txt; echo "exit=$?"
```

Expected: exit 0.

Then perturb — add an unmarked site to a governed file, and confirm the CHECK (not just the
script) goes red:

```bash
printf '\n  smuggled = "http://127.0.0.1:4096/global/health";\n' >> users/dev/home.base.nix
nix flake check --print-build-logs --keep-going 2>&1 | tee /tmp/flake-red.txt; echo "exit=$?"
grep -c 'no frontdoor-exempt marker' /tmp/flake-red.txt   # must be >= 1
git checkout -- users/dev/home.base.nix    # ONLY safe here: throwaway worktree, file untouched by peers
nix flake check 2>&1 | tail -2; echo "exit=$?"            # back to 0
```

Expected: exit non-zero with the marker message, then exit 0 after revert.

> **Note on `git checkout --`:** normally banned in shared worktrees. This plan runs in a
> **throwaway worktree** created for this step, and the file is one this task just
> perturbed. Do not run it in `/home/dev/projects/workstation`.

**Step 3: Commit.**

---

## Task 7: Document the peer protocol

Today the protocol exists only in the guard's stderr. Once the gate is armed, a blocked
peer needs to find the right fix faster than the wrong one.

**Files:** Modify `AGENTS.md`.

**Step 1:** Add a short subsection under the repo's existing conventions:

```markdown
## Front-door opacity guard

`nix flake check` runs `users/dev/test-frontdoor-opacity.sh`: no shipped consumer may
address an individual serve (`127.0.0.1:4096-4099`) without an inline exemption.

If it blocks your PR, the fix is **three edits in your own PR**:

1. **Marker** on (or within 3 lines above) the line:
   `frontdoor-exempt(<ROW>): <one-line reason>`
2. **Table row** in `docs/plans/2026-07-26-phase9-consumer-disposition.md`. The row must
   be a C*/D* exemption class **and its path column must name your file** — you cannot
   borrow another host's row. If no row describes your file, add one.
3. **Manifest count** for your file in the guard's `EXPECTED_MANIFEST`.

The count is per-file *because* a single scalar merges clean-but-wrong across concurrent
PRs. Same-file edits are meant to conflict; resolve them by hand.

**The wrong fix**, which the guard now rejects: citing an existing row that does not
describe your file. That was shipped once and reverted. If routing through the door
(`:4700`) is possible at all, do that instead of adding an exemption.
```

**Step 2: Commit.**

---

## Final verification (run all three, capture to files)

```bash
bash users/dev/test-frontdoor-opacity.sh > /tmp/final-guard.txt 2>&1; echo "guard=$?"
bash users/dev/test-frontdoor-opacity-guard.sh > /tmp/final-meta.txt 2>&1; echo "meta=$?"
nix flake check --print-build-logs --keep-going > /tmp/final-flake.txt 2>&1; echo "flake=$?"
tail -3 /tmp/final-guard.txt; tail -3 /tmp/final-meta.txt
```

All three exit 0. Then **`adversarial-reviewer-fable` on the real diff — mandatory**, then
ONE PR, `gh pr merge --squash` (the repo forbids merge commits).

---

## Out of scope — do not drift into these

- `workstation-nv5l` (forward-pool stall protection, P1) — needs a design call.
- Step 2 residuals (`vjq0`, `u417`, `pcf3`), Step 4 (`4b1q`), `km5f`.
- `workstation-eon4`, `workstation-0dm8`, the global-ro cache (#221) — all CLOSED.
- Structural opacity (unix sockets / netns, `pcf3`) — stays P3. This step buys the
  enforcement that makes the convention real; it does not make it a guarantee.
