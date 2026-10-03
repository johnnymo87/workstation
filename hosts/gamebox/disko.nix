# Disk layout for gamebox: Samsung 960 Pro 512GB NVMe.
#
# Addressed by stable by-id path, not /dev/nvme0n1, so a second drive added
# later can never shift which disk disko formats.
#
# The swap partition is deliberately generous for a 16 GiB machine: building
# Sunshine with CUDA (and occasionally other large derivations) locally can
# exceed RAM, and an OOM-killed build is slower than a swapping one.
{ lib, ... }:
{
  disko.devices = {
    disk.main = {
      type = "disk";
      device = lib.mkDefault "/dev/disk/by-id/nvme-Samsung_SSD_960_PRO_512GB_S3EWNX0J617016J";
      content = {
        type = "gpt";
        partitions = {
          ESP = {
            size = "1G";
            type = "EF00";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
              mountOptions = [ "umask=0077" ];
            };
          };
          swap = {
            size = "16G";
            content = {
              type = "swap";
              discardPolicy = "both";
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
