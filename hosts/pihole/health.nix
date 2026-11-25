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
    systemctl is-active pihole-ftl.service
    dig +time=3 +tries=1 +short @127.0.0.1 example.com A | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
    ${pkgs.lib.concatMapStringsSep "\n" (
      record:
      let
        fields = pkgs.lib.splitString " " record;
        address = builtins.head fields;
        name = builtins.elemAt fields 1;
      in
      "dig +time=3 +tries=1 +short @127.0.0.1 ${pkgs.lib.escapeShellArg name} A | grep -Fx ${pkgs.lib.escapeShellArg address}"
    ) (import ./records.nix)}
    dig +tcp +time=3 +tries=1 +short @127.0.0.1 nasa.lan A | grep -Fx '10.0.1.10'
    count=$(${ftl}/bin/pihole-FTL sqlite3 -batch -noheader -list /var/lib/pihole/gravity.db 'SELECT COUNT(*) FROM gravity;')
    [[ "$count" =~ ^[0-9]+$ ]]
    (( count > 0 ))
    systemctl is-active pihole-gravity.timer
    echo "Pi-hole DNS records and $count gravity entries verified."
  '';
}
