# iOS 149 detail actions

The user supplied a movie detail screenshot and clarified that the buttons
should match the app's new style. This follow-up changes presentation only:

- Play/Resume uses the same dark row surface, thin border and restrained text
  as other updated controls, with an accent play glyph instead of the green tile.
- Favorites and Watched use dark idle surfaces and outline symbols, with filled
  accent symbols and a subtle tint when selected. Shuffle uses the same treatment.
- All retain their 50-point touch targets and disabled/pressed feedback. Existing
  play targets, resume positions, favorite writes, watched progression, shuffle,
  collections and playback/source selection are retained.
- Connected Seerr stays available as a compact matching button with its official
  mark below the main row, so it cannot compress the play and toggle controls.
  Toggle accessibility labels now describe their actual actions.

The TV's rendered detail page continues using its existing `tvActions` layout.
The new style is iPhone-only. No cast or artwork service changes are included;
the user's follow-up specifically clarified the buttons as the requested fix.
The previous iOS148 login-logo, compact sign-in button and non-glass tab-selection
changes are included through ancestry. iPhone149 is dispatched from a new branch
so the pending iPhone148 run is not superseded or cancelled. TV96 is untouched.

Local source/asset/packaging/focus/YAML/diff checks can run on Windows. Existing
full navigation/playback/Library SDK suites remain enabled. Actual Apple SDK and
device appearance validation depend on CI/device feedback; no appearance-only
tests duplicate the style implementation.
