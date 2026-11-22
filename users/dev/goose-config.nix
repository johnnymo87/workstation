# Shared goose configuration for every host (devbox, cloudbox, and the Mac since
# workstation-6w7i.17). Ensures each host runs the packaged goose CLI on PATH, warn on stray hand-installed
# binaries, and enforce platform extension defaults and subagent roles policy
# on ~/.config/goose/config.yaml without clobbering writable runtime state.
{ config, pkgs, lib, isCloudbox, isDevbox, isDarwin, ... }:

let
  isGooseHost = isCloudbox || isDevbox || isDarwin;

  # goose: the SAME package goose-serve runs (hosts/{cloudbox,devbox}, the launchd agent in
  # users/dev/home.darwin.nix, pkgs/goose), so the
  # interactive CLI, every unattended `goose run` and goose-serve all run one binary. Bound to
  # its own name: `pkgs.goose` in nixpkgs is the pressly/goose DATABASE MIGRATION TOOL.
  gooseCli = pkgs.callPackage ../../pkgs/goose { };

  # On the NixOS hosts the profile's `goose` is NOT gooseCli but a wrapper
  # exec'ing /var/lib/goose/current, the approved binary goose-serve also runs
  # (L6, modules/goose-current.nix). So this switch never changes which goose
  # the CLI runs, and the CLI and the serve cannot split: only goose-link moves
  # the link. gooseCli above is still the PIN, which the version asserts below
  # gate the config on, and which the cutover approves after its probe. The Mac
  # keeps gooseCli itself (bead A10).
  #
  # The fallback to the pin is for a host whose SYSTEM config predates L6:
  # pull-workstation switches home-manager on its timer but never the system,
  # and devbox has no system auto-upgrade, so this wrapper can land before
  # /var/lib/goose/current exists. Without the link, the serve is still the
  # pre-L6 unit exec'ing its own baked-in pin, and running the pin here is
  # exactly the pre-L6 behaviour. Once the system switch creates the link, the
  # fallback never fires again. Until it does, a pin bump moves this host's CLI
  # and not its serve: seed the link (a system switch while the pin still equals
  # the running serve) on every NixOS goose host before a pin PR merges.
  gooseOnPath =
    if isDarwin then gooseCli
    else pkgs.writeShellScriptBin "goose" ''
      goose=/var/lib/goose/current/bin/goose
      if [ ! -e /var/lib/goose/current ]; then
        echo "goose: /var/lib/goose/current absent (system config predates L6; sudo nixos-rebuild switch); running the pin" >&2
        goose=${gooseCli}/bin/goose
      fi
      exec "$goose" "$@"
    '';

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
  } // lib.optionalAttrs isCloudbox {
    # Every goose here that is NOT goose-serve (the interactive CLI, honk's
    # sandbox serve) reads these from config.yaml. Without the Gemini host the
    # sonnet-tier roles (gemini-3.8-flash, pkgs/goose-roles) would follow
    # GCP_VERTEX_HOST into cfp, which is Claude-only. goose-serve sets the same
    # three by env (hosts/cloudbox, where env outranks this file), deriving the
    # Gemini host from the aigateway intent flag; this file has no such gate, so
    # with the gateway disabled a CLI Gemini delegate fails loudly rather than
    # bypassing the ledger. Bead workstation-tzzk.
    GCP_VERTEX_GEMINI_HOST = "http://127.0.0.1:8080";
    GCP_VERTEX_SESSION_HEADER = "x-opencode-session,x-session-id";
    GCP_VERTEX_PARENT_SESSION_HEADER = "x-parent-session-id";
    # GOOSE_THINKING_EFFORT is deliberately NOT here: it is set only in
    # goose-serve's env (hosts/cloudbox), because in this file it would also turn
    # thinking on for the CLI and honk's haiku test sandbox. Bead
    # workstation-6w7i.18.
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
    # The comma-separated session header list (goose-serve env in hosts/cloudbox
    # and the settings above) makes an older goose fail every Vertex turn, Claude
    # included. Pinning pkgs/goose back must fail evaluation, not production.
    assert lib.assertMsg (!isCloudbox || lib.versionAtLeast gooseCli.version "1.54.0-patched.13")
      "cloudbox goose settings (GCP_VERTEX_SESSION_HEADER list, GCP_VERTEX_GEMINI_HOST) require goose >= 1.54.0-patched.13 (current: ${gooseCli.version})";
    pkgs.writeText "goose-extension-policy.json"
      (builtins.toJSON {
        extensions = gooseExtensionsEnabled;
        settings = gooseConfigSettings;
      });

  gooseConfigEnforce = pkgs.callPackage ../../pkgs/goose-config-enforce { };
in
lib.mkIf isGooseHost {
  home.packages = [ gooseOnPath ];

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

      This file is generated by home-manager (workstation users/dev/goose-config.nix).
      Do not edit it here.

      `config.yaml` itself stays writable, because goose writes it: `goose configure`,
      extension toggles and its own migrations. On every home-manager switch,
      `goose-config-enforce` sets `extensions.<key>.enabled` to match
      `gooseExtensionsEnabled` and top-level settings to match `gooseConfigSettings`
      in goose-config.nix, leaving everything else alone. An extension or setting
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
