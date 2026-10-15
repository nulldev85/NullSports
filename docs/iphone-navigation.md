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
The Guide measures where navigation overlaps its full available region and
shortens the vertical list's viewport by that amount. The measured region
keeps its full height, so shrinking the list cannot change the measurement.
SwiftUI owns the zero bottom scroll margins; UIKit does not overwrite them.
The end-of-list test uses the production viewport component and checks the
visible list edge, zero extra inset, and exact last-row alignment through
custom/glass/custom switches.

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
