# iPhone Library collections, Skip Intro and BetterPosters

This extends PR84's recycled iPhone shelves. The tvOS playback repair remains
separate in PR85; these features are iPhone-only. No merge is authorized yet.

## Collections

Library has a Collections panel and a Collections menu entry. My Collections
supports creation, adding/removing movies and shows, renaming and deletion.
Hold a poster or use the collection button on a movie/show page to choose its
collections. The existing app menu and panel styling is reused. Collection cards
preview up to three saved posters; empty collections use a folder symbol.

Collections participates in Library > Edit Shelves with the same persistent
row ordering as other shelves. Its stable row ID is `collections`. The home
screen and editor both apply the existing saved order; Reset restores its
original first-row position. The header also uses the existing saved shelf name.
Skip Intro, BetterPosters and collection-membership switches explicitly use the
selected accent, overriding the settings container's neutral text tint.

The collections browser also lists all collections exposed by connected servers.
The home panel previews the first 20; See All has the complete list. Server
collections use their existing parent-item route and are not copied or modified.
Opening a server collection uses the existing Library folder loading behavior,
including its existing result limit. This change does not introduce server-side
collection editing or bulk collection-member fetching during startup.

Personal collections are saved in this phone's UserDefaults as original
source-scoped MediaItems. An item belongs to a collection by libraryKey (server
UUID + item ID); equal IDs on different servers are distinct. Display metadata
is not written into those snapshots. Playback, tracking, and metadata still use
the original item IDs. Collection membership does not mark anything watched or
alter Continue Watching. Collections stay local to the phone. If a server is
removed, saved items remain in their collections but need that source reconnected
to play. They can be removed through the Collections picker.

## IntroDB

Official docs consulted on 2026-10-17:
- https://introdb.app/docs/api
- https://introdb.app/docs/how-it-works
- https://introdb.app/docs/terms

Only the documented anonymous GET /segments endpoint is used, with the SHOW's
IMDb ID and exact season/episode numbers. Episode-specific IMDb IDs are never
used as series IDs. The parent is resolved through the existing source identity
and metadata resolver. Display-provider preferences remain unchanged when an
external ID is resolved solely for IntroDB. Validated AIOStreams packed IDs can
supply missing coordinates; opaque IDs and titles are not guessed as IMDb IDs.

Lookups start in parallel with Library episode playback, not in its URL-opening
path. Live playback and previews never receive a lookup closure. No credentials,
source URLs or server tokens are sent to IntroDB. Request timeout is five seconds;
in-flight episode lookups coalesce. Successful data is cached in memory for one
day, missing data for one hour, transient failures for one minute. The cache is
bounded to 256 entries and HTTP429 backs off across episodes. No bulk lookup or
write/submission API is used. Closing the view prevents late publication.

Responses must match the requested identity. Only the intro field is consumed;
milliseconds are preferred over seconds. Nonfinite/negative/reversed timestamps,
segments outside 5–180 seconds, absent/low confidence (<0.8), and zero submissions
are rejected. A known player duration beyond the intro endpoint is required.

Skip Intro is a manual button, visible only within that interval, outside errors,
loading, scrubbing and PiP. It uses the existing seek/coalescing path, not a source
restart or a watched-state write. Controls-visible placement is in the transport
panel; with controls hidden it sits at the lower right. Next Episode has priority.
Rewinding into the intro can offer the button again. Community timestamps are not
release-specific guarantees; no inferred offsets or automatic skipping is added.
Movies, credits and recaps are not skipped. Settings > Metadata > Skip Intro is
enabled by default and includes attribution.

Public smoke check: the official Game of Thrones S01E01 request returned an intro
437–531s in both seconds and milliseconds. The Breaking Bad S01E01 response had
intro:null, confirming the no-data case. These were public API checks, not proof
of the timing on a tester's selected release.

## BetterPosters

