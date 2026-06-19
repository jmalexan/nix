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

      "bazarr.nasa.jmalexan.com" = ssl // {
        serverAliases = [ "bazarr" ];
        locations."/" = {
          proxyPass       = "http://localhost:6767";
          proxyWebsockets = true;
        };
      };

      "calibre.nasa.jmalexan.com" = ssl // {
        serverAliases = [ "calibre" ];
        # Kobo sync sends large JSON payloads in response headers; the
        # defaults cause "upstream sent too big header" errors.  Values
        # from the calibre-web Kobo integration wiki.
        extraConfig = ''
          proxy_buffer_size       1024k;
          proxy_buffers           4 512k;
          proxy_busy_buffers_size 1024k;
        '';
        locations."/" = {
          proxyPass       = "http://127.0.0.1:8083";
          proxyWebsockets = true;
          # X-Forwarded-Host is already set by recommendedProxySettings;
          # adding it here too causes WSGI to see "calibre, calibre" which
          # breaks calibre-web's download URL generation.
          # X-Scheme is needed because calibre-web's ReverseProxied middleware
          # reads HTTP_X_SCHEME (not HTTP_X_FORWARDED_PROTO) to set wsgi.url_scheme.
          extraConfig = ''
            proxy_set_header X-Scheme https;
          '';
        };
      };

      "calibre-desktop.nasa.jmalexan.com" = ssl // {
        serverAliases = [ "calibre-desktop" ];
        # Selkies streams large frames and uses websockets for the display
        # channel, clipboard, and file transfer.
        extraConfig = ''
          client_max_body_size  500M;
          proxy_buffer_size     1024k;
          proxy_buffers         4 512k;
          proxy_busy_buffers_size 1024k;
          proxy_read_timeout    3600s;
          proxy_send_timeout    3600s;
        '';
        locations."/" = {
          proxyPass       = "http://127.0.0.1:8085";
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

      "musicassistant.nasa.jmalexan.com" = ssl // {
        serverAliases = [ "musicassistant" ];
        locations."/" = {
          proxyPass       = "http://localhost:8095";
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
