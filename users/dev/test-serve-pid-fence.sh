#!/usr/bin/env bash
# Serve registry PID fence: the wrapper-side invariant guard (bead workstation-4b1q).
#
# WHAT THE FENCE IS. Each serve wrapper exports OPENCODE_SERVE_EXPECTED_PID=$$ and
# then `exec`s `opencode serve`. `exec` REPLACES the shell process, so the serve's
# own pid IS the $$ that was exported. The opencode-patched binary compares
# process.pid against that variable and refuses to claim the routing slot (exit 21)
# when they disagree. A child process inherits the VARIABLE but can never inherit
# the PID, which is what makes the check discriminating -- and unlike the older
# port-only fence it does not care what the impostor binds, so it closes the
# port / hostname (::1 vs 127.0.0.1) / socket variants in one stroke.
#
# WHY THIS SCRIPT EXISTS. The fence is only sound while the wrapper `exec`s. If an
# edit ever turns
#     exec opencode serve --port ...
# into
#     opencode serve --port ...
# the serve becomes a CHILD of the wrapper shell, its pid stops matching $$, and
# every serve in the pool crash-loops on exit 21 -- at the next deploy, on a box
# nobody is watching. The roadmap's Step 4 says explicitly: assert the exec
# property, do not leave it as a comment. This is that assertion, and `nix flake
# check` runs it (see checks.aarch64-linux.serve-pid-fence in flake.nix).
#
# It is a STATIC check over the wrapper sources on purpose. The alternative -- a
# runtime probe -- can only fail after the bad wrapper has already been deployed,
# which is exactly the window this is meant to close.

set -euo pipefail

fail=0
note() { printf '  %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1"; fail=1; file_fail=1; }

# The three files that define an `opencode serve` wrapper. Keep in sync with the
# roadmap's Step 4 list; a fourth wrapper MUST be added here or it ships unfenced.
WRAPPERS=(
  "hosts/cloudbox/configuration.nix"
  "users/dev/home.devbox.nix"
  "users/dev/home.darwin.nix"
)

echo "== serve PID fence: wrapper invariants =="

# Every check below runs against a COMMENT-STRIPPED view of the file, never the raw
# text. Checking the raw text was a real defect, caught in adversarial review and
# reproduced: changing the export to `# export OPENCODE_SERVE_EXPECTED_PID=$$` left
# this guard GREEN while shipping the fence UNARMED. Commenting a line out "to
# debug" is the single most plausible human edit here, so the guard has to survive
# exactly that. A green guard covering a disarmed fence is worse than no guard.
#
# Limitation, stated rather than hidden: `sed 's/#.*$//'` is a crude Nix comment
# stripper and would also truncate a `#` inside a string literal. None of the lines
# it must see (the export, the `opencode serve --port` launch) contain one, and the
# manifest check below fails loudly if a wrapper ever stops matching these shapes.
stripped_of() { sed 's/#.*$//' "$1"; }

for f in "${WRAPPERS[@]}"; do
  file_fail=0
  if [[ ! -f "$f" ]]; then
    bad "$f: wrapper file not found (renamed? update WRAPPERS in this script)"
    continue
  fi
  body=$(stripped_of "$f")

  # 1. The export must be present AND LIVE (not commented out). Without it the
  #    fence is UNARMED -- a deliberate, safe state in the binary (unset = unarmed,
  #    never fatal, so the binary release and the host rebuild are order-independent),
  #    but NOT a state we intend to ship.
  if ! grep -q 'export OPENCODE_SERVE_EXPECTED_PID=\$\$' <<< "$body"; then
    bad "$f: no live 'export OPENCODE_SERVE_EXPECTED_PID=\$\$' (missing or commented out) -- fence would ship UNARMED"
  fi

  # 2. Every serve launch must be exec'd. This is the load-bearing half: the export
  #    above is only TRUE because of the exec, which makes the serve REPLACE this
  #    shell and inherit its pid.
  launches=$(grep -n 'opencode serve --port' <<< "$body" || true)
  if [[ -z "$launches" ]]; then
    bad "$f: no 'opencode serve --port' launch found (did the invocation shape change?)"
    continue
  fi
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    stripped=$(printf '%s' "$line" | sed 's/^[0-9]*://; s/^[[:space:]]*//')
    if [[ "$stripped" != exec\ * ]]; then
      bad "$f: serve launch is not exec'd -> the serve becomes a CHILD, pid != \$\$, exit 21 crash-loop"
      note "offending line: $stripped"
    fi
  done <<< "$launches"

  # 3. EVERY export must precede EVERY launch. An export after the exec is dead code
  #    that would still satisfy check 1.
  last_exp=$(grep -n 'export OPENCODE_SERVE_EXPECTED_PID' <<< "$body" | tail -1 | cut -d: -f1 || true)
  first_launch=$(grep -n 'opencode serve --port' <<< "$body" | head -1 | cut -d: -f1 || true)
  if [[ -n "$last_exp" && -n "$first_launch" && "$last_exp" -gt "$first_launch" ]]; then
    bad "$f: an export appears AFTER a serve launch (line $last_exp > $first_launch) -- that export is dead code"
  fi

  [[ "$file_fail" -eq 0 ]] && note "$f: OK"
done

# 4. MANIFEST: the WRAPPERS list must be COMPLETE, not merely correct. A fourth
#    wrapper added elsewhere would ship unfenced while this guard stayed green --
#    the same "green guard, real gap" shape as the bug in check 1.
#
#    A pool wrapper is identified by the port fence marker it must already carry.
#    Deliberately NOT keyed on `opencode serve`: pkgs/opencode-frontdoor's route-gate
#    launches a serve with no OPENCODE_SERVE_ID / OPENCODE_ROUTING_DB, so it joins no
#    pool, claims no registry slot, and is legitimately out of scope.
echo "== serve PID fence: wrapper manifest =="
found=$(grep -rl 'OPENCODE_SERVE_EXPECTED_PORT' --include='*.nix' . 2>/dev/null | sed 's|^\./||' | sort)
declared=$(printf '%s\n' "${WRAPPERS[@]}" | sort)
if [[ "$found" != "$declared" ]]; then
  bad "WRAPPERS is stale. Files exporting OPENCODE_SERVE_EXPECTED_PORT != the declared list."
  note "declared: $(printf '%s ' $declared)"
  note "found:    $(printf '%s ' $found)"
  note "A new wrapper must be ADDED to WRAPPERS in this script, or it ships unfenced."
else
  note "manifest complete ($(wc -w <<< "$found") wrappers)"
fi

if [[ "$fail" -ne 0 ]]; then
  echo
  echo "The serve PID fence invariant is broken. See bead workstation-4b1q and"
  echo "docs/plans/2026-07-31-frontdoor-next-roadmap.md Step 4."
  exit 1
fi

echo "== serve PID fence: all wrapper invariants hold =="
