{ pkgs, ... }: let
  stateDir = "/Data/smb/Internal/Services/ring-mqtt";

  # Credentials for ring-mqtt's RTSP gateway. These are NOT a security
  # boundary — the listener is bound to loopback and only Frigate's go2rtc
  # ever dials it — but ring-mqtt leaves the RTSP server disabled entirely
  # unless BOTH livestream_user and livestream_pass are non-empty, so they
  # have to be something. The matching URL lives in services/frigate.nix.
  livestreamUser = "frigate";
  livestreamPass = "frigate";

  # Seeded once onto the NAS (see the tmpfiles `C` rule below). Two reasons
  # this is a copied file rather than a read-only /nix/store symlink:
  #
  #  1. ring-mqtt's docker runmode reads /data/config.json and calls
  #     process.exit(1) if it is missing — there is no env-var-only path and
  #     no built-in default, so *something* must exist at that path.
  #  2. /data is a bind mount of this directory into the container. A symlink
  #     pointing into /nix/store would dangle inside the container, which has
  #     no /nix/store mounted.
  #
  # Same posture as frigate/home-assistant/music-assistant on this host: Nix
  # provisions the infrastructure, the app owns its own config afterwards.
  # Edit it in place (e.g. to pin `location_ids`) without a rebuild.
  seedConfig = pkgs.writeText "ring-mqtt-config.json" (builtins.toJSON {
    # Bridged container, so the broker is reached over the docker gateway
    # rather than the host's loopback — see the --add-host below and the
    # matching 172.17.0.1 listener in mqtt.nix.
    mqtt_url = "mqtt://host.docker.internal:1883";
    mqtt_options = "";

    livestream_user = livestreamUser;
    livestream_pass = livestreamPass;

    # Publishes camera/doorbell entities over MQTT discovery, which is what
    # makes them appear in Home Assistant with no HA-side config at all.
    enable_cameras = true;

    # Ring Alarm features. Off because there is no alarm panel on this
    # account; turning them on just adds dead entities.
    enable_modes = false;
    enable_panic = false;
    disarm_code = "";

    hass_topic = "homeassistant/status";
    ring_topic = "ring";

    # Empty = all locations on the account.
    location_ids = [ ];
  });
