# Soccer and motorsports

Both iPhone and tvOS add Soccer, Formula 1, and NASCAR Cup Series to the existing
Sports selector. They use the app's cards, choice panels, reminders, channel
preferences, previews, and fullscreen playback. The playback engines are unchanged.

## Soccer

The bundled directory contains 374 distinct clubs and national teams across 18
competitions: Premier League, La Liga, Bundesliga, Serie A, Ligue 1, MLS, NWSL,
Champions League, Europa League, Conference League, men's and women's World Cups,
EURO, Copa América, Gold Cup, Africa Cup of Nations, Asian Cup, and Nations League.
Use the competition filter in Sports or Settings > My Teams. Follow identity is
the ESPN team ID, so following a club once covers its domestic and cup games.
Men's and women's national teams retain separate IDs.

Scores, status, start times, venues, and broadcasts come from ESPN. Penalty and
aggregate scores remain separate from match goals. Postponed/canceled fixtures
are not treated as playable; a delayed start never becomes live merely because
its scheduled time passed. Soccer uses the existing today/tomorrow window.

## Formula 1 and NASCAR

Racing covers the next 14 days. F1 practice, qualifying, sprint qualifying,
sprint, and race sessions have their own IDs and actual start times. NASCAR
coverage is the Cup Series. Follow either series in Settings > My Teams or an
event menu. Hold an event and choose Race Details to see its session, circuit,
start, broadcasts, and drivers when supplied. Completed-session driver order is
shown when present; missing entries and live standings are not invented.

## Matching and data boundaries

Soccer matching requires both teams in the current/time-overlapping listing,
or a dedicated matchup channel with no conflicting guide entry. Youth, women's
versus men's, replay and archive checks prevent lookalike matches. Racing requires
the series, venue/event, and correct session, rejecting other NASCAR classes,
practice/qualifying mismatches, pre-race programs and replays. A broadcaster name
alone is never sufficient. Choose Another Channel remains available for feeds
whose guide is incomplete or differently named.

The shared client coalesces requests and caches near-live feeds for 20 seconds
and idle/future feeds for five minutes. Soccer requests Eastern-calendar feed
days, filters actual timestamps to the local window, deduplicates events, and
falls back to the supported competition feeds if the global page hits its cap.
Racing requests a padded range so a Sunday race is not lost when its weekend is
indexed by Friday practice. A failed sport preserves its last good slate and
reports unavailable data independently. No new server deployment is required.

Competition and team crests use the original ESPN-hosted artwork. Soccer is a
category with a soccer-ball symbol; actual competitions have their own logos.
Bundled F1 and NASCAR marks retain the original downloaded bytes, with sources
and hashes in `SportsArtworkSources.json`. NASCAR's black wordmark has a light
backing for legibility. Refresh the soccer directory with
`Tools/update-global-sports.py --cache-dir <outside-checkout-directory>`.

## Validation

Offline directory/artwork checks verify counts, stable IDs, coverage and original
asset hashes. Shared XCTest coverage exercises authentic fixtures, malformed
events, delays, penalties, national-team distinctions, safe channel selection,
individual race sessions, source driver results, feed-day/DST boundaries, isolated
outages, caching, capped-feed fallback, persistence and provider-scoped favorites.
These SDK tests run on both platforms in CI. Local Windows checks cannot confirm
Apple SDK compilation or on-device layout; those remain pending build and tester
review.
