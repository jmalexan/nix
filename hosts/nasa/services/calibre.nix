{ pkgs, config, ... }: {
  # Pin UIDs/GIDs for stable ZFS file ownership across rebuilds.
  users.users.calibre-web.uid = 987;
  users.groups.calibre-web.gid = 987;

  # calibre-web needs write access to the library (updates metadata.db,
  # cover cache, etc.) and read access to all book files.
  #
  # The upstream nixpkgs package omits optional dependencies (including
  # jsonschema, which gates Kobo sync support). Override to add them.
  services.calibre-web.package = pkgs.calibre-web.overridePythonAttrs (old: {
    dependencies = old.dependencies ++ old.optional-dependencies.kobo;
    # nixpkgs bumped requests past calibre-web 0.6.25's wheel pin
    # (requests<2.33.0). Relax it so the runtime check passes.
    pythonRelaxDeps = (old.pythonRelaxDeps or [ ]) ++ [ "requests" ];
  });

  services.calibre-web = {
    enable = true;
    dataDir = "/Data/smb/Internal/Services/calibre-web";
    listen = {
      ip   = "127.0.0.1";
      port = 8083;
    };
    options = {
      calibreLibrary      = "/Data/smb/Media/Books";
      enableBookConversion = true;   # ebook-convert for format changes
      enableKepubify       = true;   # EPUB → KEPUB for better Kobo rendering
      enableBookUploading  = true;   # upload books via web UI
    };
  };

  # ── Calibre desktop (containerised) ──────────────────────────────────────
  # Browser-accessible full Calibre via KasmVNC, for workflows calibre-web
  # can't handle (ACSM → DRM-free EPUB via DeDRM plugin, etc.).
  #
  # Runs as PUID=987 so it writes library files as the same user calibre-web
  # uses — both services share /Data/smb/Media/Books directly. Avoid running
  # them simultaneously when editing metadata to prevent metadata.db
  # contention.
  age.secrets.calibre-desktop-password = {
    file = ../../../secrets/calibre-desktop-password.age;
  };

  virtualisation.docker.enable = true;
  virtualisation.oci-containers.backend = "docker";

  virtualisation.oci-containers.containers.calibre-desktop = {
    image = "lscr.io/linuxserver/calibre:latest";
    autoStart = true;
    ports = [ "127.0.0.1:8085:8080" ];   # KasmVNC HTTPS
    environment = {
      PUID = "987";
      PGID = "987";
      TZ   = "America/New_York";
      CUSTOM_USER = "admin";
    };
    environmentFiles = [
      # Must contain a line `PASSWORD=<value>` for KasmVNC auth.
      config.age.secrets.calibre-desktop-password.path
    ];
    volumes = [
      "/Data/smb/Internal/Services/calibre-desktop:/config"
      "/Data/smb/Media/Books:/books"
    ];
  };
}
