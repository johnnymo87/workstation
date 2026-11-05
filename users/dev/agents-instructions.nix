# User-level agent instructions, harness-agnostic: ~/.agents/AGENTS.md.
#
# ONE source (assets/agents/AGENTS.md), read by every harness on every host:
#   - goose reads ~/.agents/AGENTS.md natively as a global hint
#     (crates/goose/src/hints/load_hints.rs, Paths::in_agents_home_dir).
#   - opencode reads it as its global ~/.config/opencode/AGENTS.md, which is a
#     link to this file (users/dev/opencode-config.nix). Its opencode-only rules
#     are a separate file loaded through `instructions`.
#
# A REAL FILE, NOT A HOME-MANAGER SYMLINK. goose canonicalizes the hint path and
# skips it, with only a tracing warning, when the real path falls outside the
# hint's own directory (hints/import_files.rs sanitize_existing_path ->
# validate_canonical_path). A home.file link resolves into /nix/store, so goose
# would silently load nothing. Measured on cloudbox 2026-11-05 (goose
# 1.54.0-patched.10, GOOSE_PATH_ROOT fixture): symlinked file -> not loaded,
# identical regular file -> loaded. Hence the copy below, and the assertion
# that nothing re-adds it as a home.file.
#
# The copy is mode 0444 and replaced on every switch where it differs, so a
# hand edit is reverted: change assets/agents/AGENTS.md instead.
{ config, lib, pkgs, assetsPath, ... }:

let
  rel = ".agents/AGENTS.md";
  src = "${assetsPath}/agents/AGENTS.md";
in
{
  assertions = [{
    assertion = !(config.home.file ? ${rel});
    message = "~/${rel} must be a real file (goose skips a symlinked global hint); it is deployed by home.activation.deployAgentsInstructions in users/dev/agents-instructions.nix, not home.file.";
  }];

  home.activation.deployAgentsInstructions = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    dst="${config.home.homeDirectory}/${rel}"
    if [ -L "$dst" ] || ! ${pkgs.diffutils}/bin/cmp -s ${src} "$dst"; then
      run mkdir -p "$(dirname "$dst")"
      run rm -f "$dst.hm-tmp"
      # Same-directory temp + rename, so a reader never sees a partial file.
      run ${pkgs.coreutils}/bin/install -m 0444 ${src} "$dst.hm-tmp"
      run mv -f "$dst.hm-tmp" "$dst"
    fi
  '';
}
