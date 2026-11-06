# Separate personal and agent development environments

`home` stays the owner's personal development container, with its existing login,
GitHub credentials, SSH keys, and working files. `robots` is a separate QEMU/KVM VM
on NASA. Pair with the agent by connecting your editor or Rex to that VM. Use
separate clones and Git branches to move changes between environments.

## Boundaries

- 2 vCPUs, 4 GiB RAM, a 64 GiB sparse persistent root disk in
  `/var/lib/microvms/robots/root.img`, and its own writable Nix store.
- `robot` account, no sudo, no trusted Nix daemon access. Shared development
  packages and Home Manager styling; a bot Git author identity.
- No host directory, host Nix daemon, Docker socket, journal directory, private
  SSH key, personal GitHub login, or personal Tailscale state is mounted/copied.
- Owner public SSH keys permit inbound ordinary SSH as `robot`. Agent forwarding
  is disabled. Rex accepts the owner's existing Tailscale user and opens only
  the guest `robot` account. Nothing permits an outbound owner Rex identity.
- A routed TAP (`agenttap0`, guest `10.200.201.2/30`) keeps the guest off `br0`.
  An independent host nftables table runs before host/Docker accept rules and
  checks the incoming interface and source. IPv6 packets from the TAP are dropped.
- Outbound LAN exceptions: NASA `10.0.1.10` TCP 443 (existing app APIs) and 2222
  (phone-approved SSH), DNS `10.0.1.20` TCP/UDP 53. Other private destinations,
  host admin SSH/Rex, and new host-network connections into the guest are denied.
- Public IPv4 TCP 80/443 and UDP 123/3478/41641 support downloads, AI services,
  time, and Tailscale. Tailscale can fall back to HTTPS relays when a direct peer
  path is blocked. This is network isolation, not a general Internet allowlist.
- The guest enrolls only with `tag:agent`. The applied policy in
  [tailscale-agent-policy.json](tailscale-agent-policy.json) gives it no outbound
  tailnet grant, including via subnet routers or an exit node. Personal devices
  and `tag:ci` retain their prior access. Do not restore the wildcard source grant
  or enroll the VM under the owner's identity.

NAS HTTPS includes existing services with their existing authentication. The VM
must receive only deliberately scoped app tokens. Do not treat access to an
unauthenticated app as read-only. Code brought back to the personal environment
also needs normal trust/review before it runs with personal credentials.

## Credentials and release

The supplied one-use tagged Tailscale auth key and the repository-scoped GitHub
App signing key are age-encrypted to the existing NASA/owner recipients. The VM
never receives any of those decryption keys. NASA decrypts the two files with
agenix; systemd loads them into the QEMU service's private credential directory;
QEMU fw_cfg passes them to the guest service manager. Only the scoped bot key and
approval requester token are installed for `robot`, in mode-0600 files. The
requester can ask for access; it cannot approve requests. No worker, gate,
enrollment, deployment, or owner credentials are passed into the guest.

The guest Tailscale daemon owns its persistent node state; `robot` is not its
operator. The one-use key is not needed for ordinary reconnects or restarts.
Recreating the VM disk requires a fresh tagged enrollment key. Key expiry before
first deployment also requires replacing the encrypted enrollment file. After
successful enrollment, remove the spent bootstrap key in a follow-up release;
keep the persistent node state and retire the unused enrollment configuration.

The deployment framework and this VM are included in PR #57. The owner's merge
approves the combined release. It targets NASA; it starts a new VM and
reloads relevant firewall/nginx/gate configuration. It does not restart `home`.
Future guest configuration changes restart the VM, so save agent work before
merging a guest update. Removing the VM declaration does not erase its disk.

## Migration and verification

1. Confirm Tailscale accepts the saved policy and its tests. This was reported
   complete during setup. Only `robots` gets the new tag; never retag `home`.
2. After the owner merges and CI reports deployment success, confirm `robots`
   appears as `tag:agent` in the Tailscale device list. Open Rex on that device or
   `ssh robot@robots` with a trusted local public-key identity and no `-A`.
   Compare its SSH host key with the `ROBOTS_SSH_HOST_KEY` line in the production
   deployment log before accepting it; never disable host-key verification.
   CI waits for the guest to report SSH, Rex, Tailscale, and credentials ready.
3. In the guest, run `github-bot status`, clone the repositories you want to work
   on, and restore source-only work on branches. Keep personal repositories in
   `home` separate. Do not synchronize home directories, `.ssh`, `.config/gh`,
   Tailscale state, or existing AI credential directories.
4. Establish the agent's AI tool authorization separately. Any credential given
   to a process running as `robot` is readable by that account; use only the
   intended tool/account scope, never a general personal credential bundle.
5. Verify an approved read-only NASA request using `nasa-approved-access --reason
   'Verify the new agent VM' -- hostname`. It still requires explicit phone
   approval, has no sudo, and expires after 15 minutes. Ordinary NAS SSH remains
   blocked. The repository wrapper honors `NASA_APPROVAL_REQUESTER_FILE` too.
6. Verify from a new session actually running on `robots` that owner credential
   files and personal machines are unavailable. This setup session remains in
   `home` until the client is switched; preparing the VM does not move it.

The bot key is deliberately repository-scoped and can propose PRs, not merge or
change protections. Your personal credentials remain in `home`. Do not revoke
those credentials as part of this migration. The old agent sessions in `home`
must be closed once work moves to the VM.

## Tests and recovery

`nix build .#checks.x86_64-linux.agent-network` boots a disposable NixOS test
machine and exercises the real firewall with separate guest/uplink namespaces:
private/host denies, permitted APIs/DNS/web, spoofing, IPv6, new inbound traffic,
DNAT to a private target, and stop/reload behavior. The boundary survives service
stop and atomically reloads without flushing unrelated rules.

`nix build .#checks.x86_64-linux.agent-guest` boots the real guest configuration
under QEMU software emulation, with fake credentials and no network, twice. It
checks credential delivery/permissions, non-sudo identity, ordinary unprivileged
Nix-store writes, persistent data, and stable SSH host keys. Production enrollment,
Rex connectivity, and hardware KVM still need post-deployment verification.

Use CI for routine guest updates. For recovery, use the authorized NASA access
workflow; the agent guest is not an administrator backdoor. A host administrator
can stop `microvm@robots`, preserve/copy its disk, or restore a previous NASA
configuration. Back up needed source in Git; this initial release does not add
VM disk backups or replicate personal home directories.

References: [microvm host](https://microvm-nix.github.io/microvm.nix/host.html),
[systemd credentials](https://systemd.io/CREDENTIALS/),
[Tailscale selectors](https://tailscale.com/docs/reference/targets-and-selectors).
