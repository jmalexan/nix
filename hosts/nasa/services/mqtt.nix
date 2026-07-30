{ ... }: {
  # ── MQTT broker ───────────────────────────────────────────────────────────────
  # Exists because the Home Assistant Frigate integration *requires* MQTT — it
  # will not load without it, and Frigate publishes its detection/occupancy state
  # over the broker rather than the HTTP API. Both producers (Frigate) and the
  # consumer (Home Assistant) run on this host, so the broker only ever needs to
  # be reachable over loopback.
  #
  # Bound to 127.0.0.1 rather than the LAN, so anonymous access is not exposed to
  # anything off-box; nothing in the firewall opens 1883. Frigate can reach it
  # because its container is host-networked (see frigate.nix) — a bridged
  # container would not see the host's loopback and would need the broker bound
  # to the docker gateway instead.
  #
  # If a device off this host ever needs the broker (a Zigbee2MQTT bridge, an
  # ESPHome sensor), do NOT just widen the address: add a second listener with
  # real users/passwords, and keep this anonymous one loopback-only.
  services.mosquitto = {
    enable = true;
    listeners = [{
      address = "127.0.0.1";
      port    = 1883;

      # No password file: on a loopback-only listener, credentials would just be
      # a plaintext secret sitting in two config files for no security gain.
      omitPasswordAuth = true;
      settings.allow_anonymous = true;

      # The module always loads the ACL-file plugin, and an empty ACL denies
      # everything — so anonymous clients need an explicit blanket grant.
      acl = [ "topic readwrite #" ];
    }];
  };
}
