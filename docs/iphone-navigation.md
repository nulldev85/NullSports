# iPhone navigation

Settings > Liquid Glass chooses between two bottom navigation bars:

- **Off:** Lineup's charcoal rectangular panel, with softly rounded corners,
  the existing five icons and labels, a raised selected tile, and a marker in
  the user's accent color. Each entire tile is tappable and selects immediately.
- **On (iOS 26 and later):** Apple's native Liquid Glass tab bar. The original
  UIKit appearance is restored; Lineup does not draw a glass substitute.

Both styles control the same `TabView` and selection binding. Changing the
style does not replace the tab controller, reset the selected tab, or rebuild
navigation stacks. The custom panel reserves its bottom safe area so the Guide
and Library can scroll to their last rows. Inline full-screen playback hides
both bars. Full-screen presentations cover navigation as usual. Page headers,
menus, and player controls retain their existing surfaces.

`NavigationStyleTests` switches styles, checks native appearance restoration,
visits all five tabs in their visual order, checks controller identity, and
checks full-screen visibility. Its screenshots are exported in the iPhone
workflow's `Lineup-iPhone-navigation-previews` artifact. `GuideScrollLayoutTests`
checks that the last Guide row remains reachable in both styles.
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
