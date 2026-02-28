# Claude Code skills deployment
# Deploys skills to ~/.claude/skills/ where Claude Code auto-discovers them
# Skills are tool-agnostic workflows usable from any project
{ config, lib, pkgs, assetsPath, isDarwin, isCloudbox, ... }:

let
  claudeAssetsPath = "${assetsPath}/claude";

  mkSkill = name: {
    ".claude/skills/${name}/SKILL.md".source =
      "${claudeAssetsPath}/skills/${name}/SKILL.md";
  };

  mkSkills = names:
    lib.foldl' (acc: name: acc // (mkSkill name)) {} names;

  # Work-only skills (macOS + cloudbox)
  workOnlySkills = [
    "fetching-atlassian-content"
  ];

  # fetching-atlassian-content has a reference file
  fetchingAtlassianReferences = {
    ".claude/skills/fetching-atlassian-content/REFERENCE.md".source =
      "${claudeAssetsPath}/skills/fetching-atlassian-content/REFERENCE.md";
  };
in
{
  home.file =
    lib.optionalAttrs (isDarwin || isCloudbox) (
      mkSkills workOnlySkills
      // fetchingAtlassianReferences
    );
}
