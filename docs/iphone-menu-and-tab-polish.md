# iPhone menu and navigation polish

Library stream results fill the large sheet from the top. The charcoal card
uses the same headers, dividers, rows and pressed states as other app menus,
and its list scrolls above a separate, always-visible Cancel row. There is no
content-height measurement or short fallback panel. Filtering, late server
answers, errors, ranking, metadata and playback selection remain supported.

Settings > Tab Order lets users drag all five destinations into their preferred
order and restore the default. A local preference drives both the native and
custom bars. Selection uses stable destination tags; custom return-home logic
resolves the saved visual order. Tab pages retain stable SwiftUI identities.
The custom bar's full-width background is removed; its own panel is retained.
The Guide applies measured bottom navigation coverage once, without an
additional inherited home-indicator margin. Its existing layout regression
checks exact last-row alignment across repeated custom/native style switches.

App-owned toolbar controls use LineupToolbarItem. On iOS 26 and later it hides
the native shared glass background and preserves the app control's intrinsic
width. Text in LineupBarButtonStyle is one line with its full fitting width.
The helper covers Catch Up, Choose Another Channel, provider/server setup,
accent selection and mixing, favorite/shelf ordering, Library search, and
diagnostic actions. Existing custom player close icons retain their app style.
The Guide and Library dropdown buttons also use the helper; the ellipsis
control's own outline is removed. Native Liquid Glass remains the bottom
navigation option. Apple's [toolbar background API](https://developer.apple.com/documentation/swiftui/toolbarcontent/sharedbackgroundvisibility(_:))
provides the per-item customization.

Choose Another Channel resolves game suggestions once on opening or when the
provider catalog/favorites change. It builds a sorted, case/diacritic-folded
channel index off the UI actor and filters it in a cancellable background task
after a 120ms typing debounce. Stale queries or catalogs cannot publish over
newer work. Clearing search restores the full provider order, with suggestions
separate; radio entries are excluded. Text changes do not rerun game matching,
provider sorting, or per-row favorite-array searches. Dismissal cancels work.

Xcode checks include saved-order repair/persistence, reordered custom tab
activation/return home, actual native/custom order changes with stable
selection, stream-panel geometry and long-list scrolling, toolbar label widths
and screenshot capture, and search coalescing/provider replacement/cancellation.
Full simulator validation and release packaging run in the review builds.

Device review:

- Open movie/episode results with one and many matches. Check top alignment,
  scrolling, source filters and Cancel in portrait and landscape.
- Drag Settings, Search and Library to new positions. Switch navigation styles,
  relaunch, and confirm tapping each destination and returning home still work.
- Check the floating custom bar against Library artwork and other page colors.
- Open Catch Up, Choose Another Channel, Accent Color, its mixer, provider/server
  setup and Library dialogs. Check readable, themed close/Done buttons.
- Type and clear a long channel search with a large provider, then type quickly
  in another direction. Confirm suggestions return and old results stay gone.
- Open and close TV Guide's options; confirm the extra ring is absent.
