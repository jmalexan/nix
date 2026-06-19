{ ... }: {
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
  # Runs from the official container image rather than the nixpkgs module: the
  # community package omits pywidevine and the Widevine CDM, so the Apple Music
  # provider can't import/authenticate under it. Upstream only supports the
  # container / HA add-on anyway. Host networking is required for the :8095 UI
  # plus mDNS-based airplay/sonos discovery on br0.
  #
  # Providers are configured through the web UI and persist in /data — this
  # replaced the module's declarative `providers` list, so spotify, jellyfin,
  # lastfm_scrobble, sendspin, airplay, and sonos must be re-added there on
  # first boot (state does NOT carry over from the old /var/lib/music-assistant).
  # apple_music can now be enabled too: the image bundles the CDM, so it just
  # needs an Apple Music subscription to authenticate.
  virtualisation.oci-containers.containers.music-assistant = {
    image = "ghcr.io/music-assistant/server:2.8.9";
    autoStart = true;
    extraOptions = [ "--network=host" ];
    volumes = [
      "/Data/smb/Internal/Services/music-assistant:/data"
      # Mount our CA bundle so the container's Python can verify internal HTTPS
      # services signed by our private CA — the Alpine image's trust store lacks
      # it. The SSL_CERT_FILE/REQUESTS_CA_BUNDLE env vars point the stdlib ssl
      # and requests stacks at it (mirrors the old systemd-service env).
      "/etc/ssl/certs/ca-certificates.crt:/etc/ssl/certs/ca-certificates.crt:ro"
      "/etc/localtime:/etc/localtime:ro"
    ];
    environment = {
      TZ                 = "America/New_York";
      SSL_CERT_FILE      = "/etc/ssl/certs/ca-certificates.crt";
      REQUESTS_CA_BUNDLE = "/etc/ssl/certs/ca-certificates.crt";
    };
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
