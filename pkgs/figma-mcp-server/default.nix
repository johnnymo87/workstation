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

# GLips/Figma-Context-MCP ("Framelink", npm `figma-developer-mcp`), built from a
# pinned source tag with its pnpm lockfile, rather than `npx -y` at MCP start.
#
# Why this server and not Figma's own:
#   - Figma's REMOTE MCP (https://mcp.figma.com/mcp) is OAuth-only and admits
#     only clients in Figma's MCP Catalog: dynamic client registration at
#     https://api.figma.com/v1/oauth/mcp/register returns 403 for OpenCode, and
#     a personal access token is rejected with 401. Measured 2026-10-12.
#   - Figma's DESKTOP MCP (http://127.0.0.1:3845/mcp) is served by the Figma
#     desktop app, so it cannot run on a headless host (cloudbox).
#   Framelink talks to the public REST API with a personal access token, runs
#   headless over stdio, and has exactly two tools, both reads:
#   `get_figma_data` and `download_figma_images` (renders nodes to PNG/SVG on
#   local disk). The only Figma scope it needs is `file_content:read`.
#
# Why built, not `npx -y figma-developer-mcp@<ver>`:
#   npx pins the top-level package only; its ~16 deps are caret ranges resolved
#   at every cold start. This process holds a Figma token that can read every
#   file its owner can, so the whole closure is pinned here by the lockfile.
#
# Hardening is split between this wrapper and the opencode.json entry
# (users/dev/opencode-config.nix, `figmaMcpEntry`):
#   - telemetry: upstream sends usage events to PostHog BY DEFAULT. The wrapper
#     forces it off with env vars, so every invocation (MCP or `fetch` CLI) is
#     covered, not just the one opencode makes.
#   - `.env`: upstream loads `<cwd>/.env` with override=true, which would let a
#     checkout's .env replace FIGMA_API_KEY / FIGMA_PROXY / IMAGE_DIR. The MCP
#     entry passes `--env /dev/null` to defeat that.
#
# Bumping: change `version` + `hash`, then set `pnpmDeps.hash` to lib.fakeHash,
# build, and copy the hash nix reports. Re-read upstream's CHANGELOG for new
# tools: anything that writes to Figma breaks this server's read-only premise.
stdenv.mkDerivation (finalAttrs: {
  pname = "figma-mcp-server";
  version = "0.13.2";

  src = fetchFromGitHub {
    owner = "GLips";
    repo = "Figma-Context-MCP";
    rev = "v${finalAttrs.version}";
    hash = "sha256-Deh3Mrqrm0k5WjjUd3KEECLb6qRALq1VRcQ7YQbfO0k=";
  };

  pnpmDeps = fetchPnpmDeps {
    inherit (finalAttrs) pname version src;
    pnpm = pnpm_10;
    fetcherVersion = 2;
    hash = "sha256-uOizv5dT2fk+cX4jerm4EMkYhasX0bDzuVjVSVN6R+A=";
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

  # Drop devDependencies (tsup, vitest, eslint, ...) from the runtime closure.
  preInstall = ''
    pnpm prune --prod --ignore-scripts
  '';

  # Under libexec/<pname>/, not lib/node_modules: home-manager merges every
  # package into one buildEnv, and a transitive dep here could otherwise collide
  # with another package's lib/node_modules/<dep> (see pkgs/dvc).
  installPhase = ''
    runHook preInstall

    dest=$out/libexec/${finalAttrs.pname}
    mkdir -p "$dest"
    cp -r dist node_modules package.json "$dest/"

    makeWrapper ${lib.getExe nodejs} $out/bin/figma-mcp-server \
      --add-flags "$dest/dist/bin.js" \
      --set FRAMELINK_TELEMETRY off \
      --set DO_NOT_TRACK 1

    runHook postInstall
  '';

  meta = {
    description = "Framelink Figma MCP server (read-only Figma design context for agents)";
    homepage = "https://github.com/GLips/Figma-Context-MCP";
    license = lib.licenses.mit;
    mainProgram = "figma-mcp-server";
    platforms = lib.platforms.unix;
  };
})
