# Shared goose configuration for Linux hosts (devbox and cloudbox).
# Ensures both hosts run the packaged goose CLI on PATH, warn on stray hand-installed
# binaries, and enforce platform extension defaults and subagent roles policy
# on ~/.config/goose/config.yaml without clobbering writable runtime state.
{ config, pkgs, lib, isCloudbox, isDevbox, ... }:

let
  isLinuxHost = isCloudbox || isDevbox;

  # goose: the SAME package goose-serve runs (hosts/{cloudbox,devbox}, pkgs/goose), so the
  # interactive CLI, every unattended `goose run` and goose-serve all run one binary. Bound to
  # its own name: `pkgs.goose` in nixpkgs is the pressly/goose DATABASE MIGRATION TOOL.
  gooseCli = pkgs.callPackage ../../pkgs/goose { };

  # goose's default extension set, for any session that does not name its own
  # extensions (`_meta.enabledExtensions` in the ACP initialize request).
  #
  # ~/.config/goose/config.yaml stays WRITABLE (goose writes it: configure,
  # toggles, its own migrations; see the goose-serve unit comment in
  # hosts/cloudbox/configuration.nix), so instead of a store symlink this
  # re-applies only `.extensions.<key>.enabled` on every switch. A toggle made
  # by hand is therefore reverted on the next switch: change it here.
  #
  # Why each is off: eng-agent-platform
  # docs/plans/2026-09-22-goose-extension-defaults-design.md §3/§4 (a cautious
  # default, revisited in the honk extension tour, bead honk-9qf.20).
  gooseExtensionsEnabled = {
    developer = true;
    analyze = true;
    todo = true;
    skills = true;
    chatrecall = true; # honk-9qf.20: read-only past-session search
    summon = true; # subagent roles, honk-9qf.19; requires goose >= patched-1.54.0.10 and the settings below
    code_execution = false;
    tom = false;
    orchestrator = false;
    summarize = false;
    apps = false;
    extensionmanager = false;
    scheduler = false;
  };

  # The platform-extension keys goose 1.54 knows (PLATFORM_EXTENSIONS in
  # crates/goose/src/agents/platform_extensions/mod.rs). goose ignores an
  # unknown key, and several of these default to ON when absent, so a typo
  # above would silently leave the real extension on: fail evaluation instead.
  # A goose bump that adds or renames one should update this list.
  gooseKnownExtensionKeys = [
    "analyze" "apps" "chatrecall" "code_execution" "developer" "extensionmanager"
    "orchestrator" "scheduler" "skills" "summarize" "summon" "todo" "tom"
  ];

  # Deploy path for goose subagent roles (users/dev/goose-roles.nix deploys to
  # ~/.config/goose/subagent-roles; keep in sync).
  gooseRolesDeployPath = ".config/goose/subagent-roles";

  gooseConfigSettings = {
    GOOSE_SUBAGENT_ROLES_DIR = "${config.home.homeDirectory}/${gooseRolesDeployPath}/roles";
    GOOSE_SUBAGENT_DEFAULT_RECIPE = "${config.home.homeDirectory}/${gooseRolesDeployPath}/unscoped.yaml";
  };

  gooseExtensionPolicy =
    let
      unknown = lib.subtractLists gooseKnownExtensionKeys (lib.attrNames gooseExtensionsEnabled);
      hasSubagentSettings =
        (gooseConfigSettings ? GOOSE_SUBAGENT_ROLES_DIR)
        && (builtins.isString gooseConfigSettings.GOOSE_SUBAGENT_ROLES_DIR)
        && (gooseConfigSettings.GOOSE_SUBAGENT_ROLES_DIR != "")
        && (gooseConfigSettings ? GOOSE_SUBAGENT_DEFAULT_RECIPE)
        && (builtins.isString gooseConfigSettings.GOOSE_SUBAGENT_DEFAULT_RECIPE)
        && (gooseConfigSettings.GOOSE_SUBAGENT_DEFAULT_RECIPE != "");
      gooseVersionOk = lib.versionAtLeast gooseCli.version "1.54.0-patched.10";
    in
    assert lib.assertMsg (unknown == [ ])
      "gooseExtensionsEnabled has unknown goose extension key(s): ${lib.concatStringsSep ", " unknown}";
    assert lib.assertMsg (!gooseExtensionsEnabled.summon || hasSubagentSettings)
      "gooseExtensionsEnabled.summon requires non-empty string values for GOOSE_SUBAGENT_ROLES_DIR and GOOSE_SUBAGENT_DEFAULT_RECIPE in gooseConfigSettings (goose treats empty values as unset, which would cause delegates to inherit every parent tool)";
    assert lib.assertMsg (!gooseExtensionsEnabled.summon || gooseVersionOk)
      "gooseExtensionsEnabled.summon requires goose >= 1.54.0-patched.10 (current: ${gooseCli.version}); older goose ignores subagent policy keys and delegates would inherit every parent tool";
    pkgs.writeText "goose-extension-policy.json"
      (builtins.toJSON {
        extensions = gooseExtensionsEnabled;
        settings = gooseConfigSettings;
      });

  gooseConfigEnforce = pkgs.callPackage ../../pkgs/goose-config-enforce { };
