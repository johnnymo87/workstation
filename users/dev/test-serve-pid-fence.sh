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

for f in "${WRAPPERS[@]}"; do
  file_fail=0
  if [[ ! -f "$f" ]]; then
    bad "$f: wrapper file not found (renamed? update WRAPPERS in this script)"
    continue
  fi

  # 1. The export must be present. Without it the fence is UNARMED -- which is a
  #    deliberate, safe state in the binary (unset = unarmed, never fatal, so the
  #    binary release and the host rebuild are order-independent), but it is NOT a
  #    state we intend to ship. Silence here would be a silently-disarmed fence,
  #    the precise failure class this bead is about.
  if ! grep -q 'export OPENCODE_SERVE_EXPECTED_PID=\$\$' "$f"; then
    bad "$f: missing 'export OPENCODE_SERVE_EXPECTED_PID=\$\$' (fence would ship UNARMED)"
  fi

  # 2. Every serve launch must be exec'd. This is the load-bearing half: the
  #    export above is only TRUE because of the exec.
  #
  #    Matched on the launch shape `opencode serve --port`, which is how all three
  #    wrappers invoke it. Comments are stripped first so the long rationale
  #    comments that quote the command (and deliberately show the non-exec form as
  #    the thing NOT to do) cannot trip the check.
  launches=$(sed 's/#.*$//' "$f" | grep -n 'opencode serve --port' || true)
  if [[ -z "$launches" ]]; then
    bad "$f: no 'opencode serve --port' launch found (did the invocation shape change?)"
    continue
  fi
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    # Strip the leading "N:" that grep -n adds, then the leading whitespace.
    stripped=$(printf '%s' "$line" | sed 's/^[0-9]*://; s/^[[:space:]]*//')
    if [[ "$stripped" != exec\ * ]]; then
      bad "$f: serve launch is not exec'd -> the serve becomes a CHILD, pid != \$\$, exit 21 crash-loop"
      note "offending line: $stripped"
    fi
  done <<< "$launches"

  [[ "$file_fail" -eq 0 ]] && note "$f: OK"
done

# 3. The export must come BEFORE the exec in each file. An export placed after the
#    exec line is dead code and would ship an unarmed fence that LOOKS armed to
#    check 1 above -- a green guard covering a disarmed fence is worse than none.
for f in "${WRAPPERS[@]}"; do
  [[ -f "$f" ]] || continue
  exp_line=$(sed 's/#.*$//' "$f" | grep -n 'export OPENCODE_SERVE_EXPECTED_PID' | head -1 | cut -d: -f1 || true)
  exec_line=$(sed 's/#.*$//' "$f" | grep -n 'opencode serve --port' | head -1 | cut -d: -f1 || true)
  if [[ -n "$exp_line" && -n "$exec_line" && "$exp_line" -gt "$exec_line" ]]; then
    bad "$f: export appears AFTER the serve launch (line $exp_line > $exec_line) -- fence would be unarmed"
  fi
done

if [[ "$fail" -ne 0 ]]; then
  echo
  echo "The serve PID fence invariant is broken. See bead workstation-4b1q and"
  echo "docs/plans/2026-07-31-frontdoor-next-roadmap.md Step 4."
  exit 1
fi

echo "== serve PID fence: all wrapper invariants hold =="
