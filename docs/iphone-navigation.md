# iPhone navigation

Settings > Liquid Glass chooses between two bottom navigation bars:

- **Off:** Lineup's charcoal rectangular panel, with softly rounded corners,
  the existing five icons and labels, a raised selected tile, and a marker in
  the user's accent color. Each entire tile is tappable and selects immediately,
  with a short press response and light selection haptic.
- **On (iOS 26 and later):** Apple's native Liquid Glass tab bar. The original
  UIKit appearance is restored; Lineup does not draw a glass substitute.

Both styles control the same `TabView` and selection binding. Changing the
style does not replace the tab controller, reset the selected tab, or rebuild
navigation stacks. The custom panel reserves its bottom safe area so the Guide
and Library can scroll to their last rows. Inline full-screen playback hides
both bars. Full-screen presentations cover navigation as usual. Page headers,
menus, and player controls retain their existing surfaces.

Settings > Tab Order has permanent drag handles and Restore Default Order.
Order is saved locally and drives both the native TabView and custom panel.
Stable destination tags keep selection and return-home targeting independent
of position. Missing, repeated or unknown saved entries are repaired without
hiding a destination. The custom panel draws only its own rounded charcoal
surface; it has no full-width background behind or below it.

Tapping a custom tab returns that destination to its home and scrolls its root
content to the top. Library, Search and Settings register a root-owned SwiftUI
reset, so destination links reset along with their navigation state. A UIKit
pop alone leaves SwiftUI's path out of sync. Tab controllers, root view models
and player owners stay in place; only the pushed stack resets. This also works
when tapping the current tab, with no whole-page animation. Press feedback and
scrolling respect Reduce Motion. The Guide's horizontal time position stays
in place.

`NavigationStyleTests` switches styles, checks native appearance restoration,
visits all five tabs in their visual order, checks controller identity, and
checks full-screen visibility. Its screenshots are exported in the iPhone
workflow's `Lineup-iPhone-navigation-previews` artifact. `GuideScrollLayoutTests`
checks that the last Guide row remains reachable in both styles.
Additional navigation checks exercise every custom destination's return home,
scrolling, controller preservation, and a real SwiftUI navigation path pop.
The Guide's shared channel scroller measures the actual UIKit scroll viewport
against the active navigation boundary and applies that coverage once, through
SwiftUI bottom content and indicator margins. The native glass layout can
extend this inner UIScrollView below the outer SwiftUI region: the outer region
may report zero overlap while the inner viewport has 83 points behind the bar.
Measuring or shrinking only that outer region therefore misses the covered rows.
No tab-bar height is hard-coded, and scroll offsets do not affect the reading.

A transparent, noninteractive observer follows the actual scroll view's
[frame layout guide](https://developer.apple.com/documentation/uikit/uiscrollview/framelayoutguide).
Its layout and safe-area callbacks catch late native-bar changes even when the
much taller scrolling content does not resize, including while scrolled to the
end. Updates are event-driven and publish only when clearance changes. Removing
the content probe detaches the observer. Native mode ignores an outgoing custom
panel boundary. The existing configuration prevents a second automatic top
navigation inset; SwiftUI owns the measured bottom margin.

The end-of-list test uses the same channel scroller as the app and preserves
exact usable-edge and final-row alignment through repeated custom/glass
switches. A UIKit regression shows and hides the native bar after initial
layout with a tall, scrolled content probe and no manual refresh. Neither test
assumes a fixed tab-bar height or a zero bottom inset.

Device review: turn Liquid Glass off and check the panel in Sports, TV Guide,
Library, Search, and Settings. Change the accent color, switch tabs repeatedly,
and confirm scrolling and pushed pages remain in place after switching styles.
Expand a Sports or Guide preview and return: navigation should disappear and
return with the player transition. With Liquid Glass on, check Apple's native
bar over scrolling content. Check the last Guide channel and Library row in
both styles.
With the Lineup bar, push several Library or Search detail pages, tap the tab
icon, and confirm its home returns. Scroll down and tap again to return to the
top. Repeat across the five tabs, including fast consecutive taps.
