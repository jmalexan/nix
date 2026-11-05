{ config, ... }: {
  age.secrets.cloudflare-token = {
    file = ../../../secrets/cloudflare-token.age;
    # Decrypted at boot to /run/agenix/cloudflare-token (root-readable only)
  };

  # The upstream pre-start script runs as root and resolves $USER to install
  # the secret-bearing config for ddclient. Dynamic user lookup can fail while
  # NSS/systemd are being replaced during a switch. A static account keeps that
  # lookup available; DynamicUser still supplies the unit's sandboxing.
  users.groups.ddclient = { };
  users.users.ddclient = {
    isSystemUser = true;
    group = "ddclient";
  };

  services.ddclient = {
    enable = true;
    protocol = "cloudflare";
    zone = "jmalexan.com";
    username = "token"; # literal string for Cloudflare API token auth
    passwordFile = config.age.secrets.cloudflare-token.path;
    domains = [ "home.jmalexan.com" ];
    usev4 = "webv4, webv4=ipify-ipv4"; # detect public IPv4 via ipify
    ssl = true;
  };
}
