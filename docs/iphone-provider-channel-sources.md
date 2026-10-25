# iPhone provider identity and game feeds

Build 142 supersedes the single-active-provider behavior described below.
See [Concurrent providers](iphone-concurrent-providers.md): enabled providers
are combined in Sports, TV Guide and Search, and selecting a feed no longer
switches the preferred account. Build 141's complete IPA workflow passed before
this extension; the new SDK regressions await the build142 workflow.

Build 138 adds the active IPTV provider's name beneath the Sports masthead and
in the manual channel search. Sports → Channels now searches every saved provider,
keeps the quality sections, and labels every feed with its service name.
Selecting a feed makes that provider active. Settings → IPTV has a pencil button
for renaming either the active or an inactive service (1–80 trimmed characters).

## Account isolation

- Results are identified by provider UUID **and** stream ID. Equal numbers and
  XMLTV channel IDs from different services never share guide evidence.
- The existing strict event scorer runs separately for each provider. Existing
  automatic matching, quality ranking and broad manual search policy remain.
- The active provider uses its existing validated in-memory results. Other
  providers fetch channel/category/guide metadata on demand, without probing or
  opening video connections. Results appear as services finish; failures are
  named and do not discard successful providers' matches.
- The catalog coalesces duplicate requests, limits provider downloads to two
  globally, and caches at most three snapshots for two minutes. Cache identity
  includes account UUID, connection fields and a digest incorporating its secret;
  names do not invalidate the account cache. Secrets are not logged or persisted
  by the new catalog. Missing device credentials produce a named sign-in message.
- Canceled/replaced sheets reject late publications. Selection checks the saved
  connection, current device secret, snapshot age, exact stream metadata and live
  event evidence again. Removed or changed accounts cannot open an old result.
- Choosing another service installs that exact fetched snapshot in the existing
  provider store, restores that account's favorites/preferences/recents, rebuilds
  its sports index and uses the existing player and source URL construction.
  No second provider download is needed for selection. Schedules are retained as
  shared sports data. Playback and Last Channel from the previous account retire.
- Renaming changes only the persisted profile name. UUID, Keychain credentials,
  active account, Guide defaults, favorites and channel preferences retain their
  existing identity. Cloud settings use the existing persistence path.

## Validation

Local metadata/target-membership checks: 12 tests passed. Playback project and
engine version checks, tvOS focus check and whitespace check passed. This Windows
workspace has no Swift or Apple SDK; compilation and new SDK tests await CI.

Seven new iOS SDK regressions cover colliding channel/EPG IDs and source URLs,
expired/recycled evidence, coalescing/cache connection isolation, partial provider
failure/retry, concurrency bounds, removed connections, and rename persistence
including Keychain credentials and provider-scoped saved data. Existing quality
grouping and all playback tests stay enabled. Private tester accounts and actual
multi-provider playback have not been tested here.

The prior playback fixes are included. Full Seerr integration remains deferred
until the tester's playback fixes are validated, as requested.

## Build 139: TV Guide placement

The TV Guide player now receives the active service's name. Inline, it appears
in a dedicated, Dynamic Type-scaled row directly below the video and before the
replay timeline/programme metadata. The owning Guide reserves the same height
above both List and TV Guide modes, preventing the label from covering rows.
Fullscreen uses one truncated line in a dark capsule beneath the playback
badges, inside the existing safe-area padding. It hides/shows with the controls;
the measured header includes it so channel banners remain clear of the label.
Only the Guide supplies this optional display value; playback/source selection,
stats, catch-up and PiP behavior are unchanged. Existing local checks passed;
SDK/device validation remains pending the new IPA workflow.

## Build 140: compiler repair

Reported build139 failed in both app compilation jobs at
`MobileProviderChannels.swift`: the error enum is nested in `XtreamClient`, so
the fallback now uses `XtreamClient.XtreamError.invalidResponse`. No tests ran
in139; no IPA was produced. Provider lookup/rename and Guide label placement
remain included. No test, assertion, deadline or workflow was changed.

## Build 141: simulator test corrections

Reported build140 compiled the iPhone simulator app, test bundle and Release
app; its package job succeeded. The suite ran651 tests (one existing skip) with two failures:
the new rename regression's real Keychain write failed with -34018 under the
unsigned simulator host, and the slow VLC regression compared Objective-C wrapper
identity. All six other provider tests and the existing replay/sidecar playback
regressions passed.

The provider store now accepts a credential backend, defaulting to the unchanged
device Keychain functions. The rename regression uses a per-test recording backend,
retains every profile/favorites/recents/credential assertion and additionally
requires zero credential rewrites/deletes plus a valid relaunched playback URL
using the original credential. No global fake Keychain or production bypass.

The slow-start regression retains its original picture/output/native-clock and
30second readiness requirements. It now checks VLCMedia's native descriptor
equality and the unchanged playback session UUID. A negative control requires
two independent media objects at the same URL to compare unequal. This rejects
actual input replacement while permitting VLCKit's normal wrapper replacement.
Upstream implementation: [media-change wrapper creation](https://github.com/videolan/vlckit/blob/3.0/Sources/VLCMediaPlayer.m#L168)
and [native descriptor equality](https://github.com/videolan/vlckit/blob/3.0/Sources/VLCMedia.m#L359).
No playback/recovery thresholds, test exclusions or workflow signing were changed.
Local checks passed; replacement SDK validation is pending CI.
