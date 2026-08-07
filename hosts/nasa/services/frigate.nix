{ pkgs, ... }: let
  ssl = {
    forceSSL          = true;
    sslCertificate    = "/var/lib/nginx/certs/server.crt";
    sslCertificateKey = "/var/lib/nginx/certs/server.key";
  };

  stateDir = "/Data/smb/Internal/Services/frigate";

  # Seed config, copied into place on first boot only (see the tmpfiles `C`
  # rule below). Frigate rewrites config.yml itself whenever you edit settings
  # or draw a motion mask/zone in the web UI, so it deliberately is NOT a
  # read-only Nix-managed file — a symlink into /nix/store would break the UI
  # editor. Same posture as home-assistant and music-assistant on this host:
  # Nix provisions the infrastructure, the app owns its own config.
  #
  # Camera credentials live in this file rather than in agenix, because it sits
  # on the NAS and is never committed to the repo.
  seedConfig = pkgs.writeText "frigate-config.yml" ''
    # Seeded once by hosts/nasa/services/frigate.nix. Safe to edit in place or
    # via the Frigate UI — NixOS will not overwrite it on later rebuilds.

    # Required by the Home Assistant Frigate integration — it refuses to load
    # without MQTT, and Frigate publishes detection/occupancy state over the
    # broker rather than the HTTP API. Broker is loopback-only, see mqtt.nix.
    mqtt:
      enabled: true
      # Frigate is bridged, so it reaches the broker over the docker gateway
      # rather than the host's loopback (--add-host in frigate.nix maps this).
      host: host.docker.internal
      port: 1883

    # Frigate's own nginx defaults to TLS on 8971 with a self-signed cert. Our
    # nginx already terminates TLS with the private CA cert and reaches Frigate
    # over loopback, so leaving this on just means proxying plain HTTP into an
    # HTTPS listener — which fails with "400 The plain HTTP request was sent to
    # HTTPS port". Upstream recommends disabling it for exactly this setup.
    tls:
      enabled: false

    auth:
      # nginx terminates TLS and proxies from the host, so without this every
      # login appears to come from 127.0.0.1 and a few failed attempts from one
      # device would rate-limit everyone out of the UI.
      trusted_proxies:
        - 127.0.0.1

    ffmpeg:
      # Decode on the RTX 3080 via NVDEC instead of burning CPU. This is the
      # single biggest win for a multi-megapixel camera and works regardless of
      # which detector is configured below.
      hwaccel_args: preset-nvidia
      # Wireless/battery cameras drop the stream between events and allow only
      # a couple of concurrent connections. Backing off before reconnecting
      # avoids hammering the camera and getting locked out of a stream slot.
      retry_interval: 10

    detectors:
      # CPU detection is the default because it works on first boot with no
      # extra files. It comfortably handles one or two cameras at 5fps detect.
      #
      # To move object detection onto the 3080 as well, export a YOLOv9 ONNX
      # model into the model_cache dir (the -tensorrt image already contains the
      # TensorRT runtime, so no other change is needed):
      #
      #   cd ${stateDir}/config/model_cache
      #   docker build . --build-arg MODEL_SIZE=t --build-arg IMG_SIZE=320 \
      #     --output . -f- <<'EOF'
      #   FROM python:3.11 AS build
      #   RUN apt-get update && apt-get install --no-install-recommends -y cmake libgl1 && rm -rf /var/lib/apt/lists/*
      #   COPY --from=ghcr.io/astral-sh/uv:0.10.4 /uv /bin/
      #   WORKDIR /yolov9
      #   ADD https://github.com/WongKinYiu/yolov9.git .
      #   RUN uv pip install --system -r requirements.txt
      #   RUN uv pip install --system onnx==1.18.0 onnxruntime onnx-simplifier==0.4.* onnxscript
      #   ARG MODEL_SIZE
      #   ARG IMG_SIZE
      #   ADD https://github.com/WongKinYiu/yolov9/releases/download/v0.1/yolov9-''${MODEL_SIZE}-converted.pt yolov9-''${MODEL_SIZE}.pt
      #   RUN sed -i "s/ckpt = torch.load(attempt_download(w), map_location='cpu')/ckpt = torch.load(attempt_download(w), map_location='cpu', weights_only=False)/g" models/experimental.py
      #   RUN python3 export.py --weights ./yolov9-''${MODEL_SIZE}.pt --imgsz ''${IMG_SIZE} --simplify --include onnx
      #   FROM scratch
      #   ARG MODEL_SIZE
      #   ARG IMG_SIZE
      #   COPY --from=build /yolov9/yolov9-''${MODEL_SIZE}.onnx /yolov9-''${MODEL_SIZE}-''${IMG_SIZE}.onnx
      #   EOF
      #
      # then replace the `cpu` detector below with:
      #
      #   detectors:
      #     onnx:
      #       type: onnx
      #   model:
      #     model_type: yolo-generic
      #     width: 320
      #     height: 320
      #     input_tensor: nchw
      #     input_dtype: float
      #     path: /config/model_cache/yolov9-t-320.onnx
      #     labelmap_path: /labelmap/coco-80.txt
      cpu:
        type: cpu

    # Restreaming: Frigate opens ONE connection to the camera and every consumer
    # (the Frigate UI, the Home Assistant card, VLC) pulls from go2rtc instead.
    # This matters enormously for both cameras here: they are cloud-brokered
    # doorbells, so every extra "connection" is a metered session against
    # Ring's or Google's servers, not a cheap LAN socket.
    go2rtc:
      streams:
        # ── Back door: Ring doorbell ──────────────────────────────────────────
        # Ring has no local RTSP/ONVIF/snapshot API — everything is brokered
        # through Ring's cloud — so this comes via the ring-mqtt container
        # (services/ring-mqtt.nix), which translates Ring's protocol into RTSP.
        #
        # Port 8555, not 8554: our own go2rtc (below) already owns 8554 on this
        # host, so ring-mqtt's gateway is published one port over. Reached via
        # host.docker.internal because both containers are bridged and neither
        # can see the other's loopback.
        #
        # TODO: replace <RING_DEVICE_ID> with the real Ring device id. Get it
        # from `docker logs ring-mqtt` after completing the account link — see
        # the runbook in services/ring-mqtt.nix.
        back_door:
          - rtsp://frigate:frigate@host.docker.internal:8555/<RING_DEVICE_ID>_live

        # ── Front door: Nest doorbell ─────────────────────────────────────────
        # Deliberately NOT a `nest:` source, even though this go2rtc supports
        # one. The Nest stream is produced by the standalone go2rtc container in
        # services/go2rtc.nix and arrives here as ordinary RTSP.
        #
        # Frigate 0.17.2 bundles go2rtc v1.9.10, and the `preload` setting that
        # makes a Nest doorbell usable only exists from v1.9.11. Without it the
        # consumer binds to a video track that Nest abandons during its initial
        # WebRTC renegotiation, and ffmpeg dies with "Video: h264, none ...
        # unspecified size" forever. The full diagnosis is in the seeded config
        # in services/go2rtc.nix.
        #
        # Plain RTSP in, so nothing here has to care about WebRTC sessions,
        # token refresh, or track renegotiation — that all stays on the far side
        # of this hop, held stable by preload.
        front_door:
          - rtsp://host.docker.internal:8556/front_door

    cameras:
      # ── Back door: Ring doorbell ───────────────────────────────────────────
      # Ships DISABLED on purpose, and is meant to stay that way at rest. This
      # is not a "fill in the URL and flip it to true" placeholder.
      #
      # Ring suppresses motion and ding events for as long as a stream is
      # open, so a permanently-enabled Frigate camera here would silently kill
      # doorbell notifications — plus drain the battery and risk overheating
      # the device. Instead, a Home Assistant automation flips this camera on
      # for ~3 minutes when ring-mqtt reports a ding or motion, by publishing
      # to frigate/back_door/enabled/set. The automation is in the runbook in
      # services/ring-mqtt.nix.
      #
      # Frigate does not start ffmpeg for a disabled camera, so the unresolved
      # <RING_DEVICE_ID> placeholder above will not stop Frigate booting.
      back_door:
        enabled: false
        ffmpeg:
          output_args:
            # Ring sends Opus audio. mp4 can technically carry Opus but few
            # players will touch it, so transcode to AAC rather than using the
            # copy preset.
            record: preset-record-generic-audio-aac
          # Pull from the go2rtc restream, not ring-mqtt directly — that keeps
          # exactly one Ring session open no matter how many things are
          # watching, which matters a lot given Ring's session limits.
          inputs:
            - path: rtsp://127.0.0.1:8554/back_door
              input_args: preset-rtsp-restream
              roles:
                - detect
                - record
        detect:
          enabled: true
          # width/height are deliberately omitted — they are optional and
          # Frigate auto-detects them from the stream. Hardcoding a guess is
          # actively worse than omitting: a mismatch makes Frigate rescale
          # every single frame. That matters here because Ring models vary a
          # lot (the 1080p doorbells are 16:9, the Pro 2 and friends use a
          # square 1536x1536 sensor).
          #
          # If Frigate ever HANGS on startup for this camera, that is the known
          # 0.17 case of a camera not advertising its resolution properly — set
          # them explicitly then, to whatever ffprobe reports, and not before.
          fps: 5
        objects:
          track:
            - person
            - dog
            - cat
        record:
          enabled: true
          # No continuous recording — there is no continuous stream to record.
          continuous:
            days: 0
          alerts:
            retain:
              days: 14
          detections:
            retain:
              days: 14
        snapshots:
          enabled: true
          retain:
            default: 14

      # ── Front door: Nest doorbell (wired) ──────────────────────────────────
      # Runs continuously, unlike the Ring above, and that is safe here for two
      # independent reasons:
      #
      #   * Mains power, so there is no battery to flatten.
      #   * The wired doorbell supports SDM's ExtendWebRtcStream command, so
      #     go2rtc renews the 5-minute WebRTC session in place and the stream
      #     survives indefinitely. The BATTERY doorbell cannot do this at all —
      #     Google's docs are explicit that its streams can only be stopped and
      #     regenerated — which is what makes that model such a poor Frigate
      #     citizen and this one a reasonable choice.
      #
      # Nest does not suppress motion events while streaming the way Ring does,
      # so there is no reason to gate this behind an automation.
      front_door:
        enabled: true
        ffmpeg:
          output_args:
            # Nest also sends Opus; same reasoning as the Ring above.
            record: preset-record-generic-audio-aac
          inputs:
            - path: rtsp://127.0.0.1:8554/front_door
              # Not preset-rtsp-restream: the WebRTC-backed stream needs a
              # longer probe before ffmpeg commits to a format, and a generous
              # socket timeout so a mid-session WebRTC renegotiation is not
              # treated as the stream dying. Spelled as a list rather than a
              # string so there is no dependence on how Frigate word-splits it.
              #
              # analyzeduration is 10s — the unit is MICROseconds, so 10M, not
              # 10 megabytes. Treat this as insurance for the first connect
              # after a restart, NOT as the fix for anything: the original
              # "Could not find codec parameters ... unspecified size" failure
              # was a track-binding bug in go2rtc and no probe window ever
              # solved it. That story is in services/go2rtc.nix.
              #
              # Do not raise it much past 10s regardless. Frigate's own watchdog
              # kills ffmpeg after 20s without a frame, so a longer probe only
              # guarantees the watchdog reaps the process mid-probe. Raising it
              # this far is otherwise free — analyzeduration is a ceiling, not
              # a fixed wait, so a warm stream starts as fast as it ever did.
              input_args:
                - -rtsp_transport
                - tcp
                - -analyzeduration
                - 10M
                - -probesize
                - 10M
                - -timeout
                - "60000000"
              roles:
                - detect
                - record
        detect:
          enabled: true
          # SDM exposes no lower-resolution substream, so detection runs on the
          # full-size frame either way.
          #
          # width/height omitted on purpose — optional, and Frigate auto-detects
          # from the stream. Worth leaving alone here in particular: Nest
          # doorbells are tall-aspect (commonly 1600x1200), so any 16:9 guess
          # would be wrong and would cost a rescale on every frame. See the
          # matching note on back_door for the one case that needs them set.
          fps: 5
        objects:
          track:
            - person
            - dog
            - cat
        record:
          enabled: true
          # Bump this once you trust the stream — a wired doorbell can happily
          # do continuous recording, it just costs pool space.
          continuous:
            days: 0
          alerts:
            retain:
              days: 14
          detections:
            retain:
              days: 14
        snapshots:
          enabled: true
          retain:
            default: 14
  '';
