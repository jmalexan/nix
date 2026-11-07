{
  config,
  lib,
  pkgs,
  ...
}:
let
  registration = pkgs.closureInfo { rootPaths = [ config.system.build.toplevel ]; };
  writeClosure = pkgs.writeClosure or pkgs.writeReferencesToFile;
  contents = writeClosure [
    config.system.build.toplevel
    registration
  ];
  erofs = pkgs.buildPackages.erofs-utils.overrideAttrs (attrs: {
    configureFlags = attrs.configureFlags ++ [ "--enable-multithreading" ];
  });
in
{
  # Upstream's per-path bind mounts dereference top-level store symlinks.
  # Copying the closure preserves the exact NAR representation instead.
  microvm.storeDisk = lib.mkForce (
    pkgs.buildPackages.runCommandLocal "robots-store-disk.erofs"
      {
        nativeBuildInputs = [
          erofs
          pkgs.buildPackages.util-linux
        ];
        passthru.regInfo = registration;
        __structuredAttrs = true;
        unsafeDiscardReferences.out = true;
      }
      ''
        mkdir store
        while IFS= read -r path; do
          cp -a -- "$path" store/
        done < ${contents}
        mkfs.erofs ${lib.concatStringsSep " " config.microvm.storeDiskErofsFlags} \
          -T 0 --all-root -L nix-store --mount-point=/nix/store "$out" store
        blkid -p -o udev "$out" | grep -qx ID_FS_TYPE=erofs
        blkid -p -o udev "$out" | grep -qx ID_FS_LABEL=nix-store
      ''
  );

  assertions = [
    {
      assertion =
        config.microvm.storeDiskType == "erofs"
        && config.microvm.writableStoreOverlay == "/nix/.rw-store"
        && config.boot.initrd.systemd.enable;
      message = "Persistent boot-store seeding requires EROFS, the robots overlay path, and systemd initrd.";
    }
  ];

  # Seed the upper layer while it is unmounted. This avoids per-file OverlayFS
  # copy-up/fsync overhead and never changes a live overlay's backing files.
  boot.initrd.systemd.storePaths = [
    pkgs.coreutils
    pkgs.findutils
  ];
  boot.initrd.systemd.services.agent-seed-nix-store = {
    description = "Seed the persistent robots package store";
    requiredBy = [ "sysroot-nix-store.mount" ];
    before = [ "sysroot-nix-store.mount" ];
    unitConfig = {
      DefaultDependencies = false;
      RequiresMountsFor = [
        "/sysroot"
        "/sysroot/nix/.ro-store"
      ];
    };
    path = [
      pkgs.coreutils
      pkgs.findutils
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      TimeoutStartSec = "10min";
      UMask = "0077";
    };
    script = ''
      source=/sysroot/nix/.ro-store
      writable=/sysroot/nix/.rw-store
      marker="$writable/boot-generation"
      if test -d /sysroot/nix/store && test "$(stat -c %m /sysroot/nix/store)" = /sysroot/nix/store; then
        echo 'Refusing to seed a mounted store overlay' >&2
        exit 1
      fi
      install -d -m 1775 "$writable/store"
      chown 0:${toString config.ids.gids.nixbld} "$writable/store"
      generation=$(find "$source" -mindepth 1 -maxdepth 1 -printf '%f\0' | sort -z | sha256sum)
      if test "$(cat "$marker" 2>/dev/null || true)" = "$generation"; then
        echo 'Persistent boot packages already seeded'
        exit 0
      fi
      scratch="$writable/.boot-copy"
      rm -rf -- "$scratch"
      mkdir -m 0700 "$scratch"
      count=0
      while IFS= read -r -d "" path; do
        name=$(basename "$path")
        target="$writable/store/$name"
        if test -e "$target" || test -L "$target"; then
          continue
        fi
        cp -a -- "$path" "$scratch/"
        # Data must reach disk before its immutable store name is installed.
        sync -f "$scratch"
        mv -T -- "$scratch/$name" "$target"
        count=$((count + 1))
        if test $((count % 100)) = 0; then echo "Seeded $count boot packages"; fi
      done < <(find "$source" -mindepth 1 -maxdepth 1 -print0)
      sync -f "$writable"
      printf '%s\n' "$generation" > "$marker.tmp"
      mv -f "$marker.tmp" "$marker"
      sync -f "$writable"
      rmdir "$scratch"
      echo "Seeded $count boot packages in the persistent store"
    '';
  };

  systemd.services.agent-persist-nix-store = {
    description = "Verify the persistent robots package store";
    wantedBy = [ "multi-user.target" ];
    before = [ "nix-daemon.service" ];
    unitConfig.RequiresMountsFor = [ "/nix/store" ];
    path = [
      pkgs.util-linux
      config.nix.package
    ];
    environment.NIX_REMOTE = "local";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      PrivateMounts = true;
      TimeoutStartSec = "2min";
    };
    script = ''
      # Only this root service's namespace is writable; robot keeps normal access.
      mount -o remount,rw,bind /nix/store
      if ! nix-store --verify; then
        echo 'Clearing unreachable build caches to reconcile an older image update' >&2
        nix-store --gc
        nix-store --verify
      fi
    '';
  };
  systemd.services.agent-ready = {
    requires = [ "agent-persist-nix-store.service" ];
    after = [ "agent-persist-nix-store.service" ];
  };
  systemd.services.nix-daemon = {
    requires = [ "agent-persist-nix-store.service" ];
    after = [ "agent-persist-nix-store.service" ];
  };
}
