{ config, pkgs, ... }: let
  certDir = "/var/lib/nginx/certs";
  caCert  = toString ../certs/ca.crt;
  caKey   = config.age.secrets.step-ca-key.path;

  subject = "/CN=nasa.jmalexan.com/O=Personal/C=US/ST=Pennsylvania/L=Pittsburgh/emailAddress=me@jmalexan.com";

  sanExt = pkgs.writeText "cert-san.ext" ''
    authorityKeyIdentifier = keyid, issuer
    basicConstraints = CA:FALSE
    keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
    subjectAltName = DNS:nasa.jmalexan.com,DNS:*.nasa.jmalexan.com,DNS:plex,DNS:qbittorrent,DNS:torrent,DNS:homeassistant,DNS:ddns,DNS:immich,DNS:truenas,DNS:romm,DNS:cobalt,DNS:lyrion,DNS:jellyfin,DNS:tmm,DNS:komga,DNS:calibre,DNS:calibre-web,DNS:open-webui,DNS:freshrss,DNS:sonarr,DNS:radarr,DNS:lidarr,DNS:prowlarr
  '';

in {
  age.secrets.step-ca-key = {
    file = ../../../secrets/step-ca-key.age;
    mode = "0400";
  };

  systemd.tmpfiles.rules = [
    "d ${certDir} 0750 root nginx -"
  ];

  systemd.services.cert-renew = {
    description = "Issue/renew nginx TLS certificate from local CA";
    # Run before nginx so certs exist on first boot.
    after    = [ "agenix.service" ];  # CA key must be decrypted first
    before   = [ "nginx.service" ];
    wantedBy = [ "nginx.service" ];
    serviceConfig = {
      Type = "oneshot";
      # CSR is temporary, key/cert go to certDir
      WorkingDirectory = certDir;
    };
    script = ''
      # Skip if the cert exists and won't expire within 30 days.
      if ${pkgs.openssl}/bin/openssl x509 -checkend 2592000 \
           -in ${certDir}/server.crt 2>/dev/null; then
        echo "Certificate is valid, skipping renewal."
        exit 0
      fi

      # -batch suppresses any interactive prompts that would block in a service.
      ${pkgs.openssl}/bin/openssl req -batch -nodes -newkey rsa:2048 \
        -keyout ${certDir}/server.key \
        -out    ${certDir}/server.csr \
        -subj   "${subject}"

      ${pkgs.openssl}/bin/openssl x509 -req \
        -in       ${certDir}/server.csr \
        -CA       ${caCert} \
        -CAkey    ${caKey} \
        -CAcreateserial \
        -CAserial ${certDir}/ca.srl \
        -days     365 \
        -out      ${certDir}/server.crt \
        -extfile  ${sanExt}

      rm -f ${certDir}/server.csr

      chown root:nginx ${certDir}/server.key ${certDir}/server.crt
      chmod 640        ${certDir}/server.key ${certDir}/server.crt

      # Reload nginx by signalling the master process directly — avoids calling
      # systemctl, which deadlocks when systemd holds a transaction lock on the
      # nginx→cert-renew dependency chain during boot.
      # If the PID file doesn't exist nginx isn't running yet and will pick up
      # the new cert when it starts normally.
      if [ -f /run/nginx/nginx.pid ]; then
        kill -HUP "$(cat /run/nginx/nginx.pid)" || true
      fi
    '';
  };

  systemd.timers.cert-renew = {
    description = "Renew nginx TLS certificate every 300 days";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # Fire 5 min after boot if overdue, then every 300 days (65-day buffer before expiry).
      OnBootSec        = "5min";
      OnUnitActiveSec  = "300d";
      Persistent       = true;
    };
  };
}
