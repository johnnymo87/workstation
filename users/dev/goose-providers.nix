# Declarative custom provider definition for goose.
# Deploys ~/.config/goose/custom_providers/codex_lb.json on cloudbox, devbox, and macOS.
#
# Facts from goose 1.60.2 source (also parsed and routed by 1.54.0-patched.18):
# - Declarative providers load from <goose config dir>/custom_providers/*.json once at
#   provider-registry init (goose-serve restart needed to pick up a new file).
# - read_to_string follows symlinks, so deploying via pkgs.writeText is safe.
# - ONE unparseable file fails the whole custom-provider load, and with it goose's
#   bundled declarative providers (register_declarative_providers returns early);
#   the native gcp_vertex_ai/anthropic providers are unaffected. Hence the
#   goose-custom-provider-codex-lb-check flake check.
# - The empty api_key_env is what makes the client send no auth (requires_auth only
#   matters when a key name is set); codex-lb injects the account token itself.
# - Until goose-serve restarts, delegate(source: "*-astra") fails loudly with
#   "Unknown provider: codex_lb".
# - In crates/goose/src/providers/provider_registry.rs (around line 253), a declarative
#   provider's metadata default_model is:
#     config.models.first().map(|m| m.name.clone()).unwrap_or_default()
#   so listing gpt-6-astra first in models makes it the provider's default model.
{ pkgs, lib, isCloudbox, isDevbox, isDarwin, ... }:

let
  codexLb = import ./codex-lb-models.nix;

  providerConfig = {
    name = codexLb.provider;
    engine = "openai";
    display_name = "codex-lb (ChatGPT subscription pool)";
    description = "ChatGPT subscription pool via codex-lb";
    api_key_env = "";
    base_url = "http://127.0.0.1:2455/v1";
    requires_auth = false;
    dynamic_models = false;
    # Models from codex-lb-models.nix, with gpt-6-astra FIRST.
    # Token costs converted from $/Mtok to $/token (/ 1e6).
    models = map (m: {
      name = m.id;
      context_limit = 272000;
      input_token_cost = m.cost.input * 1.0 / 1000000.0;
      output_token_cost = m.cost.output * 1.0 / 1000000.0;
      cache_read_token_cost = m.cost.cache_read * 1.0 / 1000000.0;
      cache_write_token_cost = m.cost.cache_write * 1.0 / 1000000.0;
      currency = "$";
      reasoning = true;
    }) codexLb.models;
  };

  providerJsonFile = pkgs.writeText "${codexLb.provider}.json" (builtins.toJSON providerConfig);
in
lib.mkIf (isCloudbox || isDevbox || isDarwin) {
  home.file.".config/goose/custom_providers/${codexLb.provider}.json".source = providerJsonFile;
}
