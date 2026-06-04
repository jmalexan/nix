{ pkgs-unstable, ... }: {
  # Use the unstable music-assistant module — the 25.11 one's seccomp filter is
  # missing `mbind`, which 2.7+ needs (service dies with SIGSYS on startup).
  disabledModules = [ "services/audio/music-assistant.nix" ];
  imports = [ "${pkgs-unstable.path}/nixos/modules/services/audio/music-assistant.nix" ];

  # The unstable MA module references cliairplay/libraop bare from `pkgs`, but
  # both packages only exist in nixpkgs-unstable. Pull them in via overlay so
  # the airplay provider can resolve its runtime deps.
  nixpkgs.overlays = [
    (_: _: {
      inherit (pkgs-unstable) cliairplay libraop;
    })
  ];

  hardware.bluetooth.enable = true;
  hardware.bluetooth.powerOnBoot = true;

  # ── Home Assistant ────────────────────────────────────────────────────────────
  # Runs from the official container image. The "Core" install method (HA as a
  # plain Python process under systemd) was deprecated by upstream in May 2025.
  # Host networking is required for HomeKit, mDNS, DHCP discovery, and UPnP to
  # see traffic on br0; NET_ADMIN/NET_RAW plus the D-Bus socket give Bluetooth
  # access via the host's bluez.
  virtualisation.oci-containers.containers.home-assistant = {
    image = "ghcr.io/home-assistant/home-assistant:stable";
    autoStart = true;
    extraOptions = [
      "--network=host"
      "--cap-add=NET_ADMIN"
      "--cap-add=NET_RAW"
    ];
    volumes = [
      "/Data/smb/Internal/Services/homeassistant/config:/config"
      "/run/dbus:/run/dbus:ro"
      "/etc/localtime:/etc/localtime:ro"
    ];
    environment.TZ = "America/New_York";
  };

  networking.firewall.allowedTCPPorts = [ 8123 ];

  # ── Matter server ─────────────────────────────────────────────────────────────
  # Standalone matter-server (port 5580) that HA's Matter integration connects
  # to over a websocket. It runs natively on the host; HA reaches it at
  # ws://localhost:5580/ws via the container's host networking. No firewall
  # opening is needed — the websocket is loopback-only and Matter/mDNS device
  # traffic rides br0, which is already a trusted interface.
  services.matter-server = {
    enable = true;
    # The module's systemd sandbox hides /proc/net (ProcSubset=pid), so
    # python-matter-server can't auto-detect the primary interface and logs
    # "Using 'None' as primary interface". Without an interface to scope IPv6
    # link-local traffic to, the post-commission CASE interview can't reach the
    # device and times out. Pin it to br0 — the host's L3 LAN interface
    # (enp5s0 is only a bridge slave and carries no addresses).
    extraArgs = [ "--primary-interface" "br0" ];
    logLevel = "debug"; # TEMP: diagnosing operational-interview timeout
  };

  # ── Music Assistant ───────────────────────────────────────────────────────────

  services.music-assistant = {
    enable = true;
    # 25.11 ships 2.6.3, but the mobile app needs the auth API added in 2.7.0.
    package = pkgs-unstable.music-assistant;
    # apple_music is intentionally omitted — nixpkgs doesn't package pywidevine
    # (Widevine CDM bindings), which the provider needs to import.
    providers = [ "spotify" "jellyfin" "lastfm_scrobble" "sendspin" "airplay" "sonos" ];
  };

  # Point Python's TLS stack at the system trust store so the bundled certifi
  # doesn't shadow our private CA when talking to internal HTTPS services.
  systemd.services.music-assistant.environment = {
    SSL_CERT_FILE      = "/etc/ssl/certs/ca-certificates.crt";
    REQUESTS_CA_BUNDLE = "/etc/ssl/certs/ca-certificates.crt";
  };

  # ── PostgreSQL ────────────────────────────────────────────────────────────────

  services.postgresql = {
    enable = true;
    # The HA container can't use peer auth (its process is root, not the hass
    # OS user), so expose PG on loopback and trust local connections from the
    # hass DB user. Loopback-only — same security posture as peer-on-socket.
    enableTCPIP = true;
    authentication = ''
      host hass hass 127.0.0.1/32 trust
      host hass hass ::1/128 trust
    '';
    ensureDatabases = [ "hass" ];
    ensureUsers = [{
      name = "hass";
      ensureDBOwnership = true;
    }];
  };
}
