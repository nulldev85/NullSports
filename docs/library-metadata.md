# Library metadata sources

Both platforms offer **Settings → Metadata** (tvOS: the Library panel). The
independent **Metadata source:** and **Episode data:** dropdowns each contain
Provider, TMDB, and TVDB. TMDB is the default for movie/show metadata and TVDB
is the default for episode data when no choice has been saved. Existing explicit
choices, including Provider, are preserved. The first choice covers movies/shows;
the second covers individual episodes.

External metadata supplies display titles, summaries, artwork, genres, and dates.
It does not replace stream URLs, server/library IDs, season/episode numbers,
runtime, progress, watched state, favorites, or Continue Watching dismissals.
The provider fields remain in the item and its encoded snapshots. Returning to
Provider restores them immediately, including after a relaunch.

## Matching and caching

- Prefer canonical provider IDs. Recognize explicit IMDb/TMDB/TVDB names and
  AIOStreams' validated packed ID layout. Bare numeric server IDs are not external
  IDs. An ID-like name is not used as a text search query.
- If IDs are absent, accept one exact normalized title/year match; ambiguous
  remakes and fuzzy results keep provider data.
- Resolve episodes from their parent series and official aired season/episode
  numbers. Do not replace provider numbering or episode order. A standalone TVDB
  episode ID can also resolve an episode without a parent.
- Fetch from visible cards/pages, coalesce simultaneous requests, limit HTTP
  concurrency to four, cache successful matches for seven days, and briefly cache
  misses/errors. Honor 429 backoff. TVDB login is coalesced and renewed on 401.
- Late results are stored under their original source/item key. Selecting another
  source cannot display an obsolete response.
- API failures fall back to provider fields without blocking Library browsing.

## App-wide credentials

The two workflows generate the ignored `Lineup/Resources/LineupMetadata.json`
before XcodeGen from repository secrets `LINEUP_TMDB_TOKEN` and
`LINEUP_TVDB_API_KEY`. Credentials are not committed or logged. TMDB supports a
read access token or v3 API key. TVDB uses a project API key, without a subscriber
PIN. Fork builds without secrets retain Provider fallback.

For local builds, export the same environment variables and run
`python3 -B Tools/configure-metadata.py` before XcodeGen. App-wide metadata keys
ship in the app bundle and can be extracted; use metadata-only project
credentials and the providers' appropriate project licenses. A server proxy is
needed if keys must never reach clients.

`Tools/verify-metadata-credentials.py` validates live movie/show/episode endpoints
using environment variables and prints only a success/failure summary. Its
optional `--install-github-secrets` flag stores them through `gh` via stdin.

## Attribution

Settings includes TMDB's logo and required notice, plus a TheTVDB link. Resolved
title pages and tvOS full-summary panels link to the metadata source. Provider
IDs learned from a confirmed match are available for stream matching, but are
not written over the provider's original IDs.

References: [TMDB API](https://developer.themoviedb.org/docs/getting-started),
[TMDB attribution](https://developer.themoviedb.org/docs/faq),
[TVDB API and attribution](https://www.thetvdb.com/api-information),
[TVDB v4 specification](https://github.com/thetvdb/v4-api/blob/main/docs/swagger.yml).

## Validation

All twelve metadata tests and the playback tests passed in iPhone build 95.
The full run compiled and executed 422 tests (one physical-device PiP test
skipped), but the picker rendering test failed while filtering; its teardown
reported a second error. Independent search and table-subscription tests passed.
The revised picker uses a native text field, with editing and Clear events
delivered directly to the search store. Completed results never overwrite its
editing buffer. The real-picker test now drives that control rather than a
separate SwiftUI binding and checks immediate query delivery, input retention,
and the existing 30,000-row rendering/filtering/clearing/scrolling/selection limits.
The results coordinator subscribes directly to completed pages; separate checks
cover subscription delivery, disconnect, and rebinding. Playback fixture coverage
includes real HTTP suffix/open-ended requests and 416 responses, plus a standalone
range-parser check. The full simulator suite remains enabled and runs serially.
Build 96 still needs simulator validation and IPA packaging before it is confirmed.

Live credentials have been checked against TMDB movie and episode endpoints and
TVDB login, movie/show details, and official episode lookup. Shared XCTest
coverage on iOS and tvOS exercises identity preservation, snapshot/history
round trips, explicit and packed ID matching, ambiguous remakes, coalescing,
numbered episodes/specials, wrong-show rejection, 401 renewal, fallback, and
independent persisted settings. Apple simulator tests and IPA packaging run in
the platform workflows; there is no local Apple SDK on the Windows workspace.

On both devices, switch each dropdown separately, check a movie with an ID-like
name and a show/episode, browse away and return, then relaunch. Return each to
Provider and confirm original display data. Check existing resume points,
watched marks, next episode, favorites, and removed Continue Watching entries.
