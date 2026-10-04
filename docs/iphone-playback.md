# iPhone playback lifecycle

How a live stream starts, survives backgrounding, moves into Picture in Picture,
and recovers — and where to hook in later failover work without breaking any of
it. Apple TV is not described here: it keeps its own player and is untouched by
everything below.

## One controller, two engines

`MobilePlaybackController` is the only playback object the iPhone views know
about. All three surfaces — the full-screen `MobilePlayerView`, the inline
`MobileGuidePlayer`, and the Live preview — hold one and talk to it through the
same small API (`start`, `toggle`, `goLive`, `handleScenePhase`, `stop`,
`shutdown`).

It owns **both** engines for the whole session and runs exactly one at a time:

| Engine | Player | Used for | Gets |
| --- | --- | --- | --- |
| `.system` | `AVPlayer` | HLS (`.m3u8`) | Picture in Picture, background audio |
| `.vlc` | `VLCMediaPlayer` | MPEG-TS (`.ts`) and anything AVPlayer refuses | Everything else |

Xtream publishes every channel at both URLs, so on the phone
`MobileEngineSelection.ordered` puts HLS first and leaves the transport stream
queued behind it as the fallback. This is deliberately the reverse of Apple TV's
order: only an `AVPlayerLayer` can drive `AVPictureInPictureController`, and
VLCKit 3.6.0 renders into an opaque `UIView` with no frame source PiP can read.
A channel whose HLS endpoint is missing or broken still plays — it just falls
through to VLC and loses the PiP button.

Both players are created once, in the controller's initializer, and are never
replaced. Channel changes, engine fallback, resizing, expanding, collapsing,
rotating and entering PiP all reuse them.

## The surface

