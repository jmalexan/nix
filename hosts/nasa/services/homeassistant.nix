{ ... }: {
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
      "brother"
      "dhcp"
      "go2rtc"
      "google_translate"   # tts / gtts
      "homekit"
      "homekit_controller"
      "ipp"
      "met"
      "mobile_app"
      "nest"
      "radio_browser"
      "sonos"
      "stream"
      "thread"
      "unifi"
      "unifiprotect"
      "upnp"
    ];

    # psycopg2 is needed for the recorder to connect to PostgreSQL.
    extraPackages = ps: with ps; [ psycopg2 grpcio ];
  };

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
