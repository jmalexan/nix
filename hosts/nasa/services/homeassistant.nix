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

  # HA needs these capabilities to manage Bluetooth adapters directly
  systemd.services.home-assistant.serviceConfig = {
    AmbientCapabilities = [ "CAP_NET_ADMIN" "CAP_NET_RAW" ];
    CapabilityBoundingSet = [ "CAP_NET_ADMIN" "CAP_NET_RAW" ];
  };

  # ── Home Assistant ────────────────────────────────────────────────────────────

  services.home-assistant = {
    enable = true;
    openFirewall = true;
    configDir = "/Data/smb/Internal/Services/homeassistant/config";
    config = {
      default_config = {};

      http = {
        use_x_forwarded_for = true;
        trusted_proxies = [ "127.0.0.1" "::1" ];
      };

      recorder.db_url = "postgresql://@/hass";
    };

    # Extra integrations — NixOS uses these to pull in required Python packages.
    extraComponents = [
      "apple_tv"
      "bluetooth"
      "bluetooth_le_tracker"
      "brother"
      "dhcp"
      "go2rtc"
      "google_translate"   # tts / gtts
      "homekit"
      "homekit_controller"
      "ipp"
      "met"
      "mobile_app"
      "music_assistant"
      "nest"
      "radio_browser"
      "smartthings"
      "sonos"
      "stream"
      "thread"
      "unifi"
      "unifiprotect"
      "upnp"
    ];

    # psycopg2 is needed for the recorder to connect to PostgreSQL.
    extraPackages = ps: with ps; [ psycopg2 grpcio zlib-ng isal ];
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

  # HomeKit bridge: 21065 21066
  # Sonos UPnP event callbacks: 1400
  # Music Assistant web/ws: 8095
  # AirPlay control: 7000, with ephemeral UDP for audio data
  networking.firewall.allowedTCPPorts = [ 21065 21066 1400 8095 7000 ];
  networking.firewall.allowedUDPPorts = [ 21065 21066 ];
  networking.firewall.allowedUDPPortRanges = [
    { from = 32768; to = 65535; }
  ];

  # ── PostgreSQL ────────────────────────────────────────────────────────────────

  services.postgresql = {
    enable = true;
    ensureDatabases = [ "hass" ];
    ensureUsers = [{
      name = "hass";
      ensureDBOwnership = true;
    }];
  };
}
