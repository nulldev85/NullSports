# iPhone Game Replays

In Sports, select **My Teams**, then scroll below the live/upcoming sections to
**Game Replays**. It appears with All Sports or NFL selected and uses the same
followed-team store as Settings and live game menus. NFL league and team logos
come from the existing official-logo assets/directory. Multiple recordings of
one matchup open the app's channel-choice panel; one recording opens directly.

This is an additional entry point to the provider's Xtream catch-up service,
not a separate replay subscription or VOD catalog. It requests past listings
with the existing `get_simple_data_table` client and opens their existing
timeshift URLs through the usual iPhone player. TV Guide catch-up behavior,
live event matching, quality verification and Library tracking stay unchanged.

Only archive-enabled NFL channels are queried. A dedicated channel for another
team, RedZone, highlights, news and other non-game feeds are excluded. Each
listing must explicitly have `has_archive`, have ended, remain wholly within
the provider's stated retention window, and identify a two-team NFL matchup
involving a followed team. Generic NFL titles can use the program description.
A team channel's name alone does not establish the recorded game's identity.
Alternate recordings of the same teams within ten minutes are grouped. The
replay list does not depend on today's sports schedule retaining past games.

Requests start on demand in My Teams, with at most three simultaneous archive
requests per load. Successful per-account/channel results cache for five
minutes; the refresh button clears that cache. Matching/filtering runs off the
main actor. Expired recordings disappear on the section's minute clock without
another network request. Cancelled or superseded loads cannot publish into a
new profile/filter selection, and failed channels don't discard good results.
This work is separate from startup refresh/progress and live quality probes.

Opening a recording rechecks only that selected channel's archive listing and
current account before creating its timeshift URL. If it is no longer available,
the player offers Retry and reports the error rather than opening a live feed.
The recording uses the existing catch-up timeline, seeking, transport, format
badges and engine selection. Going Live remains an explicit player action.

The provider only announced "NFL Teams catchup"; its private channel catalog,
recording flags and retention have not been inspected. Providers that omit
game identities or explicit recorded flags cannot populate this section safely.
An empty list is not a promise that the provider has no recordings; the TV
Guide's existing Catch Up entry remains available. M3U-only profiles do not
provide this Xtream archive table. This addition is iPhone-only.

Ten iOS regressions cover visibility, eligible channels, archive flags/retention,
two-team matching and alternate feeds, expiration, bounded concurrency/cache,
late account responses, partial failure/retry, disabled contexts, and a failed
recording opening without live fallback. iPhone119 passed SDK compilation,
simulator tests, release checks and IPA upload; the user reported that pass.
Private provider recording availability and device replay playback have not
been independently confirmed. No tests are disabled.

## Catch Up from a live Sports event

iPhone120 adds only **Catch Up** to an existing Sports event hold menu, after
Channels. It is available for any live sport with an archive-enabled matching
channel, without requiring My Teams. The entire TV Guide menu is not copied.
Opening a hold menu triggers the existing strict event-channel lookup off the
main actor; there are no new provider requests, stream probes or startup work.
All matched channels are considered, including an archive-capable alternative
when the ordinary playback feed lacks catch-up support. A menu request ID
prevents a late capability answer from modifying another or dismissed menu.

One eligible channel opens the existing Catch Up program list directly; several
offer a channel choice first. Profile and current event evidence are checked
again on channel selection. Program selection waits for the sheet to dismiss
before opening the existing fullscreen recording player. It uses the same
current/past program lookup as TV Guide, allowing a current program to start
over while still recording. Selection retains the exact account, stream and
program; playback revalidates the program and never falls back live on error.
The My Teams NFL replay section retains its stricter completed-game policy.

Four additional iOS regressions cover alternate capable feeds/deduplication,
unrelated archived feeds rejected by the real NFL/NBA/soccer event matcher,
account/program routing including ongoing programs, and menu request isolation
while keeping the original actions. These additions require iPhone120 SDK and
device validation; local source-membership, focus and diff checks passed.

## Replay seeking repair (iPhone123)

Completed fullscreen recordings use the same44-point drag control, thumb,
elapsed/remaining labels, seek coalescing and release commit as Library videos.
The player keeps controls visible during a drag and excludes gestures beginning
on the timeline from channel switching. Inline/live Guide chrome stays compact.
Replay seeking does not request Library Trickplay metadata or scan the video.

Previously only VLC had an in-place recording skip. Aether/native AVPlayer
reopened a minute-addressed provider URL for a ten-second tap; at0:06, seeking
to0:16 reopened0:00. All three engines now use their confirmed seeking capability
within the open recording. Program-relative UI destinations are translated into
open-stream offsets. Aether accepts the final target even during a running seek;
VLC uses its native position/time and AVPlayer its actual seekable time ranges.
Draft finger positions do not publish as playback progress. The landing guard
rejects stale clock samples, and pause intent survives release.

If an engine/provider cannot seek within its stream, drag previews never reopen
the provider URL. Release opens its supported whole-minute destination once;
rapid skip taps remain coalesced. A forward request that would round behind the
current picture is refused with an explanation instead of restarting the same
minute. The UI reports the actual provider minute, not an unattainable draft.
This limit is not presented as exact ten-second provider seeking.

Two SDK regressions cover the real provider fallback, final-only reopening,
minute padding, cancellation and retired gestures. A real HTTP media fixture
exercises ten-second skipping, drag release and paused dragging through both
Aether and VLC, retaining the source/session. The standalone playback-policy
check covers the0:06→0:16 rounding regression. Full tests remain enabled;
Apple SDK/device validation for this repair is pending.

## VLC pause-state follow-up (iPhone124)

Build123 compiled the app and tests. All560 tests ran, with one existing skip
and three failures in two playback tests. Real Aether replay seeks landed at10,
16 and6seconds without reopening. The VLC portion timed out while checking a
paused drag; the subtitle-attachment test also found isPlaying still true after
pause. The failed seek's teardown additionally reported InvalidTransition
idle→failed(deinit); this is retained as a pending verification concern, not
claimed to be an independent diagnosed engine defect.

The controller called VLC.pause(), then immediately read the engine's old
playing flag back into its published state. The monitor skips transport updates
while pausedByUser is true, so that published flag could stay true indefinitely.
refreshIsPlaying now respects explicit pause intent. Engine seek commands,
source URLs, tracking, coalescing and provider precision policy are unchanged.

The existing real VLC tests now await its actual VLCMediaPlayerStateChanged
pause callback with a bounded XCTest expectation. They require both immediate
control-state feedback and the actual decoder being paused; paused replay
seeking still requires the real clock and recording position within two seconds
of the final destination. Assertions and the full suite are preserved.

Build123's simulator step took24m17s, including about1m56s of test execution
and a600-second diagnostic-collection timeout after the failures. Release/IPA
steps were skipped. Subtitle preferences, Trickplay images/cache/authentication,
OpenSubtitles UI, replay provider fallback and Sports Catch Up tests passed.
The Foundation-only early preference compile/behavior check also passed.
These results validate those checks in123, not the new124 repair.

Local membership5, bundle9, focus and diff checks passed. Apple SDK and device
validation for124 remain pending. No retries, test exclusions or relaxed
assertions are introduced.

VLC3 reference for native notifications and pause implementation:
https://raw.githubusercontent.com/videolan/vlckit/3.0/Sources/VLCMediaPlayer.m
