{ config, ... }: {
  age.secrets.cloudflare-token = {
    file = ../../../secrets/cloudflare-token.age;
    # Decrypted at boot to /run/agenix/cloudflare-token (root-readable only)
  };

  services.ddclient = {
    enable = true;
    protocol = "cloudflare";
    zone = "jmalexan.com";
    username = "token";  # literal string for Cloudflare API token auth
    passwordFile = config.age.secrets.cloudflare-token.path;
    domains = [ "vpn.jmalexan.com" "nasa.jmalexan.com" ];
    usev4 = "web, web=ipify-ipv4";  # detect public IPv4 via ipify
    ssl = true;
  };
}
