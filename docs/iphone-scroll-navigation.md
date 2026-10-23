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

## Build 129 follow-up

Build 128 compiled both configurations and successfully packaged/uploaded its
staging IPA. The full simulator run executed 594 tests (one existing skip), with
two assertions failing in the new hosted navigation test: a presentation wait
and an inactive-controller array-membership assertion. All existing navigation,
Guide clearance and playback tests passed. Compact screenshots were exported
in both styles and inspected.

The UIKit bridge now reconciles the native bar's requested visibility after
toolbar/layout changes using the public tab-controller visibility API on iOS 26+.
It also refreshes its reference to the live floating bar. The new test waits
for the actual presentation width to finish animating before changing appearance,
and checks controller identity/scroll position by returning to Library instead
of assuming SwiftUI lists every inactive lazy controller in `viewControllers`.
Its two-second bounds, all cases and existing checks remain enabled; failures
now identify the precise wait call. Replacement SDK/device validation is pending.
