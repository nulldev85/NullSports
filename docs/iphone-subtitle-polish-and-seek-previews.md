# iPhone subtitle polish and seek previews

Scope is iPhone only, as explicitly selected by the owner. Existing tvOS UI,
seeking, tracking, channel matching, quality checks and audio/video timing are
not changed. No new player, service account, background video scanner or tab.

## Subtitle controls

Library playback's existing Subtitles menu offers Subtitle Settings:

- Preferred language, persisted and also used by built-in subtitle search.
  The default preserves the player's previous behavior. Aether uses its
  documented preferredSubtitleLanguages load option; VLC uses sub-language;
  the native compatibility path uses actual legible-option language metadata.
  Explicit Off remains an explicit viewer choice for that session.
- Small, Standard, Large and Extra Large text, with an optional text background
  and a sample. Preferences persist. Aether updates its foreground text canvas
  without reloading the movie; AVPlayer uses native AVTextStyleRule attributes.
  VLC uses documented FreeType media options at its next load, explicitly
  explained in the UI. No private VLCKit selectors are invoked.
- Earlier/later in0.25-second steps, bounded to30seconds each way, and Reset.
  Positive delay means later for both engines. VLC's API uses microseconds.
  Aether shifts foreground cue evaluation and its software subtitle compositor.
  This is subtitle timing only, not the cancelled audio/video Sync feature.
  Delay resets at source stop/retune; it is not saved across unrelated videos.

Image-based captions retain their original artwork. Native PiP renditions retain
their own appearance/timing; the sheet explains this. Existing PiP video is not
restarted or replaced. The native compatibility player disables timing controls
because it lacks a supported per-track delay API.

## Seek previews

The selected Jellyfin media version supplies its documented Trickplay metadata
and authenticated JPEG tile endpoint. Fields=Trickplay is requested separately
from playback, once per Library player presentation, and is cancellable.
Alternate versions require an exact media-source key; a different cut is never
used as fallback. GUID-only endpoints are not attempted for packed AIOStreams
identities; Plex/Emby/provider sources without this capability remain unchanged.
No claim of preview images for every source or Jellyfin wrapper.

The finger, elapsed time and progress bar update synchronously through the
existing seek coalescer. Thumbnail loading never gates a seek. The fixed-size
preview bubble overlays the seek bar without reflowing controls. A retained
owner does not forward frame publications to the fullscreen video view; only
the small seek view observes frames. Latest-position/generation checks reject
obsolete responses, including noncooperative requests completing after cancel.

Only a missing storyboard image is requested. Neighboring cells are cropped
locally and cached; no extra video decoder/connection is created. Image fetching,
validation, eager decoding and copying individual cropped pixels run in an actor
off the UI thread. Caches hold at most2 sheets/48MB and24 independent frames,
with an8MB response/10million-pixel limit and metadata geometry checks.
Requests across tile-boundary jitter are limited to one start per120ms, cached
cells never wait, and transport uses at most2 connections per host with bounded
timeouts. Missing images back off30seconds. Credentials stay on the configured
origin; cross-origin redirects are rejected. No automatic image generation,
image request before dragging, or unrelated-version image fallback.

## Validation

Build122 also stopped in app compilation, before any simulator tests or IPA
packaging. Its simulator step took8m38s. MobileSubtitlePreferences.matches
unwrapped its actual argument and then redeclared a local with the same name.
The normalized values now have distinct names. The Foundation-only preferences
helper is compiled and exercised by an early standalone Swift check before
dependency resolution, in addition to the existing full SDK regressions.
Local membership5, bundle9, focus, workflow lint and diff checks passed for
build123. Apple SDK tests and device playback remain pending.

Build123 subsequently compiled and passed all seven player-polish tests,
including real Trickplay pixel crops/cache/source selection/authentication.
The real Aether MP4/MKV caption appearance/timing/PiP-source integration passed.
The full build failed two VLC pause-state checks, documented in
iphone-game-replays.md. Build124 repairs the shared published pause state and
strengthens the original VLC subtitle test with its native pause callback and
actual transport assertion; no subtitle/search/thumbnail feature is removed.

