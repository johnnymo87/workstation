# goose role recipes generated from assets/opencode/agents/*.md (one source of
# truth with opencode). Output: $out/roles/<role>.yaml + $out/unscoped.yaml.
# Deployed as ONE directory symlink (users/dev/goose-roles.nix): goose reads
# recipe files with O_NOFOLLOW, so per-file home-manager symlinks are skipped.
#
# sonnetModel: the sonnet-tier roles (implementer, code-reviewer, spec-reviewer)
# run gemini-3.8-flash on gcp_vertex_ai, the model opencode's sddModel gives the
# same agents (users/dev/opencode-config.nix). goose-serve sends Gemini to
# aigateway (GCP_VERTEX_GEMINI_HOST, hosts/cloudbox) and Claude to cfp
# (GCP_VERTEX_HOST, Claude-only), bead workstation-tzzk. On the anthropic
# provider (devbox) there is no Gemini, and claude-sonnet-5-5 404s on Vertex
# here (2026-10-09), so those roles stay on Opus there. gen_goose_roles.py
# refuses a Gemini role on any provider but gcp_vertex_ai.
#
# provider: written into every role as settings.goose_provider, which OUTRANKS
# GOOSE_SUBAGENT_PROVIDER and the delegate call's own provider argument
# (summon.rs resolve_provider), with no fallback if that provider is unusable.
# So it must be a provider the HOST can actually reach. cloudbox: gcp_vertex_ai
# (the default). devbox has no GCP project, ADC or Vertex proxy and runs goose on
# anthropic via cfp-shaper -> TeamClaude, so users/dev/goose-roles.nix overrides
# this to "anthropic" there. The model ids are the same bare claude-* names on
# both providers.
{ lib, runCommand, python3, ro-shell, goose, agentsDir,
  provider ? "gcp_vertex_ai",
  opusModel ? "claude-opus-5-5",
  sonnetModel ? (if provider == "gcp_vertex_ai" then "gemini-3.8-flash" else "claude-opus-5-5") }:

runCommand "goose-roles" {
  nativeBuildInputs = [ (python3.withPackages (ps: [ ps.pyyaml ])) goose ];
  meta = {
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
} ''
  python3 ${./gen_goose_roles.py} --agents-dir ${agentsDir} --out $out \
    --ro-shell-cmd ${ro-shell}/bin/ro-shell --provider ${provider} \
    --opus-model ${opusModel} --sonnet-model ${sonnetModel}
  export HOME=$TMPDIR GOOSE_DISABLE_KEYRING=true
  for f in $out/roles/*.yaml $out/unscoped.yaml; do
    goose recipe validate "$f" || { echo "goose-roles: $f failed goose recipe validate" >&2; exit 1; }
  done
''
