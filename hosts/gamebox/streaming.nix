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
  #
  # Patch: force a fixed capture frame rate. For KWin < 6.7.80 Sunshine asks
  # PipeWire for a *variable* rate, sending 0/1 as the preferred
  # maxFramerate. KWin 6.5 offers maxFramerate as a range [1/1 .. 60/1], so
  # the 0/1 preference clamps to the range minimum and the stream is
  # negotiated at maxFramerate=1/1: KWin then delivers ~1 frame/s and
  # Sunshine pads to its 30 fps floor with repeats (observed: jerky motion,
  # ~28 fps incoming in Moonlight, `pw-cli enum-params <kwin node> Format`
  # showing maxFramerate 1/1). Requesting the client's fps instead makes the
  # preferred max 60/1, which KWin honours.
  sunshine = (unstable.sunshine.override {
    cudaSupport = true;
    cudaPackages = unstable.cudaPackages_12_9;
  }).overrideAttrs (old: {
    postPatch = (old.postPatch or "") + ''
      substituteInPlace src/platform/linux/pipewire.cpp \
        --replace-fail \
          'const AVRational fps = (negotiate_variable_rate ? AVRational {0, 1} : ::video::framerate_to_rational(config));' \
          'const AVRational fps = ((void) negotiate_variable_rate, ::video::framerate_to_rational(config));'
    '';
  });
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
    # 580 is the last driver branch supporting Pascal. `production` is 580
    # in 25.11 but is a moving pointer (595, Pascal-less, in unstable), so
    # prefer `legacy_580`, which appears once 580 leaves `production` (it
    # exists in unstable, not yet in 25.11).
    package =
      let p = config.boot.kernelPackages.nvidiaPackages;
      in p.legacy_580 or p.production;
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
    # Tailscale-only: ports are NOT opened on the LAN/Wi-Fi interfaces. The
    # box lives on an office guest network, and every client (Mac, any
    # future TV box) reaches it over the tailnet, whose interface is trusted
    # in configuration.nix. Sunshine treats Tailscale's 100.64.0.0/10 as LAN,
    # so the web UI and pairing still work over it.
    openFirewall = false;
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
    # Moonlight's launch menu. Replaces Sunshine's default apps.json, whose
    # X11/xrandr and Steam entries don't work on this box. Ryubing flags were
    # checked against its 1.3.3 source (src/Ryujinx/Utilities/
    # CommandLineState.cs); `-p` selects a profile by name from
    # ~/.config/Ryujinx/system/Profiles.json. The ROM is the bare positional
    # argument; never pass `-r`, which relocates the whole data directory.
    # Ryubing is an X11 (Avalonia) app; Sunshine's user service inherits
    # DISPLAY/XAUTHORITY from the Plasma session.
    applications.apps =
      let
        ryujinx = name: rom: profile: {
          inherit name;
          cmd = ''${lib.getExe' pkgs.ryubing "ryujinx"} -f --docked-mode --hide-cursor always -p ${profile} "/home/gamer/Games/${rom}"'';
          image-path = "desktop.png";
          # Default is 5 s from SIGTERM to SIGKILL when Moonlight quits;
          # give the emulator time to stop and flush its caches.
          exit-timeout = 15;
        };
      in
      [
        {
          name = "Desktop";
          image-path = "desktop.png";
        }
        {
          # Ryubing's own window, for settings and controller mapping.
          name = "Ryubing";
          cmd = lib.getExe' pkgs.ryubing "ryujinx";
          image-path = "desktop.png";
        }
        (ryujinx "Super Mario Bros. Wonder" "Super Mario Bros. Wonder [010015100B514000][v0][US].xci" "Jonathan")
        # The update .nsp sits beside the base game; Ryubing picks it up once
        # added under Manage Title Updates (one-time, in the Ryubing GUI).
        (ryujinx "Mario Party Superstars" "Mario Party Superstars[01006FE013472000][v0].nsp" "Jonathan")
      ];
  };

  # The Sunshine module enables Avahi to advertise the host on the LAN. That
  # is useless here (Tailscale carries no multicast; Moonlight adds the host
  # by name) and would announce it on the office guest Wi-Fi.
  services.avahi.openFirewall = false;

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
