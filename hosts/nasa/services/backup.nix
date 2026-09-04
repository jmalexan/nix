{ config, pkgs, ... }:

let
  databaseBackupDir = "/Data/smb/Internal/Backups/databases";
  docker = "${config.virtualisation.docker.package}/bin/docker";
  pgDump = "${config.services.postgresql.package}/bin/pg_dump";
in
{
  age.secrets.backblaze-env = {
    file = ../../../secrets/backblaze-env.age;
    # Decrypted to /run/agenix/backblaze-env (root-readable only)
  };
  age.secrets.restic-password = {
    file = ../../../secrets/restic-password.age;
  };

  services.restic.backups.backblaze = {
    repository = "s3:https://s3.us-east-005.backblazeb2.com/jmalexan-nasa";
    paths = [ "/Data/smb" ];

    # AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY for the B2 bucket
    environmentFile = config.age.secrets.backblaze-env.path;
    passwordFile = config.age.secrets.restic-password.path;

    timerConfig = {
      OnCalendar = "daily";
      Persistent = true; # catch up if the machine was off at midnight
    };

    initialize = true;

    pruneOpts = [
      "--keep-daily 14"
      "--keep-weekly 8"
      "--keep-monthly 12"
    ];

    # Exclude immich's regeneratable derivative files — they can be large and
    # are rebuilt automatically after a restore.
    #
    # immich-postgres holds a LIVE Postgres data dir: rsync/restic would copy a
    # torn, unrestorable snapshot, so exclude it. `database-backup.service`
    # writes a consistent logical dump under /Data/smb immediately before this
    # backup starts. It also captures Home Assistant's host PostgreSQL database.
    # immich-model-cache is downloaded models — regenerable, so skip it too.
    extraBackupArgs = [
      "--exclude=/Data/smb/Internal/Services/immich/thumbs"
      "--exclude=/Data/smb/Internal/Services/immich/encoded-video"
      "--exclude=/Data/smb/Internal/Services/immich-postgres"
      "--exclude=/Data/smb/Internal/Services/immich-model-cache"
      # BookOrbit's live PostgreSQL files likewise require a logical dump.
      "--exclude=/Data/smb/Internal/Services/bookorbit/postgres"
      # Frigate's recordings and snapshots. Deliberately NOT backed up: they
      # are surveillance video with a 14-day retention policy configured in
      # frigate.nix, they churn completely every fortnight, and they dedup
      # badly, so they would dominate both the B2 bill and the backup window.
      #
      # Worse, backing them up quietly defeats the retention policy — the prune
      # schedule here keeps 14 daily / 8 weekly / 12 monthly snapshots, so
      # footage Frigate deleted after two weeks would survive in Backblaze for
      # up to a year.
      #
      # Only media/ is excluded. frigate/config/ stays in the backup and very
      # much needs to: config.yml is UI-editable and is the real source of
      # truth for the cameras (the Nix seed only bootstraps a fresh host).
      "--exclude=/Data/smb/Internal/Services/frigate/media"
    ];
  };

  # Capture databases transaction-consistently before Restic walks /Data/smb.
  # Restic requires this oneshot, so a failed dump makes the backup fail loudly
  # rather than recording a snapshot that looks successful but lacks databases.
  systemd.services.database-backup = {
    description = "Create logical database dumps for the Restic backup";
    after = [
      "postgresql.service"
      "docker-immich-postgres.service"
      "docker-bookorbit-postgres.service"
    ];
    requires = [
      "postgresql.service"
      "docker-immich-postgres.service"
      "docker-bookorbit-postgres.service"
    ];
    unitConfig.AssertPathIsMountPoint = "/Data/smb";
    serviceConfig.Type = "oneshot";
    script = ''
      set -euo pipefail

      ${pkgs.coreutils}/bin/install -d -m 0700 -o root -g root ${databaseBackupDir}

      hass_tmp=$(${pkgs.coreutils}/bin/mktemp ${databaseBackupDir}/.hass.XXXXXX)
      immich_tmp=$(${pkgs.coreutils}/bin/mktemp ${databaseBackupDir}/.immich.XXXXXX)
      bookorbit_tmp=$(${pkgs.coreutils}/bin/mktemp ${databaseBackupDir}/.bookorbit.XXXXXX)
      cleanup() {
        ${pkgs.coreutils}/bin/rm -f \
          "$hass_tmp" "$immich_tmp" "$bookorbit_tmp"
      }
      trap cleanup EXIT

      ${pkgs.util-linux}/bin/runuser -u postgres -- \
        ${pgDump} --format=custom --clean --if-exists hass > "$hass_tmp"
      ${docker} exec immich-postgres \
        pg_dump --username=postgres --format=custom --clean --if-exists immich \
        > "$immich_tmp"
      ${docker} exec bookorbit-postgres \
        pg_dump --username=bookorbit --format=custom --clean --if-exists bookorbit \
        > "$bookorbit_tmp"

      ${pkgs.coreutils}/bin/chmod 0600 \
        "$hass_tmp" "$immich_tmp" "$bookorbit_tmp"
      ${pkgs.coreutils}/bin/mv "$hass_tmp" ${databaseBackupDir}/hass.dump
      ${pkgs.coreutils}/bin/mv "$immich_tmp" ${databaseBackupDir}/immich.dump
      ${pkgs.coreutils}/bin/mv "$bookorbit_tmp" ${databaseBackupDir}/bookorbit.dump
      trap - EXIT
    '';
  };

  systemd.services.restic-backups-backblaze = {
    after = [ "database-backup.service" ];
    requires = [ "database-backup.service" ];
  };
}
