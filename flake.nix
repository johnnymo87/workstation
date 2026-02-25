{
  description = "Workstation configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

    home-manager = {
      url = "github:nix-community/home-manager/release-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-darwin = {
      url = "github:nix-darwin/nix-darwin/nix-darwin-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    devenv = {
      url = "github:cachix/devenv";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, home-manager, nix-darwin, disko, devenv, sops-nix, ... }@inputs:
  let
    # Centralized pkgs definition to prevent drift
    pkgsFor = system: import nixpkgs {
      inherit system;
      config.allowUnfree = true;
    };

    devboxSystem = "aarch64-linux";
    devboxPkgs = pkgsFor devboxSystem;

    # Chromebook (Crostini) pkgs
    chromebookSystem = "x86_64-linux";
    chromebookPkgs = pkgsFor chromebookSystem;

    # Darwin (macOS) pkgs
    darwinSystem = "aarch64-darwin";
    darwinPkgs = pkgsFor darwinSystem;

    # Self-packaged tools (updated via nix-update in CI)
    localPkgsFor = system: let p = pkgsFor system; in {
      beads = p.callPackage ./pkgs/beads { };
      ccusage-opencode = p.callPackage ./pkgs/ccusage-opencode { };
    };

    # Custom pinentry that fetches GPG passphrase from 1Password
    pinentry-op = darwinPkgs.callPackage ./pkgs/pinentry-op { };

    # macOS host facts
    mac = import ./hosts/Y0FMQX93RR-2/vars.nix;

    # Shared Cloudflare Tunnel configuration for CCR webhooks
    ccrTunnel = {
      hostname = "ccr.mohrbacher.dev";
      port = 4731;
    };
    # All systems we target
    systems = [ devboxSystem chromebookSystem darwinSystem ];
  in {
    # Expose local packages for nix-update and nix build
    packages = builtins.listToAttrs (map (system: {
      name = system;
      value = localPkgsFor system;
    }) systems);

    # NixOS system configuration
    nixosConfigurations.devbox = nixpkgs.lib.nixosSystem {
      system = devboxSystem;
      specialArgs = { inherit ccrTunnel; };
      modules = [
        disko.nixosModules.disko
        sops-nix.nixosModules.sops
        ./hosts/devbox/configuration.nix
        ./hosts/devbox/hardware.nix
        ./hosts/devbox/disko.nix
      ];
    };

    # Home-manager configuration (standalone for fast iteration on devbox)
    homeConfigurations.dev = home-manager.lib.homeManagerConfiguration {
      pkgs = devboxPkgs;
      modules = [
        sops-nix.homeManagerModules.sops
        ./users/dev/home.nix
      ];
      extraSpecialArgs = {
        inherit self devenv ccrTunnel;
        localPkgs = localPkgsFor devboxSystem;
        assetsPath = ./assets;
        projects = import ./projects.nix;
        isLinux = true;
        isDarwin = false;
        isDevbox = true;
        isCrostini = false;
      };
    };

    # Home-manager configuration for Chromebook (Crostini)
    homeConfigurations.livia = home-manager.lib.homeManagerConfiguration {
      pkgs = chromebookPkgs;
      modules = [
        sops-nix.homeManagerModules.sops
        ./users/dev/home.nix
      ];
      extraSpecialArgs = {
        inherit self devenv ccrTunnel;
        localPkgs = localPkgsFor chromebookSystem;
        assetsPath = ./assets;
        projects = import ./projects.nix;
        isLinux = true;
        isDarwin = false;
        isDevbox = false;
        isCrostini = true;
      };
    };

    # Darwin (macOS) system configuration
    darwinConfigurations.${mac.hostname} = nix-darwin.lib.darwinSystem {
      specialArgs = { inherit inputs mac ccrTunnel; };
      modules = [
        ./hosts/Y0FMQX93RR-2/configuration.nix
        home-manager.darwinModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.extraSpecialArgs = {
            inherit devenv ccrTunnel pinentry-op;
            localPkgs = localPkgsFor darwinSystem;
            assetsPath = ./assets;
            projects = import ./projects.nix;
            isLinux = false;
            isDarwin = true;
            isDevbox = false;
            isCrostini = false;
          };
          home-manager.users.${mac.username} = { lib, ... }: {
            home.username = lib.mkForce mac.username;
            home.homeDirectory = lib.mkForce mac.homeDir;
            home.stateVersion = lib.mkForce "25.11";
            imports = [
              sops-nix.homeManagerModules.sops
              ./users/dev/home.nix
            ];
          };
        }
      ];
    };
  };
}