in
lib.mkIf isLinuxHost {
  home.packages = [ gooseCli ];

  # One goose on this host (see gooseCli above). Login and interactive shells put
  # ~/.local/bin AHEAD of the profile, so a hand-installed copy there (upstream's
  # download_cli.sh puts it there by default) would silently win for humans and
  # split the binaries again over a shared sessions.db. Say so on every switch.
  home.activation.warnStrayGoose = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    for f in "$HOME"/.local/bin/goose "$HOME"/.local/bin/goose-*; do
      if [ -e "$f" ]; then
        echo "WARNING: $f exists; every goose on this host should be the profile's (pkgs/goose). Remove it." >&2
      fi
    done
  '';

  # Apply gooseExtensionsEnabled (above) to the writable config.yaml. New
  # sessions read the file per lookup, so no goose-serve restart is needed.
  # A failure warns rather than aborting the switch: an unparseable file is
  # left exactly as it was, and a missing one is left missing (goose-serve's
  # preflight names it; goose creates it on first run).
  home.activation.enforceGooseExtensions = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run ${gooseConfigEnforce}/bin/goose-config-enforce \
      "$HOME/.config/goose/config.yaml" ${gooseExtensionPolicy} \
      || echo "WARNING: goose-config-enforce failed; ~/.config/goose/config.yaml extensions/settings not enforced" >&2
  '';

  # goose drops comments when it rewrites config.yaml, so the why lives beside it.
  home.file.".config/goose/config.yaml.README.md" = {
    force = true;
    text = ''
      # goose config.yaml: what is managed and where

      This file is generated by home-manager (workstation users/dev/${if isCloudbox then "home.cloudbox.nix" else "goose-config.nix"}).
      Do not edit it here.

      `config.yaml` itself stays writable, because goose writes it: `goose configure`,
      extension toggles and its own migrations. On every home-manager switch,
      `goose-config-enforce` sets `extensions.<key>.enabled` to match
      `gooseExtensionsEnabled` and top-level settings to match `gooseConfigSettings`
      in ${if isCloudbox then "home.cloudbox.nix" else "goose-config.nix"}, leaving everything else alone. An extension or setting
      toggled by hand is therefore reverted on the next switch. To change
      the default set, change it in workstation.

      Enabled by default: ${lib.concatStringsSep ", " (lib.attrNames (lib.filterAttrs (_: v: v) gooseExtensionsEnabled))}.
      Disabled: ${lib.concatStringsSep ", " (lib.attrNames (lib.filterAttrs (_: v: !v) gooseExtensionsEnabled))}.

      This only reaches sessions that do not name their own extensions: honk chat, the
      interactive CLI, and a serve client that omits `_meta.enabledExtensions`. Pigeon's
      `/launch --backend goose` sessions and the maven-renovate lane name their own. An
      existing session keeps the extension list it was created with; only new sessions
      see a change. For one session, use `honk chat --new --ext <name>` (repeatable; it
      replaces the default set) or `goose session --with-builtin <name>`.

      History: summon, extensionmanager, scheduler, apps and tom were switched off on
      2026-09-23 as a cautious default (eng-agent-platform
      docs/plans/2026-09-22-goose-extension-defaults-design.md, §3 and §4 per extension).
      chatrecall and todo were switched on on 2026-10-20 after the honk extension tour
      (honk bead honk-9qf.20).

      On 2026-10-21, summon is on with the subagent policy (goose patch 16,
      johnnymo87/goose#9); GOOSE_SUBAGENT_ROLES_DIR points at five generated role
      recipes (pkgs/goose-roles) scanned first so repo files cannot shadow them;
      GOOSE_SUBAGENT_DEFAULT_RECIPE gives delegates with no role the read-only set
      (developer limited to tree/read_image, analyze, skills, ro-shell), failing
      closed; both keys are also enforced by goose-config-enforce on every switch;
      needs goose >= .10 (older binaries ignore the keys); pigeon and the lane name
      their own extensions and are unaffected.
    '';
  };
}
