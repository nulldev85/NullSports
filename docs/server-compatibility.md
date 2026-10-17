# Server metadata, AIOStreams and EPGenius

This revision targets the documented contracts and reproducible gaps, rather
than changing metadata defaults in response to an unreported symptom. TMDB/TVDB
preferences, original server/item identities and local tracking remain intact.

## Metadata decoding

Optional item fields are read independently. Numeric/string provider IDs,
whole episode coordinates, years, durations and ratings are normalized without
letting an invalid optional field discard the title or its artwork. Fractional
episode/season numbers and out-of-range numbers do not become guessed episodes.
Raw provider snapshots still round-trip separately from resolved metadata.
Stream responses similarly retain valid records if another lacks an identity
or has malformed optional size/bitrate data.

## AIOStreams Jellyfin layer

Reviewed the official [Jellyfin setup](https://docs.aiostreams.viren070.me/apps/jellyfin/),
[API extensions](https://docs.aiostreams.viren070.me/reference/jellyfin-extensions/),
and stable [v2.36.0 source](https://github.com/Viren070/AIOStreams/tree/ce6244454ee131bf0945b2bd6abc670a449b224d/packages/server/src/routes/jellyfin).
Contract fixtures are synthetic; no tester account or private source is needed.

- Preserve personal `/jellyfin/u/<alias>` base paths and normal token auth.
- Keep page/catalog lookups lazy: no MediaSources field and no addon resolution
  simply to open a movie/show page. Ask PlaybackInfo when Play opens the list.
- Use advertised feature versions. Send Fresh when versions are supported;
  plain Jellyfin/Emby/Plex keep their normal requests.
- Read `aiostreams.id`, name, description and bingeGroup, and preserve the
  server's authoritative order for documented version lists. BingeGroup is
  retained as metadata; automatic matching of the next episode's release group
  is not added in this revision.
- Route selected documented versions through the server with their stable
  MediaSourceId and returned PlaySessionId. Do not bypass that snapshot using
  the old raw Path optimization. Legacy servers retain their existing fallback.
  Missing/stale versions fail through the server rather than borrowing another
  version's ID. These are direct-play requests, not transcoding requests.
- Exclude Type=Placeholder results, including no-stream notices.
- Required-genre catalogs use `/Genres?ParentId=...`, selecting the advertised
  None/all entry or the first advertised genre. Apply the returned GenreIds to
  shelves, browsing and hero-source reads. A full genre-selection interface is
  outside this revision.

The app does not advertise RequiredHttpHeaders or YouTube capabilities its
engines have not implemented. This work does not add AIOStreams user switching,
Quick Connect, tracker/history administration, or transcoding.

## EPGenius

The [official setup guide](https://epgenius.org/) supplies an M3U playlist and
XMLTV guide URL and explicitly requires an M3U connection. Lineup now offers
**M3U / EPGenius** alongside Xtream in Add Provider on iPhone and tvOS.
EPGenius curates the lineup and guide using the user's existing TV provider;
it does not supply video streams or provider credentials.
On tvOS with an existing provider, open **Settings → Sources → Live TV Sources
→ Add TV Source**, then choose **M3U / EPGenius** under Connection. The same
Live TV Sources menu selects saved connections; adding another does not replace
or activate it over the current provider. Select the saved connection to use it.

Paste the generated playlist URL and optional guide URL. A playlist's
x-tvg-url/url-tvg header can supply the guide. Known Google Drive file-share
URLs are converted to download URLs; HTML sign-in/permission pages and invalid
playlists cannot replace the last good data. Gzip XMLTV is expanded even without
a Content-Encoding header, under a decompression size limit. Invalid XMLTV
cannot silently clear a working guide.

Preserve tvg-id, group-title and tvg-logo. Channel identities derive from source
URLs with rotating auth query fields removed, not dynamic event titles. Two
different feeds sharing one guide ID remain separate. The normal refresh,
favorites, guide and sports matching paths then use those channels.

Connection URLs live in Keychain. Downloaded playback URLs and guide headers
are stored in an AES-GCM encrypted cache keyed from that secret, outside ordinary
channel snapshots. Public profile data contains only the playlist origin.

This supports live HTTP/HTTPS playlists and XMLTV. Xtream provider VOD and
catch-up routes are withheld for playlist profiles. Local-file importing,
non-HTTP sources, M3U-specific catch-up dialects and per-entry HTTP header
extensions are not implemented. Users still configure their EPGenius account
and provider credentials through EPGenius itself.

## Validation

Shared SDK tests cover malformed metadata, exact episode coordinates, stable
version IDs/order/session URLs, lazy item requests, real PlaybackInfo request
bodies, required-genre catalogs, M3U mapping/identity, encrypted caches,
compressed XMLTV, quality ranking and cache reuse/expiry. Both platforms also
probe real generated video fixtures, with an extensionless HTTP route on iPhone.
Full Apple SDK compilation, simulator suites and installable packaging run in
CI; local Windows checks cannot establish their success. Real EPGenius/AIOStreams
account and device playback review remains beta validation.
