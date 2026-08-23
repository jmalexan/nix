# RomM library links with Igir

The NAS installs the Igir version pinned by this flake and provides the manual
`romm-igir-link.service`. It creates absolute symbolic links from the untouched
torrent tree into RomM's Structure A library:

```text
/Data/smb/ROMs/
├── roms/{romm-platform-slug}/...
└── bios/{romm-platform-slug}/...
```

The exact torrent subdirectories and DAT locations are not stored in this
repository yet, so the job set is intentionally empty. Declare jobs in
`hosts/nasa/services/romm.nix` once those paths are known. For example:

```nix
services.rommIgir = {
  jobs = {
    no-intro = {
      inputs = [
        "/Data/smb/Torrents/ROMs/No-Intro"
        "/Data/smb/Torrents/ROMs/No-Intro-updates/**/*.zip"
      ];
      dats = [
        "/Data/smb/ROM-DATs/No-Intro/**/*.dat"
        "/Data/smb/ROM-DATs/No-Intro/**/*.xml"
      ];
      extraArgs = [
        "--prefer-region"
        "USA,WORLD,EUR"
      ];
    };

    mame-0278 = {
      inputs = [ "/Data/smb/Torrents/ROMs/MAME 0.278" ];
      dats = [ "/Data/smb/ROM-DATs/MAME/MAME 0.278.dat" ];
      extraArgs = [
        "--merge-roms"
        "split"
      ];
    };
  };
};
```

Each job accepts multiple `inputs` and `dats`. Add another path to either list
when a torrent or DAT set expands. Add another named job when its matching,
filtering, or MAME merge settings differ. Igir expands the globs itself, so keep
them as Nix strings rather than relying on shell expansion.

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

Routine verification is off because adding Igir's `test` command can make runs
significantly slower. Set `services.rommIgir.verify = true` globally or
`jobs.<name>.verify = true` for selected jobs.

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