in {
  # ── ring-mqtt ─────────────────────────────────────────────────────────────────
  # Bridges the Ring doorbell (back door) into MQTT, and — critically — is the
  # ONLY way to get an RTSP stream out of a Ring device. Ring exposes no local
  # RTSP, ONVIF or HTTP snapshot API; every byte is brokered through Ring's
  # cloud over their proprietary protocol. ring-mqtt speaks that protocol and
  # re-publishes the result as a plain RTSP stream plus MQTT discovery topics.
  #
  # What Home Assistant gets from this, automatically, via MQTT discovery:
  #   binary_sensor.<name>_ding      doorbell button press
  #   binary_sensor.<name>_motion    motion detection
  #   camera.<name>_snapshot         still image (does NOT hold a live stream)
  #   sensor.<name>_battery / _wifi  device health
  #   plus light/siren entities on models that have them
  #
  # ⚠️  READ THIS BEFORE POINTING FRIGATE AT IT 24/7
  # Ring cameras are designed for on-demand streaming only. Upstream is explicit
  # that continuous streaming into an NVR "will almost certainly end in
  # disappointment". The failure modes, in order of how much they will annoy you:
  #
  #   1. Ring STOPS SENDING motion and ding events while a stream is active.
  #      A 24/7 Frigate feed means you never get a doorbell notification again.
  #      This alone disqualifies the naive setup.
  #   2. Battery models drain in days rather than months.
  #   3. Sustained streaming can overheat the device.
  #   4. Ring caps interactive sessions at roughly 10 minutes anyway.
  #
  # So the Ring camera is defined in Frigate with `enabled: false` and woken
  # on demand by a Home Assistant automation — see the block at the bottom of
  # this file. That trades "always recording" for "records the event and keeps
  # the doorbell working", which is the only sane trade here.
  virtualisation.oci-containers.containers.ring-mqtt = {
    # Pinned to an exact release for the same reason as frigate/immich: under
    # oci-containers a floating tag never changes the systemd unit, so it would
    # neither auto-update nor stay reproducible.
    image = "tsightler/ring-mqtt:5.9.3";
    autoStart = true;

    volumes = [
      # Holds config.json (seeded below) and ring-state.json, which is where
      # the Ring refresh token is persisted after the one-time web-UI login.
      "${stateDir}:/data"
      "/etc/localtime:/etc/localtime:ro"
    ];

    environment.TZ = "America/New_York";

    # Bridged with everything bound to loopback, for exactly the reason spelled
    # out in frigate.nix: br0 is in networking.firewall.trustedInterfaces, so a
    # host-networked container publishes every port to the whole LAN regardless
    # of allowedTCPPorts. Both ports below are unauthenticated and must not be
    # reachable off this host.
    ports = [
      # RTSP gateway. Published on 8555 rather than 8554 because Frigate's own
      # go2rtc already owns 8554 on this host — a well-known collision between
      # these two services. The container side stays 8554.
      "127.0.0.1:8555:8554"
      # Token-generation web UI. NO AUTHENTICATION of any kind, and it is the
      # front door to the Ring account, so it stays strictly on loopback — see
      # the setup runbook below for how to reach it.
      "127.0.0.1:55123:55123"
    ];

    extraOptions = [
      # Bridged containers can't see the host's loopback, so the MQTT broker is
      # reached over the docker gateway. Matches the mqtt_url seeded above.
      "--add-host=host.docker.internal:host-gateway"
    ];
  };

  # `C` copies only when the destination does not already exist, so this seeds a
  # working config on first boot and then leaves later edits alone. The parent
  # dir is created in permissions.nix alongside every other service's state dir.
  systemd.tmpfiles.rules = [
    "C ${stateDir}/config.json 0640 root root - ${seedConfig}"
  ];

  # ── One-time setup runbook ────────────────────────────────────────────────────
  #
  # 1. Link the Ring account. The web UI is loopback-only and unauthenticated,
  #    so tunnel to it rather than exposing it — from your workstation:
  #
  #      ssh -N -L 55123:127.0.0.1:55123 nasa
  #
  #    then open http://127.0.0.1:55123 and sign in with the Ring account
  #    (including the 2FA code). The refresh token is written to
  #    /data/ring-state.json and survives restarts; you should not need to
  #    repeat this unless the token is revoked or the password changes.
  #
  #    Use a dedicated Ring "shared user" account if you'd rather not put the
  #    owner credentials on the NAS — shared users can still stream and
  #    receive events.
  #
  # 2. Confirm the bridge came up and grab the device id:
  #
  #      docker logs ring-mqtt 2>&1 | grep -i 'device id\|rtsp'
  #
  #    Each camera gets a Ring device id (a short hex string). Its RTSP path is
  #    <device_id>_live — that exact string goes into the go2rtc stream in
  #    services/frigate.nix, which currently ships a <RING_DEVICE_ID>
  #    placeholder. Verify it independently before wiring Frigate up:
  #
  #      ffprobe "rtsp://frigate:frigate@127.0.0.1:8555/<device_id>_live"
  #
  #    Expect it to take a few seconds — the stream is established on demand,
  #    and it tears down again 5-10s after the last client disconnects.
  #
  # 3. Home Assistant picks the entities up on its own through MQTT discovery
  #    (the broker in mqtt.nix is already shared with Frigate). Nothing to add
  #    on the HA side beyond having the MQTT integration configured.
  #
  # 4. Add the on-demand automation below so Frigate only streams during an
  #    event. HA's config dir is app-owned (not Nix-managed), so paste this
  #    into /Data/smb/Internal/Services/homeassistant/config/automations.yaml
  #    or build it in the UI. Adjust the entity ids to match whatever
  #    ring-mqtt actually named the device.
  #
  #      - alias: "Frigate: wake back door camera on Ring event"
  #        # `restart` so repeated motion keeps pushing the shutoff back
  #        # instead of queueing up a second copy of this automation.
  #        mode: restart
  #        triggers:
  #          - trigger: state
  #            entity_id:
  #              - binary_sensor.back_door_ding
  #              - binary_sensor.back_door_motion
  #            to: "on"
  #        actions:
  #          - action: mqtt.publish
  #            data:
  #              topic: frigate/back_door/enabled/set
  #              payload: "ON"
  #          # Long enough to capture the visit, short enough to stay well
  #          # inside Ring's ~10 minute session cap and to hand motion
  #          # detection back to the doorbell promptly.
  #          - delay: "00:03:00"
  #          - action: mqtt.publish
  #            data:
  #              topic: frigate/back_door/enabled/set
  #              payload: "OFF"
  #
  #    Note the inherent blind spot: because Ring suppresses motion events for
  #    the duration of the stream, Frigate sees the event *and what follows*,
  #    but the first second or two of the trigger itself is only ever captured
  #    by Ring's own cloud recording. There is no way around that from here.
}
