#!/usr/bin/env bash
# switch-impact.sh -- predict which units a switch would stop, start, restart or
# reload on THIS host, without switching. Read-only apart from building the new
# generations (into the store; no result symlinks) and the activation dry runs.
#
# Usage: switch-impact.sh [FLAKE_DIR]        (default: current directory)
#
# Build from a checkout of exactly what you are about to deploy (normally a
# throwaway worktree at origin/main). The answer is a diff against what is
# running NOW, so it goes stale the moment anyone else switches.
#
# NixOS hosts (devbox, cloudbox):
#   system: sudo -n <toplevel>/bin/switch-to-configuration dry-activate
#   home:   the new generation's own sd-switch --dry-run, old units = the current
#           home-manager generation (or $SWITCH_IMPACT_OLD_HM), new units = the
#           one just built
# macOS: not supported (launchd, no sd-switch). See SKILL.md.
set -euo pipefail

flake="${1:-.}"
host="$(hostname)"

case "$host" in
  devbox)   hm_target=dev ;;
  cloudbox) hm_target=cloudbox ;;
  *)
    echo "switch-impact: host '$host' is not a NixOS host this script knows (devbox, cloudbox)." >&2
    echo "On macOS, see the 'macOS' section of SKILL.md." >&2
    exit 2
    ;;
esac


# Units whose bounce reaches live agent turns or a human. A hit is not
# necessarily a reason to stop, but it is a reason to read SKILL.md's
# per-unit notes before switching. Slices are here because keep-old protects a
# slice only while it exists in both generations: one added, removed or renamed
# is stopped, and stopping it kills every command running in it.
watch_re='^(goose-serve|honkd|pigeon-daemon|teamclaude|cfp-shaper|claude-failover-proxy|aigateway|codex-lb|opencode-serve@[^ ]*|opencode-serve-pool|opencode-frontdoor|tmux-main)\.(service|target)$|^(goose-agent|oc-agent|bazel|lgtm-review)[^ ]*\.slice$'

# Exit status: 0 = every prediction below was obtained; 1 = at least one step
# could not predict (its section says UNKNOWN). Never read "no watched unit"
# from a run that exited 1.
status=0
empty="$(mktemp -d)"
trap 'rmdir "$empty" 2>/dev/null || true' EXIT

flag_units() {
  # $1 = switch output. Echoes it, then lists watched units it names.
  local out="$1" hits
  printf '%s\n' "$out" | sed 's/^/  /'
  hits="$(grep -E '^(would |Stopping|Starting|Restarting|Reloading|NOT restarting)' <<<"$out" \
          | sed -E 's/^[^:]*: //' | tr ',' '\n' | sed -E 's/^ +| +$//g' \
          | grep -E "$watch_re" | sort -u || true)"
  if [ -n "$hits" ]; then
    echo "  >> WATCHED units named above: $(tr '\n' ' ' <<<"$hits")"
  else
    echo "  >> no watched unit named"
  fi
}

echo "== host: $host   flake: $flake   rev: $(git -C "$flake" rev-parse --short HEAD 2>/dev/null || echo '?')"

echo
echo "== SYSTEM (nixos-rebuild switch --flake .#$host)"
top="$(nix build --no-link --print-out-paths "$flake#nixosConfigurations.$host.config.system.build.toplevel")"
if [ "$(readlink -f /run/current-system)" = "$top" ]; then
  echo "  identical to /run/current-system: a system switch changes nothing"
elif sudo -n true 2>/dev/null; then
  rc=0
  out="$(sudo -n "$top/bin/switch-to-configuration" dry-activate 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$out" | sed 's/^/  /'
    echo "  >> DRY-ACTIVATE FAILED (exit $rc): system prediction UNKNOWN"
    status=1
  else
    flag_units "$(grep -E '^(would |NOT restarting)' <<<"$out" || true)"
  fi
  echo "  closure delta:"
  nix store diff-closures /run/current-system "$top" | sed 's/^/    /'
else
  echo "  >> sudo needs a password here: system prediction UNKNOWN. Run by hand:"
  echo "    sudo $top/bin/switch-to-configuration dry-activate"
  status=1
fi

echo
echo "== HOME (home-manager switch --flake .#$hm_target)"
new="$(nix build --no-link --print-out-paths "$flake#homeConfigurations.$hm_target.activationPackage")"
# SWITCH_IMPACT_OLD_HM=<generation path> replays the switch from that
# generation instead of the current one. sd-switch also reads LIVE unit state,
# so a replay is only faithful for a recent, adjacent generation.
old="$(readlink -f "${SWITCH_IMPACT_OLD_HM:-$HOME/.local/state/nix/profiles/home-manager}" || true)"
if [ -z "$old" ] || [ ! -d "$old" ]; then
  echo "  >> no current home-manager generation found: home prediction UNKNOWN"
  exit 1
fi
if [ "$old" = "$new" ]; then
  echo "  identical to the current generation: a home switch changes nothing"
  exit "$status"
fi
units() { if [ -d "$1/home-files/.config/systemd/user" ]; then echo "$1/home-files/.config/systemd/user"; else echo "$empty"; fi; }
old_u="$(units "$old")"; new_u="$(units "$new")"
sd="$(grep -oE '/nix/store/[a-z0-9]+-sd-switch-[^/ ]+/bin/sd-switch' "$new/activate" | head -1 || true)"
if [ -z "$sd" ]; then
  echo "  >> sd-switch not found in $new/activate: home prediction UNKNOWN"
  status=1
else
  rc=0
  out="$("$sd" --dry-run --old-units "$old_u" --new-units "$new_u" 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$out" | sed 's/^/  /'
    echo "  >> SD-SWITCH DRY RUN FAILED (exit $rc): home prediction UNKNOWN"
    status=1
  else
    flag_units "$out"
  fi
fi

echo "  changed unit files (keep-old ones are left running; others restart if active):"
names() { find "$1" -maxdepth 1 \( -type f -o -type l \) -printf '%f\n' | sort; }
while read -r u; do
  if [ ! -e "$new_u/$u" ]; then
    echo "    removed: $u (stopped if running)"
  elif [ ! -e "$old_u/$u" ]; then
    echo "    added:   $u"
  elif ! cmp -s "$old_u/$u" "$new_u/$u"; then
    m="$(grep -h '^X-SwitchMethod' "$new_u/$u" | head -1 || true)"
    echo "    changed: $u ${m:-}"
  fi
done < <(sort -u <(names "$old_u") <(names "$new_u"))
exit "$status"
