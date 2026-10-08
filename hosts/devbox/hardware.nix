# Hardware configuration for Hetzner Cloud ARM (CAX series)
{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.configurationLimit = 10;
  boot.loader.efi.canTouchEfiVariables = false;

  boot.initrd.availableKernelModules = [ "xhci_pci" "virtio_pci" "virtio_scsi" "usbhid" ];
  boot.initrd.kernelModules = [ "virtio_gpu" ];
  boot.kernelModules = [ ];
  boot.kernelParams = [ "console=tty" ];

  services.qemuGuest.enable = true;

  networking.useDHCP = false;
  networking.interfaces.enp1s0.useDHCP = true;

  # DNS: public resolvers instead of the Hetzner ones DHCP hands out
  # (185.12.64.1/.2). Measured 2026-10-08, those dropped about half of all
  # queries from devbox (dig: ~5/10 timeouts each) while 1.1.1.1 and 9.9.9.9
  # answered 10/10, so lookups stalled for glibc's 5 s retry. The em-ci
  # runner containers got the same fix (em-ci.nix). Static servers are
  # listed first, and glibc reads only the first three, so the DHCP-supplied
  # Hetzner entries after them are never queried. (Deliberately no dhcpcd
  # change: restarting dhcpcd without `persistent` drops the address.)
  networking.nameservers = [ "1.1.1.1" "9.9.9.9" "1.0.0.1" ];
  networking.resolvconf.extraOptions = [ "timeout:2" "attempts:3" ];

  nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";

  # P5: Increase zram from default 50% to 75% of RAM (~12 GB).
  # zstd compresses at ~2:1, giving ~24 GB effective swap headroom
  # for compressible pages (language server heaps, idle sessions).
  zramSwap = {
    enable = true;
    memoryPercent = 75;
  };
}
