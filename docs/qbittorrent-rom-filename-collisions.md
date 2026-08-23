# qBittorrent ROM filename collisions

## Summary

qBittorrent can mishandle multi-file torrents that contain two paths differing
only by letter case. This is particularly likely in ROM collections, where both
spellings may be intentional and valid on the NAS's case-sensitive filesystem.

The issue was reproduced on the NAS with qBittorrent 5.2.2 and
libtorrent-rasterbar 2.0.12. Track upstream progress in:

- [qBittorrent issue #24292](https://github.com/qbittorrent/qBittorrent/issues/24292)
- [Proposed qBittorrent fix #24556](https://github.com/qbittorrent/qBittorrent/pull/24556)

The proposed fix was still unmerged when this note was written on 2026-08-23.
Do not assume that a newer package contains it without checking the release or
merged commit.

## Confirmed example

Torrent `6864d0c06b48365d208c7c5f2b1570087f4712de` contains 7,101 files and one
case-folded path collision:

```text
No-Intro/Nintendo - Nintendo Entertainment System (Headered)/RoboCop Versus The Terminator (USA) (Proto).zip
No-Intro/Nintendo - Nintendo Entertainment System (Headered)/RoboCop versus The Terminator (USA) (Proto).zip
```

Both 139,300-byte files occupy piece 868. The torrent has 1,289 pieces of 1 MiB
each, so losing that one piece leaves approximately `1288 / 1289 = 99.92%`,
which qBittorrent displays as 99.9%.

On restart, libtorrent may resolve a colliding filename to a generated name
such as `name.1.zip`, while qBittorrent's resume data still describes the
original paths. qBittorrent then rejects the fast-resume data. A representative
log message is:

```text
Failed to restore torrent. Files were probably moved or storage isn't accessible.
Reason: fast resume rejected. file_stat(.../name.1.zip): mismatching file size
```

One mismatched file causes the entire torrent to appear under **Missing Files**;
it does not mean that every payload file has disappeared. A force recheck can
restore the torrent for the current session, but the mismatch can recur after a
restart.

## Symptoms

- A ROM torrent stalls at 99.9% despite availability greater than 1.0.
- Force recheck returns to 99.9%, or temporarily restores the torrent.
- Restarting qBittorrent changes recent torrents to **Missing Files**.
- The execution log mentions a generated numeric suffix such as `.1.zip` and a
  mismatching file size.
- The Wasted counter may increase. This counter alone does not prove hash
  failures because it also includes duplicate or cancelled endgame traffic.

The Igir workflow is not responsible for changing the source payload. It reads
`/Data/smb/Torrents/ROMs` and creates symlinks in
`/Data/smb/Games/Library`.

## Manual workaround

Until a verified upstream fix is deployed:

1. Pause the affected torrent.
2. In qBittorrent's Content view, identify paths that are identical after
   case-folding.
3. Rename one member of each pair through qBittorrent. Add a genuinely unique
   suffix; changing capitalization alone is insufficient.
4. Force recheck the torrent, then resume it.
5. After it reaches 100%, restart qBittorrent once and confirm it restores and
   rechecks cleanly.

Keep the original spelling in a note if it matters to downstream DAT tooling.
Igir normally identifies ROM content using DAT metadata, but rerun
`romm-igir-link.service` and its verification after renaming source archives.

Avoid repeatedly resuming a torrent that alternates between 99.9% and
**Missing Files**. Preserve the payload and qBittorrent profile before trying
bulk resume-data repairs.

## Removing the workaround

When the upstream pull request or an equivalent fix lands:

1. Confirm the fix is included in the qBittorrent release packaged by the
   pinned Nixpkgs revision; a merged pull request alone is not sufficient.
2. Deploy the updated package normally.
3. Test with a representative torrent containing two case-only paths.
4. Confirm it reaches 100%, survives a qBittorrent restart without **Missing
   Files**, and remains at 100% after force recheck.
5. Only then consider restoring manually renamed files to their original names.

If an interim package patch is needed, keep it local to
`hosts/nasa/services/qbittorrent.nix`, reference the upstream commit, and remove
it once the pinned package contains the fix.
