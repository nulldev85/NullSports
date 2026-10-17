# tvOS recorded playback reliability

The reported case is The Wire through Jellyfin wrappers, degrading after a few
minutes on an Apple TV 4K (third generation), with both VLC and AetherEngine.
The provider VOD copy plays smoothly. Exact release/codec information and a
private-source trace were unavailable; this change does not claim to establish
the origin of every reported stutter or audio/video offset.

## Concrete recovery defect

VLC can expose a still-advancing media/audio clock while its displayed-video
counter has stopped. Lineup already detects a prolonged freeze through that
counter, but previously kept publishing the audio time and reopened two seconds
before that later time. This could save unviewed content as progress and skip it
when recovery finally ran.

The tvOS controller now retains a position supported by displayed-frame movement.
After three seconds without counter progress on a measured regular-rate source
(at least 10 fps), that position holds the UI/tracking checkpoint while the clock
runs ahead. Missing/zero counters and unknown or low frame rates do not establish
this hold. Existing health thresholds still decide when to reconnect; a confirmed
picture stall resumes two seconds before the frame-supported checkpoint on the
same URL. User pauses, seeks, track changes and source changes clear the anchor.
An ordinary buffer pause does not gain a new reconnect or seek policy.

Primary tvOS recorded playback with a known runtime also opts into AetherEngine
7.36.0's built-in `nativeVideoFrameRecovery`. The pinned source at
`c6365cc3c8850bdb670654ca26dcd21f73670875` gates decoded-frame observations to eligible
SDR native output, requires actual prior samples and buffered video, and excludes
seeks, intentional pauses, background and external playback. Repairs are bounded
inside the engine. Software/HDR paths are not treated as measured SDR output.
This option stays off for iPhone, live playback, secondary outputs and recordings
without a duration hint. It does not infer lip-sync from file names or add a Sync
button, forced codecs, arbitrary clock offsets or a transcoding feature.

## Evidence without manual format collection

The existing tvOS Playback Log automatically records measured format changes and
an on-demand playback snapshot at most every 30 seconds in steady playback.
State changes are sampled no faster than once per five seconds. It records engine,
position/runtime, selected-source format tags, available frame/read counters and
available Aether decoder, transfer and buffer measurements. Native loaded buffer,
software decoded cushion and source byte window remain separate. Missing or
non-finite measurements are omitted; no A/V drift is claimed from those values.
The log uses existing counters, with no new source probe or additional playback
connection. URLs, headers, credentials and release addresses are not included.

## Validation

Eight new Apple SDK tests cover prolonged frame freezes after minutes of normal
playback, transient buffering/user pauses, frame-anchor reset/unknown cadence,
format/snapshot logging, sampling/privacy bounds, and actual VLC/Aether playback,
pause, seek and completion through an extensionless HTTP 302 route. A separate
HTTP check verifies exact partial and suffix-range bytes through that redirect.
The shared HTTP origin is explicitly included in the tvOS test target. Existing
test suites stay enabled.

Local Windows checks cover target membership, bundle checks, workflow lint, focus
and diffs. Swift/Xcode tests, IPA delivery and actual Apple TV behavior remain
pending until the review run and device validation. The generated HTTP fixture
establishes transport coverage; it does not reproduce the tester's private file
or prove that its network, encoding or lip-sync defect has been eliminated.
