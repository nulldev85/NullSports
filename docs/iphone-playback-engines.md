# iPhone playback and Picture in Picture

Lineup for iPhone requires iOS 18. Settings offers AetherEngine 7.62.0 and MPVKit.
AetherEngine is the default for live TV, provider recordings and media libraries.
Existing MPVKit users keep their selection. Older Native, Automatic and VLC choices
resolve to AetherEngine. A change in Settings applies when the next video opens.

When a decoder fails to open a source, Lineup tries the other decoder on the same
URL, tracking failures for that URL before advancing to another candidate. AetherEngine
supports Picture in Picture through its native and sample-buffer renderers.

## PiP integration

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
