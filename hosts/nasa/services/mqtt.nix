{ ... }: {
  # ── MQTT broker ───────────────────────────────────────────────────────────────
  # Exists because the Home Assistant Frigate integration *requires* MQTT — it
  # will not load without it, and Frigate publishes its detection/occupancy state
  # over the broker rather than the HTTP API. Both producers (Frigate) and the
  # consumer (Home Assistant) run on this host, so the broker only ever needs to
  # be reachable over loopback.
  #
  # Two explicit listeners, and deliberately NOT 0.0.0.0. br0 is in
  # networking.firewall.trustedInterfaces, so binding to a wildcard address would
  # publish an anonymous broker to every device on the LAN — the firewall would
  # not stop it. Each listener is pinned to an address only local clients can
  # reach:
  #   127.0.0.1  — Home Assistant, which runs host-networked
  #   172.17.0.1 — the docker0 gateway, for the bridged Frigate container
  #
  # If a device off this host ever needs the broker (a Zigbee2MQTT bridge, an
  # ESPHome sensor), do NOT just widen the address: add a third listener with
  # real users/passwords and leave these anonymous ones local-only.
  services.mosquitto = {
    enable = true;
    listeners = [
      {
        address = "127.0.0.1";
        port = 1883;

        # No password file: on a local-only listener, credentials would just be
        # a plaintext secret sitting in two config files for no security gain.
        omitPasswordAuth = true;
        settings.allow_anonymous = true;

        # The module always loads the ACL-file plugin, and an empty ACL denies
        # everything — so anonymous clients need an explicit blanket grant.
        acl = [ "topic readwrite #" ];
      }
      {
        # docker0's fixed gateway address. Reachable only from containers on the
        # default bridge, plus the host itself.
        address = "172.17.0.1";
        port = 1883;
        omitPasswordAuth = true;
        settings.allow_anonymous = true;
        acl = [ "topic readwrite #" ];
      }
    ];
  };

  # Containers reaching the gateway address land in the host's INPUT chain, and
  # docker0 is not a trusted interface — so 1883 has to be opened there
  # explicitly. Scoped to docker0 only; this does not expose the broker on br0.
  networking.firewall.interfaces.docker0.allowedTCPPorts = [ 1883 ];

  # 172.17.0.1 only exists once dockerd has created docker0, so mosquitto must
  # not start first — it would fail to bind and land in a restart loop.
  systemd.services.mosquitto = {
    after = [ "docker.service" ];
    wants = [ "docker.service" ];
    serviceConfig = {
      Restart = "on-failure";
      RestartSec = "5s";
    };
  };
}
