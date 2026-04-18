{ pkgs, ... }: {
  # Whenever Lidarr imports music into /Data/smb/Media/Music, extract the
  # embedded cover art to cover.jpg in each album directory so Jellyfin can
  # reliably display it (Jellyfin's embedded-art reading is inconsistent).
  systemd.services.music-cover-extract = {
    description = "Extract embedded cover art to cover.jpg for music albums";
    serviceConfig = {
      Type = "oneshot";
      User = "lidarr";
      ExecStart = pkgs.writeShellScript "extract-covers" ''
        find /Data/smb/Media/Music -mindepth 2 -maxdepth 2 -type d | while read -r dir; do
          if [ ! -f "$dir/cover.jpg" ]; then
            track=$(find "$dir" -maxdepth 1 \( -name "*.flac" -o -name "*.mp3" -o -name "*.wav" \) | head -1)
            if [ -n "$track" ]; then
              ${pkgs.ffmpeg}/bin/ffmpeg -i "$track" -an -vcodec copy "$dir/cover.jpg" 2>/dev/null \
                && echo "Extracted cover: $dir"
            fi
          fi
        done
      '';
    };
  };

  systemd.paths.music-cover-extract = {
    description = "Watch for new music imports to trigger cover art extraction";
    wantedBy = [ "multi-user.target" ];
    pathConfig = {
      PathChanged = "/Data/smb/Media/Music";
      Unit = "music-cover-extract.service";
    };
  };
}
