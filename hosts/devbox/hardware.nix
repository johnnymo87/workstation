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

  nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";

  # P5: Increase zram from default 50% to 75% of RAM (~12 GB).
  # zstd compresses at ~2:1, giving ~24 GB effective swap headroom
  # for compressible pages (language server heaps, idle sessions).
  zramSwap = {
    enable = true;
    memoryPercent = 75;
  };
}
