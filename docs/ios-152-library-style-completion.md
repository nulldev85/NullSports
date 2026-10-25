# iPhone 152: Library, integrations and shared style

This iOS-only follow-up includes all eight requested changes. The later
clarification is authoritative: Similar Movies/Shows uses TMDB suggestions only.

1. Seerr sign-in methods use the original mark palettes through the entire
   form: Seerr purple/lavender/blue, Jellyfin purple/blue, Emby green/white and
   Plex gold/charcoal. Panels, field borders and login/connect/choice buttons
   share the selected palette. The main media-server forms also use their full
   palettes, including Silo blue/red/orange. All auth methods, linking, cancel,
   errors, Keychain storage and disabled states remain.
2. Library result grids now own their dark page/navigation backgrounds and
   presentation scope. Source logos/counts, menus and destination ownership
   remain; entry expands the navigation bar. Shared iOS surface/text/divider
   tokens also bring Library, Search, Settings and supporting pages into the
   Sports/Guide presentation style without changing card sizes, saved colors
   or the rounded typeface. TV colors and layout remain platform guarded.
3. Similar Movies/Shows appears immediately below Cast. It requests only
   TMDB's movie/show `/similar` endpoint, caches/coalesces responses and omits
   self/duplicate/invalid/adult entries. No server recommendations or local
   genre-overlap suggestions are blended in. An existing external ID mapping
   identifies the original title; numeric TVDB IDs are never treated as TMDB
   IDs. The lookup is separate from detail/season/resume loading. Selecting a
   suggestion uses the existing source matcher to open its available Library
   copy, or offers the connected Seerr request screen / an honest unavailable
   message. Metadata-only suggestions cannot write fake watched/favorite state
   through their hold menu. Ordinary Library card menus remain unchanged.
   TMDB attribution is visible.
4. Comedy now depicts a stand-up comedian and laughing audience, with the same
   cinematic lighting, detail, landscape shape and lower-left label space as
   the other genre tiles. Only the iOS asset changes. Its JPEG format remains;
   the source check now pins the intentional distinct iOS/TV Comedy assets,
   while retaining identical-art checks for the other 17 genres.
5. iPhone title logos start from available server artwork immediately. Fanart
   and TMDB resolve/decode independently, outside full overview/cast/ratings
   metadata loading. The first usable logo can display while another source
   is pending; server/Fanart preference remains when better-ranked artwork
   arrives. Failed server images can fall through to a real catalog image.
   Existing coalesced image downloads, downsampling, memory/disk byte caches,
   metadata request limits and backoff are reused. The next two hero titles
   are warmed at utility priority after the current header starts; all Library
   posters are not bulk-scanned. Identity, size and cancellation generation
   guards reject stale images. No universal instant-network guarantee is made.
6. Detail ratings, wrapped chip rows, metadata, synopsis, attribution and actions
   are centered. Existing title-logo centering remains. Expanded synopsis and
   accessibility type sizing remain available.
7. Play/Resume is a compact icon button using the same surface as neighboring
   actions, with the same target/resume behavior and spoken labels/episode code.
   Favorites, watched state, shuffle, Seerr and Collections remain.
8. iOS pages and settings now share the dark neutral ground/card/row, subdued
   text, borders, section captions and secondary-value tokens. Accent choices,
   branded imagery, live progress fills and playback contrast remain.

## Verification and limits

Added SDK tests for the two TMDB-only endpoint/identity/cache paths, independent
fast-logo publication while Fanart is gated, rejection of stale title/size
responses, and the discovery hold-menu action without synthetic watch writes.
All prior SDK tests remain. Local metadata/resource/membership/asset, tvOS focus,
engine project/pin, YAML and staged-diff checks run on Windows. Swift/Apple SDK
compilation, full simulator tests, IPA packaging and physical-device rendering
remain pending the iPhone 152 workflow. Earlier iPhone151 and TV97 runs are not
queried/cancelled/restarted. No merge is authorized and no TV workflow is started.

Official documentation reviewed:
- https://developer.themoviedb.org/reference/movie-similar
- https://developer.themoviedb.org/reference/tv-series-similar
- https://developer.themoviedb.org/reference/movie-images
- https://thetvdb.github.io/v4-api/

## Comedy artwork provenance

Built-in image generation edited the Comedy tile using the existing Action
and Romance tiles as style references. Original movie/show posters were not
generated. The result was inspected and copied into the project, then encoded
as JPEG for the existing asset contract; no artistic edits were made during
encoding. The default generated PNG remains at:
`C:\Users\Elmat\.codex\generated_images\01a13b60-fe2e-7623-b815-d860e31b7d49\exec-7241b011-859f-465b-aef5-871cfcaba6fb.png`.

Final asset: `iPhone/Assets.xcassets/SearchGenreComedy.imageset/genre.jpg`.
SHA-256: `89c616bbd2fad4924420841b79476cdadbb2e19d5d10daadb94aff5a6b306443`.

Final built-in prompt:

> Edit target: the first image (Comedy genre tile). Supporting style references: the second (Action tile) and third (Romance tile). Replace the entire dog-and-ball scene in the first tile with a clearly recognizable comedy scene: a charismatic stand-up comedian at a microphone on a small warm-lit brick-wall club stage, making a playful expressive gesture, with a few delighted laughing adult audience members in the foreground. Premium cinematic photography / polished cinematic illustration, rich realistic textures, dramatic but welcoming amber/red stage lighting, confident composition and depth, matching the level of detail and contrast of the other genre tiles. This must read immediately as COMEDY, not drama, music or an animal movie. Wide landscape 16:9 composition. Keep the face/performer toward center-right, reserve dark uncluttered lower-left space for the app's Comedy label. Subtle dark falloff along bottom, vivid art above. No text, letters, logos, film titles, watermarks, borders, animals or existing movie posters. Output a single finished Comedy tile only.
