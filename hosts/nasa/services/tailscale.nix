{ ... }: {
  services.tailscale = {
    enable = true;
    useRoutingFeatures = "server";  # enables exit node + subnet routing advertisement
  };

  # Allow all Tailscale traffic through the firewall
  networking.firewall.trustedInterfaces = [ "tailscale0" ];

  # ── Post-deploy (one-time) ─────────────────────────────────────────────────
  #
  #   sudo tailscale up --advertise-exit-node
  #
  # Then in the Tailscale admin console, approve the exit node for this machine.
}
