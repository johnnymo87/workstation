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
# Upgrading: bump `rev`/`hash`, re-download the patch, and check it still applies
# (`git apply --check`) -- if PR #334 lands upstream, DELETE the patch and the
# fetchpatch input rather than carrying a merged change twice.
buildGoModule rec {
  pname = "slack-mcp-server";
  version = "1.3.0-pr334";

  src = fetchFromGitHub {
    owner = "korotovsky";
    repo = "slack-mcp-server";
    # master @ 2026-08-xx, one commit past the v1.3.0 tag.
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
  patches = [ ./pr-334-file-upload.patch ];

  vendorHash = "sha256-+uQRODO9oL8mGKBmdghTxE6R9Fz+3GJFVTi17306gT8=";

  subPackages = [ "cmd/slack-mcp-server" ];

  ldflags = [ "-s" "-w" ];

  meta = {
    description = "Slack MCP server (pinned build, with PR #334 file_upload)";
    homepage = "https://github.com/korotovsky/slack-mcp-server";
    license = lib.licenses.mit;
    mainProgram = "slack-mcp-server";
  };
}
