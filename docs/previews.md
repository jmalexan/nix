# WIP app previews

Previews run inside `robots` and are available through NASA's private HTTPS
listener, without SSH tunnels or production app deployments. Up to eight can
run together, each with its own hostname, port, process, account database and
sample data. Use a separate checkout/worktree for each version you want to edit
independently. The launcher never switches branches or changes your checkout.

## Start and iterate

After the infrastructure release, `preview` is installed on `robots`:

```sh
cd /home/robot/dev/nix
preview start approve-layout --app approve
preview start updates-status --app updates --repo /home/robot/dev/nix-updates-app
preview list
```

Open `https://approve-layout.preview.nasa.jmalexan.com` on a desktop or phone
connected to the LAN or Tailscale. Sign in with the disposable password
`NASA preview password`. Production passwords and sessions do not apply.
Built-in adapters support `approve`, `updates`, and `backups`. Approve includes
pending, denied, and completed demo requests. Updates and Backups have synthetic
reports. Updates has no GitHub key or working scan/PR worker; Approve has no
connection gate, push credentials, or host worker. There is no production login
bypass: these factories exist only in the preview tool.

Starting a built-in preview runs `npm ci` when dependencies are absent, then the
frontend build. If package-lock.json changes later, run `npm ci` in that checkout
before refreshing. Static assets are copied into the instance, so building a
second version does not replace the first version's assets.

```sh
preview refresh approve-layout       # rebuild and restart, keeping sample state
preview watch approve-layout         # watch sources and refresh after edits
preview stop approve-layout          # stop and delete its disposable state
journalctl --user -u robot-preview-approve-layout.service -f
```

The watcher is optional: stopping it leaves the preview running. Browsers reload
automatically after a successful refresh, through a preview-only script inserted
by the router. A failed build leaves the existing app running. Backend changes
apply on restart. Refresh keeps the URL, sample account, app database and original
expiry deadline. Stop/start creates fresh state. Do not edit a worktree's branch
while a preview uses it; use another worktree/version instead.

The default lifetime is eight hours; `--hours 1` through `--hours 24` overrides
it. Expired routes immediately return 404. systemd stops processes at their
runtime limit; the five-minute cleanup timer stops any expired restarted unit
and removes its data. List/start/stop/refresh also clean up dead instances.
Previews stop on a VM reboot, and the cleanup timer removes their stale records.
Each instance has a 768 MiB, one-CPU, 128-task ceiling. Together they share a
2 GiB, 1.5-CPU, 512-task slice. Build commands run in the invoking shell outside
that slice. These limits bound resource use; processes still run as `robot`,
inside the existing VM boundary, rather than as separate security principals.

## Other app servers

The same router supports custom HTTP servers and WebSockets, including Vite HMR:

```sh
preview start new-ui --app custom --repo /home/robot/dev/nix -- \
  sh -c 'exec npm --prefix path/to/app run dev -- --host 127.0.0.1 --port "$PORT"'
```

Custom servers receive `PORT` and `PREVIEW_ORIGIN`. They must bind **only**
`127.0.0.1:$PORT`, accept the exact preview hostname, and use the HTTPS preview
origin for cookies, redirects and CSRF. Configure Vite's `allowedHosts` with that
exact hostname and HMR's external protocol/port as `wss`/443. Do not disable host
checks globally. The router preserves paths, Host, Origin and cookies. Custom
servers must provide their own sample data and safe integrations. `refresh`
restarts their command; custom file watching belongs to that server.

Lifecycle operations are local CLI commands only. The router offers no remote
start/stop, shell, file-serving or arbitrary upstream API. Unknown names return
404 and registry ports are restricted to the preview pool. Do not forward
production app/account sockets, secrets, or control sockets into a preview.

## Agent browser checks

Start the intended previews, then run Chromium through the existing Playwright
installation:

```sh
CHROMIUM_PATH=/path/to/chromium \
  nix develop .#microapps --command node tools/previews/browser-smoke.mjs approve-layout updates-status
```

This checks password sign-in, remembered sessions and separate origins, and
writes phone/desktop screenshots to `.local/preview-screenshots/`. Inspect those
screenshots and exercise the changed interaction before requesting review.
For infrastructure verification before release, `PREVIEW_ROUTER_URL` can point
the script at a loopback test router: Playwright forwards transport locally while
retaining the intended HTTPS browser origins. This does not verify deployed TLS,
DNS, the host/guest proxy connection, or physical phone behavior.

`nix build .#checks.x86_64-linux.previews` checks concurrent routing, HTTP request
bodies, cookies, WebSockets, expiry and reload behavior. CI runs it with the other
light checks.

## One-time infrastructure setup

The repository change configures NASA nginx, automatic private-CA certificate
coverage for `preview.nasa.jmalexan.com` and `*.preview.nasa.jmalexan.com`, and the
VM router/firewall/user services. The private listener allows the LAN, Tailscale,
NASA loopback and `robots`; the public photo listener cannot select this vhost.
NASA connects directly to `10.200.201.2:8099`, with only host source
`10.200.201.1` admitted by the guest. App ports remain loopback-only. There is no
new guest egress grant and no inbound forwarded LAN route to app ports.

**DNS prerequisite:** configure `*.preview.nasa.jmalexan.com` to resolve to
`10.0.1.10` in the DNS service used by LAN/Tailscale clients. The private DNS
service is Pi-hole and is outside this repository; the PR does not provision it.
For Pi-hole v6, append this entry to the existing `misc.dnsmasq_lines` array in
its host/container configuration, preserving all existing entries:

```text
address=/preview.nasa.jmalexan.com/10.0.1.10
```

Current Pi-hole disallows changing this option through its API; use the Pi-hole
host configuration or its Docker environment, then restart/reload FTL as required
by that deployment. See [Pi-hole configuration](https://docs.pi-hole.net/ftldns/configfile/#dnsmasq_lines).
Check an arbitrary name from both desktop and phone. Clients need the same private CA
trust and NASA LAN/subnet-route access as existing micro apps. No per-preview DNS
or certificate changes are needed afterward.

Release through the ordinary owner-reviewed PR workflow. This changes the guest
closure and restarts `robots` once, terminating running agent sessions/processes;
save work before release. Once deployed and DNS is ready, start two differently
named previews, verify HTTPS on desktop and phone, stop one and confirm the other
still works. Regular previews then require no PR or NASA connection.
