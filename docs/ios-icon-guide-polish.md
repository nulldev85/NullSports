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
tests passed in that run. The corrected regression and physical tester review
remain pending the replacement manual build; no native or device pass is
claimed from local checks.
