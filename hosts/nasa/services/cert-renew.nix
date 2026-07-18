{ config, lib, pkgs, ... }: let
  certDir = "/var/lib/nginx/certs";
  caCert  = ../certs/ca.crt;
  caKey   = config.age.secrets.step-ca-key.path;

  subject = "/CN=nasa.jmalexan.com/O=Personal/C=US/ST=Pennsylvania/L=Pittsburgh/emailAddress=me@jmalexan.com";

  # ── SAN list ───────────────────────────────────────────────────────────────
  # Derived from the actual nginx vhost config so adding a virtualHost (or a
  # serverAlias) automatically extends the cert on next rebuild. The renew
  # script below also re-issues if this list drifts from the cert in place,
  # so changes propagate without manually deleting server.crt.
  vhostNames = lib.flatten (lib.mapAttrsToList
    (name: v: [ name ] ++ (v.serverAliases or []))
    config.services.nginx.virtualHosts);

  # Names that aren't tied to a local vhost (other hosts, future services,
  # the wildcard, the apex).
  extraNames = [
    "nasa.jmalexan.com" "*.nasa.jmalexan.com"
    "plex" "ddns" "truenas" "romm" "cobalt" "lyrion"
    "tmm" "komga" "calibre-web" "open-webui" "freshrss"
  ];

  sanNames = lib.unique (extraNames ++ vhostNames);
  sanList  = lib.concatMapStringsSep "," (n: "DNS:${n}") sanNames;

  sanExt = pkgs.writeText "cert-san.ext" ''
    authorityKeyIdentifier = keyid, issuer
    basicConstraints = CA:FALSE
    keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
    subjectAltName = ${sanList}
  '';

in {
  # Trust our private CA host-wide so internal services (Music Assistant,
  # scripts, anything using OpenSSL/Python) can verify certs issued by it.
  security.pki.certificateFiles = [ caCert ];

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
      need_renew=0

      # Reason 1: cert missing or expiring within 30 days.
      if ! ${pkgs.openssl}/bin/openssl x509 -checkend 2592000 \
           -in ${certDir}/server.crt 2>/dev/null; then
        echo "Cert missing or near expiry — will renew."
        need_renew=1
      fi

      # Reason 2: SAN list differs from what the cert currently has.
      desired=$(printf '%s\n' ${lib.escapeShellArgs sanNames} | sort -u)
      current=$(${pkgs.openssl}/bin/openssl x509 -in ${certDir}/server.crt \
                  -noout -ext subjectAltName 2>/dev/null \
                | ${pkgs.gnugrep}/bin/grep -oE 'DNS:[^,[:space:]]+' \
                | ${pkgs.gnused}/bin/sed 's/^DNS://' \
                | sort -u || true)

      if [ "$desired" != "$current" ]; then
        echo "SAN list changed — will renew."
        need_renew=1
      fi

      if [ "$need_renew" -eq 0 ]; then
        echo "Certificate is valid and SAN list unchanged, skipping renewal."
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
