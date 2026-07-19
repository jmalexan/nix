{ pkgs-unstable, ... }: {
  # Seerr — the unified successor to Overseerr/Jellyseerr (they merged in Feb
  # 2026).  A Netflix-style discovery + request front-end: users browse/search,
  # request titles, and Seerr hands approved requests to Radarr (movies) and
  # Sonarr (TV) while checking Jellyfin for what's already available.
  #
  # nasa is on stable nixpkgs (25.11), which only ships the older
  # `services.jellyseerr` module and jellyseerr 2.7.3.  We keep that module —
  # its systemd unit is identical to unstable's `services.seerr` unit — but swap
  # in the real seerr 3.3.0 package from nixpkgs-unstable (already threaded in as
  # pkgs-unstable).  When nasa moves to a channel that ships `services.seerr`,
  # collapse this to `services.seerr.enable = true;` and drop the override; the
  # config dir stays /var/lib/jellyseerr until stateVersion reaches 26.05.
  #
  # No filesystem/media wiring needed: Seerr talks to Jellyfin/Radarr/Sonarr
  # purely over their HTTP APIs (systemd DynamicUser; state in /var/lib/jellyseerr).
  # It runs on the host, so in the setup wizard point it at:
  #   Jellyfin  ->  http://localhost:8096       (host)
  #   Radarr    ->  http://10.200.200.2:7878     (Mullvad netns, via veth bridge)
  #   Sonarr    ->  http://10.200.200.2:8989     (Mullvad netns, via veth bridge)
  services.jellyseerr = {
    enable = true;
    package = pkgs-unstable.seerr;
    openFirewall = false;  # fronted by nginx (see nginx.nix), listens on 5055
  };
}
