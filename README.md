# Lineup

Lineup is a quiet living-room client for Apple TV and iPhone, covering the two
things a lineup means: the games on now, and the library you browse.

**Live** organizes an Xtream provider's channels around the NFL, NBA, NHL, MLB
and college football rather than dropping everything into one enormous grid, and
matches each game to the channel actually carrying it. **Guide** is the full
channel list with search and favorites. **Media Servers** browses Jellyfin and
Nullfin libraries, including the catalogs and streams from any addons configured
on the server.

Xtream-compatible profiles, passwords stored in the device Keychain, and native
VLC playback throughout. You supply the provider, server and streams you are
authorized to watch; Lineup does not include or sell content.

## iCloud sync and game reminders

Lineup saves followed teams and one-off game reminders locally and schedules a
notification 15 minutes before a known upcoming game. The app refreshes the
today-and-tomorrow schedule while open; after it schedules a reminder, the device
can deliver it while Lineup is closed. Notification permission is requested when
the first team or game reminder is selected. Each device schedules its own alerts.

The iPhone and Apple TV targets share the private CloudKit container
`iCloud.com.nulldev85.Lineup`. It synchronizes provider and media-server profiles,
their Keychain credentials or tokens, channel favorites, media shelves, theme,
followed teams, and one-off reminder choices. The payload is stored in a CloudKit
encrypted field. Schedule, guide, and stream caches stay local and are refetched.
Sync needs both devices signed into the same Apple Account and a signed build with
the iCloud/CloudKit entitlement. In the Apple Developer portal, enable iCloud and
assign this same container to **both** existing bundle identifiers,
`com.nulldev85.NullSports` and `com.nulldev85.NullSports.iOS`. Regenerate signing
profiles after enabling the capability. An unsigned IPA or a signing profile
without that entitlement cannot use CloudKit. Deploy the `LineupSettings` record
type with encrypted `payload` field from CloudKit development to production
before distributing release builds. Account shows the current sync status.

> Formerly NullSports. The app's bundle identifier and stored data keep the old
> name so existing installs keep their providers, servers and saved passwords —
> see the note in `project.yml`.

## Build

Run the **Build Lineup tvOS IPA** workflow in GitHub Actions. The downloadable artifact contains an unsigned tvOS IPA ready for your normal signing process.

## iPhone

The `LineupiOS` target supports iPhones on iOS 17 or later, with a touch-first
Live screen, league filters, searchable channel guide, favorites, provider setup,
and full-screen VLC playback in portrait or landscape. Unmatched games open a
manual channel picker. Provider credentials, schedules, guide parsing, and channel
matching share the Apple TV implementation. Profiles and favorites are stored
locally on each device; they do not sync between iPhone and Apple TV.

Run **Build Lineup iPhone IPA**, or push the `iphone` branch. Download the
`Lineup-iPhone-unsigned-IPA` artifact, unzip it, and sign/install the enclosed
IPA using your usual sideloading tool. Its bundle ID is
`com.nulldev85.NullSports.iOS` — unchanged by the rename, deliberately, so the
build installs over an existing one instead of arriving as a second empty app.
TestFlight distribution is not configured yet.

For a local Mac build, run `xcodegen generate` and build the `LineupiOS` scheme.
The iPhone target includes the shared models/services/store/design and its own
`iPhone` views/assets; it excludes the TV views and TV icon catalog.

Device smoke check before release: connect a provider, relaunch with cached data,
filter leagues, choose a matched and an unmatched game, search/filter channels,
favorite/unfavorite, play/pause/retry/close a stream, rotate during playback,
background and resume, verify audio, and remove the provider. This first phone
version plays one stream at a time and pauses when backgrounded.

iPhone 0.17.2 adds team records to Live cards and a timeline EPG with frozen
channel logos, a fixed time ruler, aligned program blocks, elapsed shading, and
a current-time marker in the Lineup palette. Swipe horizontally for later
programs and vertically for more channels. Tap Now to return to the current
window. Use the toolbar filter menu for categories/favorites, and long-press a
channel logo to add or remove a favorite. Tapping a channel or program plays that
channel live (future listings are not recordings). The timeline includes eight
hours starting one half-hour before the current half-hour boundary.

iPhone 0.17.3 opens Guide selections in a player above the timeline, with channel
and current-program information underneath. Tap the video to show/hide controls.
Expand hides navigation, tabs, status bar, and system overlays and extends the
video surface to every screen edge, in either orientation. Collapse returns to
the guide using the same player and stream connection. Close or leaving Guide
stops playback. The Live screen's manual channel picker retains its existing
selection behavior. Device checks: switch channels while browsing, expand and
collapse while playing/paused, rotate, close, switch tabs, and background/resume.

iPhone 0.17.4 fixes a video-surface startup race introduced with inline playback:
media now waits for the video host to be mounted and sized before starting VLC.
The same host stays attached and resizes its renderer during fullscreen changes.
Both Guide and Live players use this lifecycle. Verify actual moving video and
audio on first selection, channel switches, close/reopen, rotate, fullscreen
expand/collapse, and background/resume on an iPhone before considering the
audio-only regression resolved.

iPhone 0.17.5 replaces the Live cards with a compact scoreboard: underlined
league tabs, On Air and dated upcoming sections, thin dividers, aligned scores,
team records, and a narrow status/network column. The full matchup row remains
tappable, including manual channel selection for unmatched games. Check narrow
iPhones, long team names, larger accessibility text, and partial schedule data.

iPhone 0.17.8 creates a fresh VLC session for each Guide channel selection and
explicitly tears it down when leaving Guide. Queued callbacks from retired hosts
are disconnected, and audio without video output triggers fallback instead of
being treated as successful playback. Simulator tests cover surface ownership
and tab-return teardown; actual video decoding still needs a provider/device
smoke test. Guide logos now use the full program-row height without a tile
background (wide logos preserve their aspect ratio). The time triangle and
vertical playhead are removed; elapsed program shading remains.

iPhone 0.17.9 adds interactive horizontal paging between Live, Guide, and Account.
The bottom tabs remain tappable and also accept swipes. Timeline/league-strip
scrolling keeps priority; use the header or bottom tabs to change pages from the
EPG. Paging is disabled during fullscreen playback. Swipe down in either full-
screen player to close; short drags spring back and Reduce Motion suppresses
the transform animation. The app icon is now a white NS monogram on black.
Device checks: completed/cancelled swipes, fast tab taps, timeline scrolling,
fullscreen in both orientations, player close buttons, and Reduce Motion.

iPhone 0.17.10 corrects the simulator test host path to the actual Lineup.app
executable. It also anchors the EPG content at the top, prevents the nested guide
scrollers from adding duplicate navigation insets, and disables horizontal
rubber-banding while preserving vertical pull-to-refresh. Account displays the
installed version/build so an older IPA can be distinguished from a new build.
The EPG remains progress-fill-only, with no triangle or vertical time marker.
