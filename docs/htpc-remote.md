# HTPC remote and playback

Remote input crosses three declarations:

1. `hosts/htpc/remote.nix` maps Flirc/HID buttons to keyboard events.
2. `home/htpc.nix` maps those events to mpv and jellyfin-mpv-shim behavior and
   owns Bigscreen launchers, MIME associations, and keymap options.
3. `home/htpc/plasma.nix` releases Plasma's global media-key grabs and pins the
   two shell shortcuts used by the remote.

Keep those files synchronized when changing a button. In particular, F13-F17
require the `fkeys:basic_13-24` KWin keymap option, while the transport buttons
must remain unassigned in Plasma so they reach the focused player.

The shim's `conf.json` is merged during Home Manager activation rather than
being linked read-only. Restart it after a settings change:

```console
systemctl --user restart jellyfin-mpv-shim
```

KWin keymap and global-shortcut changes are most reliably tested after logging
out and back in. Test tap and hold behavior separately: mpv owns repeat timing,
and the shim's script-bound D-pad does not repeat in the same way as native mpv
bindings.