Build121 failed before tests ran: the new native-input test helper omitted
explicit self in a lazy escaping compactMap closure. Fixed that exact compiler
error, retaining its real editor callbacks and full assertions. Its simulator
step lasted8m38s; release/IPA steps were skipped. This was compilation, not a
runtime playback failure or packaging/storage failure.

Seven new SDK regressions cover preference persistence/sanitization and delay
bounds/reset, exact versions and millisecond/tile geometry, pixel-correct crops
and request caching, missing-image backoff, latest-position selection during an
obsolete pending response, fullscreen-owner publication isolation, and the real
Jellyfin request/authentication contract. Existing Aether MP4/MKV integration now
requires an actual rendered sidecar, immediate size/background changes and cue
timing without restarting/seeking. VLC verifies the real microsecond delay API
and retained pause/player/session. Full SDK suite stays enabled. Results are
pending CI; Windows has no Apple SDK or Swift toolchain.

Official references inspected:

- https://raw.githubusercontent.com/jellyfin/jellyfin/master/Jellyfin.Api/Controllers/TrickplayController.cs
- https://raw.githubusercontent.com/jellyfin/jellyfin/master/MediaBrowser.Model/Dto/TrickplayInfoDto.cs
- https://raw.githubusercontent.com/jellyfin/jellyfin/master/MediaBrowser.Model/Dto/BaseItemDto.cs
- https://raw.githubusercontent.com/jellyfin/jellyfin/master/MediaBrowser.Model/Querying/ItemFields.cs
- https://videolan.videolan.me/VLCKit/interface_v_l_c_media_player.html
- https://raw.githubusercontent.com/videolan/vlc/3.0.x/modules/text_renderer/freetype/freetype.c
- https://developer.apple.com/documentation/avfoundation/avtextstylerule
- Pinned AetherEngine 7.40.1 source, including setSoftwareSubtitleDelay and
  LoadOptions.preferredSubtitleLanguages, inspected locally.

## Apple TV (Round 4 of the port)

The models and services moved into `Lineup/Services` unchanged and both apps
use them: `SubtitlePreferences.swift`, `TrackMemory.swift`, `OpenSubtitles.swift`
(with the results filter) and `SeekPreview.swift`. Seek-preview fetching
(`MediaServerClient.seekPreview`, `JellyfinClient.seekPreview`,
`MediaLibrary.seekPreview`) and Aether's subtitle styling
(`AetherPlaybackSession.configureSubtitles`) are no longer iPhone-only.

- **Subtitles menu.** Every Library title now has one, even without
  subtitles of its own: its tracks, then Find Subtitles Online (where
  OpenSubtitles is configured and the title can be identified) and Subtitle
  Settings. The Audio and Subtitles menus say when a choice is kept for the
  show.
- **Subtitle Settings.** Size (Small, Standard, Large, Extra Large),
  background, the language a title opens with, and timing in quarter seconds
  with Reset. Size, background and language are kept on the Apple TV; timing
  resets for each video. Aether changes the look at once; VLC sets it as a
  video opens, so it applies from the next one, and the screen says so.
- **Find Subtitles Online.** A full-screen list of OpenSubtitles releases in
  the chosen language. Select one: it is checked, written to its own file and
  added to the engine (VLC's playback slave, Aether's external track), and the
  engine chooses it. A reconnect adds it again once the picture is back. The
  files go when the title closes.
- **Per-show tracks.** As on the phone: an episode's show keeps the sound and
  subtitles chosen in it, the next episode opens on those languages, and once
  its tracks are listed it is put on the same track by name, else language.
  Turning subtitles off is kept too.
- **Seek previews.** On Jellyfin, the server's trickplay thumbnail for the
  place being scrubbed to rides above the seek bar, with its time. The seek bar
  alone watches the thumbnails, so the player does not redraw for each one.

`Tests/tvOS/PlaybackEngineTests.swift` checks the kept sound coming back on
the next episode by name and language, and that timing goes to the engine in
quarter seconds and resets for the next title.
