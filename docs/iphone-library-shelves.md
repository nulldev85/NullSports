# iPhone Library shelves

Scope: iPhone Library poster rows, including Continue Watching, Favorites,
catalogs and related titles. tvOS keeps its current focus and shelf paths.

Horizontal rows use a UICollectionView with explicit item sizes and reusable
cells. The existing SwiftUI card supplies artwork, titles and tracking overlays.
UIKit handles scrolling and selection; a native hold presents the existing app
menu. Playback and navigation are owned by the screen, outside recycled cells.
Title and metadata lines reserve scaled space, independent of the source image
dimensions or a late title update. Related posters use the same 150-point width
as the main shelves. Episode titles also reserve two lines.

Each row retains its leading visible identity and distance from that poster.
An insertion or view recreation restores that position; removing the anchor
clamps the previous offset to the remaining content. Metadata-only publications
do not reload the row or reset its scroll position. iPhone source catalogs stay
unmapped; visible cards still resolve and display the selected metadata source.
Only the hero observes changes in vertical scroll activity, so pausing rotation
does not invalidate the whole Library screen.

Artwork uses the shared decoded-image cache and download deduplication. The new
iPhone subscriber keys displayed images by URL and decode size and rejects a
cancelled or superseded response. Portrait decode sizes account for their longer
edge; server requests use Retina pixel widths. Preview progress is attached to
the visible artwork frame, so cropping cannot move it outside that frame.
Nearby collection-view prefetch requests replace eager downloads from every row.

Validation: new Apple SDK regressions exercise a 500-title native row, cell
recycling, fixed geometry, title updates, insertion/recreation/removal offsets,
selection and native accessibility menu actions, Retina sizing, late image
responses and cancelled subscribers. Async tests await actual request callbacks.
The complete existing simulator suite remains enabled. Local source-membership,
team-directory, focus and diff checks run on Windows; SDK validation and physical
iPhone scrolling remain pending until the review build and device test finish.
No frame-rate or device-performance result is inferred from these source checks.
