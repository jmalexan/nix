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
        # Also cloud-only. Google's Smart Device Management (SDM) API hands out
        # a WebRTC stream, which go2rtc terminates and re-offers as RTSP. The
        # SDM WebRTC session expires every ~5 minutes; go2rtc renews it, which
        # is the whole reason for using its native `nest:` source rather than
        # trying to plumb the Home Assistant camera entity into Frigate.
        #
        # TODO: fill in the five credentials — see the runbook at the bottom of
        # this file. protocols=WEB_RTC is correct for the battery Nest Doorbell
        # and the 2nd-gen wired one (anything managed by the Google Home app).
        # A 1st-gen wired Nest Hello still on the old Nest app can use
        # protocols=RTSP instead, which is markedly more stable if it applies.
        front_door:
          - nest:?client_id=<CLIENT_ID>&client_secret=<CLIENT_SECRET>&refresh_token=<REFRESH_TOKEN>&project_id=<PROJECT_ID>&device_id=<DEVICE_ID>&protocols=WEB_RTC&video=h264&audio=opus

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
          # TODO: match to the stream's real resolution or Frigate rescales
          # every frame. Ring models differ — the 1080p doorbells are
          # 1920x1080, but the Pro 2 and similar use a square 1536x1536 sensor.
          # Check with ffprobe against the go2rtc path once it is up.
          width: 1920
          height: 1080
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

      # ── Front door: Nest doorbell ──────────────────────────────────────────
      # Enabled continuously, which is fine for a WIRED Nest doorbell. If this
      # is the BATTERY model, do not leave it like this: SDM live streaming
      # flattens that battery in days. Give it the same treatment as the Ring
      # above — set `enabled: false` and drive it from an HA automation on the
      # Nest integration's doorbell/motion events.
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
              input_args:
                - -rtsp_transport
                - tcp
                - -analyzeduration
                - 5M
                - -probesize
                - 5M
                - -timeout
                - "60000000"
              roles:
                - detect
                - record
        detect:
          enabled: true
          # SDM exposes no lower-resolution substream, so detection runs on the
          # full-size frame. TODO: confirm with ffprobe — Nest doorbells are
          # tall-aspect (e.g. 1600x1200), not 16:9.
          width: 1920
          height: 1080
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
  # but it means the camera blocks above must be mirrored by hand:
  #
  #   sudo cp /Data/smb/Internal/Services/frigate/config/config.yml{,.bak}
  #   sudo $EDITOR /Data/smb/Internal/Services/frigate/config/config.yml
  #   sudo systemctl restart docker-frigate
  #
  # Keeping the two in sync by hand is the cost of a UI-editable config. If they
  # ever drift badly, delete config.yml and let the seed re-copy on restart —
  # but that discards any masks/zones drawn in the UI.
  #
  # ── Nest credentials runbook ──────────────────────────────────────────────────
  #
  # The five values in the `front_door` go2rtc stream go in the NAS copy of
  # config.yml, NOT in this file — client_secret and refresh_token are live
  # credentials and this repo is committed to git. (Same reasoning as the note
  # at the top of seedConfig.)
  #
  # Google gates Nest camera access behind the Smart Device Management API, and
  # there is no way around it — no local RTSP, no ONVIF. Expect ~30 minutes:
  #
  # 1. Device Access Console (https://console.nest.google.com/device-access):
  #    accept the terms and pay the one-time US$5 registration fee. This
  #    requires a PERSONAL Google account — Workspace accounts cannot complete
  #    the OAuth flow at all, so use the gmail.com account that owns the
  #    doorbell. Note the Project ID it issues -> project_id.
  #
  # 2. Google Cloud Console: create a project, enable the "Smart Device
  #    Management API", and create an OAuth 2.0 Client ID of type "Web
  #    application" -> client_id and client_secret.
  #
  #    Set the OAuth consent screen's Publishing Status to "In production".
  #    Left "In testing", Google expires the refresh token after 7 DAYS and the
  #    stream dies every week — this is the single most common way this setup
  #    rots. It does not require Google verification for personal use.
  #
  # 3. Run the OAuth flow once to exchange an authorisation code for a refresh
  #    token -> refresh_token. The Home Assistant Nest docs walk through this
  #    step by step: https://www.home-assistant.io/integrations/nest/
  #
  # 4. Get device_id by listing the devices on the project:
  #
  #      curl -H "Authorization: Bearer <access_token>" \
  #        "https://smartdevicemanagement.googleapis.com/v1/enterprises/<project_id>/devices"
  #
  #    Use the trailing segment of the device's `name` field.
  #
  # 5. Do step 1-3 ONCE and reuse the same project for the Home Assistant Nest
  #    integration — it wants the identical client_id/client_secret/project_id.
  #    Set HA up too: go2rtc gives Frigate pixels, but only the HA integration
  #    delivers the doorbell-press event, and a press is not a motion event.
  #    Pub/Sub is required for those events to arrive in real time; HA's config
  #    flow provisions the subscription for you.
  #
  # Verify before wiring Frigate up — go2rtc's own UI at http://127.0.0.1:1984
  # (ssh -N -L 1984:127.0.0.1:1984 nasa) will show the stream and any auth error
  # far more legibly than Frigate's ffmpeg logs will.
}
