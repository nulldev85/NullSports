# Apple TV playback engines

Lineup supports VLC and AetherEngine on tvOS 18 and later. VLC remains the default.
Choose Settings → Playback → Playback Engine. The choice is local to the Apple TV
and takes effect when the next stream opens, including Sports and Guide previews,
Library playback, provider recordings, and Multiview. Changing it does not replace
an already playing stream. A preview opened full screen keeps the same engine,
connection, picture surface, and audio state.

The player info displays the **actual active engine**, not the saved preference:
VLC or AetherEngine. Previews and Multiview labels also identify their engine.
There is no automatic fallback that could label a VLC session as AetherEngine.

## Implementation and dependency versions

`TVPlaybackController` owns transport, bounded reconnects, VOD resume, provider
catch-up/Start Over, screen-awake policy, track restoration, and progress for both
engines. Engine adapters supply native playback, clocks, and stream information.
Movie and episode tracking continues through the existing local tracking policy;
a dropped stream is not counted as a completed title.

The Aether integration uses the unmodified **7.36.0** tag, revision
`c6365cc3c8850bdb670654ca26dcd21f73670875`, and pins FFmpegBuild 3.7.1,
LibDovi 2.1.0, LibTrueHD 2.3.0, and LibDTSX 1.0.1. It uses the fast-zap live
profile, automatic source video selection, audio-track selection, and host-rendered
text, styled text, and bitmap subtitles. Provider catch-up remains Lineup's own
recording timeline. Aether's separate DVR buffer is not enabled.

`LineupAetherPlayback` is a dynamic framework containing AetherEngine's static
Swift package. This keeps its FFmpeg references separate from VLC's FFmpeg.
The release build checks `_avcodec_open2` binds to AetherLibavcodec, verifies
embedded decoder resources and notices, and checks the tvOS 18 deployment floor.
Both app targets embed the nine FFmpeg `.framework` files from
`BUILT_PRODUCTS_DIR` using implicit framework references with app linkage disabled.
SwiftPM's `-product` graph nodes are not runtime files and cannot be copied.
Xcode automatically copies Aether's SwiftPM resource
bundle through the package dependency graph. A separate bundle dependency would
create duplicate copy tasks and fail the build.
`Tools/check-aether-bundle.py` checks every runtime binary and its framework
dependencies, reporting the exact missing file if packaging is incomplete.
Its `--project` check also inspects the generated copy/link phases before building,
rejecting package-product copies, duplicate or missing frameworks, extra resource
copies, and direct app linkage of Aether's runtime.
Both runners use Xcode 27, the upstream tested toolchain. iPhone also supports
AetherEngine with an iOS 18 minimum; see `iphone-playback-engines.md`.

Settings → About → Playback acknowledgements contains the complete bundled
license notices and exact corresponding source links.

## Source and device limits

AetherEngine does not expose arbitrary video-track switching inside one container.
Its adaptive video selection is automatic; the VLC video-track chooser remains
available for sources with multiple video tracks. Lineup's alternate media-source
selection works with either engine. Codec, HDR, surround output, and audio-route
support depend on the engine, Apple TV model, operating system, and connected TV
or receiver; simulator output does not prove those hardware paths.

Previews and Multiview suppress HDMI frame-rate/range changes. Standalone
full-screen sessions allow content matching. A preview handed to full screen
keeps its original session rather than forcing a second display negotiation.

## Verification

The shared controller tests cover persisted engine selection, the actual info
label, next-stream changes, preview handoff, independent Multiview audio, resume,
seek, pause, mute, track restoration, negative subtitle IDs, reconnect positions,
natural completion, and finite provider recordings.

The build runner generates an original 12-second H.264 MKV with two AAC audio
tracks and SRT subtitles. Integration tests open it through both real adapters,
wait for rendered video and an advancing clock, select audio and subtitles, pause,
seek, change mute, and reach natural completion. Another test interrupts an Aether
load and opens a replacement session to check that stale work cannot restart it.
The result bundle exports decoder-labelled screenshots as the
`Lineup-tvOS-playback-previews` artifact. A screenshot alone is not proof of a
decoded frame; the tests also require the backend's picture-ready signal.

Release compilation and the packaged-runtime checks passed in run 38658173076.
The bridge retains measured seekability across Aether 7.36's software audio-track
rebuild, which clears the engine's source flag without probing it again. Live and
forward-only sources remain ineligible. Simulator sessions request software
decoding; physical hardware-decoder coverage is still required.
Corrected simulator regressions and physical-device validation remain pending.
Before merge, review both engine choices on a physical Apple TV with live TV,
Guide/Sports preview → full screen → preview, Multiview audio switching, provider
Start Over and catch-up, a movie resumed after closing, two consecutive episodes
marked watched, manual watched/unwatched, and a removed Continue Watching card
staying hidden. Check embedded/bitmap subtitles and alternate audio with your
sources, then test a dropped stream and a subsequent engine switch.
