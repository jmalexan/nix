{ pkgs, config, ... }: let
  stateDir = "/Data/smb/Internal/Services/eufy-security-ws";

  # Label this bridge shows up as in the eufy app's "trusted devices" list
  # (Account → Security → Devices). Naming it after the host is what lets you
  # tell this session apart from a real phone when revoking access.
  trustedDeviceName = "nasa-home-assistant";

  # ISO 3166-1 alpha-2. NOT a cosmetic setting: it picks which regional eufy
  # cloud the bridge logs into, and an account registered in one region is
  # invisible from another. A wrong value here looks exactly like "the
  # integration found no devices", so it lives in plain sight rather than
  # inside the encrypted env file.
  country = "US";
in {
  # ── eufy-security-ws ──────────────────────────────────────────────────────────
  # Bridges eufy Security devices (cameras, doorbells, locks, entry sensors)
  # into Home Assistant. Same shape as ring-mqtt.nix on this host: eufy exposes
  # no local API of any kind, so a translation layer speaks their proprietary
  # cloud + P2P protocol and re-publishes it as something HA can consume.
  #
  # The moving parts, because this one is unusually indirect:
  #
  #   eufy cloud ──push──┐
  #                      ├──► eufy-security-ws (this container, :3000)
  #   station ──P2P/UDP──┘              │  websocket
  #                                     ▼
  #                          HA + eufy_security integration (HACS)
  #                                     │  raw H264 bytes over HTTP POST
  #                                     ▼
  #                          go2rtc (services/go2rtc.nix, on 127.0.0.2)
  #                                     │  rtsp://127.0.0.2:8554/<serial>
  #                                     ▼
  #                                 HA camera entity
  #
  # The HA-side half is a HACS integration, so it is installed through the HACS
  # UI (already set up on this host) rather than from here — this module only
  # provides the parts HACS cannot: the bridge container, the credentials, and
  # a go2rtc endpoint on an address the integration can actually be pointed at.
  # See the runbook at the bottom of this file.
  #
  # ⚠️  UPSTREAM DEPRECATION — READ BEFORE RELYING ON THIS
  # bropat/eufy-security-ws carries a loud deprecation notice: eufy is migrating
  # to the "eufy Mega" (5-in-1 app) backend and has already begun removing the
  # legacy APIs this library is built on. Push notifications were restored
  # against the new v6 backend as a stopgap, but anything still on a legacy
  # endpoint can break without warning, and the library stops working entirely
  # once the legacy API is switched off. A ground-up Mega-based integration is
  # in development across the HA/Homebridge/Homey communities. Treat everything
  # below as a stopgap with a finite shelf life, not a settled setup.
  #
  # ⚠️  A SECOND EUFY ACCOUNT IS REQUIRED
  # Every time this bridge starts it forces all other sessions on the account to
  # log off — including your phone. Do NOT put the primary account credentials
  # in the secret below. Instead create a second eufy account, share the home
  # with it *with admin rights*, log into the eufy app once as that account so
  # the devices materialise, and use those credentials here.
  age.secrets.eufy-credentials.file = ../../../secrets/eufy-credentials.age;

  virtualisation.oci-containers.containers.eufy-security-ws = {
    # Pinned exactly, like every other container on this host — under
    # oci-containers a floating tag never changes the systemd unit, so it would
    # neither auto-update nor stay reproducible.
    image = "bropat/eufy-security-ws:3.1.0";
    autoStart = true;

    volumes = [
      # persistentDir. Holds the login/refresh token and the P2P station cache,
      # so a restart does not re-trigger captcha/MFA.
      "${stateDir}:/data"
      "/etc/localtime:/etc/localtime:ro"
    ];

    # USERNAME and PASSWORD only — see the note above about COUNTRY.
    environmentFiles = [ config.age.secrets.eufy-credentials.path ];

    environment = {
      TZ                  = "America/New_York";
      COUNTRY             = country;
      PORT                = "3000";
      TRUSTED_DEVICE_NAME = trustedDeviceName;
      # How long a motion/person/ding event stays "on" in HA before it resets.
      # The upstream default is 10s; these are push events with no explicit
      # "cleared" message, so this value *is* the entity's on-duration.
      EVENT_DURATION_SECONDS = "10";
    };

    # Bridged with the websocket on loopback, for exactly the reason spelled out
    # in ring-mqtt.nix and go2rtc.nix: br0 is in
    # networking.firewall.trustedInterfaces, so a host-networked container
    # publishes every port to the whole LAN regardless of allowedTCPPorts. This
    # websocket is COMPLETELY UNAUTHENTICATED and is full control of the eufy
    # account — unlock the door, disarm the alarm, pull video. It must not be
    # reachable off this host. Home Assistant runs with host networking, so it
    # reaches it at 127.0.0.1:3000 either way.
    ports = [ "127.0.0.1:3000:3000" ];

    # ⚠️  The one thing bridging costs you: upstream recommends host networking
    # so the container can find stations by UDP broadcast. Bridged, that
    # broadcast does not reach the LAN and the bridge falls back to cloud
    # discovery — which works, but gives up direct local P2P. If local streaming
    # does not establish, DO NOT reach for --network=host (see above); pin the
    # station addresses instead, which is what STATION_IP_ADDRESSES exists for:
    #
    #   environment.STATION_IP_ADDRESSES = "T8010N1234567890:192.168.1.50";
    #
    # (serial:ip, semicolon-separated; serials are on the station label and in
    # the HA device page once the integration is up. Give the stations DHCP
    # reservations first, or the pin goes stale.)
    extraOptions = [
      # Consistent with the other bridged containers here; lets the config
      # reference host services later without surprise.
      "--add-host=host.docker.internal:host-gateway"
    ];
  };

  # Create the persistent dir from the container's OWN unit rather than a
  # systemd.tmpfiles rule, for the reason documented at length in ring-mqtt.nix:
  # on `nixos-rebuild switch` the container unit and
  # systemd-tmpfiles-resetup.service are pulled in with no ordering between
  # them, so a tmpfiles rule can lose the race. 0700 because this directory
  # holds the account's refresh token.
  systemd.services.docker-eufy-security-ws.preStart = ''
    ${pkgs.coreutils}/bin/install -d -m 0700 -o root -g root ${stateDir}
  '';

  # No networking.firewall entry on purpose, and no 172.17.0.1 publish either —
  # unlike the RTSP gateways in go2rtc.nix and ring-mqtt.nix, the consumer here
  # is Home Assistant, which runs with host networking. It reaches 127.0.0.1:3000
  # directly, so none of the docker0-gateway plumbing those two need applies.

  # ── One-time setup runbook ────────────────────────────────────────────────────
  #
  # 1. Fill in the credentials for the SECONDARY eufy account (see the warning
  #    above — using the primary account will log your phone out every restart):
  #
  #      agenix -e secrets/eufy-credentials.age
  #
  #    Until this is done the container crash-loops on a login failure, which is
  #    the intended, visible behaviour of the placeholder that ships in the repo.
  #
  # 2. In the eufy app, on the secondary account, turn ON every push
  #    notification type you care about (motion, person, doorbell ding, lock,
  #    alarm). This is not optional polish: the integration is push-driven, and
  #    an event with notifications disabled never reaches HA at all. The
  #    settings are per-device, not per-account.
  #
  # 3. Also in the app, set Streaming Quality and Streaming Codec to LOW on
  #    every camera. Upstream is emphatic about this — HA cannot keep up with
  #    the higher settings and you get a stream that never plays.
  #
  # 4. Deploy and watch it log in:
  #
  #      nixos-rebuild switch --flake .#nasa
  #      docker logs -f eufy-security-ws
  #
  #    Expect a captcha or MFA challenge on the first login. Those are answered
  #    from the HA side (step 6), not here — the bridge will sit waiting.
  #
  # 5. Install the integration through HACS:
  #      HACS → Integrations → search "Eufy Security" → Download → restart HA.
  #    It is in the HACS default index, so no custom repository is needed. Note
  #    there is no HACS integration named "Eufy Home" — that name belongs to the
  #    app; the other eufy lines are jeppesens/eufy-clean (vacuums, custom
  #    repository) and HA core's legacy `eufy` (plugs/bulbs/switches).
  #
  # 6. Settings → Devices & Services → Add Integration → "Eufy Security"
  #    (exactly that — plain "Eufy" is the unrelated legacy core integration).
  #      Host: 127.0.0.1     Port: 3000
  #    If it reports a captcha or MFA requirement, use Reconfigure: the captcha
  #    image renders in the dialog, and the MFA code is emailed/texted to the
  #    secondary account. Restart HA afterwards.
  #
  # 7. In the integration's Configure → options, set
  #
  #      rtsp_server_address = 127.0.0.2
  #
  #    ⚠️  This is the step that is easy to get wrong and hard to debug. The
  #    integration hard-codes go2rtc's ports (1984 for the API, 8554 for RTSP —
  #    see eufy_security_api/const.py) and lets you configure only the address.
  #    On this host 127.0.0.1:1984/:8554 is *Frigate's* bundled go2rtc, so the
  #    default would push eufy video into the wrong instance. services/go2rtc.nix
  #    therefore also publishes the standalone go2rtc on the loopback alias
  #    127.0.0.2 at go2rtc's default ports, purely so this field has something
  #    correct to point at. Leaving it at 127.0.0.1 fails in a confusing way:
  #    the stream appears to start and then no video ever arrives.
  #
  #    Cameras that support RTSP natively (a "continuous/NAS recording" option
  #    in the app) do not need go2rtc at all — the integration uses the camera's
  #    own RTSP URL and that path is considerably more reliable than P2P.
  #
  # 8. Streams do not start by themselves. Call `camera.turn_on` on the entity
  #    (and `camera.turn_off` to stop). P2P streams also drop occasionally; an
  #    off/on cycle restarts them, and the camera state (idle / preparing /
  #    streaming) is what to trigger automations on.
  #
  # ── Verifying ─────────────────────────────────────────────────────────────────
  #
  #   docker logs eufy-security-ws 2>&1 | grep -i 'connected\|captcha\|mfa\|error'
  #
  #   # the websocket itself (should list your devices):
  #   ssh -N -L 3000:127.0.0.1:3000 nasa
  #   websocat ws://127.0.0.1:3000  # then: {"messageId":"1","command":"start_listening"}
  #
  #   # once a stream is running, confirm it landed in the RIGHT go2rtc:
  #   ssh -N -L 1985:127.0.0.1:1985 nasa   # then http://127.0.0.1:1985
  #   # a stream named after the camera's serial should be present
}
