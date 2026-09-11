{
  config,
  lib,
  pkgs,
  vars,
  ...
}:
let
  docker = "${config.virtualisation.docker.package}/bin/docker";
  network = "bookorbit";
  stateDir = "/Data/smb/Internal/Services/bookorbit";
  publicUrl = "https://bookorbit.${vars.nasa.domain}";
  privateCa = ../../../certs/ca.crt;
in
{
  # BookOrbit owns its application state and the shared book library. Library
  # files use the media group so they remain writable through SMB.
  # The /downloads mount below exposes only BookOrbit's qBittorrent category,
  # rather than granting the Requests workflow access to unrelated torrents.
  # Its Book Dock is nested below that same bind mount because Linux rejects
  # hardlinks between distinct bind mounts even when ZFS backs both paths.
  users.users.bookorbit = {
    uid = 985;
    group = "bookorbit";
    isSystemUser = true;
    extraGroups = [ "media" ];
  };
  users.groups.bookorbit.gid = 985;

  # POSTGRES_PASSWORD, JWT_SECRET, SETUP_BOOTSTRAP_TOKEN, and encryption keys
  # for credentials stored by BookOrbit. This includes a pre-generated
  # BOOK_REQUEST_ENCRYPTION_KEY for the documented but unreleased Requests
  # workflow. Docker reads it without copying plaintext into the Nix store.
  age.secrets.bookorbit-env.file = ../../../secrets/bookorbit-env.age;

  virtualisation.oci-containers.containers = {
    bookorbit-postgres = {
      # BookOrbit 2.2+ ships PostgreSQL 18 with pgvector. Keep this major pinned:
      # changing it requires a dump into a fresh data directory and restore.
      image = "docker.io/pgvector/pgvector:pg18@sha256:2ba9ca5f2e7daa0f0e7723cba1ee9167bab54efd3640516a44ac1a928dd67e7a";
      autoStart = true;
      environment = {
        POSTGRES_USER = "bookorbit";
        POSTGRES_DB = "bookorbit";
        PGDATA = "/var/lib/postgresql/data/pgdata";
      };
      environmentFiles = [ config.age.secrets.bookorbit-env.path ];
      volumes = [ "${stateDir}/postgres:/var/lib/postgresql/data" ];
      extraOptions = [
        "--network=${network}"
        "--health-cmd=pg_isready -U bookorbit -d bookorbit"
        "--health-interval=10s"
        "--health-timeout=5s"
        "--health-retries=10"
        "--health-start-period=20s"
      ];
    };

    bookorbit = {
      image = "ghcr.io/bookorbit/bookorbit:2.9.0@sha256:3bf8d823d2c2179e519a96e08b928506c2a459e7854ab42ea584cdc78b50e6f4";
      autoStart = true;
      dependsOn = [ "bookorbit-postgres" ];
      # Eufy already occupies host port 3000; nginx fronts this private port.
      ports = [ "127.0.0.1:3001:3000" ];
      environment = {
        NODE_ENV = "production";
        PORT = "3000";
        POSTGRES_HOST = "bookorbit-postgres";
        POSTGRES_PORT = "5432";
        POSTGRES_USER = "bookorbit";
        POSTGRES_DB = "bookorbit";
        APP_URL = publicUrl;
        CLIENT_URL = publicUrl;
        PUID = "985";
        # Use the shared media group so files finalized into /books remain
        # writable through SMB as well as by BookOrbit.
        PGID = "993";
        # Keep prose and manga as separate BookOrbit libraries while preserving
        # the existing /books path already stored in BookOrbit's database.
        LIBRARY_BROWSE_ROOT = "/";
        BOOK_DOCK_PATH = "/downloads/.book-dock";
        # Trust the private CA that signs the internal nginx certificate so
        # Requests can connect securely to Prowlarr through its HTTPS vhost.
        NODE_EXTRA_CA_CERTS = "/etc/ssl/certs/jmalexan-private-ca.crt";
        NODE_MAX_OLD_SPACE_SIZE = "2048";
        LOG_LEVEL = "info";
      };
      environmentFiles = [ config.age.secrets.bookorbit-env.path ];
      volumes = [
        "${stateDir}/data:/data"
        "/Data/smb/Media/Books:/books"
        "/Data/smb/Media/Manga:/manga"
        "${privateCa}:/etc/ssl/certs/jmalexan-private-ca.crt:ro"
        # Requests creates a short-lived probe here when testing hardlinks, so
        # this dedicated category mount must be writable. The Book Dock lives
        # beneath this same container mount at /downloads/.book-dock.
        "/Data/smb/Torrents/BookOrbit:/downloads"
      ];
      extraOptions = [
        "--network=${network}"
        "--init"
        "--read-only"
        "--tmpfs=/tmp:rw,nosuid,nodev"
        "--cap-drop=ALL"
        "--cap-add=CHOWN"
        "--cap-add=DAC_OVERRIDE"
        "--cap-add=FOWNER"
        "--cap-add=SETGID"
        "--cap-add=SETUID"
        "--security-opt=no-new-privileges:true"
        "--stop-timeout=30"
        "--health-cmd=node -e \"const p=process.env.PORT||3000;fetch('http://127.0.0.1:'+p+'/api/v1/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))\""
        "--health-interval=30s"
        "--health-timeout=5s"
        "--health-retries=3"
        "--health-start-period=20s"
      ];
    };
  };

  systemd.services =
    (lib.genAttrs
      [
        "docker-bookorbit"
        "docker-bookorbit-postgres"
      ]
      (name: {
        after = [
          "bookorbit-network.service"
        ]
        ++ lib.optional (name == "docker-bookorbit") "bookorbit-library-access.service";
        requires = [
          "bookorbit-network.service"
        ]
        ++ lib.optional (name == "docker-bookorbit") "bookorbit-library-access.service";
      })
    )
    // {
      bookorbit-library-access = {
        description = "Grant BookOrbit access to library and download storage";
        after = [ "zfs-mount.service" ];
        requires = [ "zfs-mount.service" ];
        wantedBy = [ "multi-user.target" ];
        unitConfig.AssertPathIsMountPoint = "/Data/smb";
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          # The one-time ownership migration may walk a large existing library.
          TimeoutStartSec = "30min";
        };
        script = ''
          stamp=${stateDir}/data/.storage-access-v2
          if [ ! -e "$stamp" ]; then
            # The image drops to UID 985 with su-exec, which does not preserve
            # Docker supplemental groups reliably. Named ACLs express the
            # intended access directly and survive the Calibre transition.
            ${pkgs.acl}/bin/setfacl -R -m u:985:rwX /Data/smb/Media/Books
            ${pkgs.findutils}/bin/find /Data/smb/Media/Books -type d \
              -exec ${pkgs.acl}/bin/setfacl -m d:u:985:rwx '{}' +

            # Preserve read access to existing downloads outside BookOrbit's
            # own category; only the dedicated category below is writable.
            ${pkgs.acl}/bin/setfacl -R -m u:985:r-X /Data/smb/Torrents
            ${pkgs.findutils}/bin/find /Data/smb/Torrents -type d \
              -exec ${pkgs.acl}/bin/setfacl -m d:u:985:r-x '{}' +

            ${pkgs.coreutils}/bin/touch "$stamp"
            ${pkgs.coreutils}/bin/chown bookorbit:bookorbit "$stamp"
          fi

          requests_stamp=${stateDir}/data/.requests-storage-access-v1
          if [ ! -e "$requests_stamp" ]; then
            # BookOrbit creates a temporary file in the mapped download path
            # to prove hardlinks work. Grant its stable UID write access to
            # this category and propagate that ACL to future qBittorrent files.
            ${pkgs.acl}/bin/setfacl -R -m u:985:rwX /Data/smb/Torrents/BookOrbit
            ${pkgs.findutils}/bin/find /Data/smb/Torrents/BookOrbit -type d \
              -exec ${pkgs.acl}/bin/setfacl -m d:u:985:rwx '{}' +

            ${pkgs.coreutils}/bin/touch "$requests_stamp"
            ${pkgs.coreutils}/bin/chown bookorbit:bookorbit "$requests_stamp"
          fi

          single_mount_stamp=${stateDir}/data/.requests-single-mount-v1
          if [ ! -e "$single_mount_stamp" ]; then
            old_dock=${stateDir}/data/book-dock
            new_dock=/Data/smb/Torrents/BookOrbit/.book-dock

            ${pkgs.coreutils}/bin/install -d -m 02770 -o bookorbit -g media "$new_dock"

            # Preserve anything already waiting in the old Book Dock while
            # moving the active path below the Requests download bind mount.
            # -n keeps an existing destination entry if names collide.
            if [ -d "$old_dock" ]; then
              ${pkgs.findutils}/bin/find "$old_dock" -mindepth 1 -maxdepth 1 \
                -exec ${pkgs.coreutils}/bin/mv -n -t "$new_dock" -- '{}' +
            fi

            ${pkgs.acl}/bin/setfacl -R -m u:985:rwX "$new_dock"
            ${pkgs.findutils}/bin/find "$new_dock" -type d \
              -exec ${pkgs.acl}/bin/setfacl -m d:u:985:rwx '{}' +

            ${pkgs.coreutils}/bin/touch "$single_mount_stamp"
            ${pkgs.coreutils}/bin/chown bookorbit:bookorbit "$single_mount_stamp"
          fi

          manga_stamp=${stateDir}/data/.manga-storage-access-v1
          if [ ! -e "$manga_stamp" ]; then
            # Manga is a distinct writable library. Existing files may retain
            # ownership from the retired Komga deployment, so use the same
            # stable named-ACL approach as the prose library.
            ${pkgs.acl}/bin/setfacl -R -m u:985:rwX /Data/smb/Media/Manga
            ${pkgs.findutils}/bin/find /Data/smb/Media/Manga -type d \
              -exec ${pkgs.acl}/bin/setfacl -m d:u:985:rwx '{}' +

            ${pkgs.coreutils}/bin/touch "$manga_stamp"
            ${pkgs.coreutils}/bin/chown bookorbit:bookorbit "$manga_stamp"
          fi

          ownership_stamp=${stateDir}/data/.book-library-ownership-v1
          if [ ! -e "$ownership_stamp" ]; then
            # Complete the Calibre retirement without deleting metadata.db or
            # any library content. BookOrbit owns the files; the shared media
            # group preserves direct SMB access.
            ${pkgs.coreutils}/bin/chown -R bookorbit:media /Data/smb/Media/Books
            ${pkgs.coreutils}/bin/chmod -R g+rwX /Data/smb/Media/Books
            ${pkgs.findutils}/bin/find /Data/smb/Media/Books -type d \
              -exec ${pkgs.coreutils}/bin/chmod g+s '{}' +

            ${pkgs.coreutils}/bin/touch "$ownership_stamp"
            ${pkgs.coreutils}/bin/chown bookorbit:bookorbit "$ownership_stamp"
          fi
        '';
      };

      bookorbit-network = {
        description = "BookOrbit private container network";
        after = [
          "docker.service"
          "docker.socket"
        ];
        requires = [ "docker.service" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          ${docker} network inspect ${network} >/dev/null 2>&1 || \
            ${docker} network create ${network}
        '';
      };
    };
}
