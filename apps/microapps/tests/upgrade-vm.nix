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
      imports = [ ../../../modules/microapps.nix ];
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
  '';
}
