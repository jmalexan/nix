# Infrastructure debugging

The current environment has a read-only local wrapper for inspecting logs copied from the `nasa` host:

```sh
nasa-journalctl [journalctl arguments]
```

Use this wrapper first for NAS service debugging instead of attempting SSH, `journalctl -M .host`, or a systemd journal gateway. It accepts normal `journalctl` filters, for example:

```sh
nasa-journalctl -u ddclient.service --since "30 days ago" --no-pager -n 300
```

The wrapper may print a harmless warning about a missing journal directory before returning available NAS journal entries.

# NAS access

Use an application's authenticated API for application operations, and the copied
journal wrapper above for logs. Do not start with SSH when either covers the task.

When a task needs host filesystem access or another operation the APIs cannot
perform, explain that specific need and obtain explicit permission before opening
a NASA SSH connection, even when credentials are available. Permission to edit
or test this repository does not authorize a host connection. Prefer
`tools/nasa-access.py --approved --reason '...' -- <command>`: it requests explicit
phone approval before connecting as `nasa-automation`, with read-only host files,
no sudo, and a 15-minute maximum. Approval in the app is the connection permission;
do not ask for duplicate chat confirmation. It uses a temporary key and needs no
forwarded agent. It never falls back to administrator access.

If the task needs privileges the gate does not provide, explain that specific
need and obtain explicit permission for the legacy maintenance connection through
`tools/nasa-access.py` without `--approved`. That mode uses a temporarily forwarded
SSH agent. Both modes verify the host key, disable further agent forwarding, and
record the reason and exit status. Neither authorizes unrelated operations.

Do not install a persistent NAS private key, change SSH authorization, disable
host-key checking, or expose host/container control sockets as an access shortcut.
If a permitted legacy maintenance task has no forwarded agent available, finish
independent work and request the missing connection. See `docs/nasa-access.md`
for setup and examples.
