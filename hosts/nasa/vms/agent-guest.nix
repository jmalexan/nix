{
  config,
  lib,
  pkgs,
  pkgs-unstable,
  claude-code-pkg,
  home-manager-stable,
  rex,
  vars,
  ...
}:
let
  agentVars = vars // {
    user = vars.user // {
      name = "robot";
      fullName = "Jmalexan NASA Automation";
      email = "jmalexan-nasa-automation[bot]@users.noreply.github.com";
    };
  };
in
{
  imports = [
    (import ../../../modules/dev-environment.nix { inherit pkgs pkgs-unstable claude-code-pkg; })
    (import ../../../modules/rex.nix {
      inherit rex;
      vars = agentVars;
    })
    ../../../modules/trust-private-ca.nix
    home-manager-stable.nixosModules.home-manager
  ];
  microvm = {
    hypervisor = "qemu";
    vcpu = 2;
    mem = 4096;
    shares = [ ];
    devices = [ ];
    interfaces = [
      {
        type = "tap";
        id = "agenttap0";
        mac = "02:00:00:00:ca:02";
      }
    ];
    volumes = [
      {
        image = "root.img";
        mountPoint = "/";
        size = 65536;
      }
    ];
    writableStoreOverlay = "/nix/.rw-store";
    credentialFiles = {
      agent-tailscale = "/run/credentials/microvm@robots.service/agent-tailscale";
      agent-github = "/run/credentials/microvm@robots.service/agent-github";
      agent-requester = "/run/credentials/microvm@robots.service/agent-requester";
    };
  };
  # QEMU fw_cfg credentials arrive in PID 1, never in the Nix store.
  boot.initrd.kernelModules = [ "qemu_fw_cfg" ];
  networking.hostName = "robots";
  networking.useDHCP = false;
  systemd.network.enable = true;
  systemd.network.networks."10-agent" = {
    matchConfig.MACAddress = "02:00:00:00:ca:02";
    address = [ "10.200.201.2/30" ];
    routes = [ { Gateway = "10.200.201.1"; } ];
    networkConfig = {
      IPv6AcceptRA = false;
      LinkLocalAddressing = "no";
    };
  };
  networking.nameservers = [ "10.0.1.20" ];
  networking.search = [ vars.nasa.domain ];
  time.timeZone = vars.timeZone;
  services.timesyncd.enable = true;
  services.tailscale = {
    authKeyFile = "/run/credentials/tailscaled-autoconnect.service/agent-tailscale";
    extraUpFlags = [
      "--advertise-tags=tag:agent"
      "--accept-routes=false"
      "--accept-dns=false"
      "--ssh=false"
    ];
    extraSetFlags = [
      "--accept-routes=false"
      "--accept-dns=false"
      "--ssh=false"
    ];
  };
  systemd.services.tailscaled-autoconnect.serviceConfig.ImportCredential = "agent-tailscale";
  services.openssh = {
    enable = true;
    openFirewall = false;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
      AllowUsers = [ "robot" ];
      AllowAgentForwarding = false;
    };
  };
  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 22 ];
  users.users.robot = {
    isNormalUser = true;
    shell = pkgs.fish;
    openssh.authorizedKeys.keys = import ../../../users/authorized-keys.nix;
  };
  security.sudo.enable = false;
  programs.nix-ld.enable = true;
  nix.settings = {
    trusted-users = lib.mkForce [ "root" ];
    max-jobs = 1;
    cores = 2;
    auto-optimise-store = false;
  };
  environment.systemPackages = [
    (import ../../../tools/github-bot.nix { inherit pkgs; })
    (import ../../../apps/microapps { inherit pkgs; }).access
  ];
  environment.variables.NASA_APPROVAL_REQUESTER_FILE = "/home/robot/.local/share/nasa-access/requester";
  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    extraSpecialArgs.vars = agentVars;
    users.robot = import ../../../home/linux.nix;
  };
  systemd.services.agent-github-identity = {
    description = "Install the repository-scoped GitHub App identity";
    wantedBy = [ "multi-user.target" ];
    before = [
      "sshd.service"
      "rex-login-server.service"
    ];
    after = [ "systemd-user-sessions.service" ];
    serviceConfig = {
      Type = "oneshot";
      ImportCredential = [
        "agent-github"
        "agent-requester"
      ];
      RemainAfterExit = true;
      UMask = "0077";
    };
    script = ''
      install -d -m 0700 -o robot -g users /home/robot/.local/share/nasa-access
      install -m 0600 -o robot -g users "$CREDENTIALS_DIRECTORY/agent-requester" /home/robot/.local/share/nasa-access/requester
      install -d -m 0700 -o robot -g users /home/robot/.local/share/nasa-github-app
      install -m 0600 -o robot -g users "$CREDENTIALS_DIRECTORY/agent-github" /home/robot/.local/share/nasa-github-app/private-key.pem
      printf '%s\n' '{"app_id":"5637230"}' > /home/robot/.local/share/nasa-github-app/config.json
      chown robot:users /home/robot/.local/share/nasa-github-app/config.json
    '';
  };
  systemd.services.agent-ready = {
    description = "Report guest readiness and public SSH host key";
    wantedBy = [ "multi-user.target" ];
    requires = [
      "agent-github-identity.service"
      "sshd.service"
      "tailscaled-autoconnect.service"
      "rex-login-server.service"
      "rex-tailscale-serve.service"
    ];
    after = [
      "agent-github-identity.service"
      "sshd.service"
      "tailscaled-autoconnect.service"
      "rex-login-server.service"
      "rex-tailscale-serve.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      printf 'ROBOTS_SSH_HOST_KEY %s\n' "$(cat /etc/ssh/ssh_host_ed25519_key.pub)" > /dev/ttyS0
      printf 'ROBOTS_READY\n' > /dev/ttyS0
    '';
  };
  assertions = [
    {
      assertion = config.microvm.shares == [ ];
      message = "Agent VM must not share host filesystems.";
    }
    {
      assertion = !(builtins.elem "wheel" config.users.users.robot.extraGroups);
      message = "Agent must not have sudo privileges.";
    }
    {
      assertion = config.nix.settings.trusted-users == [ "root" ];
      message = "Agent must not control the Nix daemon.";
    }
  ];
  system.stateVersion = "26.05";
}
