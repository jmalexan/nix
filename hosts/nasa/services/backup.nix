{ config, ... }: {
  age.secrets.backblaze-env = {
    file = ../../../secrets/backblaze-env.age;
    # Decrypted to /run/agenix/backblaze-env (root-readable only)
  };
  age.secrets.restic-password = {
    file = ../../../secrets/restic-password.age;
  };

  services.restic.backups.backblaze = {
    repository = "s3:https://s3.us-east-005.backblazeb2.com/jmalexan-nasa";
    paths      = [ "/Data/smb" ];

    # AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY for the B2 bucket
    environmentFile = config.age.secrets.backblaze-env.path;
    passwordFile    = config.age.secrets.restic-password.path;

    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;   # catch up if the machine was off at midnight
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
    # torn, unrestorable snapshot, so exclude it. The DB is therefore NOT in this
    # backup — same as before the containerisation (it lived in the host's
    # /var/lib/postgresql, also outside /Data/smb). TODO: add a pg_dump timer
    # writing a consistent dump under /Data/smb so the DB is captured here.
    # immich-model-cache is downloaded models — regenerable, so skip it too.
    extraBackupArgs = [
      "--exclude=/Data/smb/Internal/Services/immich/thumbs"
      "--exclude=/Data/smb/Internal/Services/immich/encoded-video"
      "--exclude=/Data/smb/Internal/Services/immich-postgres"
      "--exclude=/Data/smb/Internal/Services/immich-model-cache"
    ];
  };
}
