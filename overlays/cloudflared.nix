# cloudflared >= 2026.10.2, required by Cloudflare's eMudhra (emSign)
# certificate-compromise advisory (blog.cloudflare.com/emudhra-certificate-compromise,
# 2026-10-20): earlier versions still trust eight compromised intermediates.
# On macOS, a non-Homebrew install needs >= 2026.10.3.
#
# Why an override and not just a newer channel: as of 2026-10-26 no nixpkgs
# branch ships >= 2026.10.2. nixos-25.11 (our `nixpkgs`) is EOL at 2025.11.1;
# nixos-unstable and master are at 2026.10.1, with the bump still open as
# NixOS/nixpkgs#576762.
#
# Why the separate `nixpkgs-cloudflared` input: the fix in 2026.10.2 is a Go
# toolchain bump ("Bump go to 1.27.3"), and 2026.10.3+ declares `go 1.27.3` in
# go.mod, so the binary must be built with Go >= 1.27.3. Stable has Go 1.25;
# the existing `nixpkgs-unstable` lock has 1.27.1 and also feeds gamebox's
# Sunshine and devbox's github-runner, which this should not move. The
# dedicated input is locked to a nixos-unstable revision whose go_1_27 is
# 1.27.3, and is used for nothing else.
#
# The override retires itself: once `nix flake update nixpkgs-cloudflared`
# brings a recipe at or past `minVersion`, that recipe is used as-is, so this
# can never pin cloudflared BELOW what the input ships. Drop the overlay and
# the input once the channel `nixpkgs` follows ships cloudflared >= minVersion.
{ nixpkgs-cloudflared }:
final: prev:
let
  pinned = nixpkgs-cloudflared.legacyPackages.${prev.stdenv.hostPlatform.system};
  minVersion = "2026.10.4";
in
{
  cloudflared =
    if prev.lib.versionAtLeast pinned.cloudflared.version minVersion
    then pinned.cloudflared
    else pinned.cloudflared.overrideAttrs (finalAttrs: old: {
      version = minVersion;
      src = prev.fetchFromGitHub {
        owner = "cloudflare";
        repo = "cloudflared";
        tag = finalAttrs.version;
        hash = "sha256-HuKjytbGutwjUMepozeUmeeHczm4qI7vMvS+hgLsaZ0=";
      };
      vendorHash = "sha256-WtGk5HE6PxAWqwvj8mAAzobuoSw+y6BqBEEB0hRQafk=";
    });
}
