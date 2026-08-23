# RomM library links with Igir

The NAS installs Igir 5.4.0 from the source and npm dependency hashes pinned in
`packages/igir.nix`, and provides the manual `romm-igir-link.service`. It
creates absolute symbolic links from the untouched torrent tree into RomM's
Structure A library:

```text
/Data/smb/Games/
├── Library/
│   ├── roms/{romm-platform-slug}/...
│   └── bios/{romm-platform-slug}/...
├── DATs/
│   └── Console/*.dat
└── Patches/
    └── {romm-platform-slug}/{game}/...
```

`Library` is RomM's generated view, `DATs` contains identification metadata,
and `Patches` is reserved for original patch files. qBittorrent intake remains
under `/Data/smb/Torrents/ROMs`; it is intentionally outside the curated games
tree and remains untouched.

The configured jobs scan the entire qBittorrent ROM category. This lets new
providers and separately downloaded BIOS sets work without changing Nix, as
long as they remain somewhere below `/Data/smb/Torrents/ROMs`:

Some ROM torrents contain filenames that differ only by letter case. See
[qBittorrent ROM filename collisions](qbittorrent-rom-filename-collisions.md)
before troubleshooting torrents stalled at 99.9% or marked **Missing Files**
after a qBittorrent restart.

```nix
services.rommIgir.jobs.console-1g1r = {
  inputs = [ "/Data/smb/Torrents/ROMs" ];
  dats = [ "/Data/smb/Games/DATs/Console/**/*.dat" ];
  bios = false;
  verify = false;
  extraArgs = [
    "--input-checksum-quick"
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
  dats = [ "/Data/smb/Games/DATs/Console/**/*.dat" ];
  roms = false;
  verify = false;
  extraArgs = [ "--input-checksum-quick" ];
};
```

The first job builds a USA-first English 1G1R console collection. The second
keeps the same 1G1R preferences away from BIOS selection. Adding ROM or BIOS
torrents below the input root requires no configuration change. Adding another
No-Intro console DAT below `/Data/smb/Games/DATs/Console` likewise takes effect
on the next run. Igir expands the glob itself rather than relying on the shell.

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

## One-time storage migration

Move the existing library and DAT tree before deploying this path change. The
commands preserve the directories and their contents; they do not copy or
rewrite any ROM, BIOS, DAT, or torrent file. Stop RomM first so it cannot scan
while the host paths are changing:

```console
sudo systemctl stop romm-igir-link.service docker-romm.service
test ! -e /Data/smb/Games/Library
test ! -e /Data/smb/Games/DATs
sudo install -d -m 0755 -o jmalexan -g root /Data/smb/Games
sudo mv /Data/smb/ROMs /Data/smb/Games/Library
sudo mv /Data/smb/ROM-DATs /Data/smb/Games/DATs
```

Both `test` commands must succeed before either move. If one fails, inspect the
existing destination instead of nesting the old directory inside it. Deploy
the new Nix configuration after the moves; the changed RomM unit will mount
`Games/Library` back at the same `/romm/library` container path.

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

Routine runs share the original `console-1g1r.cache`, skip the expensive `test`
pass, trust checksums embedded in qBittorrent-verified archives, and omit
per-file verbose logging. Set a job's `verify` value or the module-wide
`services.rommIgir.verify` to `true` when a full verification pass is wanted.

An optional timer is available but disabled. Enable it only after choosing a
schedule appropriate for the downloads:

```nix
services.rommIgir.timer = {
  enable = true;
  onCalendar = "daily";
  randomizedDelaySec = "1h";
};
```

The service runs as `jmalexan:media`: `/Data/smb/Games/Library` is writable by
that account, and qBittorrent's `/Data/smb/Torrents` tree is group-readable.
Ensure any separately managed DAT directory is readable by `jmalexan` before
running.

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
