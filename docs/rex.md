# Rex remote terminals

`modules/rex.nix` enables the official Rex NixOS login server on `nasa`,
`htpc`, and the `home` container. Sessions run as `jmalexan`; only the
Tailscale identity in `vars.user.tailscaleLogin` can access that account.
The login server uses PAM and preserves account sessions when it restarts.

Rex is pinned to the official preview channel in `flake.lock`. Update it with
`nix flake update rex rex-unstable`, then run the normal checks and deploy. The
two inputs follow each host's Nixpkgs channel so the binary's glibc matches
the PAM modules it loads at login. The upstream
module installs the CLI, terminfo, PAM policy, and SSH terminal fallback.

## Connect from the app

Connect the client device to Tailscale. In Rex for Mac, choose **Add Remote
Host…** and enter each address:

| Host | Address |
| --- | --- |
| NAS | `https://nasa.tailf18bf1.ts.net:7297` |
| Development container | `https://home.tailf18bf1.ts.net:7297` |
| Media PC | `https://htpc.tailf18bf1.ts.net:7297` |

The single allowed account is selected automatically. The HTPC must be awake;
run `wake-htpc` on the NAS if needed. CLI host registrations do not sync to
the app; add these addresses in the app itself.

For a CLI connection:

```console
rex -S https://nasa.tailf18bf1.ts.net:7297 ls
```

## Enrollment and deployment

Deploy `nasa` to update both the NAS and its `home` container; deploy `htpc`
separately using the normal repository deployment workflow. The `home`
container uses Tailscale userspace networking, so it needs no TUN device or
extra device permissions. On its first deployment, enroll it once:

```console
sudo tailscale up --hostname=home --accept-dns=false
```

Open the displayed login URL and authenticate to the same tailnet as the
other hosts. `--accept-dns=false` preserves the container's existing LAN DNS.
Confirm the allocated MagicDNS name with `tailscale status`; if Tailscale
adds a suffix because the name is already taken, use that name in the app.

MagicDNS and HTTPS certificates must be enabled for the tailnet. The module
manages Tailscale Serve on port 7297 and leaves port 443 available for the
NAS web services. Do not manually replace its Serve mapping. No public
HTTP listener or anonymous account access is enabled.

## Check service health

On each host:

```console
systemctl status rex-login-server rex-tailscale-serve
tailscale serve status
cat /etc/rex/accounts.jsonc
rex terminfo status
```

For NAS logs from the development container, use the copied journal:

```console
nasa-journalctl -u rex-login-server -u rex-tailscale-serve --since today --no-pager
```

For the development container's own logs, use
`journalctl -u rex-login-server -u rex-tailscale-serve`. A Serve unit waiting
in `tailscale wait` usually means the host still needs Tailscale enrollment.

See upstream [installation](https://www.superlogical.com/rex/docs/linux/installation),
[login server](https://www.superlogical.com/rex/docs/linux/login-server), and
[remote access](https://www.superlogical.com/rex/docs/linux/remote-access) documentation.
