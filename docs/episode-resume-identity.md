# Episode checkpoints across refreshed item IDs

The show selector already accepts a saved episode under a changed item ID by
matching its season and episode. Previously, checkpoint lookup and Continue
Watching still required the exact item ID. After a catalog refresh, the selector
could choose the correct episode but queue a new zero-position marker and hide
the genuine saved record. Playback then started from the beginning.

Tracking now uses the same episode identity consistently. An exact item ID still
matches as before. A different ID requires the same source profile, the same
nonempty series ID, and explicit matching season and episode numbers. Titles or
episode names are never enough. Other shows, seasons and source profiles remain
separate; missing coordinates do not trigger an inferred match.

Genuine playback and explicit watched/unwatched marks outrank generated Up Next
markers for that episode. New progress commits consolidate its old aliases, and
manual marks retire buffered samples and sessions under those aliases. Existing
saved checkpoints can be read immediately without a destructive migration.
Hidden Continue Watching entries keep their checkpoints and remain hidden until
a new viewing session advances, as before. Runtime and completion thresholds,
server stream selection and playback engines are unchanged.

Shared SDK regressions use ordinary one-hour runtimes for provider VOD and
Jellyfin items. They cover refreshed IDs, old progress plus a newer empty marker,
relaunch, episode counts, source/show/season isolation, explicit marks, retired
callbacks and hidden checkpoints. The tvOS regression hosts the real PlayerView
with deterministic VLC/Aether backend adapters, awaits its actual load/progress/
disappearance callbacks, checks the final sub-interval sample and reopens at the
restored checkpoint. Existing real-decoder integration tests remain enabled.

These fixtures reproduce the identity-loss path without a private server. The
user reported that The Wire has a normal seek bar/runtime and fails with both
provider VOD and Jellyfin; their actual server responses have not been inspected.
The user tested tvOS 84 and confirmed it remembers the position from before the
app was updated. They reported missing thumbnail progress as the remaining issue.

The tvOS artwork compositor now anchors progress to the visible card bounds,
separately from the cropped image. A portrait source filling a still, or a wide
source filling a poster, can extend outside that card. The previous overlay was
attached to the image's expanded bounds and could be clipped off the screen.
Both Continue Watching/Library cards and the show page's episode thumbnails use
the fixed compositor. iPhone retains its previous composition. Tracking and
resume storage/transport are unchanged in this rendering follow-up.

Two tvOS rendering regressions use generated artwork and actual restored
provider/Jellyfin checkpoints. They inspect visible accent pixels for episode and
movie progress across portrait, landscape and matching aspect ratios, retain
proof screenshots, and check the show's current-episode bar at the bottom edge.
They await actual layout callbacks instead of guessing a render delay. Apple SDK
execution remains CI validation; these render checks cannot run on Windows.
