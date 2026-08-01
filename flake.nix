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

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    devenv = {
      url = "github:cachix/devenv";
    };
  };

  outputs = { self, nixpkgs, home-manager, nix-darwin, disko, sops-nix, devenv, ... }@inputs:
  let
    # Centralized pkgs definition to prevent drift
    pkgsFor = system: import nixpkgs {
      inherit system;
      config.allowUnfree = true;
      overlays = [];
    };

    devboxSystem = "aarch64-linux";
    devboxPkgs = pkgsFor devboxSystem;

    # Darwin (macOS) pkgs
    darwinSystem = "aarch64-darwin";
    darwinPkgs = pkgsFor darwinSystem;

    # Self-packaged tools (updated via nix-update in CI)
    localPkgsFor = system: let
      p = pkgsFor system;
    in {
      ask-question = p.callPackage ./pkgs/ask-question { };
      bb = p.callPackage ./pkgs/bb { };
      beads = p.callPackage ./pkgs/beads { };
      caveman = p.callPackage ./pkgs/caveman { };
      claude-failover-proxy = p.callPackage ./pkgs/claude-failover-proxy { };
      clerk = p.callPackage ./pkgs/clerk { };
      gclpr = p.callPackage ./pkgs/gclpr { };
      git-work = p.callPackage ./pkgs/git-work { };
      gws = p.callPackage ./pkgs/gws { };
      lgtm-gh = p.callPackage ./pkgs/lgtm-gh { };
      nvims = p.callPackage ./pkgs/nvims { };
      oc-auto-attach = p.callPackage ./pkgs/oc-auto-attach { };
      oc-cost = p.callPackage ./pkgs/oc-cost { };
      oc-session-list = p.callPackage ./pkgs/oc-session-list { };
      opencode-frontdoor = p.callPackage ./pkgs/opencode-frontdoor { };
      # NOTE: `opencode-frontdoor-route-gate` is deliberately NOT exposed here.
      # It needs the PINNED opencode, and that pin lives in
      # `users/dev/home.base.nix` (edited in place by
      # .github/workflows/update-opencode-patched.yml, so it must not be moved).
      # Exposing a flake output would require a second copy of the pin here, which
      # the updater would not bump — the gate would then silently validate a STALE
      # binary while the pool ran the new one: green and wrong, at exactly the
      # moment the gate exists for. The gate is instantiated in home.base.nix
      # against the real pin; `pkgs/opencode-frontdoor/test.sh` runs the same
      # check on demand.
      opencode-launch = p.callPackage ./pkgs/opencode-launch { };
      opencode-serve-auth-sh = p.callPackage ./pkgs/opencode-serve-auth-sh { };
      reset-workspace = p.callPackage ./pkgs/reset-workspace { };
      self-compact-plugin = p.callPackage ./pkgs/self-compact-plugin { };
      session-state-plugin = p.callPackage ./pkgs/session-state-plugin { };
      teamclaude = p.callPackage ./pkgs/teamclaude { };
      vercel = p.callPackage ./pkgs/vercel { };
    } // nixpkgs.lib.optionalAttrs (system == devboxSystem || system == darwinSystem) {
      terraform = p.callPackage ./pkgs/terraform { };
    };

    # macOS host facts
    mac = import ./hosts/Y0FMQX93RR-2/vars.nix;

    # Filter projects by platform tag.
    # Projects without a `platforms` attr are included everywhere.
    allProjects = import ./projects.nix;
    projectsFor = platform: nixpkgs.lib.filterAttrs
      (_: p: !(p ? platforms) || builtins.elem platform p.platforms)
      allProjects;
    # All systems we target
    systems = [ devboxSystem darwinSystem ];
  in {
    # Expose local packages for nix-update and nix build.
    # Filter out packages whose meta.platforms excludes the target system
    # (e.g. a package restricted to aarch64 won't appear in packages.x86_64-linux).
    packages = builtins.listToAttrs (map (system: {
      name = system;
      value = let
        all = localPkgsFor system;
        platform = (pkgsFor system).stdenv.hostPlatform;
      in nixpkgs.lib.filterAttrs
        (_: pkg: nixpkgs.lib.meta.availableOn platform pkg)
        all;
    }) systems);

    # Build-level CI gate.
    #
    # `nix flake check` on its own is NOT a build gate for this repo. It
    # *evaluates* `nixosConfigurations` (drv level only) and does not even
    # evaluate `homeConfigurations` -- it just confirms the attrset exists. So a
    # derivation that is fine at eval time but fails at BUILD time sails through
    # CI green and only explodes later, on the user's machine, at `switch` time.
    #
    # That is not hypothetical. #211 added `source "${opencode-serve-auth-sh}"`
    # to three `writeShellApplication`s; that builder runs shellcheck with
    # findings treated as fatal, and shellcheck always emits SC1091 for a source
    # target it cannot resolve -- which a /nix/store path never is at lint time.
    # All three failed to build, taking `home-manager-generation` with them,
    # while CI reported success on both legs. It went unnoticed for a day, so
    # nothing from #211/#212 reached the box, which in turn silently invalidated
    # an unrelated measurement that was about to be acted on. Fixed in #215.
    #
    # Listing the configurations here makes `nix flake check` actually realise
    # them, locally and in CI, by the same command. Both NixOS hosts are
    # aarch64-linux (devbox is ARM on Hetzner, cloudbox is ARM on GCP), so the
    # ubuntu-24.04-arm leg builds all four. This is keyed per-system so the
    # x86_64 leg never tries to realise an aarch64 attribute.
    #
    # Deliberately absent:
    #
    #   nixos-cloudbox -- that host pulls in `claude-failover-proxy`, whose
    #     binary lives in a PRIVATE repo and is fetched through the GitHub API
    #     with a token supplied via `netrcImpureEnvVars`. A CI runner has no
    #     such credential, so the fetch 404s and the toplevel cannot be built
    #     there at all. This is a credential wall, not a defect: it was proven
    #     empirically in the first run of this gate (#218), where the other
    #     three checks built clean and only this one failed. Note the recurring
    #     hazard is unaffected -- `writeShellApplication` (the shellcheck-fatal
    #     builder) appears zero times in either host configuration and only in
    #     the home configs, which ARE built below. Cloudbox also keeps the
    #     eval-level checking `nix flake check` already did. Restoring a real
    #     build needs a CI credential; tracked separately.
    #
    #   darwinConfigurations -- needs a macOS builder. Tracked separately.
    checks.${devboxSystem} = {
      home-dev = self.homeConfigurations.dev.activationPackage;
      home-cloudbox = self.homeConfigurations.cloudbox.activationPackage;
      nixos-devbox = self.nixosConfigurations.devbox.config.system.build.toplevel;
    };

    # NixOS system configuration
    nixosConfigurations.devbox = nixpkgs.lib.nixosSystem {
      system = devboxSystem;
      modules = [
        disko.nixosModules.disko
        sops-nix.nixosModules.sops
        ./hosts/devbox/configuration.nix
        ./hosts/devbox/hardware.nix
        ./hosts/devbox/disko.nix
      ];
    };

    # NixOS system configuration for GCP ARM devbox
    nixosConfigurations.cloudbox = nixpkgs.lib.nixosSystem {
      system = devboxSystem;  # aarch64-linux (same as devbox)
      modules = [
        disko.nixosModules.disko
        sops-nix.nixosModules.sops
        ./hosts/cloudbox/configuration.nix
        ./hosts/cloudbox/hardware.nix
        ./hosts/cloudbox/disko.nix
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
        inherit self;
        localPkgs = localPkgsFor devboxSystem;
        devenvPkg = devenv.packages.${devboxSystem}.devenv;
        assetsPath = ./assets;
        projects = projectsFor "devbox";
        isLinux = true;
        isDarwin = false;
        isDevbox = true;
        isCloudbox = false;
      };
    };

    # Home-manager configuration for GCP ARM devbox (standalone)
    homeConfigurations.cloudbox = home-manager.lib.homeManagerConfiguration {
      pkgs = devboxPkgs;  # aarch64-linux (same as devbox)
      modules = [
        sops-nix.homeManagerModules.sops
        ./users/dev/home.nix
      ];
      extraSpecialArgs = {
        inherit self;
        localPkgs = localPkgsFor devboxSystem;
        devenvPkg = devenv.packages.${devboxSystem}.devenv;
        assetsPath = ./assets;
        projects = projectsFor "cloudbox";
        isLinux = true;
        isDarwin = false;
        isDevbox = false;
        isCloudbox = true;
      };
    };

    # Darwin (macOS) system configuration
    darwinConfigurations.${mac.hostname} = nix-darwin.lib.darwinSystem {
      specialArgs = { inherit inputs mac; };
      modules = [
        ./hosts/Y0FMQX93RR-2/configuration.nix
        home-manager.darwinModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.backupFileExtension = "hm-backup";
          home-manager.extraSpecialArgs = {
            localPkgs = localPkgsFor darwinSystem;
            devenvPkg = devenv.packages.${darwinSystem}.devenv;
            assetsPath = ./assets;
        projects = projectsFor "darwin";
        isLinux = false;
        isDarwin = true;
            isDevbox = false;
            isCloudbox = false;
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
