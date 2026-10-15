# iPhone preview controls

Sports and TV Guide share the same preview player. Close stays at the top
left; channel selection, Picture in Picture and expand sit together at the
top right. Engine, live/replay and quality badges sit along the bottom, using
whole labels so AetherEngine and 1080p are not squeezed or wrapped. Centered
play/pause and skip controls keep their own space.

The compact recorded-channel timeline sits below the picture. Both owning
screens reserve its height so it does not overlap the score, program details
or Guide rows. Full-screen playback keeps its timeline at the bottom and uses
a separate header row for badges. Channel banners clear both header rows.

The Library player's full-screen header also separates actions from metadata.
Its badges switch to a vertical arrangement when a row cannot fit.
`PlayerHeaderLayoutTests` checks actual header frames for narrow, normal and
landscape widths, including AetherEngine, replay dates and 1080p, and exports
preview attachments with the iPhone workflow's navigation previews.

Device review: show controls in Sports and Guide with PiP available, change
channels, open a recorded channel, expand/collapse and rotate. Check that all
controls remain reachable and metadata stays on one line. Repeat in Library
with long movie titles and subtitles enabled.
