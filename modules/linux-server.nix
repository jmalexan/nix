# Linux-only baseline for any NixOS host (or NixOS container).
# Hardened sshd, passwordless sudo for the wheel group.
{ ... }: {
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  # Wheel users get passwordless sudo. SSH is key-only so this is safe.
  security.sudo.wheelNeedsPassword = false;
}
