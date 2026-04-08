{ ... }: {
  services.nginx = {
    enable = true;

    recommendedGzipSettings  = true;
    recommendedOptimisation  = true;
    recommendedProxySettings = true;
    recommendedTlsSettings   = true;

    virtualHosts = {
      "immich.nasa.jmalexan.com" = {
        serverAliases = [ "immich" ];
        forceSSL          = true;
        sslCertificate    = "/var/lib/nginx/certs/server.crt";
        sslCertificateKey = "/var/lib/nginx/certs/server.key";
        extraConfig = ''
          client_max_body_size 50000M;
          proxy_read_timeout   600s;
          proxy_send_timeout   600s;
          send_timeout         600s;
        '';
        locations."/" = {
          proxyPass       = "http://localhost:2283";
          proxyWebsockets = true;
        };
      };

      "jellyfin.nasa.jmalexan.com" = {
        serverAliases = [ "jellyfin" ];
        forceSSL          = true;
        sslCertificate    = "/var/lib/nginx/certs/server.crt";
        sslCertificateKey = "/var/lib/nginx/certs/server.key";
        locations."/" = {
          proxyPass       = "http://localhost:8096";
          proxyWebsockets = true;
        };
      };

      "homeassistant.nasa.jmalexan.com" = {
        serverAliases = [ "homeassistant" ];
        forceSSL          = true;
        sslCertificate    = "/var/lib/nginx/certs/server.crt";
        sslCertificateKey = "/var/lib/nginx/certs/server.key";
        locations."/" = {
          proxyPass       = "http://localhost:8123";
          proxyWebsockets = true;
        };
      };

      "qbittorrent.nasa.jmalexan.com" = {
        serverAliases = [ "torrent.nasa.jmalexan.com" "qbittorrent" "torrent" ];
        forceSSL          = true;
        sslCertificate    = "/var/lib/nginx/certs/server.crt";
        sslCertificateKey = "/var/lib/nginx/certs/server.key";
        locations."/" = {
          proxyPass = "http://localhost:8080";
          # qBittorrent's CSRF check requires Host to match the upstream, not
          # the client-facing hostname.
          extraConfig = ''
            proxy_http_version 1.1;
            proxy_set_header   Host               $proxy_host;
            proxy_set_header   X-Forwarded-For    $proxy_add_x_forwarded_for;
            proxy_set_header   X-Forwarded-Host   $http_host;
            proxy_set_header   X-Forwarded-Proto  $scheme;
          '';
        };
      };
    };
  };

  networking.firewall.allowedTCPPorts = [ 80 443 ];
}
