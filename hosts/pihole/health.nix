# Run on the host after CI activation; use native FTL, not the CLI wrapper.
{ pkgs, ftl }:
pkgs.writeShellApplication {
  name = "pihole-health";
  runtimeInputs = [
    pkgs.systemd
    pkgs.dig
    pkgs.gnugrep
  ];
  text = ''
    # FTL synthesizes its web hostname using the queried interface's address.
    # Use the LAN endpoint so pihole.lan is checked as a LAN client sees it.
    systemctl is-active --quiet pihole-ftl.service
    dig +time=3 +tries=1 +short @10.0.1.20 example.com A | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
    ${pkgs.lib.concatMapStringsSep "\n" (
      record:
      let
        fields = pkgs.lib.splitString " " record;
        address = builtins.head fields;
        name = builtins.elemAt fields 1;
      in
      "dig +time=3 +tries=1 +short @10.0.1.20 ${pkgs.lib.escapeShellArg name} A | grep -Fxq ${pkgs.lib.escapeShellArg address}"
    ) (import ./records.nix)}
    dig +tcp +time=3 +tries=1 +short @10.0.1.20 nasa.lan A | grep -Fxq '10.0.1.10'
    count=$(${ftl}/bin/pihole-FTL sqlite3 -batch -noheader -list /var/lib/pihole/gravity.db 'SELECT COUNT(*) FROM gravity;')
    [[ "$count" =~ ^[0-9]+$ ]]
    (( count > 0 ))
    systemctl is-active --quiet pihole-gravity.timer
    echo "Pi-hole DNS records and $count gravity entries verified."
  '';
}