Official configurator https://btttr.cc/configure was inspected, including its
AIOMetadata / Other Addon mode and updateAioUrl implementation. The default is
https://btttr.cc/poster/imdb/poster-default/{imdb_id}.jpg. No unofficial add-on,
manifest proxy, Jellyfin plugin or scraped ratings API is used.

Settings > Metadata > BetterPosters is opt-in. Default style needs no account or
key. Poster Style opens the official configurator and accepts its image template
with {imdb_id} preserved. HTTPS, the exact btttr.cc host/image route, and the
documented tag/lang/rs query names are validated. Manifests, third-party hosts,
embedded credentials and unrecognized query parameters are rejected.

Only movie/show portrait cards are replaced. No IMDb match retains original art.
Missing external IDs use the existing bounded/coalesced metadata resolver on
visible cards, independently of the chosen display source; normal metadata
resolution is awaited first to avoid redundant cross-provider requests. Episode
stills, landscape cards, hero artwork and streaming-service branding retain their
existing appearance. Source IDs and metadata-source labels are unchanged.

Rated and ordinary artwork share the existing off-main decode, image cache,
network cache and source/size-keyed subscribers. Ordinary artwork remains visible
while a rated image loads or when it fails. Enabling, disabling or changing the
style updates observed cards without rebuilding shelf geometry or resetting its
scroll offset. No eager library-wide image crawl is introduced.

Default URLs do not request quality badges. Optional provider quality badges are
title/release information, not a measurement of the selected stream; the style
screen explains this. Playback format badges still use decoded source metadata.

Public smoke check: the default tt0944947 image route returned HTTP200, image/webp,
49,088 bytes, with six-hour public cache lifetime. ImageIO handles actual image
data rather than assuming JPEG from the URL suffix.

## Validation

Eight new iOS regressions cover exact identity, packed/special numbering,
malformed/unrelated/low-confidence segments, interval/duration safety, HTTP
coalescing and negative cache, rate-limit backoff, official image URL validation,
collection persistence/source scoping and preference/menu routing. An additional
native recycled-poster regression exercises its actual accessibility menu action
before and after data reordering. Existing artwork cancellation and full playback,
seeking, tracking, navigation and compatibility suites remain enabled.

Target-membership, bundle checks, focus checks, workflow lint and diff checks run
locally. Apple SDK compilation, simulator tests, IPA packaging and physical-device
validation are pending CI/tester results. Windows cannot run Xcode; no runtime
pass or frame-rate measurement is claimed here.

## Apple TV (Round 3 of the port)

The models and lookups are shared now: `Lineup/Models/LibraryCollection.swift`
(collections and their membership), `Lineup/Services/BetterPosters.swift`
(template rules, the rated-poster URL, the IMDb lookup, and the Fanart logo
lookup), `Lineup/Services/Fanart.swift` and `FanartPolicy.swift`. Their saved
values stay on each device; nothing syncs between the phone and the TV.

- **Collections.** The Library's menu has Collections: the viewer's own,
  kept on this Apple TV, and the servers' own, which open as they always did.
  Hold Select on a movie or show anywhere in the Library for Collections: each
  collection is switched by Select, and a new one is named with the TV's
  keyboard and added to at once. Hold a collection in the list to rename or
  delete it. There is no Collections shelf on the TV's home; the menu stands
  in for the phone's panel, so the shelf editor does not list one.
- **Ratings.** Metacritic's Metascore box and Letterboxd's average join
  IMDb, TMDB and Rotten Tomatoes in the preview and on the title page. The
  scores were already fetched on the TV; only the chips were the phone's.
- **BetterPosters.** Settings › Metadata › BetterPosters, off by default,
  puts rated posters on movie and show portrait cards in the default style.
  The ordinary poster shows while one loads and wherever it fails. Choosing
  another style stays on the phone, which can type the configurator's URL.
- **Title Logos.** On by default. Where the server has no logo for a title, the
  preview and the title page draw Fanart.tv's, else the title's name.
