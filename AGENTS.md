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
