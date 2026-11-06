# Enforce the guest boundary on the host, before Docker/NixOS accept rules.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.agentNetwork;
  rules = pkgs.writeText "agent-boundary.nft" ''
    add table inet agent_boundary
    flush table inet agent_boundary
    table inet agent_boundary {
      set private4 {
        type ipv4_addr; flags interval;
        elements = { 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8,
          169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 198.18.0.0/15,
          224.0.0.0/4, 240.0.0.0/4 }
      }
      chain source_guard {
        meta nfproto != ipv4 counter drop
        ip saddr != ${cfg.guestAddress} counter drop
        ct state invalid counter drop
      }
      chain host_access {
        ct state established,related accept
        ip daddr ${cfg.nasaAddress} tcp dport { 443, 2222 } accept
        counter drop
      }
      chain routed_access {
        ct state established,related accept
        ip daddr ${cfg.dnsAddress} udp dport 53 accept
        ip daddr ${cfg.dnsAddress} tcp dport 53 accept
        ip daddr @private4 counter drop
        # HTTPS also carries Tailscale DERP. No arbitrary UDP or SSH egress.
        tcp dport { 80, 443 } accept
        udp dport { 123, 3478, 41641 } accept
        counter drop
      }
      chain incoming {
        type filter hook input priority -10; policy accept;
        iifname "${cfg.interface}" jump source_guard
        iifname "${cfg.interface}" jump host_access
      }
      chain forwarding {
        type filter hook forward priority -10; policy accept;
        iifname "${cfg.interface}" jump source_guard
        iifname "${cfg.interface}" jump routed_access
        # Only replies may enter from the host network. Owner access uses
        # the guest's own Tailscale identity, not a host port forward.
        oifname "${cfg.interface}" ct state established,related accept
        oifname "${cfg.interface}" counter drop
      }
    }
  '';
  apply = pkgs.writeShellScript "agent-boundary-apply" ''
    exec ${pkgs.nftables}/bin/nft -f ${rules}
  '';
in
{
  options.services.agentNetwork = {
    enable = lib.mkEnableOption "the agent VM host network boundary";
    interface = lib.mkOption {
      type = lib.types.str;
      default = "agenttap0";
    };
    guestAddress = lib.mkOption {
      type = lib.types.str;
      default = "10.200.201.2";
    };
    nasaAddress = lib.mkOption {
      type = lib.types.str;
      default = "10.0.1.10";
    };
    dnsAddress = lib.mkOption {
      type = lib.types.str;
      default = "10.0.1.20";
    };
    uplink = lib.mkOption {
      type = lib.types.str;
      default = "br0";
    };
  };
  config = lib.mkIf cfg.enable {
    # Separate nftables table; do not switch the host/Docker firewall backend.
    systemd.services.agent-boundary = {
      description = "Host-enforced agent network boundary";
      wantedBy = [ "multi-user.target" ];
      before = [ "microvm@robots.service" ];
      reloadIfChanged = true;
      restartIfChanged = false;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = apply;
        ExecReload = apply;
        # Deliberately keep rules installed on stop/failure. Reload is atomic.
      };
    };
    # DHCP on this point-to-point link must not replace its fixed address.
    networking.dhcpcd.denyInterfaces = [ cfg.interface ];
    networking.nat = {
      enable = true;
      externalInterface = cfg.uplink;
      internalInterfaces = [ cfg.interface ];
    };
    networking.firewall.interfaces.${cfg.interface}.allowedTCPPorts = [
      443
      2222
    ];
  };
}
