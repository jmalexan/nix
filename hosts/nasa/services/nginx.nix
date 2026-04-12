{ ... }: let
  ssl = {
    forceSSL          = true;
    sslCertificate    = "/var/lib/nginx/certs/server.crt";
    sslCertificateKey = "/var/lib/nginx/certs/server.key";
  };
in {
  services.nginx = {
    enable = true;

    recommendedGzipSettings  = true;
    recommendedOptimisation  = true;
    recommendedProxySettings = true;
    recommendedTlsSettings   = true;

    virtualHosts = {
      "immich.nasa.jmalexan.com" = ssl // {
        serverAliases = [ "immich" ];
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

      "jellyfin.nasa.jmalexan.com" = ssl // {
        serverAliases = [ "jellyfin" ];
        locations."/" = {
          proxyPass       = "http://localhost:8096";
          proxyWebsockets = true;
        };
      };

      "homeassistant.nasa.jmalexan.com" = ssl // {
        serverAliases = [ "homeassistant" ];
        locations."/" = {
          proxyPass       = "http://localhost:8123";
          proxyWebsockets = true;
        };
      };

      "prowlarr.nasa.jmalexan.com" = ssl // {
        serverAliases = [ "prowlarr" ];
        locations."/" = {
          proxyPass       = "http://localhost:9696";
          proxyWebsockets = true;
        };
      };

      "sonarr.nasa.jmalexan.com" = ssl // {
        serverAliases = [ "sonarr" ];
        locations."/" = {
          proxyPass       = "http://localhost:8989";
          proxyWebsockets = true;
        };
      };

      "radarr.nasa.jmalexan.com" = ssl // {
        serverAliases = [ "radarr" ];
        locations."/" = {
          proxyPass       = "http://localhost:7878";
          proxyWebsockets = true;
        };
      };

      "lidarr.nasa.jmalexan.com" = ssl // {
        serverAliases = [ "lidarr" ];
        locations."/" = {
          proxyPass       = "http://localhost:8686";
          proxyWebsockets = true;
        };
      };

      "qbittorrent.nasa.jmalexan.com" = ssl // {
        serverAliases = [ "torrent.nasa.jmalexan.com" "qbittorrent" "torrent" ];
        locations."/" = {
          # qbittorrent runs in the Mullvad network namespace; reach it via
          # the veth pair that bridges the namespace to the host.
          proxyPass = "http://10.200.200.2:8080";
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
