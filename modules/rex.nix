# Remote shells run as the existing personal account. Tailscale identifies the
# caller; the login policy grants that identity access to this account only.
{ rex, vars, ... }:

{
  imports = [ rex.nixosModules.default ];

  services.tailscale.enable = true;

  services.rex.loginServer = {
    enable = true;
    accounts.${vars.user.name}.principals = [ "tailscale:${vars.user.tailscaleLogin}" ];
    tailscaleServe = {
      enable = true;
      # Keep 443 available for the NAS's existing HTTPS services.
      httpsPort = 7297;
    };
  };
}
