# RomM library links with Igir

The NAS installs the Igir version pinned by this flake and provides the manual
`romm-igir-link.service`. It creates absolute symbolic links from the untouched
torrent tree into RomM's Structure A library:

```text
/Data/smb/ROMs/
├── roms/{romm-platform-slug}/...
└── bios/{romm-platform-slug}/...
```

The configured jobs scan the entire qBittorrent ROM category. This lets new
providers and separately downloaded BIOS sets work without changing Nix, as
long as they remain somewhere below `/Data/smb/Torrents/ROMs`:

```nix
services.rommIgir.jobs.console-1g1r = {
  inputs = [ "/Data/smb/Torrents/ROMs" ];
  dats = [ "/Data/smb/ROM-DATs/Console/**/*.dat" ];
  bios = false;
  verify = true;
  extraArgs = [
    "--single"
    "--prefer-language"
    "EN"
    "--prefer-region"
    "USA,WORLD,EUR,JPN"
    "--prefer-retail"
    "--prefer-good"
    "--prefer-verified"
    "--prefer-revision"
    "newer"
  ];
};

services.rommIgir.jobs.console-bios = {
  inputs = [ "/Data/smb/Torrents/ROMs" ];
  dats = [ "/Data/smb/ROM-DATs/Console/**/*.dat" ];
  roms = false;
  verify = true;
};
```

The first job builds a USA-first English 1G1R console collection. The second
keeps the same 1G1R preferences away from BIOS selection. Adding ROM or BIOS
torrents below the input root requires no configuration change. Adding another
No-Intro console DAT below `/Data/smb/ROM-DATs/Console` likewise takes effect on
the next run. Igir expands the glob itself rather than relying on the shell.

Keep MAME DATs out of the Console DAT tree. MAME requires a separate job whose
DAT, source set, emulator version, and `--merge-roms` mode agree.

By default, every job performs two passes equivalent to `igir link`: one with
`--no-bios` into `roms/{romm}`, and one with `--only-bios` into `bios/{romm}`.
Both use `--link-mode symlink` and `--overwrite-invalid`; the workflow never
invokes `clean`, `move`, `copy`, `extract`, or `zip`. Existing unmatched output
is therefore left alone. Set `roms = false` or `bios = false` only for a set
that should run one pass.

## Platform mappings

Igir's built-in `{romm}` token normally produces RomM platform slugs. If a DAT
has no mapping, use one of these approaches:

- For a job containing one platform, set `platformSlug = "the-romm-slug"`.
- For a multi-DAT job, set `outputConsoleTokens` to the absolute path of an
  Igir-compatible custom token JSON file that defines the RomM values.

If a torrent root lives outside `/Data/smb/Torrents`, also add its common root
to `services.rommIgir.torrentRoots`. Every listed root is mounted read-only in
the RomM container at exactly the same absolute path. This is required because
absolute links are resolved in the container's filesystem, not on the host.

## Running and scheduling

After deploying a non-empty job configuration, run:

```console
sudo systemctl start romm-igir-link.service
sudo systemctl status romm-igir-link.service
```

Review its output with `journalctl -u romm-igir-link.service`. Only after Igir
finishes successfully should you start a RomM scan from its authenticated web
UI. The repository has no safe authenticated scan hook, so the service does not
trigger one.

Both current jobs enable verification for the initial library build. After the
links have been inspected successfully, set their `verify` values to `false` to
make routine runs faster. The module-wide default remains off; verification can
also be controlled with `services.rommIgir.verify` or per job.

An optional timer is available but disabled. Enable it only after choosing a
schedule appropriate for the downloads:

```nix
services.rommIgir.timer = {
  enable = true;
  onCalendar = "daily";
  randomizedDelaySec = "1h";
};
```

The service runs as `jmalexan:media`: `/Data/smb/ROMs` is writable by that
account, and qBittorrent's `/Data/smb/Torrents` tree is group-readable. Ensure
any separately managed DAT directory is readable by `jmalexan` before running.

## Format limitations

- Igir can link a real per-game source file such as a ZIP, CHD, ISO, or loose
  ROM. A symlink cannot represent one ROM that exists only inside a large
  multi-game archive. Use a torrent with per-game files or a separate copying
  or extraction workflow for that layout.
- BIOS sorting requires the DAT to identify BIOS entries with `isbios="yes"`
  or `[BIOS]`. Unmarked firmware cannot be separated reliably.
- MAME DAT version and `--merge-roms` mode must match both the source set and
  emulator version. Do not reuse a console job's defaults without checking.
- `--overwrite-invalid` replaces invalid destinations, but unmatched stale
  links are deliberately retained. Remove one manually only after confirming
  it is no longer wanted.
