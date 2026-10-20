# goose role recipes generated from assets/opencode/agents/*.md (one source of
# truth with opencode). Output: $out/roles/<role>.yaml + $out/unscoped.yaml.
# Deployed as ONE directory symlink (users/dev/goose-roles.nix): goose reads
# recipe files with O_NOFOLLOW, so per-file home-manager symlinks are skipped.
#
# sonnetModel: claude-sonnet-5-5 404s on Vertex here (1002 failed requests via cfp,
# 2026-10-09) and cfp is Claude-only, so goose cannot use opencode's Gemini
# rewrite. Sonnet-tier roles run on Opus until a Vertex Sonnet works.
{ lib, runCommand, python3, ro-shell, goose, agentsDir,
  opusModel ? "claude-opus-5-5", sonnetModel ? "claude-opus-5-5" }:

runCommand "goose-roles" {
  nativeBuildInputs = [ (python3.withPackages (ps: [ ps.pyyaml ])) goose ];
  meta = {
    platforms = lib.platforms.linux;
  };
} ''
  python3 ${./gen_goose_roles.py} --agents-dir ${agentsDir} --out $out \
    --ro-shell-cmd ${ro-shell}/bin/ro-shell \
    --opus-model ${opusModel} --sonnet-model ${sonnetModel}
  export HOME=$TMPDIR GOOSE_DISABLE_KEYRING=true
  for f in $out/roles/*.yaml $out/unscoped.yaml; do
    goose recipe validate "$f" || { echo "goose-roles: $f failed goose recipe validate" >&2; exit 1; }
  done
''
