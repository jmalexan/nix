{
  config,
  lib,
  vars,
  pkgs,
  ...
}:
let
  cfg = config.services.gitBroker;
  platform = import ../../../apps/git-broker { inherit pkgs; };
in
{
  imports = [ ../../../modules/git-broker.nix ];
  # Intentionally disabled until the host-only upstream credential is provisioned.
  config = lib.mkIf cfg.enable {
    services.gitBroker = {
      repositoriesFile = config.age.secrets.git-broker-repositories.path;
      clientTokenFile = "/var/lib/microapp-secrets/git-broker/client";
      upstreamTokenFile = "/run/agenix/git-broker-upstream";
    };
    age.secrets.git-broker-repositories.file = ../../../secrets/git-broker-repositories.age;
    services.restic.backups.backblaze.paths = [ cfg.clientTokenFile ];
    systemd.services.git-broker-client-credential = {
      description = "Provision the local Git broker client credential";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        UMask = "0077";
      };
      environment.PYTHONPATH = "${../../../apps/git-broker}";
      script = "${platform.python}/bin/python -m git_broker.admin --path ${lib.escapeShellArg cfg.clientTokenFile}";
    };
    systemd.services.git-broker = {
      requires = [ "git-broker-client-credential.service" ];
      after = [ "git-broker-client-credential.service" ];
    };
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
