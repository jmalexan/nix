# Shared baseline imported by every NixOS host in this flake.
# Pulls in the cross-platform dev environment and the Linux server defaults,
# then adds the things every Linux host of mine wants: bootloader, network
# manager, my user, and a couple of extra packages.
{
  pkgs,
  agenix,
  vars,
  ...
}:

{
  imports = [
    ./dev-environment.nix
    ./linux-server.nix
  ];

  # ── Boot ──────────────────────────────────────────────────────────────────

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # ── Networking ────────────────────────────────────────────────────────────

  networking.networkmanager.enable = true;

  # ── Locale & Time ─────────────────────────────────────────────────────────

  time.timeZone = vars.timeZone;

  # ── Users ─────────────────────────────────────────────────────────────────

  users.users.${vars.user.name} = {
    isNormalUser = true;
    description = vars.user.fullName;
    extraGroups = [
      "wheel"
      "networkmanager"
    ];
    shell = pkgs.fish;
    home = "/home/${vars.user.name}";
    openssh.authorizedKeys.keys = import ../users/authorized-keys.nix;
  };

  # ── Packages ──────────────────────────────────────────────────────────────

  environment.systemPackages = with pkgs; [
    screen
    agenix.packages.${pkgs.stdenv.hostPlatform.system}.default
  ];

  # ── Nix Settings ──────────────────────────────────────────────────────────

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };

}
