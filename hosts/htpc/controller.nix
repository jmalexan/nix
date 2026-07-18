# Xbox controller support. The chosen connection is Bluetooth, handled by
# xpadneo for proper rumble, battery reporting and button mapping.
{ config, lib, pkgs, ... }:

{
  # ── Bluetooth ───────────────────────────────────────────────────────────────
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
    # Keep the adapter quick to re-pair so the controller reconnects instantly
    # when powered on (this is what "wakes" the screen — see desktop.nix idle notes).
    settings.General.FastConnectable = true;
  };

  # Best-in-class Bluetooth Xbox controller driver.
  hardware.xpadneo.enable = true;

  # Wired Xbox controllers work out of the box via the in-kernel `xpad` driver.

  # The Xbox Wireless Dongle (proprietary 2.4GHz) needs the out-of-tree `xone`
  # driver. It is left OFF here because (a) the chosen connection is Bluetooth and
  # (b) xone can fail to build against very new kernels like linuxPackages_latest.
  # If you switch to the dongle, uncomment (it also enables wake — see below):
  # hardware.xone.enable = true;

  # ── Wake-on-controller ────────────────────────────────────────────────────────
  # Powering on a controller can only wake the PC over the Xbox Wireless Dongle or
  # a USB cable — Bluetooth CANNOT wake the host. This rule is inert over Bluetooth
  # and will "just work" if you later attach the dongle/cable. It also needs BIOS
  # setup on the UM760:
  #   • enable "USB Wake Support"
  #   • disable "ErP Ready"  (ErP cuts USB standby power, killing wake)
  # Microsoft's USB vendor id is 045e; this enables USB wakeup for all Xbox gear.
  services.udev.extraRules = ''
    ACTION=="add|change", SUBSYSTEM=="usb", DRIVERS=="usb", ATTRS{idVendor}=="045e", ATTR{power/wakeup}="enabled"
  '';
}
