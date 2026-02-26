# Disk partitioning for GCP Compute Engine (C4a ARM)
#
# C4a uses NVMe storage controller, so the boot disk is /dev/nvme0n1.
# Single pd-balanced 50GB disk — no separate persistent volume.
# All state lives on the root partition.
{ lib, ... }:

{
  disko.devices = {
    disk.main = {
      type = "disk";
      device = lib.mkDefault "/dev/nvme0n1";
      content = {
        type = "gpt";
        partitions = {
          ESP = {
            size = "512M";
            type = "EF00";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
              mountOptions = [ "umask=0077" ];
            };
          };
          root = {
            size = "100%";
            content = {
              type = "filesystem";
              format = "ext4";
              mountpoint = "/";
            };
          };
        };
      };
    };
  };
}
