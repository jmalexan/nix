{ pkgs }:
pkgs.testers.runNixOSTest {
  name = "agent-network-boundary";
  requiredFeatures.kvm = false;
  nodes.machine = { lib, ... }: {
    imports = [ ../modules/agent-network.nix ];
    virtualisation.memorySize = 1024;
    virtualisation.cores = 2;
    virtualisation.qemu.package = lib.mkForce pkgs.qemu;
    networking.dhcpcd.denyInterfaces = [
      "uplink0"
    ];
    services.agentNetwork = {
      enable = true;
      uplink = "uplink0";
    };
    # Prove the independent boundary wins over permissive host rules.
    networking.firewall.trustedInterfaces = [
      "agenttap0"
      "uplink0"
    ];
    environment.systemPackages = [
      pkgs.python3
      pkgs.iproute2
      pkgs.iptables
      pkgs.nftables
    ];
  };
  testScript = ''
    machine.start()
    machine.wait_for_unit("agent-boundary.service")
    machine.succeed("${pkgs.python3}/bin/python ${./agent_network.py}", timeout=180)
  '';
}
