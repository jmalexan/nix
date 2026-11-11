# Separate personal and agent development environments

`home` stays the owner's personal development container, with its existing login,
GitHub credentials, SSH keys, and working files. `robots` is a separate QEMU/KVM VM
on NASA. Pair with the agent by connecting your editor or Rex to that VM. Use
separate clones and Git branches to move changes between environments.

## Boundaries

- 2 vCPUs, an 8 GiB guest RAM ceiling, a 64 GiB sparse persistent root disk in
  `/var/lib/microvms/robots/root.img`, and its own writable Nix store.
- The virtio balloon device enables free-page reporting: the guest returns
  unused pages to NASA automatically and can use them again on demand. The guest
  always sees 8 GiB; there is no host-side controller adjusting its visible RAM.
  This is not a reservation or a guarantee that NASA can satisfy peak demand.
  Freed pages can be reclaimed; guest page caches and other in-use pages still
  consume host RAM. NASA has 32 GiB shared with its other workloads.
- Compressed swap (zram, logical capacity 50% of guest RAM capped at 2 GiB)
  buffers transient memory spikes from concurrent agents/builds within guest RAM.
  It does not provide more physical RAM or guarantee sustained workloads fit.
- `robot` account, no sudo, no trusted Nix daemon access. Shared development
  packages and Home Manager styling; a bot Git author identity.
- The only host directory share is NASA’s persistent journal at
  `/var/log/nasa-journal`, enforced read-only by QEMU and mounted read-only.
  `robot` can read it through `nasa-journalctl` without sudo or SSH.
- No host Nix daemon, Docker socket, private
  SSH key, personal GitHub login, or personal Tailscale state is mounted/copied.
- Owner public SSH keys permit inbound ordinary SSH as `robot`. Agent forwarding
  is disabled. Rex accepts the owner's existing Tailscale user and opens only
  the guest `robot` account. Nothing permits an outbound owner Rex identity.
- A routed TAP (`agenttap0`, guest `10.200.201.2/30`) keeps the guest off `br0`.
  An independent host nftables table runs before host/Docker accept rules and
  checks the incoming interface and source. IPv6 packets from the TAP are dropped.
- Outbound LAN exceptions: NASA `10.0.1.10` TCP 443 (existing app APIs) and 2222
  (phone-approved SSH), DNS `10.0.1.20` TCP/UDP 53. Other private destinations,
  host admin SSH/Rex, and forwarded host-network connections into the guest are denied.
  NASA alone can reach the dedicated preview router at guest TCP 8099; preview
  app ports remain loopback-only. See [WIP previews](previews.md).
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

## Preloaded context

`robot-guide` explains available tools, systems, access paths, and limitations.
The source files are in `hosts/nasa/vms/context/`, deployed under `/etc/robot/`.
Home Manager installs the shared instructions as `~/.codex/AGENTS.md` and
`~/.claude/CLAUDE.md`, so new CLI sessions load them automatically. No personal
configuration or credentials are copied. `/home/robot/dev` is the project workspace.

### Agent permissions

The VM is the local execution boundary. Guest-only `codex` and `claude` launchers
select Codex `sandbox_mode = "danger-full-access"` / `approval_policy = "never"`
and Claude Code `--permission-mode bypassPermissions`. Local work, downloads,
builds, caches, and Git operations therefore do not require per-command approval.
Existing user configuration and authentication files are preserved. Explicit CLI
options can choose stricter modes. These launchers apply to programs invoked
through the guest system PATH; clients bundling their own agent executable or
imposing a session permission profile must be configured separately. Existing
sessions retain their permissions; start a new session after deployment.

Shared agent instructions require approval for external writes unless the user's
request or the project's delivery instructions already authorize the action.
Authorized external reads need no additional chat confirmation. This distinction
is an agent instruction, not a read/write filter on outgoing HTTPS: an agent can
use the scoped credentials available to `robot`. The no-sudo account, VM/network
isolation, scoped credentials, NASA phone-approved access gate, and owner-reviewed
release process remain enforced separately. This does not grant new external
access or permission to bypass those controls.

