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
Library artwork remains clear behind the status bar and options button.
The iPhone Library hero uses the detail page's primary/poster artwork in a
portrait frame, with a long vertical fade behind the copy into the Library
background. Its four-second rotation and crossfade remain in place.
Pulling down past the top of Library home or a title's detail page progressively
zooms its header artwork, anchored at the bottom to fill the exposed top area.
The same effect covers movie, show and other playable-item detail headers.
Titles, ratings, page indicators, fades and controls keep their normal size.
Only the artwork receives the scroll-relative visual transform; the resting
layout, decoded image size and cache key remain stable. The scroll view's own
bounce restores the picture on release, with no extra gesture, timer or spring.
Reduce Motion leaves the normal scroll behavior without the zoom. This uses
SwiftUI's [geometry-based visual effects](https://developer.apple.com/documentation/swiftui/view/visualeffect(_:)).
The home carousel uses a native horizontal pan recognizer whose delegate rejects
vertical and mainly vertical movement before recognition. Checking direction only
after a SwiftUI drag ended could already have intercepted the Library's pull.
The parent scroll view explicitly allows vertical bounce even with a short
Library. Scroll-phase changes pause the four-second rotation during a pull or
scroll, and horizontal swipes pause it until release/cancellation. This uses
[UIKit gesture integration](https://developer.apple.com/documentation/swiftui/uigesturerecognizerrepresentable)
and [early recognition decisions](https://developer.apple.com/documentation/uikit/uigesturerecognizerdelegate/gesturerecognizershouldbegin(_:)).
Its home and full-bleed detail screens hide the navigation bar background and,
on iOS 26+, the separate [top scroll-edge effect](https://developer.apple.com/documentation/swiftui/view/scrolledgeeffecthidden(_:for:)).
The Guide applies measured bottom navigation coverage once, without an
additional inherited home-indicator margin. Its existing layout regression
checks exact last-row alignment across repeated custom/native style switches.
The custom bar also reports physical position changes and removal within its
own window. The Guide observes those events as well as its viewport layout:
an origin-only bar movement must update clearance even when the list never
resizes. Reports are coalesced and unchanged geometry does no work; detached
Guides remove their subscriptions. A regression exercises the 83-to-118-point
coverage change without manually refreshing the list, plus later removal.
The other four tabs reserve the custom panel's measured coverage in their native
navigation container, including pushed Library/Search/Settings pages. The panel
is an overlay without a second outer SwiftUI inset or full-width background.
Window/home-indicator protection is counted once, and the custom reservation is
restored when switching to Liquid Glass or entering full-screen playback.

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

Choose Another Channel keeps its editing buffer in a native text field.
Editing and Clear events go directly to the search store. Completed-result
renders never write into the editor or disturb its cursor/composition state.
Only completed answers publish to the results view, after cancellable background
filtering with a 120ms debounce. The picker listens specifically to catalog and
favorite changes, without observing every sports-store publication. Catalog
sorting, folded search names, favorite lookup and suggestion deduplication are
built in background work; the opening path does not scan the full Guide for
favorites. Stale queries/catalogs cannot publish over newer work, and dismissal
cancels queued work. Clearing search restores provider order with suggestions
separate; radio entries and duplicate channel IDs are excluded.

Results use a reusable UIKit table with the existing SwiftUI channel-logo rows,
Lineup headers, panel colors and dividers. Only visible rows are configured.
A page identity skips table work when an unrelated parent redraws, without a
comparison or SwiftUI identification pass over the provider's entire array.
All channels remain reachable; there is no result cap or extra paging control.
Apple describes List's eager identifier collection in
[Demystify SwiftUI performance](https://developer.apple.com/videos/play/wwdc2023/10160/)
and supports these hosted rows through
[UIHostingConfiguration](https://developer.apple.com/documentation/swiftui/uihostingconfiguration).

Xcode checks include saved-order repair/persistence, reordered custom tab
activation/return home, actual native/custom order changes with stable
selection, stream-panel geometry and long-list scrolling, toolbar label widths
and screenshot capture, and search coalescing/provider replacement/cancellation.
A 30,000-channel model case checks that drafts do not publish catalog-sized UI
updates. A real picker/window regression drives the actual text control's editing
and Clear events, checks that results retain its text and identity, and counts
UIKit cell requests through an
external data-source wrapper: opening, clearing back to all channels, and jumping
to the last row must create fewer than 200 cells per operation. It checks reused
row selection and exports a screenshot and row-work counts with test attachments.
Full simulator validation and release packaging run in the review builds.

Device review:

- Open movie/episode results with one and many matches. Check top alignment,
  scrolling, source filters and Cancel in portrait and landscape.
- Drag Settings, Search and Library to new positions. Switch navigation styles,
  relaunch, and confirm tapping each destination and returning home still work.
- Check the floating custom bar against Library artwork and other page colors.
- Scroll Sports, Library, Search and Settings to their final entries. Check that
  they rest above navigation in both styles, including pushed pages. Rotate and
  expand/collapse an inline player; no extra bottom gap should remain afterward.
- At the top of Library and title details, check that artwork stays sharp behind
  the status bar and toolbar buttons in both navigation styles, including after
  scrolling down and returning to the top.
- Pull progressively farther down at the top of Library home, a movie, a show
  and an episode detail page. The artwork should zoom smoothly and cover the
  top edge, while labels stay the same size. Release, scroll normally, swipe
  the carousel, rotate, and repeat with both navigation styles. With Reduce
  Motion enabled, check normal scrolling without the zoom.
- Start a slow vertical pull directly on the home hero's picture, title and
  ratings, then repeat with a diagonal but mainly vertical pull. Both should
  scroll/zoom just as on a movie/show page. Also check a short Library, normal
  scrolling, a deliberate left/right swipe and a tap to open details. The title
  should not auto-advance while interacting; rotation resumes after release.
- Open Catch Up, Choose Another Channel, Accent Color, its mixer, provider/server
  setup and Library dialogs. Check readable, themed close/Done buttons.
- Type and clear a long channel search with a large provider, then type quickly
  in another direction. Confirm suggestions return and old results stay gone.
- Open and close TV Guide's options; confirm the extra ring is absent.
