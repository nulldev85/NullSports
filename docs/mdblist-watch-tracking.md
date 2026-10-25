# Watch tracking on iPhone and Apple TV

Settings > Tracking provides independent **Local Tracking** and **MDBList
Tracking** switches. Existing installations start with local tracking on and
MDBList tracking off. Connecting an API key for catalogs/ratings does not opt
the viewer into account writes.

| Local | MDBList | Library behavior |
| --- | --- | --- |
| On | Off | Existing device progress, history and Up Next |
| On | On | Device history stays saved separately; newer matched account progress supplies Library resume points, with current playback and newer local choices protected; playback and explicit watched/unwatched actions also go to MDBList |
| Off | On | Account history, active/paused progress and Up Next are matched to connected Library titles; pending activity is cached for retries |
| Off | Off | No Lineup playback/history writes; saved device and account histories are retained |

Device history keeps its existing defaults key. The MDBList working cache,
downloaded snapshot and durable outbox are scoped to the verified MDBList user
ID. An API-key digest binds that account to the current Keychain credential;
the actual API key is not stored in preferences or queued events. No existing
local history is bulk uploaded when tracking is enabled. Switching modes does
not erase either history. Existing explicit media-server actions are separate.

## Playback and matching

Library players report existing native playback samples: start/resume, pause,
periodic progress (at most one start update per minute), stop and actual EOF.
Opening a source without playback sends no scrobble. Scrubbing previews do not
become account progress. Session/source checks reject obsolete callbacks; a
native clock reset during teardown cannot turn the final stop into zero.
The tracking callback is absent from Guide, live channels and sports playback.
Playback engines, episode selection and automatic navigation are unchanged.

Movies use verified IMDb/TMDb identity. Episode scrobbles use the parent show's
TMDb identity and verified TMDb episode coordinates. A TVDB episode ID is
converted with TMDb's external-ID lookup and checked against the parent show.
Manual episode marks prefer direct episode IDs. Provider numbering without
identity evidence is not guessed. Unmatched titles are surfaced in Tracking.

Account imports in both tracking modes match namespaced external IDs, then verified episode IDs
or explicit TMDb/TVDB numbering evidence. Resume points with materially
different runtimes are not applied to another cut. Full cursor-paginated movie
and episode history, paused playback, active Now Playing and paginated Up Next must all succeed
before a snapshot is published. Failed/malformed pages keep the previous data.
An authoritative empty snapshot can clear the account cache without touching
device history. Inventory/episode read failures keep the working Library cache.

MDBList marks a title watched on pause/stop at 80%. Device tracking retains its
existing 92%/last-two-minutes completion policy. With both enabled, MDBList's
threshold does not rewrite saved device history. A newer account watched record
can appear in the merged Library, while active local playback retains its own
completion policy. Library completion does
not retire the account session before its final stop.

## Delivery and account changes

A serialized writer coalesces stale progress. Explicit watched/unwatched marks
retire queued samples that could undo the newer choice. HTTP failures retain
the outbox with bounded exponential retry; 429 honors Retry-After across app
relaunches. Authentication failures require reconnecting. Invalid acknowledgments
are not treated as success. A new local write invalidates an older downloaded
snapshot until the next full read. Outdated starts are not resurrected later.

Sync Now queues the latest actual player sample even when the normal minute
heartbeat is not due. It waits for pending identity resolution and upload
acknowledgements before requesting the full account snapshot. A Sync Now tap
during another write/read is retained and coalesced. Retry-After and authentication
blocks still apply; Sync Now does not bypass them or replay stale starts.

The active session endpoint is `/sync/now-playing`; `/sync/playback` contains
paused resume points. Active imports use the server's `progress_at_update` anchor
rather than projecting an unobserved playback clock. Expired sessions are ignored.
When MDBList reports an unknown runtime, an exact matched server item's details
can supply it. Materially different known runtimes are still rejected. A failed
inventory/details read keeps the previous mapped cache. Both-on mode merges the
mapped account records at read time without modifying the local-history defaults
key. Opting out immediately removes that account overlay.

Disabling account tracking cancels outstanding work and discards that account's
pending outbox. Account changes invalidate pending identity resolutions and
late responses; old events cannot be delivered with another account's key.
Saved history caches remain scoped to their original account. No further
scrobbles are sent after opting out; MDBList manages any session expiry.

This extends watch tracking, not personal-rating editing, OAuth/device login,
watchlist management or list editing. Existing catalogs and ratings continue
to use the current integration independently of these switches.

## Validation

Shared SDK regressions cover defaults, independent caches, opt-out,
real MediaLibrary start/pause/stop/EOF/PiP callbacks, both completion rules,
manual actions, TMDb/TVDB episode mapping, source/numbering isolation, cursor
pagination, malformed/partial/empty snapshots, durable rate-limit backoff,
account switches and failed acknowledgments. Existing real Aether MP4/MKV and
VLC playback tests additionally require tracking samples from the same player.
Both full platform suites remain enabled; no assertions or deadlines weakened.

The cross-device repair adds two independently persisted virtual-device instances
sharing a mocked account: a TV sample is synced before its heartbeat, then imported
on a phone with both switches enabled and different server/item IDs. It covers
active and paused buckets, unknown-runtime details, unchanged saved local bytes,
current playback and newer manual choices. A blocked-writer regression proves
Sync Now reads after acknowledged uploads, including a newer queued sample.
Snapshot coverage also checks active clock anchors and expired sessions. These
new SDK cases require the iPhone 146 / tvOS 94 CI builds; they are not run on Windows.

Local metadata/source-membership, playback project/pin, tvOS focus and diff
checks pass. Windows has no Apple SDK: Swift compilation, SDK tests, IPA
packaging and device behavior remain pending the dispatched CI builds.

Builds iPhone 132 and tvOS 88 stopped at app compilation: the episode identity
path redeclared `parent` in the same scope. The identified parent now has its
own binding. No SDK tests ran and neither workflow packaged an IPA. The
replacement builds retain the complete test suites and tracking behavior.

The next builds (iPhone 133 and tvOS 89) compiled both apps and ran their full
SDK suites. All 19 MDBList tests and the real Aether/VLC tracking callback
checks passed. An existing local-tracking regression failed on both: a manual
unwatched choice could be overwritten by a late EOF callback. The account
session used a source-qualified item key, while older/synthetic manual actions
can carry an unqualified item. Manual session retirement now uses the same
resolved source and episode-alias identity as local tracking. A surviving
account session may send its final stop without reviving a retired device
session. Two added regressions cover unqualified manual edits plus late
progress/EOF, and account completion after clearing device history. The
original failing regression remains unchanged. SDK verification of this repair
is pending the replacement builds.

API contract references (reviewed October 25, 2026):
- https://api.mdblist.com/docs/
- https://api.mdblist.com/schema/
- https://api.mdblist.com/docs/authentication/
