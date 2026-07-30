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
    # This matters a lot for Eufy — those cameras allow very few simultaneous
    # RTSP clients before refusing new ones.
    go2rtc:
      streams:
        eufy:
          # TODO: replace with the real URL from the Eufy app
          # (camera -> Settings -> Storage -> NAS/RTSP). Via a HomeBase this is
          # usually rtsp://<user>:<pass>@<homebase-ip>:554/live0 ; a standalone
          # camera exposes its own IP and path instead.
          - rtsp://USER:PASSWORD@CAMERA-OR-HOMEBASE-IP:554/live0

    cameras:
      eufy:
        # Flip to true once the URL above is filled in. Frigate refuses to start
        # if a camera's stream can't be opened, so it ships disabled.
        enabled: false
        ffmpeg:
          output_args:
            # Frigate's default record preset passes -an, which silently drops
            # audio from every recording. This camera emits AAC, which is
            # already mp4-native, so it copies straight through with no
            # transcode. NOTE: a camera emitting PCM/G.711 instead would need
            # preset-record-generic-audio-aac — mp4 can't carry raw PCM.
            record: preset-record-generic-audio-copy
          # Pull from the go2rtc restream, not the camera directly.
          inputs:
            - path: rtsp://127.0.0.1:8554/eufy
              input_args: preset-rtsp-restream
              roles:
                - detect
                - record
                # Audio capture opens its own ffmpeg connection. Pointing it at
                # the restream rather than the camera is what upstream
                # recommends, and avoids a second client on the camera itself.
                - audio
        # Audio event detection (bark/speech/scream/yell/fire_alarm). Defaults to
        # false, and the toggle in the Frigate UI is runtime-only — Frigate
        # re-derives the baseline from this file on every start and only spawns
        # the audio process when it is true here. Setting it in the UI alone is
        # wiped by the next container restart.
        audio:
          enabled: true

        detect:
          # Same story: defaults to false, so without this line the camera gets
          # motion detection but no object tracking at all.
          enabled: true
          # Match these to the stream's real resolution, or Frigate will scale
          # every frame. 5fps is plenty for detection and keeps the queue short.
          width: 1920
          height: 1080
          fps: 5
        objects:
          track:
            - person
            - car
            - dog
            - cat
        record:
          enabled: true
          # Event-triggered recording rather than 24/7. This is the right
          # default for a battery camera (it simply has no continuous stream to
          # record), and keeps ZFS usage bounded. For a mains-powered camera,
          # set continuous.days to however many days you want to keep.
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
}
