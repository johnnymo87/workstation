# Claude Code skills deployment
# Centralizes all skill file deployments with platform-conditional logic
{ lib, pkgs, assetsPath, ... }:

let
  isDarwin = pkgs.stdenv.isDarwin;

  # Helper to create home.file entry for a skill
  mkSkill = name: {
    ".claude/skills/${name}/SKILL.md".source =
      "${assetsPath}/claude/skills/${name}/SKILL.md";
  };

  # Helper to create entries for multiple skills
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
    ".claude/skills/notify-telegram/register.sh" = {
      source = "${assetsPath}/claude/skills/notify-telegram/register.sh";
      executable = true;
    };
  };

  # Skills deployed only on Darwin (work machine)
  darwinOnlySkills = [
    "slack-mcp-setup"
    "using-gcloud-bq-cli"
  ];

  # Skills with additional reference files need explicit entries
  beadsReferences = {
    ".claude/skills/beads/references/BOUNDARIES.md".source =
      "${assetsPath}/claude/skills/beads/references/BOUNDARIES.md";
    ".claude/skills/beads/references/CLI_REFERENCE.md".source =
      "${assetsPath}/claude/skills/beads/references/CLI_REFERENCE.md";
    ".claude/skills/beads/references/DEPENDENCIES.md".source =
      "${assetsPath}/claude/skills/beads/references/DEPENDENCIES.md";
    ".claude/skills/beads/references/WORKFLOWS.md".source =
      "${assetsPath}/claude/skills/beads/references/WORKFLOWS.md";
  };
in
{
  home.file =
    mkSkills crossPlatformSkills
    // lib.optionalAttrs isDarwin (mkSkills darwinOnlySkills)
    // beadsReferences
    // notifyTelegramScript;
}
