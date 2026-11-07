{
  config,
  lib,
  pkgs,
  pkgs-unstable,
  claude-code-pkg,
  home-manager-stable,
  rex,
  vars,
  gitBrokerEnabled ? false,
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
    # Higher guest ceiling, with unused pages returned to NASA by the balloon
    # driver's free-page reporting. No inflated balloon or scaling controller:
    # the guest sees 8 GiB throughout, while host residency follows page use.
    mem = 8192;
    balloon = true;
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
      agent-github = "/run/credentials/microvm@robots.service/agent-github";
      agent-requester = "/run/credentials/microvm@robots.service/agent-requester";
    }
    // lib.optionalAttrs gitBrokerEnabled {
      agent-git-broker = "/run/credentials/microvm@robots.service/agent-git-broker";
    };
  };
  # QEMU fw_cfg credentials arrive in PID 1, never in the Nix store.
  boot.initrd.kernelModules = [ "qemu_fw_cfg" ];
  # Concurrent agents and builds share the guest RAM. Give short memory spikes a
  # compressed buffer instead of immediately reclaiming working sets or killing
  # sessions. The compressed contents still consume guest RAM.
  zramSwap = {
    enable = true;
    memoryPercent = 50;
    memoryMax = 2 * 1024 * 1024 * 1024;
  };
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
    extraSetFlags = [
      "--accept-routes=false"
      "--accept-dns=false"
      "--ssh=false"
    ];
  };
  # Enrollment is complete. Reuse root-owned persistent node state, and fail
  # readiness rather than silently enrolling a replacement under another identity.
  systemd.services.agent-tailscale-ready = {
    requires = [
      "tailscaled.service"
      "tailscaled-set.service"
    ];
    after = [
      "tailscaled.service"
      "tailscaled-set.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      TimeoutStartSec = 150;
    };
    script = ''
      set -o pipefail
      for _attempt in $(seq 1 60); do
        if ${lib.getExe config.services.tailscale.package} status --json |
          ${pkgs.jq}/bin/jq -e '.BackendState == "Running" and ((.Self.Tags // []) | index("tag:agent") != null)' >/dev/null; then
          exit 0
        fi
        sleep 2
      done
      echo 'robots has no running tag:agent identity; restore its node state or enroll with a fresh tagged key through authorized recovery' >&2
      exit 1
    '';
  };
  systemd.services.rex-tailscale-serve = lib.mkIf config.services.rex.loginServer.enable {
    requires = [ "agent-tailscale-ready.service" ];
    after = [ "agent-tailscale-ready.service" ];
  };
  # Public key already trusted by the owner's setup environment. The approval
  # client uses HostKeyAlias=10.0.1.10 with strict verification on gate port 2222.
  programs.ssh.knownHosts.nasa = {
    hostNames = [ "10.0.1.10" ];
    publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAII8xM12gVZXzdvRDHwXwP9kIxj5fecxG5gU39rSTxUXr";
  };
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
    # robots is the sandbox. Keep these defaults guest-only and leave user
    # config/auth files alone. Explicit CLI options can select stricter modes.
    (lib.hiPrio (
      pkgs.writeShellScriptBin "codex" ''
        exec ${pkgs-unstable.codex}/bin/codex \
          -c 'sandbox_mode="danger-full-access"' \
          -c 'approval_policy="never"' "$@"
      ''
    ))
    (lib.hiPrio (
      pkgs.writeShellScriptBin "claude" ''
        exec ${claude-code-pkg}/bin/claude \
          --permission-mode bypassPermissions "$@"
      ''
    ))
    (import ../../../tools/github-bot.nix { inherit pkgs; })
    (import ../../../apps/microapps { inherit pkgs; }).access
    (pkgs.writeShellScriptBin "robot-guide" ''
      exec ${pkgs.coreutils}/bin/cat /etc/robot/systems.md
    '')
  ]
  ++ lib.optional gitBrokerEnabled (import ../../../apps/git-broker { inherit pkgs; }).client;
  environment.variables.NASA_APPROVAL_REQUESTER_FILE = "/home/robot/.local/share/nasa-access/requester";
  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    extraSpecialArgs.vars = agentVars;
    users.robot = {
      imports = [ ../../../home/linux.nix ];
      home.file.".codex/AGENTS.md".source = ./context/AGENTS.md;
      home.file.".claude/CLAUDE.md".source = ./context/AGENTS.md;
      home.file."dev/README.md".text =
        "# Workspace\n\nRun `robot-guide` for tools, systems, and repository access.\n";
    };
  };
  environment.etc = {
    "robot/AGENTS.md".source = ./context/AGENTS.md;
    "robot/systems.md".source = ./context/systems.md;
    "robot/repositories.json".source =
      if gitBrokerEnabled then
        pkgs.writeText "robot-repositories.json" (
          builtins.toJSON (
            (builtins.fromJSON (builtins.readFile ./context/repositories.json))
            // {
              planned_access_methods = { };
              access_methods.git-broker = {
                discovery = "git-broker repositories";
                endpoint = "https://git-broker.${vars.nasa.domain}";
                operations = [
                  "clone"
                  "fetch"
                  "push"
                ];
                write_policy = "Explicit repository allowlist and branch namespaces; follow the user's task authorization";
                default_delivery = "follow-user-request";
              };
            }
          )
        )
      else
        ./context/repositories.json;
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
      # Write only as the recipient user: user-controlled home paths must
      # never become a privileged file-write path on subsequent boots.
      User = "robot";
      Group = "users";
      ImportCredential = [
        "agent-github"
        "agent-requester"
      ]
      ++ lib.optional gitBrokerEnabled "agent-git-broker";
      RemainAfterExit = true;
      UMask = "0077";
    };
    script = ''
      install -d -m 0700 /home/robot/.local/share/nasa-access
      install -m 0600 "$CREDENTIALS_DIRECTORY/agent-requester" /home/robot/.local/share/nasa-access/requester
      install -d -m 0700 /home/robot/.local/share/nasa-github-app
      install -m 0600 "$CREDENTIALS_DIRECTORY/agent-github" /home/robot/.local/share/nasa-github-app/private-key.pem
      printf '%s\n' '{"app_id":"5637230"}' > /home/robot/.local/share/nasa-github-app/config.json
    ''
    + lib.optionalString gitBrokerEnabled ''
      install -d -m 0700 /home/robot/.local/share/git-broker
      install -m 0600 "$CREDENTIALS_DIRECTORY/agent-git-broker" /home/robot/.local/share/git-broker/token
    '';
  };
  systemd.services.agent-ready = {
    description = "Report guest readiness and public SSH host key";
    wantedBy = [ "multi-user.target" ];
    requires = [
      "agent-github-identity.service"
      "sshd.service"
      "agent-tailscale-ready.service"
      "rex-login-server.service"
      "rex-tailscale-serve.service"
    ];
    after = [
      "agent-github-identity.service"
      "sshd.service"
      "agent-tailscale-ready.service"
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
