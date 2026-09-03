# caveman — the opencode flavour of https://github.com/JuliusBrussee/caveman
#
# Upstream ships an imperative installer (`install.sh` / `bin/install.js
# --only opencode`) that writes straight into ~/.config/opencode/. That cannot
# work here: on our hosts ~/.config/opencode/AGENTS.md, agents/*.md and
# plugins/* are read-only symlinks into the Nix store (see
# users/dev/opencode-config.nix), so the installer would fail on the AGENTS.md
# append and anything it did manage to write would be clobbered by the next
# home-manager switch. This derivation reproduces the installer's *outputs*
# declaratively instead, pinned to a rev.
#
# Layout produced here (consumed by users/dev/opencode-config.nix and
# users/dev/opencode-skills.nix):
#
#   $out/plugin/     plugin.js + package.json + caveman-config.cjs
#   $out/skills/     one dir per skill, opencode auto-discovers SKILL.md
#   $out/commands/   slash-command markdown
#   $out/rules/      caveman-activate.md, wired in via opencode's `instructions`
#
# THE $out/plugin/ SIBLINGS ARE LOad-BEARING. plugin.js locates its helper via
#   dirname(fileURLToPath(import.meta.url))
# and opencode resolves a plugin entry through realpathSync before importing
# it, so `import.meta.url` is the NIX STORE path, not the ~/.config path. All
# three files must therefore be real siblings in ONE store directory, and the
# consumer must symlink the *directory* (not the individual files). Splitting
# them across per-file symlinks makes the plugin die at import time — and
# opencode SWALLOWS that error: `opencode debug info` still lists the plugin
# and nothing lands in opencode.log. The checkPhase below is what stands
# between us and that silent failure.
#
# Deliberately NOT packaged:
#   - agents/cavecrew-*.md — three ways broken on our hosts: `tools: [Read, ...]`
#     is the Claude Code array form which opencode's schema rejects outright,
#     and `model: haiku` is a Claude Code alias that is not a resolvable
#     opencode model id (on cloudbox an unresolvable pin dies as a silent EMPTY
#     response — see the patchAgent notes in users/dev/opencode-config.nix).
#     We already have implementer / code-reviewer / spec-reviewer with
#     host-correct pins; cavecrew-builder would additionally add a
#     write-capable agent guarded only by prose.
#   - skills/cavecrew — exists only to route to the agents above.
#   - skills/caveman-stats + commands/caveman-stats.md — pure Claude Code: the
#     skill documents a hook returning `decision: "block"` and a statusline
#     badge, neither of which exists in opencode. It could never do anything
#     here except take up room in the system prompt.
#
# COMPACTION EXEMPTION. plugin.js is patched at build time so its system-prompt
# injection never touches opencode's compaction/summary request, and so the
# always-on ruleset rides through that same gated hook rather than opencode's
# global `instructions` key (which has no per-agent scoping and would leak into
# the summarizer). See pkgs/caveman/compaction-exemption.js for the full
# rationale and pkgs/caveman/exemption-test.js for the property test that runs
# on every build.
#
# PROMPT-TOGGLE STRICTNESS. A second build-time patch, same shape. Upstream
# flips its mode flag on unanchored substring regexes over the whole user
# prompt, and that flag is HOST-GLOBAL (~/.config/opencode/.caveman-active, no
# session component), so a session writing *about* caveman silently
# reconfigured every other session on the host. The same defect made the
# documented `/caveman <level>` command DEACTIVATE, because opencode expands it
# into a command body that quotes "stop caveman" as documentation and the
# deactivation branch is checked first. See
# pkgs/caveman/prompt-toggle-strictness.js for the rationale and
# pkgs/caveman/toggle-test.js for the property test.
{ lib
, stdenvNoCC
, fetchFromGitHub
, nodejs
}:

