# iOS navigation and presentation polish

This round preserves Library, Guide, player, saved-color and login features.
It is iOS-only except for the shared MDBList handoff repair documented in
`mdblist-watch-tracking.md`, and the unchanged shared service-screen presentation
ownership used on Apple TV.

- Sports' All Sports pill uses the app's current dark presentation surface,
  restrained accent rim and subdued text, retaining its compact geometry.
- Streaming-service pages own their selected-title presentation independently
  of Library's value navigation path. The Movies/TV Shows grids no longer
  shadow the ancestor's MediaItem destination. Loading, empty and sorted-grid
  updates cannot remove the destination owner. See All owns its service push
  the same way; detail/playback/features are retained.
- The non-glass tab bar uses a near-black panel, thin rim and restrained selected
  accent. Compact-on-scroll, safe areas, tab order and retap behavior are retained.
- The color editor restores a precise hue/saturation wheel with brightness,
  hex input and Save, followed by My colors. Existing palette storage, explicit
  save/delete actions, presets, fine tuning and Cancel/Done behavior are retained.
- The playback preference presents Native player with Apple's SF Symbol. The
  old automatic saved choice migrates at read time; separate explicit Aether,
  VLC and MPV choices and version labels remain. HLS first uses AVPlayer;
  files/other containers use Aether 7.45's existing demux/remux compatibility
  pipeline while requiring an actual native AVPlayerLayer. This does not add
  codecs to AVPlayer. Unsupported native paths can retry through full Aether,
  then VLC, with an explicit fallback label/notice. The user approved this
  behavior. Compatibility Fallback defaults on and can be disabled; strict mode
  stops with a compatibility message. Native validation precedes autoplay.
  Existing track/subtitle/seek/PiP controls remain available within their engine
  limits; no universal codec or PiP-caption compatibility is claimed.
- My Teams can follow ATP Tour and WTA Tour independently. Existing individual
  follows and teams remain stored and available; no tour follows are auto-added.
- Guide channel holds offer Hide This Category and Manage Categories. Category
  dropdown holds retain Set Default and gain Hide. Preferences use provider UUID
  plus native category ID, so combined-provider IDs cannot collide. Management
  can restore categories, including when all are hidden. Favorites, Recents,
  Sports channel selection and global Search retain their sources.
- Welcome replaces only the poster background with immediate, soft accent
  contours drawn locally. An isolated asynchronous Canvas caps animation at
  30fps, pauses offscreen/in background and respects Reduce Motion. The official
  logo, fields, Xtream/M3U/server login and foreground dimming remain intact.

## Validation

New SDK cases exercise actual NavigationStack push/back presentation across both
Library-to-service routes and a catalog refresh while details are open; persisted
tour follows and matching; provider-scoped category hiding/restoration; wheel
geometry; preference migration and fallback policy; rendered native-compatible
playback and refusal of a software-only source in strict mode. Two existing
engine-specific integration tests now explicitly select Aether instead of the
former automatic preference, retaining all their original behavior assertions.
The full existing suites remain enabled.

Windows has no Swift/Apple SDK. Local source membership, packaging/pin, YAML,
focus and whitespace checks can run here; Swift compilation, SDK cases, IPA
packaging and device behavior require CI/device validation. On device verify
Movies and TV Shows push/back repeatedly, saved palettes survive upgrade, Guide
hide/unhide across providers, native/fallback labels, background animation and
Reduce Motion. Both platforms must be updated to the MDBList handoff repair for
the reported TV-to-phone scenario.
