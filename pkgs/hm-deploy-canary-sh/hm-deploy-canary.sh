# Sourceable bash library for the home-manager drift canary (workstation-4ze8).
#
# LAYER 2. workstation-h0mp shipped an activation GATE that refuses a
# `home-manager switch` which would drop live commits. The gate is deployed BY
# the thing it guards, so it cannot close its own holes: every `warn:` path in
# hm_gate_verdict, the HM_ALLOW_STALE_DEPLOY escape hatch, and a gate that is
# itself un-deployed by the last-writer-wins race it exists to prevent. This
# library is the detector that runs in a DIFFERENT deploy channel -- a NixOS
# system unit, which a home-manager switch cannot remove.
#
# WHY THIS FILE SOURCES THE GATE RATHER THAN RESTATING IT. The relation and
# verdict logic is subtle (see the squash-merge trap in hm-deploy-gate.sh: a
# plain ancestry test refuses forever after `gh pr merge --squash`). A second
# copy here would drift, and the guard family that exists to kill mirror-drift
# does not get to ship one. The unit sources pkgs/hm-deploy-gate-sh and this
# library only ADDS the out-of-band predicates.
#
# WHAT WAS MEASURED BEFORE ANY OF THIS WAS WRITTEN (cloudbox, 2026-08-18):
#
#   M1  There is no auto-upgrade and no auto-switch timer on this host, so
#       "behind origin/main" is the PERMANENT steady state between manual
#       switches. Live beacon was 2 commits behind main, one of which matched
#       the originally-proposed "deploy-relevant" globs (users/|assets/|pkgs/|
#       flake.*) -- and that commit was #382, which touched flake.nix (a
#       `checks.` entry) and a devbox test script and cannot change cloudbox's
#       home closure at all. The glob predicate was therefore a false positive
#       on day one, permanently. It is not implemented here. It was not tuned;
#       it was cut.
#
#   M2  The obvious replacement -- "compare the deployed generation's closure
#       to what main prescribes" -- is defeated by layer 1 itself. The beacon
#       is `home.file.<p>.text = "${self.rev}\n"`, so the home-manager closure
#       changes on EVERY commit, including docs-only ones. Measured: drvPath at
#       the deployed rev differed from drvPath at main, and the entire
#       difference reduced to the beacon input plus the activation script that
#       bakes the same rev. Closure identity is 100% noise as a drift signal
#       while the beacon is part of the closure.
#
#       That confound is REMOVABLE, and removing it yields an exact predicate:
#       with the beacon and the gate's activation entry forced to constants via
#       extendModules, the deployed rev and main tip produced the IDENTICAL
#       derivation (ljgfi574ggw5wcsami034z8y18m671bf). That is filed as its own
#       bead -- it costs ~15s of eval per side and couples to layer 1's
#       internal attribute names, so it is deliberately NOT in this library.
#
# WHAT THIS LIBRARY CANNOT DO, stated here so nobody has to rediscover it. A
# snapshot ancestry predicate cannot distinguish an ancestor-stale deploy from
# the benign behind-main state of M1 -- they are the same snapshot. Whether the
# 2026-08-01 incident had that shape is UNRECOVERABLE: the beacon post-dates the
# incident and home-manager generations are pruned to ~3 (users/dev/disk-
# cleanup.nix sets NIX_KEEP_GENERATIONS=3). So the transition detector is the
# one that can see that shape, and it can only see it while it is running. If
# this canary is not running at the moment of a bad switch, an ancestor-stale
# deploy remains undetectable by this library indefinitely.

# ---------------------------------------------------------------------------
# hm_canary_beacon_state <raw-beacon-contents>
#
# Classifies the beacon as a VALUE, before any git is consulted. Absence is not
# authoritative -- that is the whole lesson of the incident -- so every
# not-ok state here is alertable by the caller rather than skippable.
#
# `unknown` is a real value, not a placeholder: users/dev/hm-deploy-gate.nix
# writes the literal string when the flake source has neither rev nor dirtyRev
# (a `path:` source, or an export with no git metadata).
hm_canary_beacon_state() {
  local raw="${1-}"
  # Strip the trailing newline the beacon is written with, and nothing else --
  # leading/trailing junk must NOT be normalised away, or a corrupt beacon
  # reads as healthy.
  local v="${raw%$'\n'}"

  if [ -z "$raw" ]; then printf 'absent\n'; return 0; fi
  if [ -z "$v" ]; then printf 'empty\n'; return 0; fi
  if [ "$v" = "unknown" ]; then printf 'unknown\n'; return 0; fi

  case "$v" in
    # The dirty form is <40-hex>-dirty. Deployed from an uncommitted tree: the
    # content is not in git at all, so no ancestry question about it can be
    # answered. Reported separately from malformed because it is a legitimate
    # thing an agent can do, and it warns rather than pages.
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-dirty)
      printf 'dirty\n' ;;
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f])
      printf 'ok\n' ;;
    *)
      printf 'malformed\n' ;;
  esac
}

