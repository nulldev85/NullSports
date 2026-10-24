# iPhone playback feedback and event channel quality groups

Tester device: iPhone 15 Pro. Engines tried: VLC and AetherEngine. Jellyfin was
the movie source. No server version, example title, screenshot, file/codec,
network measurements or tester playback log was supplied. This change fixes
specific code paths consistent with the report; the private server's playback
and the exact "zoomed out" picture still need device verification.

## Changes

- The iPhone game's Channels picker groups all existing verified feeds into
  resolution sections (4K/UHD, 1080p/Full HD, 720p/HD and other supplied sizes),
  with unspecified quality last. Existing ranking within each section and all
  stream IDs are preserved. Provider quality labels remain explicitly labeled;
  grouping does not probe streams, invent measured resolutions, remove feeds,
  change automatic selection or relax event matching.
- VLC may retain `stopped`/`ended` while a new input starts asynchronously. The
  movie path previously treated that as failure after two seconds, despite its
  normal 30-second startup window. It now preserves that startup window until a
  picture has played; actual errors/stops still recover, and the live stream's
  eight-second stopped-input rule is retained. Buffer sizes are unchanged.
- VLC's two-second shape deadline previously allowed audio and the drawable to
  appear even with zero displayed pictures. It now requires a real displayed
  frame. The six-second sound-only fallback requires identified audio and no
  known video track, so a known video stream is not treated as a radio source.
- Reusing Aether's adapter while its next load is pending cannot claim a ready
  picture from the preceding renderer. `hasPicture` now excludes the adapter's
  loading state. This small readiness-contract fix is in the shared adapter;
  the remaining player/UI changes are iPhone-specific.
- Late VLC renderer views fill their actual host immediately when attached;
  Aether/MPV canvases lay out their real viewport before opening. Reattachment
  and rotation retain the renderer. The content's aspect fit is retained;
  letterboxing in the source is not automatically cropped or stretched.
- iPhone fullscreen and Guide/preview overlays distinguish Opening stream,
  Waiting for picture, Buffering, and Reconnecting. Picture history resets for
  a newly selected source, survives a retry of the same source, and updates only
  when real video has been presented. VLC's explicit buffering state also shows
  the loading indicator while its output remains allocated.

## Validation and scope

Eleven new iPhone SDK tests cover quality grouping/preserved feeds, late renderer
and canvas bounds, opening-vs-stopped decisions, actual first-frame policy,
audio-only fallback, presentation labels, a delayed extensionless HTTP movie
through the real VLC player without replacing its input, and a reused real
Aether session with a delayed second source. The existing full SDK suite and
all assertions/deadlines stay enabled. The early standalone Swift preflight
also exercises the new Foundation policies. The HTTP fixture's optional header
delay defaults to zero, preserving existing tests.

Local metadata/source membership (12), playback project/pins, tvOS focus and
diff checks pass. Windows has no Apple SDK, so Swift compilation, these tests,
IPA packaging and device/server verification remain pending CI and the tester.
No claim is made that a private Jellyfin server, every file format, or the
tester-specific framing has been verified.

Branch `codex/iphone-playback-feedback` starts from `dc0f130` and includes the
pending UFC and MDBList fixes. iPhone build 136; tvOS version remains 91. Older
workflow runs are not inspected or canceled. No merge is authorized/performed.

The user explicitly authorized full Seerr integration in the following build,
after this fixes build. No Seerr feature or connection is included here.
