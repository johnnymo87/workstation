# NixOS system configuration for devbox
{ config, pkgs, lib, ... }:

{
  # sops-nix configuration
  sops = {
    defaultSopsFile = ../../secrets/devbox.yaml;
    age = {
      # Key will be at this path on the devbox
      keyFile = "/persist/sops-age-key.txt";
      generateKey = false;
    };
    secrets = {
      github_ssh_key = {
        owner = "dev";
        group = "dev";
        mode = "0600";
        path = "/home/dev/.ssh/id_ed25519_github";
      };
    };
  };

  # System identity
  networking.hostName = "devbox";
  time.timeZone = "America/New_York";
  i18n.defaultLocale = "en_US.UTF-8";

  # Nix settings
  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    trusted-users = [ "root" "@wheel" ];
    auto-optimise-store = true;
    extra-substituters = [
      "https://cache.numtide.com"
      "https://devenv.cachix.org"
    ];
    extra-trusted-public-keys = [
      "niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g="
      "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw="
    ];
  };

  # Garbage collection
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 7d";
  };

  # System packages
  environment.systemPackages = with pkgs; [
    git curl wget htop jq unzip
    ripgrep fd fzf
    gnumake gcc
    tmux direnv neovim
    gh gnupg pinentry-curses
  ];

  # SSH server
  services.openssh = {
    enable = true;
    openFirewall = true;
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      AllowUsers = [ "dev" ];
      X11Forwarding = false;
      StreamLocalBindUnlink = "yes";
    };
  };

  networking.firewall.enable = true;

  # Persistent volume for state that survives rebuilds
  fileSystems."/persist" = {
    device = "/dev/disk/by-id/scsi-0HC_Volume_104378953";
    fsType = "ext4";
    options = [ "nofail" ];
  };

  # Bind mount projects from persistent volume
  fileSystems."/home/dev/projects" = {
    device = "/persist/projects";
    fsType = "none";
    options = [ "bind" ];
    depends = [ "/persist" ];
  };

  systemd.tmpfiles.rules = [
    # Claude state
    "d /persist/claude 0700 dev dev -"
    "L+ /home/dev/.claude - - - - /persist/claude"
    # Projects directory on persistent volume
    "d /persist/projects 0755 dev dev -"
    # SSH directory on persistent volume (for devbox key)
    "d /persist/ssh 0700 dev dev -"
    "L+ /home/dev/.ssh - - - - /persist/ssh"
  ];

  # User account with stable UID/GID for persistent volume ownership
  users.groups.dev = { gid = 1000; };

  users.users.dev = {
    isNormalUser = true;
    uid = 1000;
    group = "dev";
    description = "Development user";
    extraGroups = [ "wheel" ];
    shell = pkgs.bashInteractive;
    linger = true;  # Allow user services to run without active login
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIjoX7P9gYCGqSbqoIvy/seqAbtzbLAdhaGCYRRVbDR2 johnnymo87@gmail.com"
    ];
  };

  security.sudo.wheelNeedsPassword = false;

  # NOTE: Home-manager runs standalone, not as NixOS module
  # Run: home-manager switch --flake .#dev

  system.stateVersion = "25.11";
}
