# OpenCode system-wide skills deployment
# Deploys skills to ~/.config/opencode/skills/ where OpenCode auto-discovers them
# Skills are tool-agnostic workflows usable from any project
{ config, lib, pkgs, assetsPath, ... }:

let
  isDarwin = pkgs.stdenv.isDarwin;

  mkSkill = name: {
    ".config/opencode/skills/${name}/SKILL.md".source =
      "${assetsPath}/opencode/skills/${name}/SKILL.md";
  };

  mkSkills = names:
    lib.foldl' (acc: name: acc // (mkSkill name)) {} names;

  # Skills deployed to all platforms
  crossPlatformSkills = [
    "ask-question"
    "beads"
    "consult-chatgpt"
    "notify-telegram"
    "using-chatgpt-relay-from-devbox"
  ];

  # notify-telegram has a script that needs to be executable
  notifyTelegramScript = {
    ".config/opencode/skills/notify-telegram/register.sh" = {
      source = "${assetsPath}/opencode/skills/notify-telegram/register.sh";
      executable = true;
    };
  };

  # Skills deployed only on Darwin (work machine)
  darwinOnlySkills = [
    "slack-mcp-setup"
    "using-gcloud-bq-cli"
  ];

  # beads has additional reference files
  beadsReferences = {
    ".config/opencode/skills/beads/references/BOUNDARIES.md".source =
      "${assetsPath}/opencode/skills/beads/references/BOUNDARIES.md";
    ".config/opencode/skills/beads/references/CLI_REFERENCE.md".source =
      "${assetsPath}/opencode/skills/beads/references/CLI_REFERENCE.md";
    ".config/opencode/skills/beads/references/DEPENDENCIES.md".source =
      "${assetsPath}/opencode/skills/beads/references/DEPENDENCIES.md";
    ".config/opencode/skills/beads/references/WORKFLOWS.md".source =
      "${assetsPath}/opencode/skills/beads/references/WORKFLOWS.md";
  };

  # Superpowers skills: symlink the entire upstream skills directory
  # Uses out-of-store symlink since the repo is cloned via projects.nix, not in the Nix store
  superpowersSkills = {
    ".config/opencode/skills/superpowers".source =
      config.lib.file.mkOutOfStoreSymlink (
        if isDarwin
        then "${config.home.homeDirectory}/Code/superpowers/skills"
        else "${config.home.homeDirectory}/projects/superpowers/skills"
      );
  };
in
{
  home.file =
    mkSkills crossPlatformSkills
    // lib.optionalAttrs isDarwin (mkSkills darwinOnlySkills)
    // beadsReferences
    // notifyTelegramScript
    // superpowersSkills;
}
