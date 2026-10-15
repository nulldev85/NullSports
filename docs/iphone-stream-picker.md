# iPhone stream picker

Library Play opens a full-height charcoal panel using the same rounded corners,
header icon, divider, rows and pressed states as Lineup's dropdown menus. A
separate full-width Cancel row replaces the squeezed toolbar Close button.
The panel begins at the top of the large sheet and fills the space above
Cancel. Its header and results scroll together, including in landscape, while
Cancel remains visible. Lazy rows support long result lists. Filtering to one
result keeps the same full-height panel instead of shrinking it to the bottom.

Source filters, counts, pending requests and server errors remain available.
Results retain the existing VOD-first grouping and server ranking, release
names, quality, HDR, codecs, audio, size and bitrate information. Selecting a
result uses the existing playback, resume and episode-advance flow.

`StreamPickerLayoutTests` checks top alignment, available-height use and a
44-result scrolling list, and saves compact, long-release-name and filtered
landscape previews in the iPhone workflow's navigation previews artifact.
Device review: open streams from a movie and an episode, switch sources while
requests finish, try long result names, scroll a large result list, and confirm
Cancel, playback and return from playback behave as expected.