# ---------------------------------------------------------------------------
# hm_canary_provenance <beacon-path> <generation-beacon-path>
#
# Is the beacon actually the one the LIVE GENERATION declares?
#
# THE HOLE THIS CLOSES, which no other predicate here can see. If something
# replaces ~/.local/state/hm-deploy-rev with a regular file -- a stray `echo`,
# a restore, an agent "fixing" a confusing warning -- then the value is
# well-formed, no transition is observed, and layer 1 happily reads a LYING
# beacon and can bless a genuine regression. A wrong beacon is strictly worse
# than a missing one, because the gate trusts it.
#
# Compared by `readlink -f`, not by timestamps, and not by `readlink`:
#   * Timestamps were considered and REJECTED. The beacon is a symlink INTO the
#     nix store, and the store normalises mtimes: `stat -L -c %Y` on it returns
#     1 (1970), while `stat -c %Y` returns the activation time. A detector that
#     is one `-L` away from alerting forever is not a detector. Measured live,
#     the beacon link and the profile link also landed in the same integer
#     second (0.708s apart), so any ordering comparison needs a tolerance nobody
#     can justify. This check needs no clock at all.
#   * The FIRST HOP differs on the two sides (the beacon points into
#     ...-home-manager-files/..., the generation path into the file's own
#     derivation), so only the fully resolved path is comparable. Measured live:
#     both resolve to the identical store path.
hm_canary_provenance() {
  local beacon="${1-}" gen="${2-}"

  if [ ! -e "$beacon" ] && [ ! -L "$beacon" ]; then printf 'beacon-absent\n'; return 0; fi
  # A beacon that is not a symlink was not placed by home-manager. Checked
  # before resolving, because `readlink -f` on a regular file succeeds and
  # would otherwise report a mismatch with a misleading label.
  if [ ! -L "$beacon" ]; then printf 'not-symlink\n'; return 0; fi
  if [ ! -e "$gen" ]; then printf 'generation-absent\n'; return 0; fi

  local a b
  a="$(readlink -f "$beacon" 2>/dev/null || true)"
  b="$(readlink -f "$gen" 2>/dev/null || true)"
  if [ -z "$a" ] || [ -z "$b" ]; then printf 'unresolvable\n'; return 0; fi
  if [ "$a" = "$b" ]; then printf 'ok\n'; else printf 'mismatch\n'; fi
}

# ---------------------------------------------------------------------------
# hm_canary_judge <repo> <incoming-raw> <deployed-raw> [published-ref]
#
# The gate's own decision, re-run out of band. Requires hm_gate_classify and
# hm_gate_verdict to already be sourced.
#
# THE ONE DELIBERATE DIFFERENCE FROM LAYER 1: allow_stale is hardcoded empty,
# so `regress` + HM_ALLOW_STALE_DEPLOY=1 -- which layer 1 downgrades to
# warn:override and prints into one agent's terminal -- is judged here as
# refuse:regress and pages the fleet. An agent's deliberate override is exactly
# the case that needs an out-of-band listener. This must never be wired to the
# environment: if HM_ALLOW_STALE_DEPLOY could leak in here, the strongest leg of
# the canary would die silently.
hm_canary_judge() {
  local repo="${1-}" inc="${2-}" dep="${3-}" ref="${4-origin/main}"
  local relation
  relation="$(hm_gate_classify "$repo" "$inc" "$dep" "$ref")"
  hm_gate_verdict "$relation" ""
}

# ---------------------------------------------------------------------------
# hm_canary_alertable <verdict>
#
# Which verdicts page. Only a PROVEN regression -- the same fail-closed-on-proof
# asymmetry layer 1 uses, and for the same reason: this box has ~15 agents on
# one profile and a channel that cries wolf daily is worse than no channel.
#
# regress-unpub deliberately does NOT alert. Deploying from a PR branch is
# normal here and `gh pr merge --squash` rewrites the sha, so the dropped
# commits are genuinely unpublished. A rollback to an abandoned branch is a real
# residual of that choice and is filed rather than papered over.
hm_canary_alertable() {
  case "${1-}" in
    refuse:*) printf 'yes\n' ;;
    *)        printf 'no\n' ;;
  esac
}

