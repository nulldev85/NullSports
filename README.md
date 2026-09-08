# NullSports

NullSports is a quiet, sports-first IPTV player for Apple TV. It organizes a provider's live channels around the NFL, NBA, NHL, and MLB instead of dropping everything into one enormous grid.

The first release supports Xtream-compatible profiles, secure password storage in the Apple TV Keychain, league filtering, channel search, and native HLS playback. You supply the provider and streams you are authorized to watch; NullSports does not include or sell content.

## Build

Run the **Build NullSports tvOS IPA** workflow in GitHub Actions. The downloadable artifact contains an unsigned tvOS IPA ready for your normal signing process.

## iPhone

The `NullSportsiOS` target supports iPhones on iOS 17 or later, with a touch-first
Live screen, league filters, searchable channel guide, favorites, provider setup,
and full-screen VLC playback in portrait or landscape. Unmatched games open a
manual channel picker. Provider credentials, schedules, guide parsing, and channel
matching share the Apple TV implementation. Profiles and favorites are stored
locally on each device; they do not sync between iPhone and Apple TV.

Run **Build NullSports iPhone IPA**, or push the `iphone` branch. Download the
`NullSports-iPhone-unsigned-IPA` artifact, unzip it, and sign/install the enclosed
IPA using your usual sideloading tool. Its bundle ID is
`com.nulldev85.NullSports.iOS`. TestFlight distribution is not configured yet.

For a local Mac build, run `xcodegen generate` and build the `NullSportsiOS` scheme.
The iPhone target includes the shared models/services/store/design and its own
`iPhone` views/assets; it excludes the TV views and TV icon catalog.

Device smoke check before release: connect a provider, relaunch with cached data,
filter leagues, choose a matched and an unmatched game, search/filter channels,
favorite/unfavorite, play/pause/retry/close a stream, rotate during playback,
background and resume, verify audio, and remove the provider. This first phone
version plays one stream at a time and pauses when backgrounded.

iPhone 0.17.2 adds team records to Live cards and a timeline EPG with frozen
channel logos, a fixed time ruler, aligned program blocks, elapsed shading, and
a current-time marker in the NullSports palette. Swipe horizontally for later
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
