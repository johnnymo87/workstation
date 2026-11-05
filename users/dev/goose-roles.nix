# goose subagent roles: one DIRECTORY symlink, never per-file -- goose
# reads recipe files with O_NOFOLLOW and silently skips symlinked ones.
# Consumed via ~/.config/goose/config.yaml (enforced on switch by goose-config-enforce
# via gooseConfigSettings in users/dev/goose-config.nix):
#   GOOSE_SUBAGENT_ROLES_DIR: /home/dev/.config/goose/subagent-roles/roles
#   GOOSE_SUBAGENT_DEFAULT_RECIPE: /home/dev/.config/goose/subagent-roles/unscoped.yaml
# Requires goose >= patched-1.54.0.10. Design: docs/plans/2026-10-20-goose-subagent-roles-design.md
{ lib, localPkgs, isCloudbox, isDevbox, ... }:

#
# PROVIDER IS PER HOST. A role's settings.goose_provider outranks every other
# provider source and has no fallback, so a role pinned to a provider the host
# cannot reach makes every delegate(source: <role>) fail. cloudbox resolves
# Claude through Vertex (gcp_vertex_ai, the package default); devbox has no
# Vertex and runs goose-serve on anthropic (cfp-shaper -> TeamClaude), so it
# gets the anthropic build. Asserted by the goose-roles-tests flake check.
lib.mkIf (isCloudbox || isDevbox) {
  home.file.".config/goose/subagent-roles".source =
    if isDevbox
    then localPkgs.goose-roles.override { provider = "anthropic"; }
    else localPkgs.goose-roles;
}
