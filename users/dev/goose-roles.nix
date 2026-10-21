# goose subagent roles (cloudbox): one DIRECTORY symlink, never per-file -- goose
# reads recipe files with O_NOFOLLOW and silently skips symlinked ones.
# Consumed via ~/.config/goose/config.yaml (enforced on switch by goose-config-enforce
# via gooseConfigSettings in users/dev/home.cloudbox.nix):
#   GOOSE_SUBAGENT_ROLES_DIR: /home/dev/.config/goose/subagent-roles/roles
#   GOOSE_SUBAGENT_DEFAULT_RECIPE: /home/dev/.config/goose/subagent-roles/unscoped.yaml
# Requires goose >= patched-1.54.0.10. Design: docs/plans/2026-10-20-goose-subagent-roles-design.md
{ lib, localPkgs, isCloudbox, ... }:

lib.mkIf isCloudbox {
  home.file.".config/goose/subagent-roles".source = localPkgs.goose-roles;
}
