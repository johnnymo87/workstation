# Crostini (ChromeOS Linux) home-manager configuration
# Chromebook-specific settings: identity, sops secrets via HM module, Gemini API key
{ config, pkgs, lib, isCrostini, ... }:

lib.mkIf isCrostini {
  # Chromebook identity
  home.username = "livia";
  home.homeDirectory = "/home/livia";

  home.stateVersion = "25.11";

  # sops-nix home-manager secrets (decrypted during activation)
  # Age key must be placed at this path before first `home-manager switch`
  sops = {
    age.keyFile = "${config.home.homeDirectory}/.config/sops/age/keys.txt";
    defaultSopsFile = ../../secrets/chromebook.yaml;
    secrets = {
      gemini_api_key = {};
    };
  };

  # Export Gemini API key for OpenCode's @ai-sdk/google provider
  programs.bash.initExtra = lib.mkAfter ''
    if [ -r "${config.sops.secrets.gemini_api_key.path}" ]; then
      export GOOGLE_GENERATIVE_AI_API_KEY="$(cat "${config.sops.secrets.gemini_api_key.path}")"
    fi
  '';

  # Override git identity from home.base.nix
  # Livia has her own GitHub account; disable GPG signing (no key on this machine)
  programs.git = {
    signing.key = lib.mkForce null;
    settings = {
      user.name = lib.mkForce "Livia Delacroix";
      user.email = lib.mkForce "delacroix.livialou@gmail.com";
      commit.gpgsign = lib.mkForce false;
    };
  };

  # Auto-expire old home-manager generations
  services.home-manager.autoExpire = {
    enable = true;
    frequency = "daily";
    timestamp = "-7 days";
    store.cleanup = true;
  };
}
