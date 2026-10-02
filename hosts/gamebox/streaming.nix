# Headless game-streaming stack for gamebox: NVIDIA (Pascal) + Plasma 6
# Wayland autologin + Sunshine (KWin capture, NVENC) -> Moonlight on the Mac.
#
# Design and its gotchas: ~/Documents/RyuJinx/HEADLESS_STREAMING_PLAN.md on
# Jonathan's Mac. Hardware-driven deviations from that plan are noted inline.
{ config, lib, pkgs, nixpkgs-unstable, ... }:

let
  unstable = import nixpkgs-unstable {
    system = pkgs.stdenv.hostPlatform.system;
    config.allowUnfree = true;
  };

  # Sunshine from unstable: 25.11's 2025.924 has no `kwin` capture backend
  # (only wlr/kms/x11), and KWin capture is what makes headless connects work
  # without a portal approval dialog.
  #
  # cudaSupport for NVENC. CUDA pinned to 12.9 on purpose: CUDA 13 dropped
  # Pascal (sm_6x), and Sunshine's CMake only emits sm_60/61 kernels when
  # built with CUDA < 13. If unstable's default cudaPackages moves to 13.x,
  # an unpinned build would silently produce a Sunshine whose CUDA kernels
  # cannot run on the GTX 1080 Ti. Compiles locally (unfree CUDA is not in
  # cache.nixos.org).
  sunshine = unstable.sunshine.override {
    cudaSupport = true;
    cudaPackages = unstable.cudaPackages_12_9;
  };
in
{
  # --- GPU -----------------------------------------------------------------
  hardware.graphics = {
    enable = true;
    enable32Bit = true; # 32-bit Wine/Proton components
  };
  services.xserver.videoDrivers = [ "nvidia" ];
  hardware.nvidia = {
    # Pascal (GP102) is NOT supported by the open kernel module.
    open = false;
    modesetting.enable = true;
    # 580 is the last driver branch supporting Pascal. Pin by branch name
    # (production == 580.142 in 25.11) rather than `stable`, which will
    # eventually move to a branch that drops this card.
    package = config.boot.kernelPackages.nvidiaPackages.production;
    nvidiaSettings = false;
    powerManagement.enable = false;
  };

  # --- Virtual input (Sunshine gamepads) -----------------------------------
  # uinput: Xbox-style pads; uhid: DualSense (ds5) / Switch Pro emulation.
  boot.kernelModules = [ "uinput" "uhid" ];
  hardware.uinput.enable = true;
  # The virtual DualSense exposes motion on a separate event node that may
  # not get desktop-user ACLs (Cemu #1848); grant it explicitly.
  services.udev.extraRules = ''
    KERNEL=="event*", ATTRS{name}=="*Motion Sensors*", TAG+="uaccess"
  '';

  # --- Desktop session user ------------------------------------------------
  # Separate from `dev` (agents/admin): this account owns the autologin
  # Plasma session, Sunshine, emulators and their data.
  users.users.gamer = {
    isNormalUser = true;
    uid = 1001;
    extraGroups = [ "video" "input" "audio" "uinput" ];
    # SSH so ROMs/saves can be copied straight in (plan Phase 4).
    openssh.authorizedKeys.keys = config.users.users.dev.openssh.authorizedKeys.keys;
  };
  services.openssh.settings.AllowUsers = [ "gamer" ];

  services.displayManager = {
    sddm = {
      enable = true;
      wayland.enable = true;
      # Re-login automatically if Plasma crashes/exits; headless there is
      # nobody to type a password.
      autoLogin.relogin = true;
    };
    autoLogin = {
      enable = true;
      user = "gamer";
    };
    defaultSession = "plasma";
  };
  services.desktopManager.plasma6.enable = true;

  # Never blank, sleep or lock: a blanked dummy-plug output turns off the
  # CRTC and kills capture. System-wide KDE defaults in /etc/xdg apply to
  # `gamer` unless overridden in ~/.config.
  environment.etc."xdg/powerdevilrc".text = ''
    [AC][Display]
    DimDisplayWhenIdle=false
    TurnOffDisplayWhenIdle=false

    [AC][SuspendAndShutdown]
    AutoSuspendAction=0
  '';
  environment.etc."xdg/kscreenlockerrc".text = ''
    [Daemon]
    Autolock=false
    LockOnResume=false
  '';

  # --- Audio ---------------------------------------------------------------
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true; # Sunshine creates its virtual sinks via the Pulse API
  };

  # --- Sunshine ------------------------------------------------------------
  services.sunshine = {
    enable = true;
    package = sunshine;
    autoStart = true;
    openFirewall = true;
    # KWin capture needs no CAP_SYS_ADMIN (that is only for KMS capture).
    capSysAdmin = false;
    # Declarative settings make the web UI's config pages read-only; PIN
    # pairing and credentials still work there.
    settings = {
      sunshine_name = "gamebox";
      # Never leave this on auto: auto tries `portal` first, which pops an
      # approval dialog nobody can click on a headless box.
      capture = "kwin";
      encoder = "nvenc";
      # Only ds5 carries motion/gyro through to the host.
      gamepad = "ds5";
    };
  };

  # --- Power / Wake-on-LAN -------------------------------------------------
  services.logind.settings.Login.IdleAction = "ignore";
  systemd.sleep.extraConfig = ''
    AllowSuspend=no
    AllowHibernation=no
    AllowHybridSleep=no
    AllowSuspendThenHibernate=no
  '';
  # Ethernet only (used once the box moves home); Wi-Fi cannot wake from S5.
  networking.interfaces.enp0s31f6.wakeOnLan.enable = true;

  # --- Applications --------------------------------------------------------
  environment.systemPackages = with pkgs; [
    ryubing
    cemu
    kdePackages.libkscreen # kscreen-doctor, to pin the dummy plug's mode
  ];
}
