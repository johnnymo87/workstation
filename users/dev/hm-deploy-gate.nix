# Stale-deploy gate for `home-manager switch` (bead workstation-h0mp).
#
# THE INCIDENT. home-manager is last-writer-wins over ONE user profile, but this
# box runs many concurrent swarm worktrees at different commits. On 2026-08-01
# 09:22 a switch from a ~2-day-stale worktree silently un-deployed the
# session-state writer plugin (#230) and a shell-env fix (#225) across the whole
# fleet. Nothing alerted. It was found ~32h later, by accident, because a smoke
# test noticed an empty overlay dir. The switch SUCCEEDS and a missing plugin
# produces no output, so the failure is silent on both ends.
#
# WHY NOT THE OBVIOUS CHECK. The bead proposed verifying that the expected files
# exist in the new generation. That detects neither half of the incident: the
# stale config declared the session-state plugin ZERO times (measured:
# `git show 84900bd~1:users/dev/opencode-config.nix | grep -c session-state`
# is 0) so its generation correctly lacked the file, and shell-env.ts existed in
# both generations with only its CONTENT reverted. home-manager already
# guarantees declared->linked. Catching this needs a reference from OUTSIDE the
# config being deployed.
#
# THE REFERENCE. Each switch records the revision it deployed in a beacon file.
# The gate reads the PREVIOUS switch's beacon (activation runs entryBefore
# writeBoundary, so the old file is still in place) and refuses when the
# incoming revision does not contain it -- i.e. when activating would drop
# commits that are live right now. No network, no plugin inventory, no parser:
# any regression is caught regardless of which file changed.
#
# WHY A GATE AND NOT ONLY A CANARY. The bead's tiebreaker is "fails LOUDLY and
# cannot be silently skipped". A periodic canary lets the bad switch land and
# pages someone later, if the alert path happens to be up. This aborts the
# switch in the terminal of the agent causing it, at the moment of the mistake.
# A canary is still wanted as a second layer -- it covers the holes enumerated
# in hm_gate_verdict -- and is filed as workstation-4ze8.
#
# BLAST RADIUS. This can block every agent on a shared box. It is therefore
# deliberately asymmetric: it aborts only on a PROVEN regression (git has both
# commits and says the deployed one is unreachable from the incoming one) and
# merely warns on every form of doubt. A false refusal here is worse than the
# incident it prevents.
{ config, lib, pkgs, localPkgs, isDarwin, self ? null, ... }:

let
  # `self` is passed to the devbox and cloudbox home targets (flake.nix ~713 and
  # ~733) but NOT to the darwin one (~755), so it carries a default and the gate
  # is scoped to the Linux hosts. That is also where the failure lives: macOS is
  # a single-user laptop with no concurrent swarm worktrees racing one profile.
  enabled = !isDarwin && self != null;

  # Clean tree -> self.rev; dirty tree -> self.dirtyRev ("<sha>-dirty"); the two
  # are mutually exclusive. Measured on cloudbox 2026-08-04 against a throwaway
  # flake: clean gave rev=<sha> with dirtyRev absent, dirty gave rev absent with
  # dirtyRev=<sha>-dirty. A source with neither (a path: source) yields the
  # literal "unknown", which the gate treats as doubt and warns on.
  incomingRev = if self == null then "unknown"
                else (self.rev or (self.dirtyRev or "unknown"));

  beaconPath = ".local/state/hm-deploy-rev";
