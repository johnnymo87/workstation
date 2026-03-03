# OpenCode system-wide skills deployment
# Deploys skills to ~/.config/opencode/skills/ where OpenCode auto-discovers them
# Skills are tool-agnostic workflows usable from any project
{ config, lib, pkgs, assetsPath, isDarwin, isCloudbox, ... }:

let
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

  # Work-only skills (macOS + cloudbox)
  workOnlySkills = [
    "cleaning-bazel-monorepo-disk"
    "slack-mcp-setup"
    "using-atlassian-cli"
    "using-gcloud-bq-cli"
    "working-with-kubernetes"
  ];

  # notify-telegram has a script that needs to be executable
  notifyTelegramScript = {
    ".config/opencode/skills/notify-telegram/register.sh" = {
      source = "${assetsPath}/opencode/skills/notify-telegram/register.sh";
      executable = true;
    };
  };

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

  # using-atlassian-cli has a reference file
  atlassianReferences = {
    ".config/opencode/skills/using-atlassian-cli/REFERENCE.md".source =
      "${assetsPath}/opencode/skills/using-atlassian-cli/REFERENCE.md";
  };

  # fetching-atlassian-content lives in claude assets (shared with claude-skills.nix)
  fetchingAtlassianSkill = {
    ".config/opencode/skills/fetching-atlassian-content/SKILL.md".source =
      "${assetsPath}/claude/skills/fetching-atlassian-content/SKILL.md";
    ".config/opencode/skills/fetching-atlassian-content/REFERENCE.md".source =
      "${assetsPath}/claude/skills/fetching-atlassian-content/REFERENCE.md";
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

  # Confluence-fetched skill files: content too sensitive for source control.
  # Pages are maintained in Confluence and fetched during home-manager activation
  # via nvim --headless + FetchConfluencePage.
  #
  # Each entry fetches a Confluence page into an existing skill directory.
  # This lets sensitive companion files live alongside generic public skills.
  #
  # To add a new Confluence-fetched file:
  #   1. Create the Confluence page with the content in markdown
  #   2. Add an entry: { pageId = "1234567890"; skillName = "my-skill"; fileName = "INTERNAL.md"; }
  #   3. The activation script writes to ~/.config/opencode/skills/<skillName>/<fileName>
  #   4. The public SKILL.md can reference the companion file
  confluenceSkills = [
    # Add entries as pages are created:
    { pageId = "4909269028"; skillName = "working-with-kubernetes"; fileName = "INTERNAL.md"; }
  ];

  # Activation script: fetch Confluence pages into skill directories
  fetchConfluenceSkillsScript = let
    fetchCommands = lib.concatMapStringsSep "\n" (s: ''
      fetch_skill "${s.pageId}" "${s.skillName}" "${s.fileName}"
    '') confluenceSkills;
  in lib.optionalString (confluenceSkills != []) ''
    fetch_skill() {
      local page_id="$1"
      local skill_name="$2"
      local file_name="$3"
      local skill_dir="${config.home.homeDirectory}/.config/opencode/skills/$skill_name"
      local skill_file="$skill_dir/$file_name"

      mkdir -p "$skill_dir"

      # Skip if all required env vars aren't set
      if [ -z "''${ATLASSIAN_SITE:-}" ] || [ -z "''${ATLASSIAN_EMAIL:-}" ] || \
         [ -z "''${ATLASSIAN_API_TOKEN:-}" ] || [ -z "''${ATLASSIAN_CLOUD_ID:-}" ]; then
        echo "fetchConfluenceSkills: skipping $skill_name/$file_name (Atlassian env vars not set)"
        return 0
      fi

      echo "fetchConfluenceSkills: fetching $skill_name/$file_name (page $page_id)..."
      if ${pkgs.neovim}/bin/nvim --headless "$skill_file" \
           -c "FetchConfluencePage $page_id" -c "write" -c "quit" 2>/dev/null; then
        echo "fetchConfluenceSkills: $skill_name/$file_name updated"
      else
        echo "fetchConfluenceSkills: WARNING: failed to fetch $skill_name/$file_name"
      fi
    }

    ${fetchCommands}
  '';
in
{
  home.file =
    mkSkills crossPlatformSkills
    // beadsReferences
    // notifyTelegramScript
    // superpowersSkills
    // lib.optionalAttrs (isDarwin || isCloudbox) (
      mkSkills workOnlySkills
      // atlassianReferences
      // fetchingAtlassianSkill
    );

  # Fetch Confluence-based skills during activation (macOS + cloudbox only)
  home.activation.fetchConfluenceSkills = lib.mkIf
    ((isDarwin || isCloudbox) && confluenceSkills != [])
    (lib.hm.dag.entryAfter ["writeBoundary"] fetchConfluenceSkillsScript);
}
