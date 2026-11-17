# Pi-hole on Raspberry Pi 4

`hosts/pihole` is a standalone aarch64 NixOS DNS appliance with the native
Pi-hole FTL and web packages. It uses the stable flake input, stock Pi 4
U-Boot SD image, and existing jmalexan SSH keys. No NASA services are required
for DNS startup. DHCP remains on the router.

## Configuration

The Ethernet MAC d8:3a:dd:6d:6b:12 requests IPv4 DHCP using its MAC as client
identifier. Keep the router reservation at 10.0.1.20, network 10.0.0.0/23,
gateway 10.0.0.1. The interface is named end0 by a MAC-matched link rule.
IPv6 accepts router advertisements; upstream IPv6 resolvers require a working
IPv6 route. IPv4 Cloudflare resolvers remain available independently.

Local records live in `hosts/pihole/records.nix`. The stale public IPv6 record
for pihole.lan is intentionally omitted. Reverse lookups for 10.0.0.0/23 go to
10.0.0.1:53. The sole blocklist is https://big.oisd.nl. FTL settings are read-only:
make settings changes through Git, not the dashboard. Runtime databases remain
under /var/lib/pihole and need separate backups; NixOS rollback does not roll
back databases. Do not import the old Teleporter wholesale over Nix-managed settings.
Unspecified options use the pinned module defaults, rather than reproducing
unknown settings from the old installation.

DNS TCP/UDP 53 is allowed on Ethernet only; FTL accepts local clients. The web UI
binds to loopback. Access it with:

```sh
ssh -L 8080:127.0.0.1:80 jmalexan@10.0.1.20
```

Open http://localhost:8080/. To supply a persistent dashboard password,
create `/var/lib/pihole-web.env` using `sudoedit`, mode 0600, owned by root, with
`FTLCONF_webserver_api_password=YOUR_PASSWORD`, then restart pihole-ftl.
Use a long alphanumeric password to avoid environment-file quoting ambiguity.
The file is optional; the dashboard stays loopback-only even before provisioning.
Never commit this file or the Teleporter archive.

## Build and validate

```sh
nix eval .#nixosConfigurations.pihole.config.system.build.toplevel.drvPath
nix build .#nixosConfigurations.pihole.config.system.build.sdImage
```

Build the image on an aarch64 Linux machine (the existing Debian Pi can run Nix),
or an explicitly configured ARM builder/emulator. The x86 robots VM can evaluate
this host but cannot natively build its ARM image. Allow several GB of free disk
space. The output is `result/sd-image/*.img.zst`; decompress it before flashing,
or use an image writer that supports zstd. The image expands its root partition
on first boot. Builds here do not prove that physical Pi firmware boots correctly.

## Migration using a borrowed SD card

1. Keep the downloaded Teleporter archive off the Pi. Shut Debian down cleanly,
   remove its card, and use another computer to save a full raw image of the
   **whole original card**, including its partition table. Verify that image is
   readable and record its checksum. Keep it until the migration is complete.
   This is the recovery path after the original card is overwritten.
2. Flash the NixOS image to the borrowed card using a graphical image writer.
   Confirm the target device and capacity first: flashing erases that card.
   Keep the original card untouched. Have a local keyboard/display available
   in case network or SSH startup fails.
3. Boot the Pi from the borrowed card. Since it is the same physical Pi and
   reserved MAC, expect it to take 10.0.1.20 immediately. There is a DNS outage
   during the swap. This is a cutover trial, not a second concurrent DNS server.
   Check the router lease, SSH access with an existing key, and the /23 route.
4. On the Pi run `systemctl is-active pihole-ftl pihole-ftl-setup` (the setup
   oneshot may be inactive after success; inspect its exit status and journal).
   Verify the OISD list finished downloading and gravity loaded successfully.
   From another LAN client test:

   ```sh
   dig @10.0.1.20 example.com
   dig +tcp @10.0.1.20 example.com
   dig @10.0.1.20 nasa.lan
   dig @10.0.1.20 approve.nasa.jmalexan.com
   dig @10.0.1.20 -x 10.0.1.10
   ```

   Check all local records, router forwarding without loops, dashboard access,
   blocking using a domain actually present in the loaded OISD list, and normal
   client browsing. Reboot once to verify boot and the router reservation.
   Swap the original Debian card back in if the trial fails.
5. While the Pi serves DNS from the borrowed card, flash the **same tested build**
   to the original card on another computer. No live clone is needed, so the
   borrowed card may be larger than the original. Confirm the image fits the
   original before flashing. The original Debian installation is now erased.
6. Shut down, swap back to the original card, boot, and repeat the checks. A fresh
   image has new SSH host keys: verify its fingerprint locally before replacing
   the old known_hosts entry. Do not disable host-key checking. Provision the
   runtime password again, or securely transfer it from the temporary system.
   Preserve any runtime data you want before returning the borrowed card.

Both flashed images initially share filesystem identifiers; do not attach both
cards to the Pi at once. DNS availability still depends on this single device.
The raw Debian backup can restore the original card if recovery is needed.

## Updates and deployment enrollment

After merging and completing cutover, update manually from an authorized client:

```sh
ssh jmalexan@10.0.1.20
sudo nixos-rebuild switch --flake github:jmalexan/nix#pihole
```

Use an exact reviewed commit in the flake URL for reproducible releases.
`sudo nixos-rebuild switch --rollback` restores the previous system generation;
retain backups for state and schema migrations. DNS can briefly stop on updates.

CI evaluates the Pi configuration but does not deploy to it yet. NASA/HTPC host
selection stays unchanged, including manual `all` reconciliation. The Pi has no
CI deploy account or Tailscale enrollment. After physical boot validation, a
follow-up PR can enroll it: provision the approved network route, deploy identity,
verified SSH host key, add it to deployment selection, and add DNS health checks.
Do not enable deployment before these prerequisites exist.
