# iOS 150 complete detail-page follow-up

The screenshot showed more than button styling. The previous response narrowed
the follow-up too far; this change completes the remaining page work while
retaining the login/navigation and detail-button changes in iPhone148/149.

## Layout and presentation

- iPhone details prefer the title's landscape backdrop instead of rendering a
  full poster followed by another title logo. A poster remains an artwork fallback.
  The shorter header feathers into the dark page and centered logo/text with
  tighter spacing; no library hero or TV layout is replaced.
- The detail scroll starts at the top for each title, and navigation expands on
  entry instead of inheriting the Library's compact Sports-only state. Normal
  scroll-direction compaction and Back remain available.
- Detail-only episode, trailer, cast and related panels use the current dark
  presentation surface. Existing main Library shelf cards keep their approved
  appearance. Credits/attribution, expandable synopsis, ratings, metadata,
  collections, resume/selection, favorites, watched/shuffle, trailers, seasons,
  episodes, related titles, Seerr and playback are retained.
- Compact cast portraits replace the oversized empty silhouettes. Initials are
  used when no real picture is available; no generated actor artwork is used.

## Portrait lookup

Cast credits load on demand outside initial detail/episode/playback loading.
Verified external movie/show identity is required. Movies use TMDB movie credits;
shows use aggregate credits covering all seasons. The returned title ID must
match. Malformed rows, duplicate person IDs and unsafe portrait paths are ignored.
Provider names, roles, order and usable photos remain primary. A unique equal
name inside that verified title's credits can supply the missing portrait, with
no global actor/name search. Additional credited actors are retained. Ambiguous
equal names cannot select an arbitrary portrait.

Portrait downloads try the provider first, then its matched official TMDB image.
They reuse the existing downsampling, image cache and cancellation/generation
guards, with state local to each portrait. Late images cannot leak into another
person/title. API responses share the existing four-request concurrency limit,
in-flight coalescing, retry-after policy and 24-hour response cache. That cache
now actually enforces its 80-entry cap after removing expired entries. No
credentials are sent to the public image host, no user watch-state changes occur
and no pictures are guaranteed when both official sources lack them.

## Verification

Three SDK regressions cover exact movie identity, cache/coalescing and no searches
for unidentified titles; show aggregate roles and mismatched titles/unsafe image
paths; provider-first names/roles/photos, sequential image fallback candidates
and ambiguous equal names. Existing full SDK suites remain enabled. Local checks
can validate source membership, resource metadata, engine pins, tvOS focus, YAML
and diffs; Windows has no Swift/Apple SDK, so SDK/device verification remains
pending CI. The existing TV96 workflow and earlier iPhone runs are untouched.

Official API references reviewed October 25, 2026:
- https://developer.themoviedb.org/reference/movie-credits
- https://developer.themoviedb.org/reference/tv-series-aggregate-credits
