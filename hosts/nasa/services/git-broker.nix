{
  config,
  lib,
  vars,
  ...
}:
let
  cfg = config.services.gitBroker;
in
{
  imports = [ ../../../modules/git-broker.nix ];
  # Intentionally disabled until a repository and host-only credential are selected.
  config = lib.mkIf cfg.enable {
    services.nginx.virtualHosts."git-broker.${vars.nasa.domain}" = {
      forceSSL = true;
      sslCertificate = "/var/lib/nginx/certs/server.crt";
      sslCertificateKey = "/var/lib/nginx/certs/server.key";
      extraConfig = ''
        allow 10.200.201.2;
        allow ${vars.nasa.lanSubnet};
        allow 100.64.0.0/10;
        allow 127.0.0.1;
        deny all;
        client_max_body_size ${toString cfg.maxBundleBytes};
        proxy_read_timeout 240s;
      '';
      locations."/".proxyPass = "http://127.0.0.1:${toString cfg.port}";
    };
  };
}
