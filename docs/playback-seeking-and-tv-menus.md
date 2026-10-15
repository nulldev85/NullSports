# Held menus and Library seeking

Apple TV held-item menus now present one immutable value containing the item
title, message and actions. Each hold has a fresh sheet identity. An empty
action list cannot produce a title-only menu. Selected actions still execute
after dismissal, so an action that opens another screen does not compete with
the outgoing menu. Short Select and held Select remain exclusive.

In the Apple TV Library player, focus the progress bar and press left or right
to step ten seconds. Keep holding to move continuously and accelerate. Release
to commit the destination. Up/down commits and returns focus to the transport
buttons. The native input observer accepts only left/right presses while the
bar is focused, handles release/cancel, and removes its recognizers when its
view leaves the window. Other controls retain normal remote input.

The iPhone Library player has a 44-point touch target around the progress bar.
Touch anywhere and drag to move its indicator and time labels immediately;
release to commit the exact release position. Only the seek-bar view redraws
with finger movement. Dismissal and control hiding pause during interaction,
and VoiceOver supports adjustable playback position.
Disabling the parent dismissal gesture keeps child gestures enabled, so the
seek drag continues for its full lifetime.

Both players keep the moving destination separate from saved playback time.
Playback pauses during interaction and restores the previous play/pause choice
on release. Decoder previews keep only the latest queued position, run at most
once per 180ms, and avoid repeating identical targets. Release cancels queued
previews and commits immediately, without re-seeking a target already sent.
Stopping/retuning cancels old work. Aether keeps one seek in flight and only
the latest pending target, with the current transport intent applied afterward.
Native AVPlayer and VLC use their existing seek APIs.

Old decoder positions and end notifications cannot replace the committed
destination while the seek settles. A bounded four-second landing window
prevents an unresponsive source from freezing the clock forever. Previewing
near the end does not mark an episode watched; only the committed playback
position enters local tracking. This applies to Library movies, episodes and
provider VOD; live-channel recording timelines retain their existing behavior.

The native remote implementation follows Apple's [button press handling](https://developer.apple.com/library/archive/documentation/General/Conceptual/AppleTV_PG/DetectingButtonPressesandGestures.html)
and [allowed press types](https://developer.apple.com/documentation/uikit/uigesturerecognizer/allowedpresstypes).
AVPlayer's [seek completion behavior](https://developer.apple.com/documentation/avfoundation/avplayeritem/seek(to:completionhandler:))
allows a later request to interrupt an earlier request.
The dismissal mask uses Apple's [subviews option](https://developer.apple.com/documentation/swiftui/gesturemask/subviews),
which preserves child input while disabling the added parent gesture.

Validation includes shared seek policy/coalescing/landing tests, held-menu
payload and remote press-session tests, both tvOS engine controllers with late
position/EOF samples and stop/retune cancellation, and actual iPhone Aether
MP4/software-MKV scrubbing with pause/resume, surface and subtitle preservation.

Device review before merge:

- On a fresh launch, hold once on a Guide channel, Sports matchup and Library
  title. Confirm the full relevant menu appears immediately. Cancel, focus a
  different item, and hold once again. Releasing Select must not start playback.
- In each tvOS engine, play a Library title, focus the bar, hold both directions,
  change direction, release and move focus away. Repeat while paused and after
  opening another title. Check that the bar stays put when old frames arrive.
- On iPhone, drag in portrait and landscape, reverse direction, tap to seek,
  and release at both ends. Check that playback retains its paused/playing
  state, controls stay visible, and dragging never dismisses the player.
- Preview near the end and drag back before release; the episode must remain
  unwatched. Close during interaction and reopen to check the committed resume
  position. Repeat with a media-server file and provider VOD.
