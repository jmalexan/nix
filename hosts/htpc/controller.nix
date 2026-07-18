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

  # The internal MT7922 BT radio fails "Bluetooth: hci0: Opcode 0x0c03 failed:
  # -110" (HCI_Reset timeout) on every boot. Ruled out: rfkill, driver rebind,
  # USB reauthorize, kernel version (tried linuxPackages and _latest), a full
  # power-unplug, stale firmware (already the newest MediaTek has shipped),
  # and USB autosuspend (tested btusb.enable_autosuspend=0 live — no change).
  # Conclusion: hardware/driver-level issue, not fixable from NixOS config.
  # Working around it with an external USB Bluetooth dongle — no config
  # changes needed for that; BlueZ picks up whatever adapter registers.

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
