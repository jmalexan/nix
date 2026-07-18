{ ... }: {
  # FlareSolverr is a headless-browser proxy that solves the Cloudflare
  # "challenge" (JS/turnstile) pages some indexers put in front of their site.
  # Prowlarr hands the request to FlareSolverr, which drives Chromium to pass the
  # challenge and returns the resolved response — clearing the 503 errors you see
  # when an indexer is behind Cloudflare.  Listens on :8191 (its default).
  services.flaresolverr = {
    enable = true;
    openFirewall = false;
  };

  # Run FlareSolverr inside the Mullvad VPN namespace alongside Prowlarr.  It is
  # the process that actually reaches out to the indexer, so its egress must take
  # the same VPN path Prowlarr's own queries take (Prowlarr sits in this netns
  # for exactly that reason).  Sharing the netns also means Prowlarr reaches it
  # on localhost — configure the FlareSolverr proxy in Prowlarr as
  # http://localhost:8191.
  systemd.services.flaresolverr = {
    after    = [ "mullvad-netns.service" ];
    requires = [ "mullvad-netns.service" ];
    serviceConfig.NetworkNamespacePath = "/run/netns/mullvad";
  };
}
