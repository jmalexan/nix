{ config, vars, ... }:
let
  internalHost = name: "${name}.${vars.nasa.domain}";
  ssl = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx/certs/server.crt";
    sslCertificateKey = "/var/lib/nginx/certs/server.key";
  };

  # Streaming LLM responses need buffering off and long timeouts so tokens
  # reach the client live instead of being held by nginx.
  streamingProxy = ''
    proxy_buffering      off;
    proxy_read_timeout   600s;
    proxy_send_timeout   600s;
  '';
in
{
  # Public certificate issuance uses DNS-01, so neither certificate creation
  # nor renewal depends on forwarding WAN port 80. The existing Cloudflare
  # token is already restricted to root and used for DNS updates.
  security.acme = {
    acceptTerms = true;
    defaults.email = "me@jmalexan.com";
    certs."photos.jmalexan.com" = {
      dnsProvider = "cloudflare";
      group = "nginx";
      credentialFiles.CLOUDFLARE_DNS_API_TOKEN_FILE = config.age.secrets.cloudflare-token.path;
    };
  };

  services.nginx = {
    enable = true;

    recommendedGzipSettings = true;
    recommendedOptimisation = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;

    virtualHosts = {
      # The router maps public TCP 443 to this dedicated listener. Keeping it
      # off nginx's normal 443 listener prevents any private vhost from being
      # selected by a public request, regardless of its Host/SNI value.
      "photos.jmalexan.com" = {
        listen = [
          {
            addr = "0.0.0.0";
            port = 8443;
            ssl = true;
          }
        ];
        # This also tells the NixOS nginx module to render the certificate
        # directives; the explicit listen above still controls the sole port.
        onlySSL = true;
        useACMEHost = "photos.jmalexan.com";
        extraConfig = ''
          proxy_buffering    off;
          proxy_read_timeout 600s;
          proxy_send_timeout 600s;
          send_timeout       600s;

          add_header Strict-Transport-Security "max-age=31536000" always;
        '';
        locations."/" = {
          proxyPass = "http://127.0.0.1:2284";
        };
      };

      "${internalHost "immich"}" = ssl // {
        serverAliases = [ "immich" ];
        extraConfig = ''
          client_max_body_size 50000M;
          proxy_read_timeout   600s;
          proxy_send_timeout   600s;
          send_timeout         600s;
        '';
        locations."/" = {
          proxyPass = "http://127.0.0.1:2283";
          proxyWebsockets = true;
        };
      };

      "${internalHost "jellyfin"}" = ssl // {
        serverAliases = [ "jellyfin" ];
        locations."/" = {
          proxyPass = "http://127.0.0.1:8096";
          proxyWebsockets = true;
        };
      };

      "${internalHost "homeassistant"}" = ssl // {
        serverAliases = [ "homeassistant" ];
        # Home Assistant 2026.8 currently falls back to relative OAuth
        # endpoints behind this TLS-terminating proxy. Codex requires absolute
        # endpoint URLs, so serve only the discovery document here; the actual
        # authorization and token requests are still proxied to Home Assistant.
        locations."= /.well-known/oauth-authorization-server".extraConfig = ''
          default_type application/json;
          add_header Cache-Control "no-store";
          return 200 '{"authorization_endpoint":"https://${internalHost "homeassistant"}/auth/authorize","token_endpoint":"https://${internalHost "homeassistant"}/auth/token","revocation_endpoint":"https://${internalHost "homeassistant"}/auth/revoke","client_id_metadata_document_supported":true,"response_types_supported":["code"],"service_documentation":"https://developers.home-assistant.io/docs/auth_api"}';
        '';
        locations."/" = {
          proxyPass = "http://127.0.0.1:8123";
          proxyWebsockets = true;
        };
      };

      # Seerr runs on the host (not the Mullvad netns) and listens on 5055.
      "${internalHost "seerr"}" = ssl // {
        serverAliases = [ "seerr" ];
        locations."/" = {
          proxyPass = "http://127.0.0.1:5055";
          proxyWebsockets = true;
        };
      };

      # sonarr/radarr/lidarr/bazarr run inside the Mullvad network namespace
      # (see their service modules); reach them via the veth pair that bridges
      # the namespace to the host, exactly like qbittorrent below.
      #
      # Prowlarr is the exception: it runs on the host so that it shares an
      # egress IP with FlareSolverr (see prowlarr.nix for why).  It is still
      # addressed over the veth, but at the *host* end of the pair — it binds
      # 10.200.200.1 rather than a wildcard to stay off the trusted br0.
      "${internalHost "prowlarr"}" = ssl // {
        serverAliases = [ "prowlarr" ];
        locations."/" = {
          proxyPass = "http://${vars.nasa.hostVethIP}:9696";
          proxyWebsockets = true;
        };
      };

      "${internalHost "sonarr"}" = ssl // {
        serverAliases = [ "sonarr" ];
        locations."/" = {
          proxyPass = "http://${vars.nasa.namespaceVethIP}:8989";
          proxyWebsockets = true;
        };
      };

      "${internalHost "radarr"}" = ssl // {
        serverAliases = [ "radarr" ];
        locations."/" = {
          proxyPass = "http://${vars.nasa.namespaceVethIP}:7878";
          proxyWebsockets = true;
        };
      };

      "${internalHost "bazarr"}" = ssl // {
        serverAliases = [ "bazarr" ];
        locations."/" = {
          proxyPass = "http://${vars.nasa.namespaceVethIP}:6767";
          proxyWebsockets = true;
        };
      };

      "${internalHost "calibre"}" = ssl // {
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
          proxyPass = "http://127.0.0.1:8083";
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

      "${internalHost "calibre-desktop"}" = ssl // {
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
          proxyPass = "http://127.0.0.1:8085";
          proxyWebsockets = true;
        };
      };

      # Calibre's built-in content server is configured and started from the
      # desktop UI under Preferences → Sharing over the net.
      "${internalHost "calibre-content"}" = ssl // {
        serverAliases = [ "calibre-content" ];
        locations."/" = {
          proxyPass = "http://127.0.0.1:8081";
        };
      };

      "${internalHost "bookorbit"}" = ssl // {
        serverAliases = [ "bookorbit" ];
        extraConfig = ''
          client_max_body_size 2G;
          proxy_read_timeout   600s;
          proxy_send_timeout   600s;
        '';
        locations."/" = {
          proxyPass = "http://127.0.0.1:3001";
          proxyWebsockets = true;
        };
      };

      "${internalHost "lidarr"}" = ssl // {
        serverAliases = [ "lidarr" ];
        locations."/" = {
          proxyPass = "http://${vars.nasa.namespaceVethIP}:8686";
          proxyWebsockets = true;
        };
      };

      "${internalHost "musicassistant"}" = ssl // {
        serverAliases = [ "musicassistant" ];
        locations."/" = {
          proxyPass = "http://127.0.0.1:8095";
          proxyWebsockets = true;
        };
      };

      "${internalHost "qbittorrent"}" = ssl // {
        serverAliases = [
          (internalHost "torrent")
          "qbittorrent"
          "torrent"
        ];
        locations."/" = {
          # qbittorrent runs in the Mullvad network namespace; reach it via
          # the veth pair that bridges the namespace to the host.
          proxyPass = "http://${vars.nasa.namespaceVethIP}:8080";
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

      "${internalHost "frigate"}" = ssl // {
        serverAliases = [ "frigate" ];
        extraConfig = ''
          client_max_body_size 25M;
          proxy_buffering      off;
          proxy_read_timeout   600s;
          proxy_send_timeout   600s;
        '';
        locations."/" = {
          # 8971 is authenticated; Frigate's port 5000 is not.
          proxyPass = "http://127.0.0.1:8971";
          proxyWebsockets = true;
        };
      };

      "${internalHost "chat"}" = ssl // {
        serverAliases = [ "chat" ];
        extraConfig = streamingProxy;
        locations."/" = {
          proxyPass = "http://127.0.0.1:8093";
          proxyWebsockets = true;
        };
      };

      "${internalHost "ollama"}" = ssl // {
        serverAliases = [ "ollama" ];
        # Ollama's API is unauthenticated; admit only tailnet, LAN, and local
        # clients. Streaming responses must not be buffered.
        extraConfig = streamingProxy + ''
          client_max_body_size 50M;
          allow 100.64.0.0/10;
          allow 10.0.0.0/8;
          allow 127.0.0.1;
          deny  all;
        '';
        locations."/" = {
          proxyPass = "http://127.0.0.1:11434";
          # Ollama rejects the public Host header. The recommended proxy include
          # would overwrite this value, so spell out its forwarding headers.
          recommendedProxySettings = false;
          extraConfig = ''
            proxy_set_header Host localhost:11434;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
          '';
        };
      };
    };
  };

  networking.firewall.allowedTCPPorts = [
    80
    443
    8443
  ];
}
