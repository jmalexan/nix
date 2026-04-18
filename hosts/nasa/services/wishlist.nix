{ pkgs, lib, ... }:

let
  authorizedKeys = import ../../../users/authorized-keys.nix;

  # Wishlist server settings only — no items list here.
  # Hosts are loaded from /home/jmalexan/.ssh/config (managed by home-manager).
  # public-keys takes a list of raw key strings (not file paths).
  wishlistConfig = pkgs.writeText "wishlist.yaml" (''
    listen: 0.0.0.0
    port: 2222
    public-keys:
  '' + lib.concatMapStrings (k: "      - ${k}\n") authorizedKeys + ''
    endpoints:
      - name: "nasa (local shell)"
        address: localhost:22
        user: jmalexan
      - name: home
        address: home.nasa.lan:22
        user: jmalexan
      - name: pihole
        address: pihole.lan:22
        user: jmalexan
  '');
in
{
  environment.systemPackages = [ pkgs.wishlist ];

  systemd.services.wishlist = {
    description = "Wishlist SSH bastion menu";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      ExecStart = "${pkgs.wishlist}/bin/wishlist serve --config ${wishlistConfig}";
      User = "jmalexan";
      # Wishlist generates and persists its SSH host keys here on first start.
      StateDirectory = "wishlist";
      WorkingDirectory = "/var/lib/wishlist";
      Restart = "on-failure";
    };
  };

  # Wishlist listens on 2222 so it doesn't conflict with sshd on 22.
  networking.firewall.allowedTCPPorts = [ 2222 ];
}
