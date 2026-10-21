# iPhone playback and Picture in Picture

Lineup requires **iOS 18** and embeds unmodified **AetherEngine 7.45.0** alongside
the existing Apple and VLC players. Settings → Playback Engine offers:

- **Automatic** (default): Apple's AVPlayer for HLS, AetherEngine for other URLs.
- **AetherEngine**: try AetherEngine for every source, including HLS.
- **VLC**: always use VLC; this integration does not provide PiP.

The setting is local to the iPhone and applies to the next video opened. Changing
it does not replace an active session. The player badge identifies the actual
engine: AVPlayer, AetherEngine, or VLC. This applies to Guide/Sports playback,
provider VOD, movies and episodes from Nullfin and other connected media servers,
and provider recordings. URL query strings do not affect engine selection, and
extensionless server routes can now use Aether and PiP.

Automatic preserves the existing HLS-first order. If a player cannot start a
source, Lineup tries another PiP-capable endpoint or engine before VLC. Failed
engines are tracked per URL to prevent fallback loops. VLC remains a compatibility
fallback, with a visible notice that PiP is unavailable for that playback.

## PiP integration

The previous player allowed PiP only for URLs routed to AVPlayer. Every URL other
than `.m3u8` or `.m3u`, even an MP4, went directly to VLC. Aether provides native
`AVPlayerLayer` and software `AVSampleBufferDisplayLayer` sources, so both of its
video rendering paths can be connected to AVKit PiP on iOS.

The bridge owns one PiP controller for the active renderer. Its sample-buffer
delegate supplies play/pause, source-clock time ranges, and skips; it reports
PiP transitions to the engine before backgrounding. Native subtitle renditions
are prepared at load, and native subtitle rendering is enabled during PiP.
Aether composites subtitles into software PiP frames. Its renderer remains
owned across view resize and handoff. The existing Apple layer is retained when
its original host disappears during PiP, and reused when a host returns.

The button uses AVKit's actual `isPictureInPicturePossible`, rather than assuming
every source is ready. Aether exposes the actual renderer route in Diagnostics.
The source still must decode successfully, the device must support PiP, and iOS
must permit starting it. Unsupported, protected, or broken media cannot be
promised PiP merely by selecting an engine.

Progress, resume, completion, manual tracking, and Continue Watching dismissals
remain with Lineup's existing controller and Library policy. Aether's foreground
video restoration does not start a second player. Provider catch-up opens a
finite recording rather than enabling a separate DVR buffer.

## Validation and physical iPhone review

The iPhone workflow uses Xcode 27 and checks the iOS 18 deployment floor, dynamic
FFmpeg symbol binding, bundled resources/notices, and background audio mode.
The app embeds Aether's nine processed dynamic `.framework` files from
`BUILT_PRODUCTS_DIR`, without linking the engine into the executable. SwiftPM's
`-product` nodes are not files to embed. Xcode copies its SwiftPM resource bundle
automatically; an additional bundle dependency would duplicate that copy task.
The shared bundle check validates all runtime files and their framework dependencies.
Before building, its `--project` mode checks the generated copy/link phases for
real framework references, one copy per runtime, and preserved engine isolation.
Generated fixtures cover MP4, software-decoded MPEG-2 MKV, and paced live TS over
a local HTTP server. The origin publishes its port only after NWListener is
ready, and a range-request test verifies the HTTP fixture before decoder tests.
Tests exercise extensionless server URLs, actual rendering, resume, seek, pause,
subtitles, surface reuse, and preferences. Simulator sessions request software
decoding because device hardware decoders are unavailable there. Native and
software PiP source coverage both remain required on physical iPhones.
Existing local tracking and navigation regression suites remain included.
Screenshots are exported with the existing iPhone preview artifact.

The simulator does not prove a floating PiP window or background lifecycle on an
iPhone. The physical-device PiP test explicitly skips in the simulator and, on
device, requires AVKit to actually activate then stop each source's PiP window.
iPhone simulator compilation, framework embedding, Aether playback tests,
playback policy, and local tracking passed in run 38661435840. The only failure
was the Guide's duplicated bottom inset with Liquid Glass enabled. The corrected
Guide check, release packaging, and physical-device results remain pending.

Before merging, test each of Automatic and AetherEngine with your live TV,
provider VOD, and a Nullfin movie and episode. Start PiP manually, press Home,
pause/resume and skip from the PiP controls, return to Lineup, rotate or expand
the player, and close PiP while backgrounded. Check audio, subtitles, position,
watched status, and a removed Continue Watching card. Repeat with a software
format and confirm the actual engine badge. Confirm VLC selection still plays
your sources and does not advertise unavailable PiP.
