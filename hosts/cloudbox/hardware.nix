# Hardware configuration for GCP Compute Engine ARM (c4a Axion series)
#
# C4a uses:
#   - NVMe storage controller (not virtio-scsi) → disk is /dev/nvme0n1
#   - gVNIC network driver (not virtio-net) → NIC is eth0 (predictable names off)
#   - UEFI boot (ARM requires it)
#
# We import google-compute-config.nix which handles:
#   - google-guest-agent (OS Login, metadata, SSH key management)
#   - NIC naming (usePredictableInterfaceNames = false → eth0)
#   - MTU 1460, GCP NTP server, serial console
#   - qemu-guest profile (virtio base modules)
{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/virtualisation/google-compute-config.nix")
  ];

  # ARM requires UEFI — override the default legacy GRUB from google-compute-config
  boot.loader.grub.enable = lib.mkForce false;
  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.configurationLimit = 10;
  boot.loader.efi.canTouchEfiVariables = false;  # GCP manages EFI vars

  # C4a-specific: NVMe disk + gVNIC network (3rd gen+ requirement)
  boot.initrd.availableKernelModules = [
    "nvme"        # C4a disk interface (NVMe, not virtio-scsi)
    "virtio_pci"  # Virtio PCI bus (still used for some devices)
    "virtio_mmio" # ARM virtio transport
  ];
  boot.initrd.kernelModules = [ "virtio_gpu" ];
  boot.kernelModules = [ "gvnic" ];  # C4a required NIC driver

  # Override google-compute-config's fileSystems — disko manages these
  fileSystems."/" = lib.mkForce {
    device = "/dev/disk/by-partlabel/disk-main-root";
    fsType = "ext4";
  };

  nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";

  zramSwap.enable = true;
}
