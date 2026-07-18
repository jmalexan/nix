# Simple declarative disk layout for the HTPC: one NVMe, GPT, EFI + ext4 root.
# (nasa uses ZFS; that's overkill for an appliance, so this stays plain.)
{ ... }: {
  disko.devices = {
    disk = {
      nvme = {
        type = "disk";
        # Verify this is your NVMe boot drive before installing:
        #   lsblk -o NAME,SIZE,MODEL,TRAN
        # A /dev/disk/by-id/... path is more stable if you prefer.
        device = "/dev/nvme0n1";
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
  };
}
