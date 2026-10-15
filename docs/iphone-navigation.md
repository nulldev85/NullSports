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

Tapping a custom tab returns that destination's existing navigation stack to
its home and scrolls its root content to the top. This also works when tapping
the current tab. It preserves the native controllers and view models; changing
tabs does not animate the whole page. Press feedback and scrolling respect
Reduce Motion. The Guide's horizontal time position stays in place.

`NavigationStyleTests` switches styles, checks native appearance restoration,
visits all five tabs in their visual order, checks controller identity, and
checks full-screen visibility. Its screenshots are exported in the iPhone
workflow's `Lineup-iPhone-navigation-previews` artifact. `GuideScrollLayoutTests`
checks that the last Guide row remains reachable in both styles.
Additional navigation checks exercise every custom destination's return home,
scrolling, controller preservation, and a real SwiftUI navigation path pop.
The Guide measures the custom panel directly and adds only clearance that the
native scroll inset has not already reserved. It observes native inset changes
so switching to Liquid Glass does not double the bottom space.

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
