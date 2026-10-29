# BookOrbit manga metadata

The NAS runs the MangaBaka metadata provider alongside BookOrbit on its private
Docker network. Both images are pinned by version and digest in
`hosts/nasa/services/bookorbit.nix` and tracked by the updates dashboard.
External providers require BookOrbit 3.6.0 or later. The provider publishes no
host port, mounts no library files, and needs no API key or persistent storage.

## Enable after deployment

Provider registration and field rules are stored in BookOrbit's database, so
these steps are needed once after deploying the NixOS configuration:

1. Open **Settings > Metadata > Providers > External** as a BookOrbit admin.
2. Add MangaBaka with the address `http://bookorbit-mangabaka:8080`. If its
   directory card pre-fills `http://mangabaka:8080`, replace that address.
3. Enable **Allow private address**, save, choose **Test**, and enable the
   provider. Leave the authorization header empty on this private network.
4. Choose **Use in field rules**, or add MangaBaka to individual rules under
   **Settings > Metadata > Field Rules**. For manga, put it ahead of general
   sources for title and series. Use its covers when a series cover is suitable.
   Review the scope of those rules before changing priorities: this instance
   also has a prose library.
5. Try **Edit Metadata > Search** on a manga volume and review the proposed
   fields before running a bulk refresh.

## Coverage and limits

MangaBaka covers manga, manhwa, manhua, and light novels. It supplies series
titles, descriptions, authors, genres, tags, ratings, and series covers.
Queries such as `Berserk Vol. 3`, `Berserk v03`, and `One Piece #5` preserve the
volume number in the returned title and series position. A bare trailing
number is not treated as a volume, since it may be part of the series title.

Its records describe a series rather than an individual edition. It does not
supply ISBNs, page counts, volume-specific covers, or later volumes' publication
dates. Keep other sources in the rules for edition-specific metadata. The
provider's default throttling respects MangaBaka's API limits.

## Troubleshooting

Inspect copied NAS logs with:

```console
nasa-journalctl -u docker-bookorbit-mangabaka.service -u docker-bookorbit.service --since "1 hour ago" --no-pager -n 200
```

For a private-address error, enable **Allow private address** on the provider.
For connection errors, check its address and container logs; `localhost` points
to BookOrbit itself. After a provider update, choose **Test** to refresh its
reported version immediately.

Upstream references: [BookOrbit provider setup](https://github.com/bookorbit/bookorbit/blob/v3.6.0/docs/METADATA_PROVIDERS.md)
and [MangaBaka provider mapping](https://github.com/bookorbit/bookorbit-metadata-providers/tree/main/providers/mangabaka).
