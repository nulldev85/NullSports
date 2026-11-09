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
Local source checks and asset verification do not establish a native or
physical-device pass. Those results await the manually requested iPhone build
and tester review.
