{ vars, ... }: {
  # FlareSolverr is a headless-browser proxy that solves the Cloudflare
  # "challenge" (JS/turnstile) pages some indexers put in front of their site.
  # Prowlarr hands the request to FlareSolverr, which drives Chromium to pass the
  # challenge and returns the resolved response — clearing the 503 errors you see
  # when an indexer is behind Cloudflare.  Listens on :8191 (its default).
  services.flaresolverr = {
    enable = true;
    openFirewall = false;
  };

  # ── Deliberately NOT in the Mullvad namespace ─────────────────────────────
  #
  # This service used to share the netns with Prowlarr so its egress took the
  # same VPN path.  That is exactly what broke it: Cloudflare scores VPN and
  # datacenter exit IPs as high-risk and serves the hardest challenge variant,
  # which the Chromium automation cannot clear.  The failure looks like
  #
  #   Challenge detected. Title found: Just a moment...
  #   Error solving the challenge. Timeout after 60.0 seconds.
  #
  # On the ISP address the challenge is at least solvable.  The trade-off is
  # accepted knowingly: searches against FlareSolverr-tagged indexers now leave
  # the tunnel, and both the ISP and the indexer see the home address.
  #
  # This does NOT change torrent traffic.  qbittorrent is the only thing here
  # that joins a swarm and it stays namespaced (see qbittorrent.nix) — this
  # service only ever makes HTTPS requests to indexer web servers.
  #
  # To put it back on the VPN, restore
  #   serviceConfig.NetworkNamespacePath = "/run/netns/mullvad";
  # drop the HOST binding and the firewall rule below, and point Prowlarr's
  # proxy back at http://localhost:8191.
  systemd.services.flaresolverr = {
    # Bound to the host end of the veth pair, NOT the 0.0.0.0 it defaults to.
    # br0 is in networking.firewall.trustedInterfaces, so a wildcard bind would
    # hand every device on the LAN an open fetch-any-URL proxy and the firewall
    # would not stop it.  10.200.200.1 is reachable only from this host and from
    # inside the Mullvad namespace, which is exactly the set of clients that
    # need it.  (Address is hostVethIP in mullvad.nix.)
    environment.HOST = vars.nasa.hostVethIP;

    # The bind address only exists once mullvad-netns.service has created the
    # veth pair, so this still orders after it even though it no longer joins
    # the namespace — otherwise it would fail to bind and restart-loop.
    # partOf, not just requires: requires propagates stop but not restart, and a
    # netns restart recreates veth-host, stranding the old socket.
    after = [ "mullvad-netns.service" ];
    requires = [ "mullvad-netns.service" ];
    partOf = [ "mullvad-netns.service" ];
  };

  # Prowlarr is still inside the namespace, so it reaches this service across
  # the veth and lands in the host's INPUT chain.  veth-host is not a trusted
  # interface, so 8191 has to be opened there explicitly — scoped to that
  # interface only, so this does not expose the proxy on br0.
  #
  # Configure the FlareSolverr proxy in Prowlarr as http://10.200.200.1:8191;
  # it is no longer on localhost from Prowlarr's point of view.
  networking.firewall.interfaces.veth-host.allowedTCPPorts = [ 8191 ];
}