in {
  # ── Frigate NVR ───────────────────────────────────────────────────────────────
  # Object-detection NVR for the RTSP cameras, running from the upstream
  # container image (nixpkgs' services.frigate builds without the TensorRT/ONNX
  # GPU runtime, and upstream only supports the container anyway). Pinned to an
  # exact patch release rather than `stable` for the same reason as immich: under
  # oci-containers a floating tag never changes the systemd unit, so it would
  # neither auto-update nor stay reproducible.
  #
  # Home Assistant consumes this through the HACS "Frigate" integration pointed
  # at http://127.0.0.1:5000, plus the MQTT broker in mqtt.nix — the integration
  # requires both. HA is host-networked too, so loopback reaches this directly.
  virtualisation.oci-containers.containers.frigate = {
    image = "ghcr.io/blakeblackshear/frigate:0.17.2-tensorrt";
    autoStart = true;

    volumes = [
      "${stateDir}/config:/config"
      "${stateDir}/media:/media/frigate"
      "/etc/localtime:/etc/localtime:ro"
    ];

    environment.TZ = "America/New_York";

    # Bridge networking with every port bound to loopback. Do NOT switch this to
    # --network=host: br0 is in networking.firewall.trustedInterfaces, so a
    # host-networked container has ALL its ports reachable from the LAN no matter
    # what allowedTCPPorts says — which would publish the completely
    # unauthenticated API on :5000 to every device on the network. Binding to
    # 127.0.0.1 is how calibre-desktop, open-webui and ollama stay private on
    # this host, and it is the only thing that actually works here.
    ports = [
      "127.0.0.1:5000:5000"  # unauthenticated internal API — for the HA integration
      "127.0.0.1:8971:8971"  # authenticated UI/API — nginx proxies to this one
      "127.0.0.1:8554:8554"  # go2rtc RTSP restream — consumed by HA on this host
      # go2rtc's own web UI. Unauthenticated, hence loopback like :5000, but
      # worth having published: for the cloud-brokered doorbells it is the only
      # place that shows *why* a stream failed (expired Nest token, Ring session
      # refused) instead of a generic ffmpeg read error.
      "127.0.0.1:1984:1984"
    ];

    extraOptions = [
      # Bridged containers can't see the host's loopback, so the MQTT broker is
      # reached over the docker gateway instead. See mqtt.nix for the matching
      # listener; the seeded config points at `host.docker.internal`.
      "--add-host=host.docker.internal:host-gateway"
      # CDI device injection, set up by hardware.nvidia-container-toolkit below.
      # Gives the container NVDEC for ffmpeg decoding and CUDA/TensorRT for the
      # optional ONNX detector.
      "--device=nvidia.com/gpu=all"
      # Frigate keeps raw decoded frames in /dev/shm; the 64m Docker default is
      # far too small and shows up as decode errors under load.
      "--shm-size=256m"
      # Recording segments are written here before being remuxed into
      # /media/frigate. Keeping it in RAM spares the pool a lot of small writes.
      "--tmpfs=/tmp/cache:size=1g"
    ];
  };

  # Generates CDI specs under /var/run/cdi and turns on Docker's `cdi` feature,
  # which is what makes --device=nvidia.com/gpu=all resolve. The module asserts
  # that the nvidia driver is present — satisfied by services.xserver.videoDrivers
  # in hardware-configuration.nix.
  hardware.nvidia-container-toolkit.enable = true;

  # `C` copies only when the destination does not already exist, so this seeds a
  # working config on first boot and then leaves Frigate's own edits alone.
  # The model_cache dir is where an exported ONNX model goes (see seedConfig).
  # The parent /Data/smb/Internal/Services/frigate dir is created in
  # permissions.nix alongside every other service's state dir.
  systemd.tmpfiles.rules = [
    "d ${stateDir}/config             0750 root root -"
    "d ${stateDir}/config/model_cache 0750 root root -"
    "d ${stateDir}/media              0750 root root -"
    "C ${stateDir}/config/config.yml  0640 root root - ${seedConfig}"
  ];

  services.nginx.virtualHosts."frigate.nasa.jmalexan.com" = ssl // {
    serverAliases = [ "frigate" ];
    extraConfig = ''
      # Live view and the event clip player hold long-lived connections, and
      # buffering a video stream through nginx just adds latency.
      proxy_buffering    off;
      proxy_read_timeout 600s;
      proxy_send_timeout 600s;
    '';
    locations."/" = {
      # 8971 is the authenticated port; Frigate's own login guards it. Never
      # proxy 5000 here — that one has no auth at all.
      proxyPass       = "http://127.0.0.1:8971";
      proxyWebsockets = true;
    };
  };

  # ── ⚠️  Applying camera changes to an ALREADY-DEPLOYED host ───────────────────
  #
  # The tmpfiles rule above is `C` (copy-if-absent). Once Frigate has booted on
  # this host even once, config.yml exists and NIXOS WILL NEVER OVERWRITE IT.
  # Editing seedConfig in this file therefore has no effect on a running NAS —
  # it only changes what a rebuilt-from-scratch host would start with.
  #
  # That is deliberate (Frigate rewrites config.yml itself from the UI editor),
  # but it means the camera blocks above must be mirrored onto the live host.
  #
  # PREFER THE FRIGATE UI for this — Settings, then the raw YAML editor. It
  # validates before it will restart, which matters more than convenience here:
  # an invalid config sends Frigate into safe mode, and safe mode used to force
  # record retention to 0 days and wipe recordings while you debugged. That bug
  # was fixed in 0.17.1 and this host is pinned to 0.17.2, so it is no longer a
  # live hazard — but hand-editing the file still bypasses the one check that
  # stops a typo from taking the NVR down. Use the editor.
  #
  # If you do edit on disk, take a backup first and restart explicitly:
  #
  #   sudo cp /Data/smb/Internal/Services/frigate/config/config.yml{,.bak}
  #   sudo $EDITOR /Data/smb/Internal/Services/frigate/config/config.yml
  #   sudo systemctl restart docker-frigate
  #
  # Note that go2rtc stream changes always need a full restart either way —
  # go2rtc runs as a child process configured at Frigate startup. Camera, zone
  # and mask edits do apply live in 0.17.
  #
  # Keeping the two in sync by hand is the cost of a UI-editable config. If they
  # ever drift badly, delete config.yml and let the seed re-copy on restart —
  # but that discards any masks/zones drawn in the UI.
  #
  # ── Nest credentials runbook ──────────────────────────────────────────────────
  #
  # The Home Assistant Nest integration is ALREADY SET UP on this host, and it
  # needed the exact same five values. So there is nothing to register and
  # nothing to pay for — lift the credentials out of HA rather than repeating
  # the Device Access / Google Cloud dance.
  #
  # They go in the NAS copy of config.yml, NOT in this file: client_secret and
  # refresh_token are live credentials and this repo is committed to git. (Same
  # reasoning as the note at the top of seedConfig.)
  #
  # ⚠️  Do NOT "simplify" this to go2rtc's hass:// source.
  # It looks like the obvious move — point go2rtc at the camera entity HA
  # already has and skip the credentials entirely — and it is a trap. The
  # hass:// source hands Frigate a raw SDM stream URL, and the Nest API only
  # issues those for 5 minutes with no renewal. Upstream's wording is blunt:
  # "Do not use this with Frigate! If the stream expires, Frigate will consume
  # all available RAM on your machine within seconds." The nest:// source
  # configured above exists precisely because it extends the session before it
  # expires. Same reason rules out felipecrs/hass-expose-camera-stream-source,
  # which explicitly does not support Google-Home-migrated (WebRTC) Nest cams.
  #
  # Extract the values from HA's config dir
  # (/Data/smb/Internal/Services/homeassistant/config):
  #
  # 1. project_id + refresh_token, from the Nest config entry:
  #
  #      sudo jq -r '.data.entries[] | select(.domain=="nest") | .data
  #                  | {project_id, refresh_token: .token.refresh_token}' \
  #        .storage/core.config_entries
  #
  # 2. client_id + client_secret. Modern HA keeps these in the Application
  #    Credentials store, not the config entry:
  #
  #      sudo jq -r '.data.items[] | select(.domain=="nest")
  #                  | {client_id, client_secret}' \
  #        .storage/application_credentials
  #
  #    (Older HA releases inlined these in the config entry instead, so if that
  #    file has no nest item, re-run the step 1 query without the field filter
  #    and look for client_id/client_secret in the entry data.)
  #
  # 3. device_id — ask the API rather than guessing, since HA's device registry
  #    stores the fully-qualified name and go2rtc wants only the last segment:
  #
  #      ACCESS=$(curl -s -X POST https://oauth2.googleapis.com/token \
  #        -d client_id=<CLIENT_ID> -d client_secret=<CLIENT_SECRET> \
  #        -d refresh_token=<REFRESH_TOKEN> -d grant_type=refresh_token \
  #        | jq -r .access_token)
  #      curl -s -H "Authorization: Bearer $ACCESS" \
  #        "https://smartdevicemanagement.googleapis.com/v1/enterprises/<PROJECT_ID>/devices" \
  #        | jq -r '.devices[] | "\(.type)\t\(.name)\t\(
  #            .traits."sdm.devices.traits.CameraLiveStream".supportedProtocols)"'
  #
  #    Take the trailing segment of `name` (after .../devices/).
  #
  #    The third column is the authoritative answer to WEB_RTC vs RTSP — do not
  #    infer it from the model. Expect ["WEB_RTC"] for this doorbell; if it
  #    unexpectedly reports ["RTSP"], the device is still on the legacy Nest
  #    app, and switching the stream above to protocols=RTSP is worth doing
  #    (plain RTSP needs no session renewal at all).
  #
  # Notes on sharing one refresh token between HA and go2rtc:
  #  - It works. Google does not rotate refresh tokens on use, so both clients
  #    can hold the same one indefinitely; go2rtc's copy is an independent
  #    snapshot and will keep working even if HA later re-authenticates.
  #  - Revoking the app's access in the Google account, or deleting the OAuth
  #    client, kills BOTH at once. That is the intended blast radius.
  #  - If the OAuth consent screen is still in "Testing", Google expires the
  #    refresh token after 7 days and both HA and this stream die weekly. Since
  #    the HA integration has been running longer than that, it is presumably
  #    already "In production" — worth confirming while you are in the console.
  #  - Both clients now poll the same SDM project, so the API quota is shared.
  #    It is generous for two consumers, but if streams start failing with 429s
  #    this is where to look first.
  #
  # Keep the HA integration regardless of Frigate: go2rtc supplies pixels, but
  # only HA delivers the doorbell-press event over Pub/Sub — and a press is not
  # a motion event, so Frigate alone will never tell you someone rang the bell.
  #
  # Verify before wiring Frigate up — go2rtc's own UI at http://127.0.0.1:1984
  # (ssh -N -L 1984:127.0.0.1:1984 nasa) will show the stream and any auth error
  # far more legibly than Frigate's ffmpeg logs will.
}
