# iPhone 154 / Apple TV 99: updated icon, title logos and Search home

The user supplied the improved glossy red play mark and requested replacement
of the earlier icon. During the same work they reported slow detail logos on
BOTH platforms and Search's navigation icon not returning to its home screen.
The existing iPhone153 genre ordering, Nullfin detail-loading fix and all earlier
features remain in the branch ancestry.

## Artwork and packaging

Prepared from the new reference with the built-in imagegen tool. The updated
ruby mark keeps its wavy glass reflections, thin upper-left highlight, curved
edges and darker finish. The former colored halo is removed.

Saved masters (the source of all packaged sizes):

- BuildAssets/PlayIcon/icon-color.png
- BuildAssets/PlayIcon/icon-tinted.png
- BuildAssets/PlayIcon/play-mark.png

Final iPhone standard/dark/tinted assets:
iPhone/Assets.xcassets/LineupAppIcon.appiconset/

Final Apple TV large/small/@2x icon and standard/wide/@2x Top Shelf artwork:
Lineup/Assets.xcassets/Lineup App Icon & Top Shelf Image.brandassets/

BuildAssets/package-play-icon.ps1 performs deterministic sizing/encoding,
preserves opaque RGB 1024-square iPhone assets and the three Apple TV parallax
layers, and replaces the red halo with a neutral soft shadow on charcoal.
Top Shelf now uses the transparent mark on a full-width background so there
is no baked square tile or seam. Existing catalog names and layer roles remain.

Fonts, tracking, login, provider data, playback behavior and CI job logic remain.
Older running builds are left alone; the new branch avoids the previous iPhone
branch's cancellation group.

## Title logos on both platforms

- Apple TV previously used titleLogo(), which waited for full metadata and then
  Fanart before trying TMDB. Both platforms now use the same progressive
  LineupTitleArtwork / LineupTitleLogo path. Server, Fanart and TMDB can resolve
  and decode independently. Server/Fanart preference and exact identity guards
  remain, with immediate title-text fallback if no real logo is available.
- Detail pages warm logos concurrently with their metadata/season/backdrop work,
  including before TV's existing focus-preparation gate opens. The gate and all
  episode/resume/related paths remain.
- Decoded title logos have a bounded 64-entry/48MB, one-day memory cache scoped
  to the item's server/profile, type and original name, including the catalog
  art setting. A common 1280-pixel decode target avoids refetching/decoding merely
  because hero/detail widths differ. Enriching metadata doesn't discard the
  already usable title image. Late/cancelled old-title responses remain rejected.
- Positive public Fanart/TMDB logo URLs survive relaunch in a bounded one-day
  index, allowing the existing image byte cache to be used without repeating the
  catalog API lookup. No server URLs, API keys, authorization headers, full API
  responses or negative errors are stored in this index. Restored entries are
  size-bounded, expired entries ignored, and only the known public HTTPS image
  hosts/paths with no credentials/query strings accepted. Unconfigured services
  and disabled catalog artwork retain their existing behavior.
- TMDB's logo resolver uses already verified IDs from resolved metadata instead
  of stripping them and searching the title again. Whole logo lookups coalesce.
  Fanart rate-limit/auth/missing-art backoff and strict returned-ID validation
  remain. No timeout is reduced and no successful asset is invented.
- Five new SDK regressions are shared by the phone and TV test targets: first
  image before slow preferred catalog; hero-to-detail bitmap reuse with metadata
  enrichment and profile/setting isolation; Fanart restoration without another
  API request or persisted key; TMDB resolved-ID/coalescing/recreation; rejection
  of private or credential-bearing image URLs. Existing phone loader tests
  continue through a compatibility alias to the same shared implementation.

## Search home

The phone's existing home handler rebuilt its NavigationStack but left the
selected genre and query outside that stack. SwiftUI therefore reopened the
same destination. The handler now clears genre/title destinations, query and
result/filter/choice state, invalidates pending provider/quality work, then
rebuilds the stack. Both glass and solid bars use the existing handler; no
navigation redesign or destination feature is removed.

## Verification

Run the native packager through its existing Python entry point, inspect the
final standard/tinted, TV layer composite and Top Shelf assets, and verify all
16 packaged PNGs against their manifests: exact dimensions, RGB backgrounds and
nonempty transparent layers. Check iPhone154 / TV99 versions, shared source/test
membership, normal local resource/engine/focus checks and staged diff.
Apple asset compilation and IPA/device checks remain pending CI; Windows does
not have the Apple SDK. Existing build/test workflows remain enabled.

## Exact imagegen prompts

### Color master
Use case: precise-object-edit.
Asset type: production Lineup app icon, one square 1024 x 1024 artwork.
Edit target and exact design reference: the supplied updated icon presentation sheet. Extract and faithfully recreate ONLY the large left app icon, without any other examples, labels or presentation sheet.
The updated mark is a glossy deep ruby/crimson curved play triangle pointing right, with rounded corners, a thin pale pink upper-left rim, subtle dark lower/right bevel and the DISTINCTIVE SOFT WAVY LIGHT BAND across the lower middle of the red glass. Preserve this flowing shallow S-shaped reflection and the softer second reflection beneath it exactly as shown. The triangle is richer and darker than a neon-red icon.
Preserve the reference proportions: triangle roughly 37% of icon width and 43% of icon height, optically centered. Keep the exact silhouette and understated reflections. Nearly black charcoal background, gently lighter above and dark below, with a small soft black drop shadow. NO red halo or colored background glow.
Output one finished opaque full-bleed square icon artwork. Extend the icon's dark field naturally all the way to the four canvas edges. No baked-in rounded-square outer tile, border, external margin or mockup; the operating system supplies the outer corner mask.
No text, labels, letters, badges, extra symbols, duplicates, grid or watermark. Keep the provided updated design; do not redesign or exaggerate it.

### Tinted master
Use case: precise-object-edit.
Asset type: production Lineup iOS tinted app icon, one square canvas.
Edit target: the supplied finished updated red Lineup icon.
Change ONLY the colors to neutral grayscale: the same glossy pale-silver play triangle with the same distinctive soft wavy reflections across the lower middle, lighter upper-left rim, dark right bevel and subdued black drop shadow on the same near-black charcoal background.
Keep the exact silhouette, rounded corners, placement, proportions, scale, light-band shapes and background gradient. Do not flatten or remove the flowing reflection detail. Remove every red/pink tint and any colored halo. This must be the same icon in monochrome.
Deliver opaque full-bleed square artwork with no baked outer corner mask, border, margin, text, labels, duplicates, mockup or watermark.

### TV transparent mark
Use case: background-extraction.
Asset type: Lineup Apple TV icon foreground layer.
Edit target: supplied finished updated red Lineup icon.
Remove ONLY its charcoal/black background and outer drop shadow. Keep the ruby-red curved play triangle itself unchanged, including the distinctive flowing light waves across its lower middle, upper-left pink rim, rounded corners, deep red bevel, placement and scale.
Output the SAME square canvas with the play mark in the SAME position and size. Genuine transparent alpha around the symbol, clean antialiased edges, no dark matte, no red halo, no checkerboard pixels, no text, no added glow or shadow. Preserve the original glass shading and wave detail.
