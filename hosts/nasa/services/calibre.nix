{ pkgs, ... }: {
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
}
