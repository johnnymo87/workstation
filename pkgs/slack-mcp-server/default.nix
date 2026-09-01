{ lib, buildGoModule, fetchFromGitHub }:

# korotovsky/slack-mcp-server, built from source and PINNED, rather than
# fetched at runtime by `npx -y slack-mcp-server@latest`.
#
# Two reasons for the switch:
#
# 1. Upstream has no file-UPLOAD tool. Downloading works (`attachment_get_data`,
#    gated by SLACK_MCP_ATTACHMENT_TOOL),
#    but posting a file back is only implemented in PR #334, applied below.
# 2. `npx -y ...@latest` is an unpinned network fetch on every MCP start: no
#    reproducibility, no offline start, and a silent upgrade path into a server
#    that holds a Slack user token.
#
# Upgrading: bump `rev`/`hash`, re-download the PR patch, and check it still
# applies (`git apply --check`). `git apply --check` passing says NOTHING about
# what the patch now contains -- the PR branch is mutable, so diff the fresh
# download against the vendored copy and re-review whatever is new. (Or fetch
# the immutable per-commit URL: .../commit/<sha>.patch.) The vendored copy here
# was audited at PR head 9555f5901a5d3e738b836f2d1dde6675bf92d096.
# If PR #334 lands upstream, DELETE that patch rather than carrying a merged
# change twice; keep the local one until upstream restricts the download host.
buildGoModule rec {
  pname = "slack-mcp-server";
  version = "1.3.0-pr334+hostguard";

  src = fetchFromGitHub {
    owner = "korotovsky";
    repo = "slack-mcp-server";
    # master, three commits past the v1.3.0 tag (all three are docs-only:
    # `git describe` reports v1.3.0-3-gb88c0de).
    rev = "b88c0de3f706f4f07337c9eda7133c736d1c9524";
    hash = "sha256-sfKAqY47EiUnQHO30pxGr8JxlhiXtBJVFMBZ7k9a0NM=";
  };

  # Vendored, not fetchpatch'd: a GitHub PR's .patch endpoint is MUTABLE (it
  # follows the branch), so fetching it would make this build's source depend on
  # whatever the PR author pushes next. The file is in-tree so the exact diff
  # going into a binary that holds a Slack user token is reviewable here.
  # Regenerate with:
  #   curl -sL https://github.com/korotovsky/slack-mcp-server/pull/334.patch \
  #     -o pkgs/slack-mcp-server/pr-334-file-upload.patch
  patches = [
    ./pr-334-file-upload.patch
    # Ours, not upstream's. See the header comment inside it: upstream hands
    # files.info's url_private straight to slack-go, which attaches the bearer
    # token to whatever URL it is given. This restricts that to Slack hosts.
    ./local-restrict-download-host.patch
  ];

  vendorHash = "sha256-+uQRODO9oL8mGKBmdghTxE6R9Fz+3GJFVTi17306gT8=";

  subPackages = [ "cmd/slack-mcp-server" ];

  # subPackages narrows the BUILD to the one binary -- and, less obviously, the
  # default checkPhase along with it, to a package that has no tests at all
  # ("[no test files]"). Left alone, the guard's unit test below would be dead
  # weight that never runs. Point the check at the packages the patches touch.
  checkPhase = ''
    runHook preCheck
    # -run '^TestUnit': upstream's TestIntegration* tests need a live workspace
    # (SLACK_MCP_XOXP_TOKEN, an OpenAI key, network), none of which exist in the
    # sandbox and none of which should. The unit tests are the ones that can
    # actually falsify a patch.
    go test -run '^TestUnit' ./pkg/handler/... ./pkg/server/...
    runHook postCheck
  '';

  ldflags = [ "-s" "-w" ];

  meta = {
    description = "Slack MCP server (pinned build, with PR #334 file_upload)";
    homepage = "https://github.com/korotovsky/slack-mcp-server";
    license = lib.licenses.mit;
    mainProgram = "slack-mcp-server";
  };
}
