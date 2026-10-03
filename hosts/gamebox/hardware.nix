# Hardware configuration for gamebox (physical PC).
#
# ASUS ROG Maximus IX Hero (Z270), Intel i7-7700K, 16 GiB DDR4,
# Samsung 960 Pro NVMe, GTX 1080 Ti (Pascal), Intel I219-V Ethernet
# (enp0s31f6), Intel AX210 Wi-Fi (wlp3s0).
{ config, lib, pkgs, modulesPath, ... }:
{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.configurationLimit = 10;
  # Physical UEFI machine: let NixOS register its own boot entry.
  boot.loader.efi.canTouchEfiVariables = true;

  boot.initrd.availableKernelModules = [ "xhci_pci" "ahci" "nvme" "usbhid" "usb_storage" "sd_mod" ];
  boot.kernelModules = [ "kvm-intel" ];

  # iwlwifi (AX210) firmware lives in linux-firmware; without this the Wi-Fi
  # card is dead on first boot and the box is unreachable at the office.
  hardware.enableRedistributableFirmware = true;
  hardware.cpu.intel.updateMicrocode = true;

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  # Swap partition (disko.nix) is primary; zram absorbs short spikes first.
  zramSwap = {
    enable = true;
    memoryPercent = 50;
  };
}
