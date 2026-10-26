# MDBList-only resume and iPhone navigation polish

With Local Tracking off, the account working cache previously rebuilt player
progress using the catalog runtime before considering the real player duration.
A zero runtime became a one-second movie: a genuine 50% stop became a half-second
resume record and was filtered out of Continue Watching. A different nonzero
catalog runtime could also move the resume point to the wrong time. These code
paths can explain the reported same-device failure; private device/account logs
were not inspected.

The account cache now prefers the actual transport's measured duration, with a
validated catalog/prior-cache fallback only when no measurement exists. The real
percentage is still uploaded through the existing start/pause/stop API. The
pending account cache keeps Continue Watching available while that upload/read
completes; it does not silently enable Local Tracking or write its history key.

The cache retains an optional measured duration and a verified movie-ID link for
the exact provider/server item. Imports can therefore match a movie even when its
lightweight inventory row omits IDs or the VOD catalog is not yet loaded. No title
name matching, account mixing, source-ID substitution or extra catalog download
is introduced. Conflicting inventory IDs are rejected. Old cache data still
decodes because the fields are optional.

Account progress is converted using the known duration of that particular copy.
When a remote runtime describes a materially different cut, its percentage is not
applied; this device's actual resume point is retained. Newer watched history
still takes precedence. Existing complete-snapshot, account/opt-out isolation,
manual unwatched handling, empty-snapshot removal, retry and current-session
guards remain. Both-on mode still keeps saved device history separate.

For iPhone, selected non-glass tab labels now use the selected icon's accent
color. Glass and compact behavior remain. The official Seerr mark appears in
the Library menu, and TV Guide's menu has a matching entry opening the existing
Seerr screen. Login methods, playback and other Guide actions are unchanged.

## Validation

Four new shared SDK test cases cover VOD with zero runtime and a cold catalog;
Jellyfin with zero/missing/different catalog runtime; the actual 50% HTTP upload
and paused download, same-device display and relaunch; incompatible-cut retention
with newer watched-history precedence; exact cached movie identity with a
metadata-poor inventory and decoding of legacy caches. Device-history bytes are
required to remain unchanged in MDBList-only mode. Existing complete SDK suites
and all previous tracking regressions remain enabled.

Local metadata/source/resource/focus/pin/YAML/diff checks run on Windows. Swift,
Apple SDK and device behavior require CI and device testing. Build numbers:
iPhone 151 and Apple TV 97, since the tracking repair is shared by both targets.
Earlier running builds are not queried or cancelled; no merge is authorized.

MDBList's public OpenAPI schema was refreshed October 25, 2026. It documents
`/scrobble/pause` as saving resumable progress, `/scrobble/stop` below 80% as a
paused session, `/sync/playback` as paused progress, and `/sync/now-playing` as
active sessions. No personal account requests or credentials were used for the
documentation check.

References:
- https://api.mdblist.com/docs/
- https://api.mdblist.com/schema/
