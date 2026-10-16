# Playback format badges

iPhone and Apple TV show selected-source format information alongside the
existing engine, live/replay and resolution labels. Supported confirmations
include HDR10, HDR10+, HLG, Dolby Vision, Dolby Atmos, DTS:X, audio/video codec,
frame rate and audio channels/layout. Unknown attributes stay absent.

These describe the stream, not a promise about the television, speakers,
headphones, tone mapping, passthrough or spatial rendering. A 4K/HEVC/10-bit
picture does not establish HDR. E-AC-3, surround channel count, release names
and channel names do not establish Atmos.

AetherEngine 7.36.0 supplies `sourceVideoFormat`, `sourceVideoCodecName` and
`sourceVideoFrameRate`. Audio follows the selected track ID, using its codec,
layout, JOC confirmation and decoder profile. Its `isAtmos` covers E-AC-3 JOC;
TrueHD Atmos and DTS:X use their explicit decoder profiles. See the pinned
[TrackInfo API](https://github.com/superuser404notfound/AetherEngine/blob/7.36.0/Sources/AetherEngine/PlayerState.swift)
and [FFmpeg profile names](https://github.com/FFmpeg/FFmpeg/blob/master/libavcodec/profiles.c).
The source format is kept separate from Aether's display-dependent output format.

The iPhone system-player fallback reads enabled AVPlayerItem tracks. It loads
format descriptions asynchronously, checks PQ/BT.2020, HLG and Dolby Vision
signaling, and confirms E-AC-3 JOC through the audio format list or a bounded
`dec3` configuration parser. Conflicting variant descriptions omit the disputed
attribute. A generation token, current-item identity and enabled-track IDs reject
results from a retired item or an audio selection changed during the read.

VLCKit 3.6 exposes codec, frame rate and channel count through its
[public track dictionary](https://github.com/videolan/vlckit/blob/3.0/Headers/Public/VLCMedia.h).
The adapter selects the current video/audio track IDs and respects libVLC's
FourCC byte order. This API does not expose HDR transfer functions or Atmos
confirmation, so those advanced labels remain absent on VLC.

Controllers refresh metadata through their existing playback monitor; there
is no additional source connection, URL probe or decoding change. The native
reader allows one asynchronous read at a time, at most once per second.
Retune/stop clears old labels, and new selections replace old attributes.
Apple TV refreshes labels while paused as well as during playback/scrubbing.

iPhone Sports/Guide previews use a horizontally scrollable strip of whole
labels below the controls. Fullscreen players wrap whole badges onto additional
rows. The channel banner clears the measured header height. Apple TV Sports and
Guide previews fade the labels after four seconds; fullscreen and Multiview use
their existing controls/label visibility. Badges do not take remote focus.

`PlaybackMediaInfoTests` runs on both platforms and covers truthful labels,
HDR/SDR format descriptions, ordinary surround versus JOC, truncated/oversized
configurations and codec-qualified profiles. tvOS controller tests cover stream
changes and clearing on retune/stop. Existing real-player integration tests now
require actual H.264/AAC or AAC metadata from their playback fixtures and reject
false HDR/Atmos claims. iPhone header geometry checks include long format labels
at narrow, normal and landscape widths. These Apple SDK tests require CI;
this Windows checkout cannot execute them locally.

Device review: play known HDR/Dolby Vision and JOC sources, change audio tracks,
pause and switch back to ordinary SDR/stereo. Compare preview/fullscreen and
retune between channels. Verify preview autohide, PiP, subtitles and that the
compact strip remains separate from transport controls. Source signaling must
be present for an advanced label to appear.
