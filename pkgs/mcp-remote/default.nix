{
  lib,
  stdenv,
  fetchFromGitHub,
  fetchPnpmDeps,
  pnpmConfigHook,
  pnpm_10,
  nodejs,
  makeWrapper,
}:

# geelen/mcp-remote: a stdio MCP server that proxies to a remote (streamable
# HTTP / SSE) MCP server, adding --header values and an OAuth login whose
# tokens it keeps in ~/.mcp-auth/ (0600) and refreshes itself.
#
# honkd runs it (`honkd --mcp-remote-bin`) to give goose sessions the remote
# servers in opencode.json that goose cannot take directly: datadog (a Bearer
# {file:} header; honkd hands the secret over in an env var that mcp-remote
# substitutes into `--header 'Authorization:Bearer ${HONK_MCP_HDR_0}'`) and
# notion (OAuth). See honk's docs/chat.md, "Remote servers with headers or
# OAuth".
#
# Why built, not `npx -y mcp-remote@<ver>` (the atlassian wrapper's way):
#   - npx runs as TWO processes, `npm exec` and a node child. goose stops an
#     extension by killing the pid it spawned, so the node child survives. While
#     mcp-remote waits for an OAuth browser callback it reads no stdin and has
#     no timeout, so each failed enable left a node process holding the callback
#     port and the login lock forever (reproduced 2026-11-24). Here the wrapper
#     execs node: one process.
#   - npx pins only the top-level package; its deps are caret ranges resolved at
#     cold start. This process holds a Datadog PAT, so the closure is pinned by
#     the lockfile.
#
# The token-store directory is named after package.json's version
# (~/.mcp-auth/mcp-remote-<version>/), so a bump starts with no logins: every
# OAuth server (notion) needs its one-time login again. Run
# `mcp-remote <url>` in a terminal on the host, forward the callback port it
# prints (`ssh -L <port>:localhost:<port> <host>`), open the printed URL.
#
# Bumping: change `version` + `hash`, then set both `pnpmDeps.hash` values to
# lib.fakeHash, build on Linux and on the Mac, and copy each hash nix reports.
stdenv.mkDerivation (finalAttrs: {
  pname = "mcp-remote";
  version = "0.1.38";

  src = fetchFromGitHub {
    owner = "geelen";
    repo = "mcp-remote";
    rev = "v${finalAttrs.version}";
    hash = "sha256-+oNI2Uq7gW3sLzJS4ky2+BXhTmo44+WpcdYgieGPpmI=";
  };

  pnpmDeps = fetchPnpmDeps {
    inherit (finalAttrs) pname version src;
    pnpm = pnpm_10;
    fetcherVersion = 2;
    # Per platform: pnpm fetches only the optional native packages (esbuild,
    # rollup, ...) for the host's os/cpu, so the store differs on darwin. The
    # Linux hash was measured on cloudbox (aarch64-linux), the darwin one on
    # the Mac (aarch64-darwin) on 2026-11-25. When bumping, measure both.
    hash =
      if stdenv.hostPlatform.isDarwin then
        "sha256-dVMHSxCWrWyKZnAteOALH2G76qI1FTnGOTwMULwGh4c="
      else
        "sha256-ULwS0Z9+r7Si3e8/ZGbv9OVgKEnok3xIJ9EEaDYcCBs=";
  };

  nativeBuildInputs = [
    nodejs
    pnpmConfigHook
    pnpm_10
    makeWrapper
  ];

  buildPhase = ''
    runHook preBuild
    pnpm build
    runHook postBuild
  '';

  # Drop devDependencies (tsup, vitest, prettier, ...) from the runtime closure.
  preInstall = ''
    pnpm prune --prod --ignore-scripts
  '';

  # Under libexec/<pname>/, not lib/node_modules (see pkgs/figma-mcp-server).
  # makeWrapper's script ends in `exec node ...`, so the server is one process.
  installPhase = ''
    runHook preInstall

    dest=$out/libexec/${finalAttrs.pname}
    mkdir -p "$dest"
    cp -r dist node_modules package.json "$dest/"

    makeWrapper ${lib.getExe nodejs} $out/bin/mcp-remote \
      --add-flags "$dest/dist/proxy.js"

    runHook postInstall
  '';

  meta = {
    description = "Stdio MCP proxy to remote MCP servers, with headers and OAuth";
    homepage = "https://github.com/geelen/mcp-remote";
    license = lib.licenses.mit;
    mainProgram = "mcp-remote";
    platforms = lib.platforms.unix;
  };
})
