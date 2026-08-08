# Dedicated identity used by the GitHub Actions production deployment job.
# Network access is independently restricted by the tailnet policy; this key
# only authenticates the ephemeral runner after it reaches a host.
{ pkgs, ... }:

{
  users.users.deploy = {
    isNormalUser = true;
    description = "GitHub Actions deployment user";
    extraGroups = [ "wheel" ];
    shell = pkgs.bashInteractive;
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILqnvCr13cQOZOSpubTKWpC/rkbjklNBL0ZcteLGWUSp github-actions jmalexan/nix auto-deploy"
    ];
  };
}
