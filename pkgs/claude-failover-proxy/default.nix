# claude-failover-proxy -- personal budget-gated failover proxy for opencode.
#
# Sits in front of Claude-on-Vertex and transparently fails opencode sessions
# over to a personal Claude Max backend (TeamClaude) once the daily Vertex
# spend ceiling is hit, in a cache-smart, session-sticky way. Source lives in
# the PRIVATE repo johnnymo87/claude-failover-proxy; this packages only the
# pre-built standalone bun binary attached to each GitHub release.
#
# == Private release-asset fetch (the delta vs pkgs/bb, pkgs/gws) ==
# The repo is private, so a plain fetchurl of browser_download_url 404s. We:
#   - fetch via the GitHub API asset endpoint (.../releases/assets/<id>), which
#     serves the raw bytes with `Accept: application/octet-stream`;
#   - authenticate with a token through netrc, NOT a `-H Authorization` header:
#     GitHub 302-redirects the asset to S3 and curl drops a forwarded auth
#     header on the cross-host hop, but honours netrc creds matched to
#     api.github.com only;
#   - get the token into the fetchurl sandbox via netrcImpureEnvVars, which
#     forwards $GITHUB_TOKEN from the BUILDER process's environment. On cloudbox
#     the nix-daemon carries it via systemd.services.nix-daemon EnvironmentFile
#     -> sops template "nix-daemon-github-token" wrapping the github_api_token
#     secret (see hosts/cloudbox/configuration.nix).
# pkgs.fetchurl does NOT honour nix.settings.netrc-file (builtin fetcher only),
# so netrcImpureEnvVars + netrcPhase is the mechanism. Verified empirically on
# cloudbox 2026-06-19 (positive build + negative control: empty token -> 404).
#
# THE 404 GOTCHA (root cause proven 2026-06-24, bead workstation-306j -- this
# supersedes the earlier, WRONG "bootstrap / restart the daemon" explanation):
# a FOD's impureEnvVars are read from the env of WHATEVER PROCESS performs the
# build. `dev` (non-root) can't write the store, so its builds are delegated to
# the nix-daemon -> the EnvironmentFile token applies -> fetch works. But ROOT
# OWNS the store, so `sudo nixos-rebuild` builds the FOD LOCALLY in the root
# process, whose env (sudo strips it) has NO GITHUB_TOKEN -> empty netrc
# password -> GitHub 404. The daemon's token is irrelevant to a root-local
# build. `systemctl restart nix-daemon` and `nix-store --add-fixed` do NOT fix
# this. THE FIX (in hosts/cloudbox/configuration.nix): export NIX_REMOTE=daemon
# for sudo (Defaults env_file) so root's build is routed through the daemon too,
# which makes the EnvironmentFile token apply. With that in place a plain
# `sudo nixos-rebuild switch` self-serves the private fetch -- no manual steps.
#
# == Why a wrapper instead of autoPatchelfHook ==
# bun --compile produces a single-file executable that appends the JS bundle as
# a trailer read by offset from EOF. patchelf rewrites the ELF and changes the
# file size, which CORRUPTS that trailer -> SIGSEGV at startup (verified). So we
# must NOT patchelf/strip the binary. Instead we keep it pristine in $out/libexec
# and launch it through the nix glibc dynamic linker from a tiny $out/bin wrapper.
# bun locates its bundle via argv (not /proc/self/exe), so invoking it as
# `ld.so --library-path <glibc> <binary>` works (verified).
#
# asset id is PER-RELEASE; .github/workflows/update-claude-failover-proxy.yml
# resolves tag -> asset id and bumps url + hash together.
{
  lib,
  stdenv,
  fetchurl,
  glibc,
}:

let
  version = "0.7.0";

  sources = {
    "aarch64-linux" = fetchurl {
      name = "claude-failover-proxy-${version}-linux-arm64";
      url = "https://api.github.com/repos/johnnymo87/claude-failover-proxy/releases/assets/463349511";
      hash = "sha256-K50NEn5wl9mZzWu6pt8AB26VfpmRpML2Eu4bVs11dFk=";
      # Stream the raw asset bytes rather than the JSON metadata.
      curlOptsList = [ "-H" "Accept: application/octet-stream" ];
      # Forward $GITHUB_TOKEN from the (nix-daemon) environment into the sandbox
      # and authenticate via netrc. See header comment for why not -H Authorization.
      netrcImpureEnvVars = [ "GITHUB_TOKEN" ];
      netrcPhase = ''
        echo "machine api.github.com login x-access-token password $GITHUB_TOKEN" > netrc
      '';
    };
  };

  # Launch the pristine bun binary through the nix dynamic linker. glibc covers
  # every NEEDED lib (libc/libpthread/libdl/libm); stdenv.cc.cc.lib is added
  # defensively for any runtime dlopen of libstdc++/libgcc_s.
  libPath = lib.makeLibraryPath [ glibc stdenv.cc.cc.lib ];
  interpreter = "${glibc}/lib/ld-linux-aarch64.so.1";

in

stdenv.mkDerivation {
  pname = "claude-failover-proxy";
  inherit version;

  src = sources.${stdenv.hostPlatform.system}
    or (throw "claude-failover-proxy: unsupported system ${stdenv.hostPlatform.system} (only aarch64-linux is released today)");

  # The "source" is a single binary; skip unpack.
  dontUnpack = true;

  # CRITICAL: never let the fixup phase run patchelf/strip on the bun binary --
  # it corrupts the appended bundle trailer (see header comment).
  dontFixup = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 "$src" "$out/libexec/claude-failover-proxy"
    mkdir -p "$out/bin"
    # printf (single-quoted format) keeps "$@" literal in the emitted script;
    # nix interpolates the store paths, bash expands $out to bake the absolute
    # libexec path.
    printf '#!%s\nexec %s --library-path %s "%s/libexec/claude-failover-proxy" "$@"\n' \
      "${stdenv.shell}" "${interpreter}" "${libPath}" "$out" \
      > "$out/bin/claude-failover-proxy"
    chmod +x "$out/bin/claude-failover-proxy"
    runHook postInstall
  '';

  doCheck = false;

  meta = with lib; {
    description = "Personal budget-gated failover proxy: routes opencode Claude-on-Vertex traffic to Claude Max (TeamClaude) when the daily Vertex budget is exceeded";
    homepage = "https://github.com/johnnymo87/claude-failover-proxy";
    license = licenses.mit;
    sourceProvenance = with sourceTypes; [ binaryNativeCode ];
    mainProgram = "claude-failover-proxy";
    platforms = [ "aarch64-linux" ];
  };
}
