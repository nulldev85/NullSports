# iPhone stream picker

Library Play opens a compact charcoal panel using the same rounded corners,
header icon, divider, rows and pressed states as Lineup's dropdown menus. A
separate full-width Cancel row replaces the squeezed toolbar Close button.
The panel grows with its contents and scrolls when needed, including in
landscape, while Cancel remains visible.

Source filters, counts, pending requests and server errors remain available.
Results retain the existing VOD-first grouping and server ranking, release
names, quality, HDR, codecs, audio, size and bitrate information. Selecting a
result uses the existing playback, resume and episode-advance flow.

`StreamPickerLayoutTests` saves compact, long-release-name and filtered
landscape previews in the iPhone workflow's navigation previews artifact.
Device review: open streams from a movie and an episode, switch sources while
requests finish, try long result names, scroll a large result list, and confirm
Cancel, playback and return from playback behave as expected.
