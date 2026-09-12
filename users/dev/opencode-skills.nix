# OpenCode system-wide skills deployment
# Deploys skills to ~/.config/opencode/skills/ where OpenCode auto-discovers them
# Skills are tool-agnostic workflows usable from any project
{ config, lib, pkgs, localPkgs, assetsPath, isDarwin, isCloudbox, ... }:

let
  mkSkill = name: {
    ".config/opencode/skills/${name}/SKILL.md".source =
      "${assetsPath}/opencode/skills/${name}/SKILL.md";
  };

  mkSkills = names:
    lib.foldl' (acc: name: acc // (mkSkill name)) {} names;

  # Skills deployed to all platforms
  crossPlatformSkills = [
    "adding-opencode-skills"
    "ask-question"
    "attributing-causes"
    "beads"
    "formatting-slack-messages"
    "migrating-beads-schema"
    "opencode-launch"
    "preparing-for-compaction"
    "reviewing-github-prs"
    "reviving-worktree-orphaned-sessions"
    "scheduling-wakes"
    "searching-sessions"
    # Cross, not work-only: PR shepherding applies to personal repos and this
    # one too, and the skill already anticipates devbox (it tells you to treat a
    # PR as not lgtm-bound when ~/projects/lgtm/lgtm.yml is absent). The
    # work-only classification was stale, and it left devbox as the one host
    # where agents invented their own PR-monitoring behavior per session.
    "shepherding-pull-requests"
    "swarm-messaging"
    "swarm-shaped-work"
    "using-chatgpt-relay"
    "using-gws"
  ];

  # Work-only skills (macOS + cloudbox)
  workOnlySkills = [
    "cleaning-disk"
    "escalating-azure-aks-rbac"
    "monitoring-deployments"
    "pagerduty-mcp-setup"
    "reading-jenkins-builds"
    "rollbar-mcp-setup"
    "slack-mcp-setup"
    "using-atlassian"
    "using-buildbuddy"
    "using-gcloud-bq-cli"
    "working-with-kubernetes"
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

  # using-atlassian has a reference file and an executable helper script
  atlassianExtras = {
    ".config/opencode/skills/using-atlassian/REFERENCE.md".source =
      "${assetsPath}/opencode/skills/using-atlassian/REFERENCE.md";
    ".config/opencode/skills/using-atlassian/confluence-to-md.sh" = {
      source = "${assetsPath}/opencode/skills/using-atlassian/confluence-to-md.sh";
      executable = true;
    };
  };

  # shepherding-pull-requests has an executable monitoring python script
  shepherdingExtras = {
    ".config/opencode/skills/shepherding-pull-requests/monitor-pr.py" = {
      source = "${assetsPath}/opencode/skills/shepherding-pull-requests/monitor-pr.py";
      executable = true;
    };
  };

  # monitoring-deployments has an executable rollout-monitoring python script
  monitoringDeploymentsExtras = {
    ".config/opencode/skills/monitoring-deployments/monitor-rollout.py" = {
      source = "${assetsPath}/opencode/skills/monitoring-deployments/monitor-rollout.py";
      executable = true;
    };
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

  # caveman skills (pkgs/caveman), all three hosts. Each is a whole directory
  # symlink rather than a bare SKILL.md because several carry companion files
  # (caveman-compress ships the Python scripts it shells out to, caveman ships
  # assets). Same split as superpowers: skills are wired here, the plugin and
  # its config live in opencode-config.nix.
  #
  # Not gated by host: this is plain skill text with no MCP, secret, or model
  # dependency, so cloudbox / devbox / macOS all get the same set.
  #
  # cavecrew and caveman-stats are NOT here — see pkgs/caveman/default.nix for
  # why (broken agent schema / model pins, and a Claude-Code-only hook
  # mechanism that opencode has no equivalent for).
  cavemanSkills =
    lib.foldl' (acc: name: acc // {
      ".config/opencode/skills/${name}".source = "${localPkgs.caveman}/skills/${name}";
    }) {} [
      "caveman"
      "caveman-commit"
      "caveman-compress"
      "caveman-help"
      "caveman-review"
    ];

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
    { pageId = "5386600450"; skillName = "escalating-azure-aks-rbac"; fileName = "INTERNAL.md"; }
    { pageId = "5398265910"; skillName = "monitoring-deployments"; fileName = "INTERNAL.md"; }
    { pageId = "5667029033"; skillName = "reading-jenkins-builds"; fileName = "INTERNAL.md"; }
  ];

  # Activation script: fetch Confluence pages into skill directories
  fetchConfluenceSkillsScript = let
    fetchCommands = lib.concatMapStringsSep "\n" (s: ''
      fetch_skill "${s.pageId}" "${s.skillName}" "${s.fileName}"
    '') confluenceSkills;
  in lib.optionalString (confluenceSkills != []) ''
    # Reachability/auth preflight, run at most once per activation.
    #
    # WHY: the fetch below is `nvim --headless ... >/dev/null 2>&1`, which
    # collapses every distinct failure — expired token, no Confluence licence,
    # VPN down, page deleted, nvim plugin broken — into one indistinguishable
    # "WARNING: failed to fetch". That message sent a reader looking for a
    # network or nvim problem when the actual cause was a revoked API token,
    # which no amount of staring at the activation log could reveal. Classify
    # the failure ONCE, up front, and say which of those it is.
    #
    # The env-var guard above only proves the credentials are NON-EMPTY. It
    # cannot tell a live token from a dead one; that is what this probe adds.
    _conf_probed=0
    _conf_ok=0
    _conf_diag=""

    conf_preflight() {
      [ "$_conf_probed" = "1" ] && return 0
      _conf_probed=1

      # NOTE the `|| true` rather than `|| echo "000"`. curl writes its
      # -w '%{http_code}' template (which is literally "000" when no response
      # was received) BEFORE exiting non-zero, so an `|| echo "000"` fallback
      # APPENDS to that and yields "000000" — which falls through to the `*)`
      # branch and reports "unexpected" for the single most expected failure
      # there is. `|| true` keeps curl's own output; ${code:-000} covers the
      # case where curl printed nothing at all.
      local code
      code="$(${pkgs.curl}/bin/curl -sS -o /dev/null -w '%{http_code}' \
                --max-time 20 \
                -u "$ATLASSIAN_EMAIL:$ATLASSIAN_API_TOKEN" \
                "https://$ATLASSIAN_SITE/wiki/rest/api/user/current" 2>/dev/null || true)"

      case "''${code:-000}" in
        200)
          _conf_ok=1
          ;;
        000)
          _conf_diag="cannot reach https://$ATLASSIAN_SITE (network/VPN/DNS). Confluence content left as-is."
          ;;
        401)
          _conf_diag="HTTP 401 from $ATLASSIAN_SITE — the Atlassian API token is expired or revoked. Re-mint at https://id.atlassian.com/manage-profile/security/api-tokens and update the ${if isDarwin then "'atlassian-api-token' Keychain item" else "atlassian_api_token sops secret"}."
          ;;
        403)
          _conf_diag="HTTP 403 'caller cannot access Confluence' from $ATLASSIAN_SITE — either the API token is dead (an ANONYMOUS request returns this same 403, so 403 alone does not prove the token was even read) or the account $ATLASSIAN_EMAIL has no Confluence product access. Check the token first; Jira /rest/api/3/myself returning 401 with the same credentials confirms a dead token."
          ;;
        *)
          _conf_diag="HTTP $code from $ATLASSIAN_SITE/wiki/rest/api/user/current — unexpected; Confluence content left as-is."
          ;;
      esac

      if [ "$_conf_ok" != "1" ]; then
        echo "fetchConfluenceSkills: Confluence unavailable: $_conf_diag" >&2
        echo "fetchConfluenceSkills: skipping all ${toString (builtins.length confluenceSkills)} Confluence-backed skill file(s); previously fetched copies (if any) are untouched." >&2
      fi
      return 0
    }

    fetch_skill() {
      local page_id="$1"
      local skill_name="$2"
      local file_name="$3"
      local skill_dir="${config.home.homeDirectory}/.config/opencode/skills/$skill_name"
      local skill_file="$skill_dir/$file_name"

      mkdir -p "$skill_dir"

      # Load Atlassian env vars (activation scripts don't have .bashrc sourced)
      if [ -z "''${ATLASSIAN_API_TOKEN:-}" ]; then
        ${if isDarwin then ''
          export ATLASSIAN_SITE=$(/usr/bin/security find-generic-password -s atlassian-site -w 2>/dev/null || echo "")
          export ATLASSIAN_EMAIL=$(/usr/bin/security find-generic-password -s atlassian-email -w 2>/dev/null || echo "")
          export ATLASSIAN_API_TOKEN=$(/usr/bin/security find-generic-password -s atlassian-api-token -w 2>/dev/null || echo "")
          export ATLASSIAN_CLOUD_ID=$(/usr/bin/security find-generic-password -s atlassian-cloud-id -w 2>/dev/null || echo "")
        '' else ''
          if [ -r /run/secrets/atlassian_api_token ]; then
            export ATLASSIAN_SITE="$(cat /run/secrets/atlassian_site 2>/dev/null || echo "")"
            export ATLASSIAN_EMAIL="$(cat /run/secrets/atlassian_email 2>/dev/null || echo "")"
            export ATLASSIAN_API_TOKEN="$(cat /run/secrets/atlassian_api_token 2>/dev/null || echo "")"
            export ATLASSIAN_CLOUD_ID="$(cat /run/secrets/atlassian_cloud_id 2>/dev/null || echo "")"
          fi
        ''}
      fi

      # Skip if all required env vars aren't set
      if [ -z "''${ATLASSIAN_SITE:-}" ] || [ -z "''${ATLASSIAN_EMAIL:-}" ] || \
         [ -z "''${ATLASSIAN_API_TOKEN:-}" ] || [ -z "''${ATLASSIAN_CLOUD_ID:-}" ]; then
        echo "fetchConfluenceSkills: skipping $skill_name/$file_name (Atlassian env vars not set)"
        return 0
      fi

      # Classify auth/reachability before blaming the fetch. On failure this
      # already printed one detailed line; stay quiet per-page rather than
      # emitting N copies of the same WARNING.
      conf_preflight
      if [ "$_conf_ok" != "1" ]; then
        return 0
      fi

      echo "fetchConfluenceSkills: fetching $skill_name/$file_name (page $page_id)..."
      # Use configured nvim from profile so plugins (atlassian.lua) are loaded
      local nvim_bin="${config.home.homeDirectory}/.nix-profile/bin/nvim"
      if [ ! -x "$nvim_bin" ]; then
        # Fallback for macOS if not in nix profile
        nvim_bin="nvim"
      fi

      # FetchConfluencePage *inserts* at the cursor rather than replacing the
      # buffer, so fetching into $skill_file directly would append another full
      # copy of the page on every activation (this silently grew the k8s file to
      # 16MB / 940 copies, making each rebuild take ~40s). Always fetch into a
      # fresh empty temp file, then swap it in only if we got content — a failed
      # fetch leaves the previous copy intact.
      local tmp_file="$skill_dir/.$file_name.tmp.$$"
      rm -f "$skill_dir/.$file_name.tmp."*

      # Keep nvim's diagnostics instead of discarding them: a fetch that fails
      # AFTER a green preflight is a per-page problem (page deleted, no space
      # permission, atlassian.lua broken) and the reason is in this output.
      local log_file="$skill_dir/.$file_name.fetchlog.$$"
      rm -f "$skill_dir/.$file_name.fetchlog."*

      if PATH="${config.home.homeDirectory}/.nix-profile/bin:${pkgs.curl}/bin:$PATH" $nvim_bin --headless "$tmp_file" \
           -c "FetchConfluencePage $page_id" -c "write" -c "quit" >"$log_file" 2>&1 && [ -s "$tmp_file" ]; then
        mv -f "$tmp_file" "$skill_file"
        rm -f "$log_file"
        echo "fetchConfluenceSkills: $skill_name/$file_name updated"
      else
        rm -f "$tmp_file"
        # Credentials are known-good here, so ask about this specific page.
        local page_code
        page_code="$(${pkgs.curl}/bin/curl -sS -o /dev/null -w '%{http_code}' \
                      --max-time 20 \
                      -u "$ATLASSIAN_EMAIL:$ATLASSIAN_API_TOKEN" \
                      "https://$ATLASSIAN_SITE/wiki/rest/api/content/$page_id" 2>/dev/null || true)"
        # `|| true`, not `|| echo "000"` — see conf_preflight above.
        case "''${page_code:-000}" in
          200)
            # Deliberately NOT "not an access problem": this probe and
            # atlassian.lua hit DIFFERENT APIs. The probe is REST; the fetch
            # goes through the GraphQL gateway with an ARI built from
            # ATLASSIAN_CLOUD_ID. A wrong cloud id, or a denial that applies
            # only to the GraphQL path, reads 200 here and still fails there.
            echo "fetchConfluenceSkills: WARNING: page $page_id is readable over REST (HTTP 200) but the nvim fetch produced nothing. The fetch uses the GraphQL gateway, not REST, so this is most likely a client-side fault (atlassian.lua / nvim) or a bad ATLASSIAN_CLOUD_ID — see the nvim output below." >&2
            ;;
          404)
            echo "fetchConfluenceSkills: WARNING: page $page_id not found (HTTP 404) — deleted, moved, or not visible to $ATLASSIAN_EMAIL. Fix or drop the entry for $skill_name in users/dev/opencode-skills.nix." >&2
            ;;
          *)
            echo "fetchConfluenceSkills: WARNING: page $page_id returned HTTP $page_code." >&2
            ;;
        esac
        if [ -s "$log_file" ]; then
          echo "fetchConfluenceSkills: last lines of nvim output ($log_file):" >&2
          tail -n 5 "$log_file" >&2
        else
          rm -f "$log_file"
        fi
        echo "fetchConfluenceSkills: WARNING: failed to fetch $skill_name/$file_name (previous copy, if any, left intact)" >&2
      fi
    }

    ${fetchCommands}
  '';
in
{
  home.file =
    mkSkills crossPlatformSkills
    // beadsReferences
    // superpowersSkills
    // cavemanSkills
    // shepherdingExtras
    // lib.optionalAttrs (isDarwin || isCloudbox) (
      mkSkills workOnlySkills
      // atlassianExtras
      // monitoringDeploymentsExtras
    );

  # Fetch Confluence-based skills during activation (macOS + cloudbox only)
  home.activation.fetchConfluenceSkills = lib.mkIf
    ((isDarwin || isCloudbox) && confluenceSkills != [])
    (lib.hm.dag.entryAfter ["writeBoundary"] fetchConfluenceSkillsScript);
}
