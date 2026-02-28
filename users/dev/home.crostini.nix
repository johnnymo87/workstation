# Crostini (ChromeOS Linux) home-manager configuration
# Chromebook-specific settings: identity, sops secrets via HM module, Gemini API key
{ config, pkgs, lib, isCrostini, projects, ... }:

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

  # Crostini (Debian) tmux fix: source hm-session-vars.sh from .bashrc
  # On NixOS this happens automatically, but on Debian the Nix profile PATH
  # set in .profile gets clobbered when tmux starts a new login shell.
  # Sourcing it here ensures ~/.nix-profile/bin is on PATH inside tmux panes.
  programs.bash.initExtra = lib.mkAfter ''
    if [ -e "$HOME/.nix-profile/etc/profile.d/hm-session-vars.sh" ]; then
      . "$HOME/.nix-profile/etc/profile.d/hm-session-vars.sh"
    fi

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

  # Ensure declared projects are cloned (runs during home-manager switch)
  home.activation.ensureProjects = let
    mkLine = name: p: ''
      ensure_repo ${lib.escapeShellArg name} ${lib.escapeShellArg p.url}
    '';
    lines = lib.concatStringsSep "\n" (lib.mapAttrsToList mkLine projects);
  in lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    ensure_repo() {
      local name="$1"
      local url="$2"
      local dir="${config.home.homeDirectory}/projects/$name"

      if [ -d "$dir/.git" ]; then
        return 0
      fi

      echo "Cloning $name ..."
      ${pkgs.git}/bin/git clone --recursive "$url" "$dir" || echo "WARNING: Failed to clone $name (check SSH access)"
    }

    mkdir -p "${config.home.homeDirectory}/projects"
    ${lines}
  '';

  # Auto-expire old home-manager generations
  services.home-manager.autoExpire = {
    enable = true;
    frequency = "daily";
    timestamp = "-7 days";
    store.cleanup = true;
  };
}
