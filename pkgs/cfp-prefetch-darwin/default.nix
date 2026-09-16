# cfp-prefetch-darwin -- place the private claude-failover-proxy release asset
# into the Nix store BEFORE a darwin-rebuild tries to fetch it.
#
# == Why this exists ==
# pkgs/claude-failover-proxy fetches a binary from a PRIVATE GitHub repo. On
# cloudbox that works unattended: the nix-daemon carries a GITHUB_TOKEN via a
# sops EnvironmentFile, and the fetchurl forwards it through
# `netrcImpureEnvVars`. On this Mac nothing supplies such a token --
#
#   - the nix-daemon LaunchDaemon plist has no environment, and putting a PAT
#     there would make it world-readable;
#   - `sudo` strips the user's environment, so `sudo darwin-rebuild` cannot
#     carry one in either;
#   - `nix build --option impure-env GITHUB_TOKEN=...` needs the
#     `configurable-impure-env` experimental feature, which is not enabled here;
#   - `pkgs.fetchurl` ignores `nix.settings.netrc-file` (that setting only
#     reaches Nix's own builtin fetchers).
#
# -- and an un-fetchable source fails the WHOLE system build, not just cfp. So
# without this helper, every `darwin-rebuild switch` on this Mac dies the moment
# the daily auto-bump PR lands a new cfp version.
#
# == Why pre-seeding is sound rather than a hack ==
# A fixed-output derivation's output path is a function of its `name` and its
# `outputHash` ALONE. Not the URL, not the system, not how the bytes arrived.
# So placing identical bytes under the identical name yields the identical store
# path, Nix sees the path as already valid, and the FOD is never run. The hash
# is still enforced -- `nix store add` recomputes it, and we compare the
# resulting path against the one the flake expects before declaring success.
#
# == Usage ==
#   cfp-prefetch-darwin            # idempotent; no-op when already seeded
#   cfp-prefetch-darwin --flake ~/Code/workstation
#
# Run it before `darwin-rebuild switch`. It is a no-op on a host whose daemon
# can fetch the asset itself, and on any non-darwin system it exits 0 without
# doing anything.
{
  lib,
  writeShellApplication,
  gh,
  coreutils,
}:

writeShellApplication {
  name = "cfp-prefetch-darwin";

  runtimeInputs = [ gh coreutils ];

  text = ''
    flake="''${HOME}/Code/workstation"

    while [ $# -gt 0 ]; do
      case "$1" in
        --flake) flake="$2"; shift 2 ;;
        -h|--help)
          echo "usage: cfp-prefetch-darwin [--flake DIR]"
          echo
          echo "Seeds the private claude-failover-proxy release asset into the"
          echo "Nix store so that darwin-rebuild does not have to fetch it."
          exit 0 ;;
        *) echo "cfp-prefetch-darwin: unknown argument: $1" >&2; exit 2 ;;
      esac
    done

    if [ "$(uname -s)" != "Darwin" ]; then
      echo "cfp-prefetch-darwin: not darwin, nothing to do"
      exit 0
    fi

    # `nix` is deliberately taken from PATH rather than pinned: pinning a nix
    # from nixpkgs into a helper that talks to the LOCAL daemon invites a
    # client/daemon protocol mismatch.
    if ! command -v nix >/dev/null 2>&1; then
      echo "cfp-prefetch-darwin: nix not on PATH" >&2
      exit 1
    fi

    # Ask the FLAKE what it wants, so this helper can never drift from the
    # package definition the way a hardcoded asset id would.
    eval_attr() {
      nix eval --raw "$flake#claude-failover-proxy.src.$1"
    }

    want_path="$(eval_attr outPath)"
    want_name="$(eval_attr name)"
    want_hash="$(eval_attr outputHash)"
    url="$(eval_attr url)"

    if nix path-info "$want_path" >/dev/null 2>&1; then
      echo "cfp-prefetch-darwin: already seeded: $want_path"
      exit 0
    fi

    token="$(/usr/bin/security find-generic-password -s github-api-token -w 2>/dev/null || true)"
    if [ -z "$token" ]; then
      echo "cfp-prefetch-darwin: no 'github-api-token' in the login Keychain." >&2
      echo "  Add one with contents:read on johnnymo87/claude-failover-proxy:" >&2
      echo "    security add-generic-password -s github-api-token -a \"\$USER\" -w" >&2
      exit 1
    fi

    tmp="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp'" EXIT

    echo "cfp-prefetch-darwin: fetching $want_name"
    # The GitHub API asset endpoint serves the raw bytes with this Accept
    # header; without it you get JSON metadata that hashes to the wrong thing.
    if ! GH_TOKEN="$token" gh api "$url" \
        -H "Accept: application/octet-stream" \
        > "$tmp/$want_name"; then
      echo "cfp-prefetch-darwin: download failed (is the token's scope right?)" >&2
      exit 1
    fi

    got_hash="$(nix hash file --type sha256 --sri "$tmp/$want_name")"
    if [ "$got_hash" != "$want_hash" ]; then
      echo "cfp-prefetch-darwin: hash mismatch for $want_name" >&2
      echo "  flake expects: $want_hash" >&2
      echo "  downloaded:    $got_hash" >&2
      echo "This means the release asset was replaced, or default.nix is stale." >&2
      exit 1
    fi

    got_path="$(nix store add --mode flat --name "$want_name" "$tmp/$want_name")"
    if [ "$got_path" != "$want_path" ]; then
      # Should be unreachable: identical name + identical content must produce
      # the identical path. Fail loudly rather than leave a rebuild to discover
      # that the seed did not land where the build will look.
      echo "cfp-prefetch-darwin: seeded the wrong path" >&2
      echo "  expected: $want_path" >&2
      echo "  got:      $got_path" >&2
      exit 1
    fi

    echo "cfp-prefetch-darwin: seeded $got_path"
  '';

  meta = with lib; {
    description = "Seed the private claude-failover-proxy release asset into the Nix store on macOS";
    platforms = platforms.darwin;
    mainProgram = "cfp-prefetch-darwin";
  };
}
