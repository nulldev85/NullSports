# iPhone preview controls

Sports and TV Guide share the same preview player. Close stays at the top
left; channel selection, Picture in Picture and expand sit together at the
top right. Engine, live/replay, quality and confirmed stream-format badges sit
in a horizontally scrollable strip along the bottom, using whole labels so
AetherEngine, 1080p and Dolby Vision are not squeezed or wrapped. Centered
play/pause and skip controls keep their own space.

The compact recorded-channel timeline sits below the picture. Both owning
screens reserve its height so it does not overlap the score, program details
or Guide rows. Full-screen playback keeps its timeline at the bottom and uses
a separate header area for badges. Channel banners clear its measured height,
including additional rows of format labels.

The Library player's full-screen header also separates actions from metadata.
Its whole badges flow onto additional rows when a row cannot fit.
`PlayerHeaderLayoutTests` checks actual header frames for narrow, normal and
landscape widths, including AetherEngine, replay dates, 1080p, Dolby Vision,
Dolby Atmos, HEVC and frame rate, and exports
preview attachments with the iPhone workflow's navigation previews.

Device review: show controls in Sports and Guide with PiP available, change
channels, open a recorded channel, expand/collapse and rotate. Check that all
controls remain reachable and metadata stays on one line. Repeat in Library
with long movie titles and subtitles enabled.

See [format sources and accuracy checks](playback-format-badges.md).