let
  # Skills that actually function under opencode.
  skills = [
    "caveman"
    "caveman-commit"
    "caveman-compress"
    "caveman-help"
    "caveman-review"
  ];

  # Slash commands, kept in lockstep with `skills` above.
  commands = [
    "caveman.md"
    "caveman-commit.md"
    "caveman-compress.md"
    "caveman-help.md"
    "caveman-review.md"
  ];
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "caveman";
  version = "0-unstable-2026-07-03";

  src = fetchFromGitHub {
    owner = "JuliusBrussee";
    repo = "caveman";
    rev = "0d95a81d35a9f2d123a5e9430d1cfc43d55f1bb0";
    hash = "sha256-VqRHx3/4SSCnEh3cUJ/he5saIfwNhS0hOzoH/wwtU2o=";
  };

  nativeBuildInputs = [ nodejs ];

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/plugin $out/skills $out/commands $out/rules

    # Plugin: all three files land as real siblings in one directory.
    # caveman-config.js is renamed to .cjs because the plugin dir's
    # package.json declares "type": "module" — a bare .js sibling would be
    # loaded as ESM and break plugin.js's require() bridge. This mirrors what
    # upstream's bin/install.js does.
    #
    # plugin.js is the PATCHED copy; the patchers assert every anchor and fail
    # the build if upstream moved. Two patches, applied in sequence:
    #   1. compaction exemption + ruleset routing
    #   2. prompt-toggle strictness (prose must not flip the host-global flag)
    # They touch disjoint regions of the file, so the order is not load-bearing;
    # it is fixed only so the anchors are checked in a predictable order.
    node ${./compaction-exemption.js} \
      src/plugins/opencode/plugin.js \
      src/rules/caveman-activate.md \
      plugin.exemption.js
    node ${./prompt-toggle-strictness.js} \
      plugin.exemption.js \
      $out/plugin/plugin.js
    cp src/plugins/opencode/package.json  $out/plugin/package.json
    cp src/hooks/caveman-config.js        $out/plugin/caveman-config.cjs

    ${lib.concatMapStringsSep "\n" (s: ''
      cp -r skills/${s} $out/skills/${s}
    '') skills}

    ${lib.concatMapStringsSep "\n" (c: ''
      cp src/plugins/opencode/commands/${c} $out/commands/${c}
    '') commands}

    cp src/rules/caveman-activate.md $out/rules/caveman-activate.md

    runHook postInstall
  '';

  doInstallCheck = true;

  # Guards the silent-death mode described in the header comment, plus the
  # payload we promise to the consumers.
  installCheckPhase = ''
    runHook preInstallCheck

    for f in plugin.js package.json caveman-config.cjs; do
      if [ ! -f "$out/plugin/$f" ]; then
        echo "FAIL: $out/plugin/$f missing — plugin.js's sibling lookup would break at import time, silently." >&2
        exit 1
      fi
    done

    # caveman-config.cjs must be requireable as CommonJS; plugin.js evaluates
    # it by hand and destructures these four names off module.exports.
    for sym in getDefaultMode safeWriteFlag readFlag VALID_MODES; do
      if ! grep -q "$sym" "$out/plugin/caveman-config.cjs"; then
        echo "FAIL: caveman-config.cjs no longer exports $sym; plugin.js would throw on load." >&2
        exit 1
      fi
    done

    ${lib.concatMapStringsSep "\n" (s: ''
      if [ ! -f "$out/skills/${s}/SKILL.md" ]; then
        echo "FAIL: $out/skills/${s}/SKILL.md missing" >&2
        exit 1
      fi
    '') skills}

    ${lib.concatMapStringsSep "\n" (c: ''
      if [ ! -f "$out/commands/${c}" ]; then
        echo "FAIL: $out/commands/${c} missing" >&2
        exit 1
      fi
    '') commands}

    # caveman-compress's SKILL.md is useless without the scripts it shells out to.
    if [ ! -f "$out/skills/caveman-compress/scripts/compress.py" ]; then
      echo "FAIL: caveman-compress scripts not packaged; the skill would reference missing files." >&2
      exit 1
    fi

    # Nothing cavecrew-shaped may leak in — see the header comment.
    if [ -e "$out/skills/cavecrew" ] || compgen -G "$out/**/cavecrew-*" >/dev/null 2>&1; then
      echo "FAIL: cavecrew payload leaked into the output." >&2
      exit 1
    fi

    # THE load-bearing check: drive the real shipped plugin's hooks and prove a
    # compaction request comes out byte-identical while a normal one is terse.
    # A compaction leak is invisible at runtime, so it has to fail here.
    export TEST_SCRATCH="$TMPDIR/caveman-exemption-scratch"
    node ${./exemption-test.js} "$out/plugin/plugin.js"

    # The other invisible-at-runtime property: a deliberate command toggles the
    # mode, prose that merely mentions the command does not. The flag is
    # host-global and its writes are unlogged, so a regression here silently
    # reconfigures every concurrent session with nothing to debug from.
    TEST_SCRATCH="$TMPDIR/caveman-toggle-scratch" \
      node ${./toggle-test.js} "$out/plugin/plugin.js"

    echo "OK: caveman opencode payload complete (plugin siblings, ${toString (builtins.length skills)} skills, ${toString (builtins.length commands)} commands, ruleset)."

    runHook postInstallCheck
  '';

  meta = with lib; {
    description = "opencode payload (plugin, skills, commands, ruleset) for the caveman terse-output skill";
    homepage = "https://github.com/JuliusBrussee/caveman";
    license = licenses.mit;
    platforms = platforms.all;
  };
})
