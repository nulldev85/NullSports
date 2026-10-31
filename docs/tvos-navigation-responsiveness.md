# Apple TV navigation responsiveness

The user confirmed iPhone983 improves responsiveness and fixes Settings, then
reported severe lag throughout Apple TV. Both baseline workflows at bd977c0
(iPhone983 and TV723) succeeded. This follow-up changes Apple TV view paths;
the working iPhone implementation and player quality/engine/buffer policies
are preserved.

## Confirmed source paths

- The score crawl constructed at least two copies of every score, potentially
  hundreds of score/logo views in an extremely wide strip. Its repeating
  keyframe animator had no active-tab input. Apple's
  [keyframe documentation](https://developer.apple.com/documentation/swiftui/keyframeanimator)
  confirms its content closure is updated each animation frame. This is a
  persistent rendering-work path, not proof of a particular device's CPU trace.
- TV Guide used the shared synchronous, single-entry channel-list cache.
  Catalog/favorite changes or a competing query could make a focus/layout update
  filter/sort the provider catalog on the UI actor. Remote movement searched
  the resulting array again, and choosing a default preview could scan every
  channel's programs on that actor.
- Library focus changes built all item keys for the selected shelf, even though
  its special membership handling only concerns the small Continue Watching
  row. Browse getters repeatedly joined history to catalog/series state and
  rebuilt favorite rows. Library prefetch subsequently requested the first
  artwork of every shelf, including distant shelves that were not visible.

These are source findings, not measured attribution of all lag on the user's
physical Apple TV. Device behavior remains a required review check.

## Resulting behavior

The crawl now renders a viewport-sized window (four entries for a 1920-point
viewport), cycling through all scores. One Core Animation translation moves it;
there is no per-frame SwiftUI callback. A task advances the window approximately
once every twelve seconds. Score changes retain the current game and current
translation. Tab/scene/fullscreen lifecycle gates pause the animation/task;
empty data and Reduce Motion stay idle. Typography, logos, score data, speed,
spacing and the larger gap at the loop boundary are retained.

Guide filtering, sorting and channel-position indexing run on cancellable
background snapshots. Publication checks the requesting library, catalog
revision and query, and inactive/obsolete work cannot install its rows.
Favorite order is retained. Remote movement uses the prepared index. The
default preview scan runs separately off the UI actor and is only needed when
no valid focused preview exists. Active rows remain available on return, and
Guide's clock/query work pauses off screen or behind its fullscreen player.

TV Library caches Continue Watching/favorites/history-presence by their actual
observed data, deferring refresh while inactive. Its content observer checks
the selected item/count/boundaries; only Continue Watching retains a bounded
twenty-item membership list. Artwork prefetch warms neighboring shelves and
cancels when inactive. The preview's pending metadata task also stops on exit.
Settings uses the same TV cache for the tracking-history action.

The Sports color canvas belongs outside MainView's native tab container.
A small shared palette object connects highlighted-game colors to that canvas
without making the tabs observe every focus change. One gradient covers top
navigation, both screen edges, content and the ticker. Standalone Sports still
provides its own canvas. A scoped UIKit bridge clears opaque defaults on the
Sports host/tab container and restores their prior colors when leaving; it
does not traverse or restyle controls during focus changes. Other tabs retain
their existing backgrounds.

## Verification

- 35 Foundation XCTest cases pass on the Linux host, including the actual
  TV Guide snapshot/index/cancellation/preview helpers and bounded ticker
  window/wrap logic, alongside all existing phone refresh/cup/tennis cases.
- 33 repository checks, both target syntax parses, TV focus and whitespace
  checks pass locally. These do not replace Apple SDK type checking.
- Native tests cover a 5000-score ticker retaining a bounded strip, a single
  animation, score changes, disappearance/input gates, resuming and empty data;
  Library observation caching/inactive updates; and a 30000-item shelf key.
- The background regression now mounts the production MainView, applies the
  real UIKit tab-bar theme, and samples top/center/bottom pixels at BOTH edges
  for two palettes. Earlier tests used Sports in a generic TabView.

Apple SDK/native execution and physical-device responsiveness for this
follow-up are pending the new review build. No merge or production/VPS update
is included. The four requested soccer cups remain included.
