# iPhone scrolling navigation

The full bottom bar starts visible. A deliberate downward vertical drag
compacts it into one 62-point Sports button at the bottom left. A short upward
drag restores all five tabs. The button uses the existing Sports activation
path, including returning to the Sports home screen, and restores the full bar.
The current tab, saved tab order, native controllers and browsed scroll position
are preserved during collapse/expansion.

The solid bar animates its width and labels with Reduce Motion respected. With
Liquid Glass enabled, the expanded native bar remains in use; the compact Sports
control uses the system glass material. Both forms retain measured bottom
clearance, including the Guide's own nested-scroller measurements.

An always-rejected touch discovery recognizer finds only the touched scroll
ancestry in the selected tab. It observes the existing scroll pan recognizers;
it never recognizes or delays a touch and does not replace their delegates.
Horizontal poster/timeline gestures, programmatic scrolling, inertial movement
and layout/refresh changes cannot independently collapse the bar. Thresholds
ignore jitter and allow an upward reversal within one gesture. Pulling at the
top keeps the full bar. Tab changes, keyboard entry, backgrounding and inline
fullscreen reset it. An accessibility action also restores all tabs.

Only iPhone sources changed; tvOS behavior and playback are unchanged.

## Validation

`NavigationScrollTests` adds deterministic direction checks plus real hosted
UIKit/SwiftUI layout checks for compact placement, both appearances, preserved
controllers/selection/scroll position, horizontal shelves, keyboard, inactive
pages and fullscreen/background gating. Existing navigation, Guide clearance
and playback tests remain enabled. The simulator run exports compact screenshots
with the existing navigation preview artifacts.

Local validation passed on Windows: all 10 metadata/source-membership tests,
the playback project/package-version checks and `git diff --check`. Swift
compilation, simulator tests, screenshot inspection and device interaction
remain pending the full iPhone IPA workflow/device test.