in
lib.mkIf enabled {
  # The beacon. Linked at linkGeneration, i.e. AFTER the gate has read the
  # previous one -- that ordering is what makes the comparison meaningful.
  home.file.${beaconPath}.text = "${incomingRev}\n";

  home.activation.assertFreshDeploy =
    # entryBefore writeBoundary: nothing has been written to $HOME yet, so
    # aborting here leaves the live generation completely untouched. Same
    # placement as home.activation.assertPlatform in home.cloudbox.nix, which
    # guards the sibling "wrong config silently deployed" class.
    lib.hm.dag.entryBefore [ "writeBoundary" ] ''
      export PATH="${lib.makeBinPath [ pkgs.git pkgs.coreutils ]}:$PATH"
      # If the library cannot be sourced, every hm_gate_* call becomes a
      # "command not found" and VERDICT ends up EMPTY -- which matched no case
      # branch and waved the deploy through in silence. That was a real defect,
      # found by pkgs/hm-deploy-gate-sh/test-behaviour.sh running this script
      # with the store path absent; the library tests could not see it, because
      # everything they exercise returns a string. A guard whose own dependency
      # vanished must not report "fine".
      GATE_LIB_OK=1
      # shellcheck source=/dev/null
      source "${localPkgs.hm-deploy-gate-sh}" 2>/dev/null || GATE_LIB_OK=0
      if [ "$GATE_LIB_OK" = 0 ] || ! command -v hm_gate_classify >/dev/null 2>&1; then
        echo "WARNING [hm-deploy-gate]: the gate library did not load; this deploy is UNCHECKED." >&2
        echo "WARNING [hm-deploy-gate]: expected ${localPkgs.hm-deploy-gate-sh}" >&2
        exit 0
      fi

      INCOMING="${incomingRev}"
      # Third seam, and the only one that can weaken the gate: it replaces the
      # revision baked in at build time. pkgs/hm-deploy-gate-sh/test-behaviour.sh
      # needs it because the baked rev is a commit no sandbox repo can contain.
      # It therefore ANNOUNCES ITSELF -- an unannounced override would be a
      # silent bypass, strictly worse than HM_ALLOW_STALE_DEPLOY, which at least
      # shouts. Never set this outside a test.
      if [ -n "''${HM_GATE_INCOMING:-}" ]; then
        echo "WARNING [hm-deploy-gate]: HM_GATE_INCOMING override in effect ($HM_GATE_INCOMING); the gate is NOT judging the tree you are deploying." >&2
        INCOMING="''${HM_GATE_INCOMING}"
      fi
      # Test seams. Both default to the real paths; they exist so the check in
      # flake.nix can run THIS script -- the shipped one, not a copy -- against
      # a scratch repo and a scratch beacon. Verifying the refusal any other way
      # would mean deploying to the live profile to install a beacon first.
      BEACON="''${HM_GATE_BEACON:-${config.home.homeDirectory}/${beaconPath}}"
      # Ancestry needs a clone holding both commits. Overridable so the gate can
      # be exercised against a scratch repo without touching the real one.
      GATE_REPO="''${HM_GATE_REPO:-${config.home.homeDirectory}/projects/workstation}"

      DEPLOYED_RAW="$(cat "$BEACON" 2>/dev/null || true)"
      INC="$(hm_gate_beacon_rev "$INCOMING")"
      DEP="$(hm_gate_beacon_rev "$DEPLOYED_RAW")"

      # hm_gate_classify, not an inlined `if` -- the tests call this exact
      # function, so the dispatch cannot drift out from under them.
      RELATION="$(hm_gate_classify "$GATE_REPO" "$INCOMING" "$DEPLOYED_RAW")"
      VERDICT="$(hm_gate_verdict "$RELATION" "''${HM_ALLOW_STALE_DEPLOY:-}")"

      case "$VERDICT" in
        allow:*)
          ;;
        refuse:*)
          echo "" >&2
          echo "FATAL: this switch would UN-DEPLOY live configuration." >&2
          echo "" >&2
          echo "  deployed now : $DEP" >&2
          echo "  this tree    : $INC${""}" >&2
          echo "" >&2
          echo "The revision you are deploying does not contain the one that is" >&2
          echo "currently live, so activating it drops commits that are running" >&2
          echo "right now -- fleet-wide, for every other agent on this box." >&2
          echo "This is bead workstation-h0mp: on 2026-08-01 exactly this took" >&2
          echo "out the session-state plugin and a shell-env fix for ~32 hours," >&2
          echo "silently, because the switch itself succeeded." >&2
          echo "" >&2
          echo "Nothing has been written; your live generation is untouched." >&2
          echo "" >&2
          echo "Fix by rebasing onto what is deployed:" >&2
          echo "    git -C \"$GATE_REPO\" fetch origin" >&2
          echo "    git rebase origin/main    # from your worktree, then re-run" >&2
          echo "" >&2
          echo "To see what you would drop:" >&2
          echo "    git -C \"$GATE_REPO\" log --oneline $INC..$DEP" >&2
          echo "" >&2
          echo "If you really mean to roll back, say so explicitly:" >&2
          echo "    HM_ALLOW_STALE_DEPLOY=1 <your switch command>" >&2
          echo "" >&2
          exit 1
          ;;
        warn:override)
          echo "WARNING [hm-deploy-gate]: HM_ALLOW_STALE_DEPLOY=1 -- deploying $INC over live $DEP." >&2
          echo "WARNING [hm-deploy-gate]: this DROPS commits other agents are running. Deliberate rollback assumed." >&2
          ;;
        "")
          # Unreachable via hm_gate_verdict, which always echoes something --
          # but an empty VERDICT is exactly what a broken library produced, and
          # the failure mode was silence. Never fall through quietly again.
          echo "WARNING [hm-deploy-gate]: produced no verdict (relation='$RELATION'); this deploy is UNCHECKED." >&2
          ;;
        warn:*)
          # Doubt, not proof. Never blocks -- see BLAST RADIUS above. Each of
          # these is a hole the drift canary (workstation-4ze8) is meant to close.
          echo "WARNING [hm-deploy-gate]: could not verify this deploy is not a regression (''${VERDICT#warn:})." >&2
          echo "WARNING [hm-deploy-gate]: deployed=''${DEP:-<none>} incoming=''${INC:-<none>} repo=$GATE_REPO" >&2
          ;;
      esac
    '';
}
