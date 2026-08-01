{ pkgs-unstable, ... }: {
  # Seerr — the unified successor to Overseerr/Jellyseerr (they merged in Feb
  # 2026).  A Netflix-style discovery + request front-end: users browse/search,
  # request titles, and Seerr hands approved requests to Radarr (movies) and
  # Sonarr (TV) while checking Jellyfin for what's already available.
  #
  # nasa is on stable nixpkgs (26.05), which now ships the `services.seerr`
  # module — so we use it directly rather than the renamed `services.jellyseerr`.
  # We still override the package: stable pins seerr 3.2.0, but this host has
  # been running 3.3.0 from nixpkgs-unstable, and Seerr migrates its database
  # forward on first start. Dropping to 3.2.0 would point an older schema reader
  # at an already-migrated DB, so keep pkgs-unstable until stable catches up.
  #
  # The config dir stays /var/lib/jellyseerr/config: the module gates its move to
  # /var/lib/seerr on `stateVersion >= 26.05`, and ours stays 25.11 by design.
  # Note the systemd unit is renamed jellyseerr.service -> seerr.service; the
  # StateDirectory is unchanged, so no data moves.
  #
  # No filesystem/media wiring needed: Seerr talks to Jellyfin/Radarr/Sonarr
  # purely over their HTTP APIs (systemd DynamicUser; state in /var/lib/jellyseerr).
  # It runs on the host, so in the setup wizard point it at:
  #   Jellyfin  ->  http://localhost:8096       (host)
  #   Radarr    ->  http://10.200.200.2:7878     (Mullvad netns, via veth bridge)
  #   Sonarr    ->  http://10.200.200.2:8989     (Mullvad netns, via veth bridge)
  services.seerr = {
    enable = true;
    package = pkgs-unstable.seerr;
    openFirewall = false;  # fronted by nginx (see nginx.nix), listens on 5055
  };
}
