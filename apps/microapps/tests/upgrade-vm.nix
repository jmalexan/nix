{ pkgs }:
pkgs.testers.runNixOSTest {
  name = "microapp-upgrade";
  nodes.machine =
    { lib, ... }:
    let
      app =
        version:
        pkgs.writeShellApplication {
          name = "demo";
          text = ''
            echo ${version} > "$STATE_DIRECTORY/version"
            exec ${pkgs.coreutils}/bin/sleep infinity
          '';
        };
    in
    {
      imports = [
        ../../../modules/microapps.nix
        ../../../modules/microapp-accounts.nix
      ];
      services.microappAccounts = {
        enable = true;
        clients = [ "microapp-demo" ];
      };
      users.groups.account-outsider = { };
      users.users.account-outsider = {
        isSystemUser = true;
        group = "account-outsider";
      };
      environment.systemPackages = [ pkgs.curl ];
      services.microapps.apps.demo = {
        enable = true;
        package = app "old";
        port = 18092;
      };
      specialisation.upgrade.configuration.services.microapps.apps.demo.package = lib.mkForce (app "new");

      # Make the old stop -> activation -> start race deterministic: unchanged
      # workers have time to restart their required app before /etc is updated.
      system.activationScripts.microapp-race.text = "${pkgs.coreutils}/bin/sleep 2";
      system.activationScripts.etc.deps = [ "microapp-race" ];
      systemd.services.microapp-pulse = {
        unitConfig.StartLimitIntervalSec = 0;
        requires = [ "microapp-demo.service" ];
        after = [ "microapp-demo.service" ];
        serviceConfig.Type = "oneshot";
        script = "true";
      };
      systemd.timers.microapp-pulse = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "1s";
          OnUnitInactiveSec = "100ms";
          AccuracySec = "1ms";
        };
      };
      virtualisation.memorySize = 768;
    };
  testScript = ''
    machine.start()
    machine.wait_for_unit("microapp-pulse.timer")
    machine.wait_until_succeeds("grep -qx old /var/lib/microapp-demo/version", timeout=30)
    machine.succeed("/run/current-system/specialisation/upgrade/bin/switch-to-configuration switch")
    machine.wait_until_succeeds("grep -qx new /var/lib/microapp-demo/version", timeout=30)
    machine.wait_for_unit("microapp-demo.service")
    machine.fail("systemctl is-failed microapp-pulse.service")
    machine.succeed("test $(systemctl show microapp-demo.service -p NRestarts --value) = 0")

    # Exercise the production socket-activated account service and its actual
    # filesystem isolation, not a network-exposed or in-process substitute.
    machine.succeed("systemctl start microapp-accounts.service")
    machine.wait_for_unit("microapp-accounts.service")
    machine.succeed("curl --fail --unix-socket /run/microapp-accounts.sock http://accounts/account")
    machine.fail("runuser -u account-outsider -- curl --fail --unix-socket /run/microapp-accounts.sock http://accounts/account")
    machine.succeed("runuser -u account-outsider -g microapp-account-clients -- curl --fail --unix-socket /run/microapp-accounts.sock http://accounts/account")
    machine.fail("runuser -u account-outsider -g microapp-account-clients -- cat /var/lib/microapp-accounts/state.sqlite")
    machine.succeed("test $(stat -c %a /var/lib/microapp-accounts/state.sqlite) = 600")
    machine.succeed("systemctl show microapp-demo.service -p SupplementaryGroups --value | grep -w microapp-account-clients")
    machine.succeed("systemctl stop microapp-accounts.socket microapp-accounts.service")
    machine.wait_for_unit("microapp-demo.service")
    machine.succeed("test ! -S /run/microapp-accounts.sock")
    machine.succeed("systemctl start microapp-accounts.socket")
    machine.succeed("curl --fail --unix-socket /run/microapp-accounts.sock http://accounts/account")
    machine.wait_for_unit("microapp-accounts.service")
  '';
}
