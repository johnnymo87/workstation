# Codex-lb model catalog and provider configuration.
# Single source of truth shared between opencode-config.nix, goose-providers.nix,
# goose-roles, and honk-models.nix.
rec {
  # Provider name used in goose custom provider and roles settings
  provider = "codex_lb";

  # Prices: models.dev base tier, $/Mtok. See the LIST-PRICE note in opencode-config.nix
  # for why the higher (>272k context) tier is omitted and why these are not zero.
  catalog = {
    "gpt-6-astra" = {
      name = "GPT-6 Astra";
      effort = "high";
      cost = { input = 10; output = 50; cache_read = 1; cache_write = 12.5; };
    };
    # codex-lb advertises ctx=500000 for this slug, but mkCodexLbModel's 272000
    # limit is kept on purpose: above 272k the whole request bills at the higher
    # tier (4/15/0.2), which opencode's cost merge cannot represent.
    "gpt-6.1-sol" = {
      name = "GPT-6.1 Sol";
      effort = "high";
      cost = { input = 2; output = 10; cache_read = 0.1; cache_write = 2.5; };
    };
    "gpt-6-luna" = {
      name = "GPT-6 Luna";
      effort = "medium";
      cost = { input = 0.1; output = 0.5; cache_read = 0.01; cache_write = 0.125; };
    };
    "gpt-5.6-sol" = {
      name = "GPT-5.6 Sol";
      effort = "high";
      cost = { input = 4; output = 20; cache_read = 0.4; cache_write = 5; };
    };
    "gpt-5.6-terra" = {
      name = "GPT-5.6 Terra";
      effort = "medium";
      cost = { input = 2; output = 12; cache_read = 0.2; cache_write = 2.5; };
    };
    "gpt-5.6-luna" = {
      name = "GPT-5.6 Luna";
      effort = "low";
      cost = { input = 0.2; output = 1.2; cache_read = 0.02; cache_write = 0.25; };
    };
  };

  # Ordered list of catalog entries, gpt-6-astra FIRST.
  models = map (id: { inherit id; } // catalog.${id}) [
    "gpt-6-astra"
    "gpt-6.1-sol"
    "gpt-6-luna"
    "gpt-5.6-sol"
    "gpt-5.6-terra"
    "gpt-5.6-luna"
  ];
}
