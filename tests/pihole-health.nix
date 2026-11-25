# Exercise deployment health failures without requiring ARM hardware or live DNS.
{ pkgs }:
let
  fakeSystemd = pkgs.writeShellScriptBin "systemctl" ''
    if [[ "''${FAIL_SERVICE:-0}" != 0 ]]; then exit 1; fi
    echo active
  '';
  fakeDig = pkgs.writeShellScriptBin "dig" ''
    if [[ "''${FAIL_DNS:-0}" = 1 ]]; then exit 1; fi
    if [[ "''${FAIL_TCP:-0}" = 1 && "$*" = *+tcp* ]]; then exit 1; fi
    for argument in "$@"; do
      case "$argument" in
        example.com) echo 1.1.1.1; exit 0 ;;
        ${pkgs.lib.concatMapStringsSep "\n" (
          record:
          let
            fields = pkgs.lib.splitString " " record;
          in
          "${builtins.elemAt fields 1}) if [[ \"\${FAIL_RECORD:-0}\" = 1 ]]; then echo 10.99.99.99; else echo ${builtins.head fields}; fi; exit 0 ;;"
        ) (import ../hosts/pihole/records.nix)}
      esac
    done
    exit 1
  '';
  fakeFTL = pkgs.writeShellScriptBin "pihole-FTL" ''
    echo "''${GRAVITY_COUNT:-221797}"
  '';
  health = import ../hosts/pihole/health.nix {
    pkgs = pkgs // {
      systemd = fakeSystemd;
      dig = fakeDig;
    };
    ftl = fakeFTL;
  };
in
pkgs.runCommand "pihole-health-tests" { } ''
  ${health}/bin/pihole-health
  for failure in FAIL_DNS=1 FAIL_TCP=1 FAIL_RECORD=1 FAIL_SERVICE=1 GRAVITY_COUNT=0 GRAVITY_COUNT=invalid; do
    if env "$failure" ${health}/bin/pihole-health; then
      echo "Health check incorrectly succeeded with $failure" >&2
      exit 1
    fi
  done
  touch "$out"
''