`MobileVideoHost` is one `UIView` that can host either renderer — VLC's own
subview, or an `AVPlayerLayer` — never both. `installPlayerLayer(for:)` is
idempotent: an existing layer for the same player is returned untouched. That
matters more than it looks, because the PiP controller is built **on** the
layer. Replacing the layer on a resize would drop PiP and restart the stream, so
`layoutSubviews` only re-frames what is already there (inside a
`CATransaction` with actions disabled, so a rotation doesn't animate it).

## Scene phase

`MobileBackgroundPolicy.action(...)` is the single decision table for what a
scene-phase change does. It is pure Foundation, lives in
`iPhone/MobilePlaybackPolicy.swift`, and is covered twice: by
`Tests/MobilePlaybackPolicyChecks.swift` (a bare `swiftc` binary the iPhone
workflow runs before anything else builds) and by `Tests/iOS/PlaybackPolicyTests.swift`.

    pausedByUser            -> .leaveAsIs     (a manual pause outranks everything)
    foreground              -> .keepPlaying
    background + PiP        -> .keepPlaying
    background + bg audio   -> .keepPlaying
    background, no bg audio -> .pause

Before this, each surface had its own `scenePhase` branch and all three paused on
background; Live tore the stream down entirely. The `.pause` row is a safety
net, not a normal state: it is reachable only if `UIBackgroundModes: audio` is
missing from `project.yml`, in which case iOS suspends the process anyway and a
clean pause beats being killed mid-buffer. `MobilePlaybackController.backgroundAudioEnabled`
reads the built `Info.plist` rather than assuming, so dropping the key degrades
visibly instead of silently.

Two things are deliberately *not* driven by `scenePhase`:

- **The layer detach.** An `AVPlayerLayer` still holding its player suspends
  decoding once its window leaves the screen, which would silence background
  audio. The controller detaches the player from the layer on
  `didEnterBackgroundNotification` and reattaches on `willEnterForegroundNotification`
  (or earlier, when PiP starts). Riding real backgrounding rather than
  `scenePhase` keeps a transient `.inactive` — a control-centre pull, a call
  banner — from blanking the video.
- **Leaving a tab.** `isActive` still tears the player down, because that is
  navigation, not backgrounding. The one exception is an active PiP window,
  which the viewer explicitly asked to keep.

## Picture in Picture

`AVPictureInPictureController` is created once per `AVPlayerLayer`, with
`canStartPictureInPictureAutomaticallyFromInline = true` — so backgrounding an
inline player hands it to the system window rather than stopping it. No new
item, no new connection, no reconnection: the same `AVPlayer` keeps the same
item and position throughout, which is the whole point.

`detachVideo` refuses to tear the engine down while PiP is active, since the
window is showing that stream and the view that started it may well be gone.
`shutdown()` stops PiP first, so an explicit close still closes everything.

## Recovery

Unchanged in shape. `LivePlaybackHealth` and `LivePlaybackRetry`
(`Lineup/Services/LivePlaybackHealth.swift`, shared with tvOS and covered by its
own `swiftc` check) still drive automatic recovery for the VLC engine, with
backoff `[1, 2, 4, 8, 15, 30]` and a manual **Retry** button on the error state.
The AVPlayer engine reports through KVO on `status` / `timeControlStatus` plus
`failedToPlayToEndTimeNotification`, and falls through to the next candidate —
normally the transport stream on VLC — via `systemEngineFailed()`.

One wrinkle worth knowing: while backgrounded, the VLC health monitor is
skipped. A backgrounded stream has no video output by design, and feeding that
to the health model reads as a lost picture and reconnects on a loop for as long
as the app stays backgrounded. Recovery resumes with a fresh baseline on return
to the foreground.

## Where the channel comes from

A stream no longer always starts from Lineup's own match. `TeamChannelPreferences.resolve`
(`Lineup/Services/TeamChannelPreferences.swift`, pure and checked by
`Tests/TeamChannelPreferenceChecks.swift`) decides what tapping a game does:
play a saved per-team channel, ask which feed when both teams disagree, fall
back to the verified match, or open the picker.

The resolver separates two things that are easy to conflate. **Available** means
the provider still carries the channel. **Verified** means current guide evidence
says it is carrying *this* game. A saved preference needs both: a regional
network is carried all season and only shows some of the schedule, so treating
its mere presence as permission would open it during a nationally exclusive
game. `SportsLibrary.isStream(_:verifiedFor:)` answers the verified question for
Lineup's own match, for a saved preference, and for every failover candidate —
one rule, so a preference can never reach playback by a weaker route than an
automatic match. Neither condition failing ever deletes the preference; it
decides the next game, not this one.
Playback itself is unchanged by this — whatever is chosen arrives at
`start(urls:)` exactly as before, and the engine, PiP and recovery behaviour
below apply identically.

One interaction worth noting: choosing a different channel replaces the whole
controller (`showPreview` tears the old one down and builds a new one), which is
deliberate and predates this — a *channel change* is a new session. That is not
the same as failover *within* one stream, which must reuse the players it has.

## Safe extension points for stream failover

The candidate list is the seam. Everything below already funnels through it, so
failover work should extend these rather than adding a parallel path:

- **`SportsLibrary.isStream(_:verifiedFor:)`** — the single evidence question.
  Anything that widens or narrows what counts as "carrying this game" belongs
  here, and is then picked up by the automatic match, the preference resolver
  and the failover plan together.
- **`MobileEngineSelection.ordered(_:)`** — the ordering policy. Pure, testable,
  and the right place for provider-aware or quality-aware preference. Anything
  added here is picked up by both the initial open and recovery, because both
  call it. Keep it a stable partition: callers rely on the transport stream
  remaining reachable behind the HLS one.
- **`MobilePlaybackController.openNext()`** — pops one candidate and dispatches
  on `MobileEngineSelection.engine(for:)`. A new engine (or a per-URL option set)
  plugs in here. It is the only place that decides which player opens a URL.
- **`scheduleRecovery(now:)`** — decides *which* candidate the next attempt
  uses. Today: first retry repeats the same endpoint, later ones rotate. Richer
  failover (per-endpoint failure counts, blacklisting a dead origin for N
  minutes, a second provider) belongs here, and only needs to leave
  `candidates` and `retryAt` set.
- **`systemEngineFailed()`** — the AVPlayer-side failure funnel. Widening what
  counts as a failure means editing this one method; note that HLS error-log
  entries are routine and deliberately *not* treated as failures.

Two constraints any extension has to keep:

1. **Never construct a second player.** Both engines are session-scoped. A
   failover that allocates a new `AVPlayer` or `VLCMediaPlayer` loses the PiP
   controller and the audio session with it.
2. **Never replace the `AVPlayerLayer`** while PiP might be running. Reuse
   `installPlayerLayer(for:)`.

## Not verified here

Written and reviewed without a build: this environment has no Xcode or Swift
toolchain. The pure policy logic is verified (both check harnesses, plus an
exhaustive pass over the decision table); the AVFoundation and VLCKit
integration is not. It needs a compile and a device pass — background audio with
the screen locked, PiP from both players, expand/collapse and rotate while
playing, an HLS channel that fails over to VLC, manual retry, and
background/resume.
