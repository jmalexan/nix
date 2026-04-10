{ config, pkgs, ... }:
let
  # IPs for the veth pair that bridges the mullvad namespace to the host.
  # nginx proxies to nsVethIP:8080 so qbittorrent stays reachable.
  hostVethIP = "10.200.200.1";
  nsVethIP   = "10.200.200.2";

  ip  = "${pkgs.iproute2}/bin/ip";
  wg  = "${pkgs.wireguard-tools}/bin/wg";
  cfg = config.age.secrets.mullvad-wg.path;

  setupScript = pkgs.writeShellScript "mullvad-ns-setup" ''
    set -euo pipefail

    # ── namespace ────────────────────────────────────────────────────────────
    ${ip} netns add mullvad
    ${ip} netns exec mullvad ${ip} link set lo up

    # ── veth pair (host ↔ namespace, so nginx can still reach qbittorrent) ──
    ${ip} link add veth-host type veth peer name veth-ns
    ${ip} link set veth-ns netns mullvad

    ${ip} addr add ${hostVethIP}/30 dev veth-host
    ${ip} link set veth-host up

    ${ip} netns exec mullvad ${ip} addr add ${nsVethIP}/30 dev veth-ns
    ${ip} netns exec mullvad ${ip} link set veth-ns up

    # ── WireGuard tunnel to Mullvad ──────────────────────────────────────────
    ${ip} link add wg0 type wireguard
    ${ip} link set wg0 netns mullvad

    # wg setconf doesn't understand wg-quick's Address/DNS lines — strip them.
    STRIPPED=$(mktemp /run/wg0-XXXXXX.conf)
    chmod 600 "$STRIPPED"
    grep -vE '^\s*(Address|DNS)\s*=' "${cfg}" > "$STRIPPED"
    ${ip} netns exec mullvad ${wg} setconf wg0 "$STRIPPED"
    rm -f "$STRIPPED"

    # Apply the address from the config file.
    MULLVAD_ADDR=$(grep -oP '(?i)(?<=^address\s=\s)[^\s,]+' "${cfg}")
    ${ip} netns exec mullvad ${ip} addr add "$MULLVAD_ADDR" dev wg0
    ${ip} netns exec mullvad ${ip} link set wg0 up

    # ── Routing inside namespace ─────────────────────────────────────────────
    # All outbound traffic goes through the VPN.  No fallback = kill switch.
    ${ip} netns exec mullvad ${ip} route add default dev wg0
    # Traffic back to the host (nginx → qbittorrent) goes over the veth.
    ${ip} netns exec mullvad ${ip} route add ${hostVethIP}/32 dev veth-ns

    # ── DNS inside namespace (Mullvad's DNS, only reachable via tunnel) ──────
    mkdir -p /etc/netns/mullvad
    DNS_IP=$(grep -oP '(?i)(?<=^dns\s=\s)[^\s,]+' "${cfg}" || echo "10.64.0.1")
    echo "nameserver $DNS_IP" > /etc/netns/mullvad/resolv.conf
  '';

  teardownScript = pkgs.writeShellScript "mullvad-ns-teardown" ''
    ${ip} link del veth-host       2>/dev/null || true
    ${ip} netns del mullvad        2>/dev/null || true
    rm -rf /etc/netns/mullvad
  '';
in {
  age.secrets.mullvad-wg = {
    file = ../../../secrets/mullvad-wg.age;
  };

  systemd.services.mullvad-netns = {
    description = "Mullvad VPN network namespace";
    wantedBy    = [ "multi-user.target" ];
    before      = [ "qbittorrent.service" ];
    after       = [ "network-online.target" ];
    wants       = [ "network-online.target" ];
    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = true;
      ExecStart       = setupScript;
      ExecStop        = teardownScript;
    };
  };
}
