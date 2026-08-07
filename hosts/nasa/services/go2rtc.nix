{ pkgs, ... }: let
  stateDir = "/Data/smb/Internal/Services/go2rtc";

  # Seeded once, then owned by the app — go2rtc's API can PATCH this file from
  # its web UI (see pkg/yaml.Patch), so it must be a real writable file rather
  # than a read-only /nix/store symlink. Same posture as frigate.nix.
  #
  # The Nest credentials go in the NAS copy of this file, never in the repo.
  seedConfig = pkgs.writeText "go2rtc.yaml" ''
    # Seeded once by hosts/nasa/services/go2rtc.nix. Safe to edit in place.

    # ── Why this instance exists ───────────────────────────────────────────────
    # Frigate already bundles go2rtc, so a second one needs justifying: Frigate
    # 0.17.2 ships go2rtc v1.9.10, and the `preload` feature below landed in
    # v1.9.11. Without preload the Nest doorbell simply does not work here, for
    # a reason that took a while to pin down:
    #
    # Nest's WebRTC session renegotiates a moment after connecting. go2rtc binds
    # the consumer to the video receiver that exists at connect time, Nest then
    # re-establishes the track, go2rtc creates a NEW receiver for it — and the
    # consumer is left attached to the orphan. The symptom is a producer that
    # looks perfectly healthy (bytes_recv climbing) while ffmpeg sees
    # "Video: h264, none ... unspecified size" and dies, because its track never
    # delivers a single byte. /api/streams shows it plainly: two h264 receivers,
    # the one with `childs` has no bytes, the one with bytes has no `childs`.
    #
    # Frigate's ffmpeg then gives up after 20s, the last consumer leaves, go2rtc
    # tears the producer down, and the next retry races from cold all over again.
    # Confirmed by hand: hold any consumer open against the stream and Frigate
    # starts working immediately.
    #
    # `preload` is exactly that consumer, made permanent. It was added upstream
    # in response to issue #605 — "Nest Doorbell go2rtc stream corrupted in
    # Frigate after stream reconnects" — i.e. this precise bug.
    #
    # If Frigate ever bundles go2rtc >= 1.9.11, this whole container can go away:
    # move the `nest:` source back into frigate.nix and add a preload block there.

    preload:
      # Holds a consumer on the stream from startup, so the Nest producer never
      # goes cold and the track renegotiation settles exactly once, before
      # Frigate ever connects.
      front_door: "video=h264&audio=opus"

    streams:
      # TODO: fill in the five credentials. See the runbook at the bottom of
      # services/frigate.nix for how to pull them out of Home Assistant's Nest
      # integration — this instance wants the identical values.
      #
      # NOTE: the nest source ignores any &video=/&audio= params (it only reads
      # client_id, client_secret, refresh_token, project_id, device_id and
      # protocols — see pkg/nest/client.go), so do not bother adding them here.
      # Track selection is the `preload` query above.
      front_door:
        - nest:?client_id=<CLIENT_ID>&client_secret=<CLIENT_SECRET>&refresh_token=<REFRESH_TOKEN>&project_id=<PROJECT_ID>&device_id=<DEVICE_ID>&protocols=WEB_RTC
  '';
in {
  # ── go2rtc (standalone) ───────────────────────────────────────────────────────
  # Dedicated go2rtc for the Nest doorbell, republishing it as a plain, stable
  # RTSP stream that Frigate's own go2rtc consumes like any ordinary camera.
  # See the long note in the seeded config for why Frigate's built-in copy
  # cannot do this job itself.
  #
  # This mirrors the ring-mqtt pattern on this host: when a cloud camera needs a
  # translation layer Frigate can't provide, that layer gets its own container
  # rather than being wedged into Frigate.
  virtualisation.oci-containers.containers.go2rtc = {
    # Pinned exactly, like every other container here — a floating tag never
    # changes the systemd unit, so it would neither auto-update nor stay
    # reproducible. The plain image already bundles ffmpeg; the `-hardware`
    # variant is only needed if a stream ever has to be transcoded, which this
    # one does not (Nest already hands us H264).
    image = "alexxit/go2rtc:1.9.14";
    autoStart = true;

    volumes = [
      "${stateDir}:/config"
      "/etc/localtime:/etc/localtime:ro"
    ];

    environment.TZ = "America/New_York";

    # Bridged, everything on loopback — same reasoning as frigate.nix and
    # ring-mqtt.nix: br0 is a trusted interface, so a host-networked container
    # would publish these unauthenticated ports to the entire LAN.
    #
    # Host ports are shifted because the defaults are already taken on this box:
    # 8554 is Frigate's go2rtc, 8555 is ring-mqtt's RTSP gateway, 1984 is
    # Frigate's go2rtc API.
    ports = [
      # RTSP, published on TWO host addresses, and it needs both:
      #
      #   127.0.0.1  — for `ssh -L` debugging and ffprobe from the host
      #   172.17.0.1 — the docker0 gateway, which is the ONLY way the bridged
      #                Frigate container can reach this one
      #
      # Frigate resolves host.docker.internal to the docker gateway, not to the
      # host's loopback, so a loopback-only publish is invisible to it: go2rtc
      # fails to dial its producer and every DESCRIBE comes back 404 — which
      # looks exactly like the stream not existing. Same reasoning as the
      # 172.17.0.1 mosquitto listener in mqtt.nix.
      #
      # Binding the gateway address exposes this to containers on the default
      # bridge and to the host, but NOT to br0 / the LAN.
      "127.0.0.1:8556:8554"
      "172.17.0.1:8556:8554"
      # API/web UI. Unauthenticated, and nothing in a container needs it, so
      # this one stays strictly on loopback.
      "127.0.0.1:1985:1984"
    ];

    # The container's own WebRTC listener (8555/tcp+udp) is deliberately NOT
    # published: Frigate consumes RTSP, and nothing else needs to reach this
    # instance. Leaving it unpublished keeps the surface minimal.

    extraOptions = [
      # Not strictly needed today — the nest source dials out to Google — but
      # keeps this consistent with the other bridged containers and lets the
      # config reference host services later without surprise.
      "--add-host=host.docker.internal:host-gateway"
    ];
  };

  # Seeded from the unit's own preStart rather than a systemd.tmpfiles `C` rule,
  # for the same reason as ring-mqtt.nix: on `nixos-rebuild switch` the
  # container unit and systemd-tmpfiles-resetup.service are pulled in with no
  # ordering between them, so a tmpfiles seed can lose the race and the
  # container starts against a missing/empty config. Doing it here makes the
  # precondition the responsibility of the unit that depends on it.
  #
  # Copy-once: the `-e` guard means the credentials you fill in on the NAS
  # survive every rebuild.
  systemd.services.docker-go2rtc.preStart = ''
    ${pkgs.coreutils}/bin/install -d -m 0700 -o root -g root ${stateDir}
    if [ ! -e ${stateDir}/go2rtc.yaml ]; then
      ${pkgs.coreutils}/bin/install -m 0640 -o root -g root \
        ${seedConfig} ${stateDir}/go2rtc.yaml
    fi
  '';

  # ── Verifying ─────────────────────────────────────────────────────────────────
  #
  #   ssh -N -L 1985:127.0.0.1:1985 nasa    # then http://127.0.0.1:1985
  #
  # A healthy front_door shows a producer whose h264 receiver has BOTH a
  # `childs` entry (the preload consumer) and a climbing byte count. If those
  # two land on different receivers again, preload is not holding and the
  # stream will fail in Frigate exactly as before.
  #
  #   curl -s http://127.0.0.1:1985/api/streams | jq '.front_door.producers'
}
