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
# per-unit notes before switching.
watch_re='^(goose-serve|honkd|pigeon-daemon|teamclaude|cfp-shaper|claude-failover-proxy|aigateway|codex-lb|opencode-serve@[^ ]*|opencode-serve-pool|opencode-frontdoor|tmux-main)\.(service|target)$'

flag_units() {
  # Reads switch output on stdin; echoes it, then lists watched units it names.
  local out hits
  out="$(cat)"
  printf '%s\n' "$out"
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
  sudo -n "$top/bin/switch-to-configuration" dry-activate 2>&1 \
    | grep -E '^(would |NOT restarting)' | flag_units || true
  echo "  closure delta:"
  nix store diff-closures /run/current-system "$top" | sed 's/^/    /'
else
  echo "  sudo needs a password here; run by hand:"
  echo "    sudo $top/bin/switch-to-configuration dry-activate"
fi

echo
echo "== HOME (home-manager switch --flake .#$hm_target)"
new="$(nix build --no-link --print-out-paths "$flake#homeConfigurations.$hm_target.activationPackage")"
# SWITCH_IMPACT_OLD_HM=<generation path> replays a past switch (to check this
# script against a journal you already have); unset, it is the current one.
old="$(readlink -f "${SWITCH_IMPACT_OLD_HM:-$HOME/.local/state/nix/profiles/home-manager}")"
if [ "$old" = "$new" ]; then
  echo "  identical to the current generation: a home switch changes nothing"
  exit 0
fi
sd="$(grep -oE '/nix/store/[a-z0-9]+-sd-switch-[^/ ]+/bin/sd-switch' "$new/activate" | head -1)"
units() { if [ -d "$1/home-files/.config/systemd/user" ]; then echo "$1/home-files/.config/systemd/user"; else mktemp -d; fi; }
if [ -z "$sd" ]; then
  echo "  could not find sd-switch in $new/activate; diff by hand:"
  echo "    diff -rq $(units "$old") $(units "$new")"
else
  "$sd" --dry-run --old-units "$(units "$old")" --new-units "$(units "$new")" 2>&1 | flag_units
fi
echo "  changed unit files (keep-old ones are left running; the rest restart if active):"
diff -rq "$(units "$old")" "$(units "$new")" 2>/dev/null \
  | sed -E 's#^Files .*/systemd/user/([^ ]+) and .*#\1#; s#^Only in .*/systemd/user[^:]*: #added/removed: #' \
  | while read -r u; do
      f="$(units "$new")/${u#added/removed: }"
      m="$(grep -h '^X-SwitchMethod' "$f" 2>/dev/null | head -1 || true)"
      echo "    $u ${m:-}"
    done