# ---------------------------------------------------------------------------
# hm_canary_generation_revs <profiles-dir>
#
# The beacon of every RETAINED home-manager generation, oldest first, as
# "<mtime>\t<rev>" lines.
#
# WHY THIS EXISTS. The transition detector needs a previous value. Seeding it
# with the CURRENT beacon on first run would bless whatever is deployed at that
# moment -- so a canary first deployed (or restored after losing its state)
# during a bad switch records the bad rev as normal and is silent forever. That
# is the h0mp failure mode reproduced inside the h0mp guard. Generations carry
# their own beacons, so the seed can be a RECONSTRUCTION instead of a blessing.
#
# Depth is NOT guaranteed: users/dev/disk-cleanup.nix sets NIX_KEEP_GENERATIONS=3,
# so this is a second source of truth, not a replacement for the canary's own
# append-only history. Measured live: 5 generations, each with a distinct rev.
hm_canary_generation_revs() {
  local dir="${1-}"
  [ -d "$dir" ] || return 0
  local link b rev
  for link in "$dir"/home-manager-*-link; do
    [ -e "$link" ] || continue
    b="$link/home-files/.local/state/hm-deploy-rev"
    [ -e "$b" ] || continue
    rev="$(cat "$b" 2>/dev/null || true)"
    rev="${rev%$'\n'}"
    [ -n "$rev" ] || continue
    # `stat` without -L on purpose: the generation link's own mtime is the
    # activation time; the store target's is normalised to the epoch.
    printf '%s\t%s\n' "$(stat -c %Y "$link" 2>/dev/null || echo 0)" "$rev"
  done | sort -n -k1,1
}

# ---------------------------------------------------------------------------
# hm_canary_selftest <scratch-dir>
#
# Proves the sourced decision logic still answers a KNOWN regression correctly,
# every pass, against a throwaway repo built on the spot.
#
# WHY A DETECTOR NEEDS ITS OWN TRIPWIRE. This canary is silent by construction:
# a wedged detector and a healthy fleet look identical from outside. That is not
# hypothetical here -- the h0mp behavioural suite caught the gate silently
# ALLOWING every deploy when its library failed to source, producing an empty
# verdict that matched no case branch. The library tests could not see it,
# because everything they exercise returns a string. If hm_gate_* ever stops
# being sourceable, this returns FAIL and the caller alerts DETECTOR DEGRADED
# rather than reporting a healthy fleet.
hm_canary_selftest() {
  local dir="${1-}"
  [ -n "$dir" ] || { printf 'FAIL:no-scratch-dir\n'; return 0; }

  command -v hm_gate_classify >/dev/null 2>&1 || { printf 'FAIL:gate-not-sourced\n'; return 0; }
  command -v hm_gate_verdict  >/dev/null 2>&1 || { printf 'FAIL:verdict-not-sourced\n'; return 0; }

  local r="$dir/selftest-repo"
  rm -rf "$r" 2>/dev/null
  mkdir -p "$r" || { printf 'FAIL:mkdir\n'; return 0; }
  (
    set -e
    cd "$r"
    # The canary runs as root from a system unit, so root's git config -- and
    # anything a future NixOS module puts in /etc/gitconfig -- would otherwise
    # decide how this fixture behaves. Neutralised: the tripwire must answer the
    # same way everywhere or it is not a tripwire. (Measured: a host config made
    # `git tag` annotated and broke the equivalent fixture in test.sh.)
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
    git init -q .
    git config user.email c@example.invalid
    git config user.name canary
    echo a > f && git add f && git commit -q -m a
    git branch -f older
    echo b > f && git add f && git commit -q -m b
    # `published` must point at the NEWER commit, so the commit dropped by
    # deploying `older` is a published one and the regression is PROVABLE.
    # Pointing it at the older commit instead yields regress-unpub, and the
    # tripwire would then assert the benign case forever.
    git branch -f published
  ) >/dev/null 2>&1 || { printf 'FAIL:fixture\n'; return 0; }

  local old new v
  old="$(git -C "$r" rev-parse older 2>/dev/null)"   # the rev being deployed
  new="$(git -C "$r" rev-parse HEAD 2>/dev/null)"    # what is live now

  # Deploying the older rev over the live newer one drops a commit that IS on
  # the published ref -> a proven regression. Asserted through the SAME entry
  # point the unit uses, so a change in dispatch cannot pass here and fail in
  # production.
  v="$(hm_canary_judge "$r" "$old" "$new" "published")"
  if [ "$v" != "refuse:regress" ]; then
    printf 'FAIL:expected-refuse-got-%s\n' "${v:-<empty>}"
    return 0
  fi

  # And the benign direction must NOT alert, or the canary pages on every
  # ordinary forward deploy.
  v="$(hm_canary_judge "$r" "$new" "$old" "published")"
  if [ "$(hm_canary_alertable "$v")" != "no" ]; then
    printf 'FAIL:forward-deploy-alerts-%s\n' "$v"
    return 0
  fi

  rm -rf "$r" 2>/dev/null
  printf 'ok\n'
}