References: [Codex sandbox and approvals](https://learn.chatgpt.com/docs/agent-approvals-security),
[Claude Code permissions](https://code.claude.com/docs/en/permissions).

The repository catalog distinguishes access from delivery: `jmalexan/nix` uses
the scoped bot and owner-approved PR releases; ordinary projects follow the user's
request, including branch-only work. Public cloning works now. Other private
repos or push targets need deliberately provisioned access. A trusted Git broker
for selected collaborator repositories is configured for activation; see
[Git broker](git-broker.md). It retains the upstream credential outside the VM
and performs only allowlisted Git operations. Activation still needs an explicit
repository policy and separately provisioned credentials. Do not fall back to forwarding the owner's agent or handing
the VM a broad token. GitHub currently does not support fine-grained PATs for
outside/repository collaborators.

References: [Codex global instructions](https://learn.chatgpt.com/docs/agent-configuration/agents-md),
[Claude Code memory](https://code.claude.com/docs/en/memory),
[GitHub token limitations](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens#fine-grained-personal-access-tokens-limitations).

## Credentials and release

The repository-scoped GitHub App signing key is age-encrypted to the existing
NASA/owner recipients. The VM never receives any of those decryption keys.
NASA decrypts the file with agenix; systemd loads it into the QEMU service's
private credential directory;
QEMU fw_cfg passes them to the guest service manager. Only the scoped bot key and
approval requester token are installed for `robot`, in mode-0600 files. The
requester can ask for access; it cannot approve requests. No worker, gate,
enrollment, deployment, or owner credentials are passed into the guest.

The guest Tailscale daemon owns its persistent node state; `robot` is not its
operator. Enrollment succeeded in PR #57. This cleanup removes the spent one-use
key, its encrypted file, and its host/guest credential wiring. Ordinary reconnects
and restarts reuse the identity in `/var/lib/tailscale`; readiness waits for a
running identity tagged `tag:agent` before starting Rex Serve. It never attempts
automatic enrollment. Recreating the disk requires authorized administrator
recovery with a fresh one-use `tag:agent` key, delivered only to the root daemon.
Do not enroll under the owner's identity or give `robot` Tailscale operator rights.

The deployment framework and VM went live through owner-merged PR #57. Its
[production run](https://github.com/jmalexan/nix/actions/runs/42166728888) succeeded.
The enrollment cleanup targets NASA and restarts `robots`, preserving its disk
and Tailscale identity. It does not restart `home`.
Guest runtime changes restart the VM, so save agent work before
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
   Codex supports `codex login --device-auth`; authorize its one-time code in
   your browser. For Claude subscriptions use `claude auth login --claudeai`,
   open its URL, and paste the returned code directly into that terminal.
   Check `codex login status` and `claude auth status`; do not print auth files.
   These fresh CLI logins stay on the VM disk across releases. They do not move
   this conversation or install the personal environment's plugins/configuration.
5. Verify an approved read-only NASA request using `nasa-approved-access --reason
   'Verify the new agent VM' -- hostname`. It still requires explicit phone
   approval, has no sudo, and expires after 15 minutes. Ordinary NAS SSH remains
   blocked. The repository wrapper honors `NASA_APPROVAL_REQUESTER_FILE` too.
6. Verify from a new session actually running on `robots` that owner credential
   files and personal machines are unavailable. This setup session remains in
   `home` until the client is switched; preparing the VM does not move it.

The bot key is deliberately repository-scoped. After the approval-based policy
is activated, its PRs require the owner's current approval and passing checks;
the bot cannot push main directly, approve its own work, or change protections.
Your personal credentials remain in `home`. Do not revoke
those credentials as part of this migration. The old agent sessions in `home`
must be closed once work moves to the VM.

The public Nix repository is cloned at `/home/robot/dev/nix`. Authenticated Rex
access is `https://robot@robots.tailf18bf1.ts.net:7297`; ordinary SSH uses
`ssh robot@robots`. The guest pins NASA's public SSH host key in
`/etc/ssh/ssh_known_hosts` so the approval client keeps strict host verification.
During setup the same public key was added to `robot`'s user known-hosts file
to test the gate before releasing the declarative configuration.

Setup verification on 2026-11-06: Codex device login completed, and the live
phone-approved connection returned `nasa` with exit status 0. The caller was
`robot` on `robots`; ordinary host SSH/Rex remained unreachable. Claude Code is
installed, but its sign-in is deferred at the owner's request. The private-repo
broker and app design follow-ups remain deferred too.

Login references: [Codex authentication](https://learn.chatgpt.com/docs/auth?surface=cli),
[Claude Code authentication](https://code.claude.com/docs/en/authentication).

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
authenticated Rex connectivity, and guest readiness were verified after PR #57
deployed. Repeat readiness and identity checks after deploying enrollment cleanup.

Use CI for routine guest updates. For recovery, use the authorized NASA access
workflow; the agent guest is not an administrator backdoor. A host administrator
can stop `microvm@robots`, preserve/copy its disk, or restore a previous NASA
configuration. The daily encrypted Restic job backs up an atomic ZFS snapshot
of the persistent VM disk without stopping robots. See [backup and disk restore](nasa-recovery.md#robots-vm-disk)
for consistency limits and recovery steps. Keep source in Git as well.

References: [microvm host](https://microvm-nix.github.io/microvm.nix/host.html),
[systemd credentials](https://systemd.io/CREDENTIALS/),
[Tailscale selectors](https://tailscale.com/docs/reference/targets-and-selectors).

## Deployment restarts and journal access

The microvm service keeps its restart trigger tied to the guest system closure.
Host-only changes do not restart robots. The Git broker and approved-access
clients package only their runtime Python files, so changes to server handlers,
tests, or packaging defaults do not change the guest image. Client code, guest
packages, mounts, boot settings, and credential-delivery configuration still
apply through a VM restart; deployments do not silently leave an old guest running.

`nasa-journalctl` accepts ordinary journalctl filters, including `-u`, `--since`,
`-n`, and `-f`. It reads the live persistent journal, including rotated files;
it cannot change host logs. Log files can contain operationally sensitive data,
so treat their contents as private and avoid copying secrets into chat or commits.
The QEMU service has journal read permission; no host control socket is shared.

The personal home container no longer mounts NASA’s journal or installs the
wrapper, Codex, or Claude Code through the shared development module. Its shell,
Rex access, development tools, personal files, credentials, and repositories stay
in place. Existing user-installed software and login state are not deleted.

## Package store across image updates

Boot packages are retained in the writable store before the Nix daemon starts,
so replacing the read-only image does not strand locally installed dependencies.
See [persistent package store](agent-store.md) for startup behavior, disk usage,
image symlink preservation, and the two-generation boot regression.
