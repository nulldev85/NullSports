# iPhone icon and Guide polish

Lineup uses the approved minimal red three-bar artwork. Normal and dark Home
Screen icons copy the approved 1024px master exactly. A grayscale derivative
supplies the tinted appearance; welcome branding uses the matching transparent
red mark. The existing tvOS icon and top-shelf slots also use that mark.
The asset-catalog names, bundle identifiers, saved settings and user data retain
their existing identities.

Masters, provenance and edit prompts are in
`BuildAssets/LineupIcon/`. The Windows entry point
`BuildAssets/generate-icons.py` packages those committed raster masters through
`package-lineup-icon.ps1`; the old play-icon script is a compatibility redirect.
CI consumes the committed catalog PNGs directly.

The iPhone Guide retains its bottom clearance while native glass navigation
fades or its compact control attaches. Margin changes do not inherit navigation
animations. Viewport-observer setup also preserves a category's consumed reset
token so a layout refresh does not repeat a top-of-list reset. Focused native
regressions cover the last row during fades, long/short category changes and the
initial reset/observer transition.

This batch is based on current main `24c9da5`, retaining the later library and
playback work. Only the Guide repair was carried over from the earlier local
batch; the closed, unmerged Cricket branch is not reintroduced.
The first manual run built and packaged the physical Release app successfully.
Its simulator suite ran 830 tests with one existing skip; four assertions in
the new long/short category regression blocked publication. The regression
read the bottom clearance before SwiftUI had applied its content margin, then
computed the list's end using the old inset. It now waits for the actual
adjusted inset to match the measured coverage before scrolling, retains the
same three-second readiness deadline and final-row checks, and also asserts
that the applied margin remains stable after scrolling. The other nine Guide
tests passed in that run.

The next manual run at `c610eb0` passed that category-switch regression, along
with the fade, reset-token and end-of-list checks. Physical Release packaging
again succeeded. Publication was blocked by a separate existing first-row test
that compared a cached SwiftUI global-coordinate preference with a UIKit
window-coordinate navigation bar (24 versus a header bottom of 82).

That test now measures a noninteractive marker on the actual first row using
[UIView coordinate conversion](https://developer.apple.com/documentation/uikit/uiview/convert(_:to:)-2kf3d),
putting both live views in the same window space. SwiftUI's
[global coordinate space](https://developer.apple.com/documentation/swiftui/coordinatespace/global)
is rooted in its own view hierarchy. The preference cache and the feedback
it published into the test's view model are removed. The exact visible-row
clearance checks and readiness deadlines remain; after reset the new scroller
must be at its own adjusted top and the first row must still physically clear
the header. The test retains a screenshot and live geometry diagnostics.
No app source, icon, workflow gate or timeout changed for either test repair.
This measurement correction and physical tester review remain pending the next
manual build; local checks are not a native or device pass.
