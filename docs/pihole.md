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
10.0.0.1:53. The sole blocklist is https://big.oisd.nl, refreshed weekly by a persistent timer. FTL settings are read-only:
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

## Automatic deployment

The Pi checks the repository's protected `main` branch every minute, without
random delay, using NixOS's `nixos-upgrade.service`. It builds and
switches locally with one build job and two cores, preserving `flake.lock`.
GitHub's existing owner approval and required PR checks control what reaches
main. The owner exemption still applies. It follows main without additionally
waiting for the post-merge GitHub workflow; PR checks remain the merge gate.

After this configuration is merged, bootstrap it once on the Pi:

```sh
sudo nixos-rebuild switch --refresh --flake github:jmalexan/nix/main#pihole
systemctl list-timers nixos-upgrade.timer
```

After that, changing `hosts/pihole/records.nix` and merging the approved PR is
sufficient: the next timer run applies it (plus build time). The updater can
apply any Pi configuration change, not only DNS records. It does not reboot
automatically; new kernels/boot configuration take effect at a manual reboot.
Unchanged configurations reuse the store and do not restart unchanged services.
Actual DNS configuration updates can briefly interrupt DNS.

To trigger a check immediately or inspect its result:

```sh
sudo systemctl start nixos-upgrade.service
systemctl show nixos-upgrade.service -p Result -p ExecMainStatus
sudo journalctl -u nixos-upgrade.service -b --no-pager -n 80
```

A failed fetch/build leaves the running system in place and retries on the next
timer run. Activation failures may leave partial changes; inspect the journal.
The service does not perform automatic health rollback, and a successful rebuild
is not proof of working DNS. Verify important releases with `dig` from a LAN
client and the FTL/gravity journals. The blocklist refresh is a separate weekly
`pihole-gravity.timer` job.

To pause updates for recovery:

```sh
sudo systemctl stop nixos-upgrade.timer
sudo systemctl stop nixos-upgrade.service
sudo nixos-rebuild switch --rollback
```

If the prior generation also enables the timer, stop it again after rollback.
Fix/revert the repository before resuming; otherwise main will be reapplied.
The timer can start again after reboot; disable `system.autoUpgrade.enable` in
the Nix configuration if you need a lasting pause. NixOS rollback does not
restore database contents or undo schema migrations.

NASA/HTPC still use push deployments through GitHub Actions. The planner validates
the Pi but excludes it from that deployment matrix (including manual `all`),
since its local timer performs deployment. Deployment needs no CI account,
private key, or host-key secret. Tailscale is enabled separately for Rex;
deployment does not depend on its connection.
Deployment status for the Pi is local in systemd, not the GitHub deployment UI.

## Rex access

The Pi imports the shared Rex login-server module. Sessions run as `jmalexan`
and accept only the existing `vars.user.tailscaleLogin` identity. The pinned
stable Rex input includes an aarch64 Linux package and follows the Pi's Nixpkgs
for PAM compatibility. This does not install the shared developer/agent toolset.

After the bootstrap rebuild, enroll the Pi from an SSH session:

```sh
sudo tailscale up --hostname=pihole --accept-dns=false
```

Open the login URL and use your existing tailnet account. Keep Tailscale DNS
acceptance disabled; the Pi must resolve independently of its own DNS service.
If the rebuild is waiting for `rex-tailscale-serve`, run enrollment from a second
SSH session. Once enrollment completes, that unit can finish. Tailnet HTTPS
certificates and MagicDNS must be enabled, as for the other Rex hosts.

Confirm its assigned DNS name using `tailscale status`; add
`https://pihole.tailf18bf1.ts.net:7297` in Rex for Mac if that is the assigned name.
If Tailscale assigns a suffix, use the actual name instead. Check:

```sh
systemctl status rex-login-server rex-tailscale-serve --no-pager
tailscale serve status
```

Only the Tailscale UDP port is opened for connectivity; Rex is served through
Tailscale Serve, not a public LAN HTTP listener. DNS remains restricted to
Ethernet. The existing SSH login remains available for enrollment and recovery.
