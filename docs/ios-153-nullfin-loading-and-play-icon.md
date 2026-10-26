# iPhone 153 / Apple TV 98: title loading, genre order and play icon

## Behavior

- iOS Search displays all 18 genres alphabetically, retaining the original
  genre identity, artwork and TMDB movie/series mappings. Apple TV genre order
  is unchanged.
- Single-title Jellyfin-compatible detail requests explicitly send the same
  metadata Fields used for catalog browsing. Nullfin otherwise treats an absent
  Fields query as requesting MediaSources, refreshes stream addons and resolves
  playback sources before returning the details. Lineup's MediaItem does not
  consume those sources; Play already obtains them separately.
- Actual playback/source discovery, probes, provider order, selected version
  IDs, session IDs, authentication, server permissions, retries and timeouts
  remain. Full metadata, cast, trailers, artwork, tracking, episodes and source
  selection remain available. No synthetic fast result or compatibility-client
  impersonation is used.
- The shared detail-client correction applies to iPhone and Apple TV.
  It removes an unnecessary request dependency; there is no claim that every
  external addon or remote metadata request becomes instantaneous.

## Source evidence and verification

Nullfin source reviewed read-only at local main
4bffc456bbbbdfa670f811860a8cee8282c3e85d:
crates/remux-server/src/api/users.rs users_items_get passes q.fields to item;
crates/remux-server/src/api/items.rs item_for_user defaults want_streams to true
when Fields is absent, then awaits addons.refresh_streams and source resolution
for movies/episodes. Explicit metadata fields exclude MediaSources.

Extended the actual JellyfinClient HTTP regression to include opening a detail
page. Its simulated Nullfin endpoint fails if this request would trigger stream
resolution, while returning cast portraits, provider IDs, runtime, trailers,
artwork and tracking flags. The following Play request still requires fresh
versions and preserves the exact returned version/snapshot identity. The genre
test verifies A-Z order and that no genre/artwork/mapping was lost.

No live Nullfin deployment, server release or watch-state modification is needed
for this client correction. No live timing measurement has been made. Windows
has no Apple SDK: compilation, simulator regressions, asset compilation, IPA
packaging and device feedback remain pending in the normal workflows.

## Icon assets

The user supplied the glossy ruby-red play icon reference and asked to apply it
as the app icon. The built-in imagegen tool was used to prepare the square
color and monochrome masters and a transparent mark, preserving the reference
shape, bevel, highlights and restrained halo. No image API key or fallback CLI.

Saved production masters:

- BuildAssets/PlayIcon/icon-color.png
- BuildAssets/PlayIcon/icon-tinted.png
- BuildAssets/PlayIcon/play-mark.png

BuildAssets/package-play-icon.ps1 performs only deterministic raster sizing,
RGB/alpha encoding and Apple TV layer packaging using Windows System.Drawing.
Both former geometric generators now delegate to this packager, so they cannot
silently restore an older logo. CI consumes the committed asset catalogs.

Final iPhone outputs are opaque RGB 1024-square PNGs under
iPhone/Assets.xcassets/LineupAppIcon.appiconset, including standard, dark and
tinted appearances. The system supplies the outer corner mask.

Apple TV's existing brandassets catalog retains its large/small/@2x sizes
and three parallax layers: dark opaque background, transparent red halo and
transparent glossy play foreground. Top Shelf standard/wide/@2x artwork uses
the same mark. No mark is stretched into the television's wider aspect ratio.

Only launch/Home Screen icon assets are replaced; in-app controls and saved
preferences retain their behavior.

## Imagegen prompts

### Color master
Use case: precise-object-edit.
Asset type: production Lineup app icon, square 1024 x 1024.
Input image: the supplied icon presentation sheet is the edit target and exact design reference. Extract and faithfully recreate ONLY the large left red play-button app icon, at full resolution, without the sheet, other variants or labels.
Keep its exact glossy translucent ruby/crimson triangular play mark pointing right, softly rounded corners, thin bright pink upper-left rim, deep red lower/right bevel, and restrained red halo on near-black. Preserve the reference proportions: play symbol about 37% of the icon width and 43% of its height, optically centered. Preserve the curved triangular silhouette and surface lighting.
Deliver just ONE finished icon artwork filling the entire square canvas. Extend the almost-black icon background cleanly to all four edges; NO baked-in outer rounded-square shape, no surrounding margin or mockup, no shadow outside an icon tile. Apple applies the outer icon mask.
No text, letters, arrows beyond the single play triangle, badges, extra marks, grid, labels, or watermark. Opaque RGB-style background. Match the reference closely; do not redesign it.

### Tinted master
Use case: precise-object-edit.
Asset type: production Lineup iOS tinted app icon, one square canvas.
Edit target: the supplied finished red Lineup icon.
Change ONLY its color to a neutral monochrome tinted-icon source: glossy pale silver/white triangular play mark, soft gray highlights and dark gray bevel, neutral dim halo on the same near-black full-bleed square background.
Preserve the exact play triangle silhouette, rounded corners, placement, scale, perspective, lighting and background layout pixel-for-pixel as closely as possible. Remove all red/pink saturation. This is the same icon in monochrome, not a new design.
No outer rounded-square tile, transparent border, labels, text, duplicate symbols, mockup or watermark. Opaque image.

### Apple TV foreground
Use case: background-extraction.
Asset type: Lineup Apple TV icon foreground layer.
Edit target: the supplied finished red play-button icon.
Remove ONLY the black background and broad red background halo. Keep the glossy ruby-red play triangle itself absolutely unchanged: its exact silhouette, placement, size, curved corners, pink upper-left highlight, lower/right bevel and internal shading.
Deliver the SAME square canvas with the play mark in the SAME position and scale as the supplied image, now surrounded by genuine transparent alpha. Clean softly antialiased edges, no black matte, no new shadow, no text, no checkerboard pixels, no labels or watermark. Preserve the solid glossy mark, not a flat silhouette.
