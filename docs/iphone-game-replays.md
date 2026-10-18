# iPhone Game Replays

In Sports, select **My Teams**, then scroll below the live/upcoming sections to
**Game Replays**. It appears with All Sports or NFL selected and uses the same
followed-team store as Settings and live game menus. NFL league and team logos
come from the existing official-logo assets/directory. Multiple recordings of
one matchup open the app's channel-choice panel; one recording opens directly.

This is an additional entry point to the provider's Xtream catch-up service,
not a separate replay subscription or VOD catalog. It requests past listings
with the existing `get_simple_data_table` client and opens their existing
timeshift URLs through the usual iPhone player. TV Guide catch-up behavior,
live event matching, quality verification and Library tracking stay unchanged.

Only archive-enabled NFL channels are queried. A dedicated channel for another
team, RedZone, highlights, news and other non-game feeds are excluded. Each
listing must explicitly have `has_archive`, have ended, remain wholly within
the provider's stated retention window, and identify a two-team NFL matchup
involving a followed team. Generic NFL titles can use the program description.
A team channel's name alone does not establish the recorded game's identity.
Alternate recordings of the same teams within ten minutes are grouped. The
replay list does not depend on today's sports schedule retaining past games.

Requests start on demand in My Teams, with at most three simultaneous archive
requests per load. Successful per-account/channel results cache for five
minutes; the refresh button clears that cache. Matching/filtering runs off the
main actor. Expired recordings disappear on the section's minute clock without
another network request. Cancelled or superseded loads cannot publish into a
new profile/filter selection, and failed channels don't discard good results.
This work is separate from startup refresh/progress and live quality probes.

Opening a recording rechecks only that selected channel's archive listing and
current account before creating its timeshift URL. If it is no longer available,
the player offers Retry and reports the error rather than opening a live feed.
The recording uses the existing catch-up timeline, seeking, transport, format
badges and engine selection. Going Live remains an explicit player action.

The provider only announced "NFL Teams catchup"; its private channel catalog,
recording flags and retention have not been inspected. Providers that omit
game identities or explicit recorded flags cannot populate this section safely.
An empty list is not a promise that the provider has no recordings; the TV
Guide's existing Catch Up entry remains available. M3U-only profiles do not
provide this Xtream archive table. This addition is iPhone-only.

Ten iOS regressions cover visibility, eligible channels, archive flags/retention,
two-team matching and alternate feeds, expiration, bounded concurrency/cache,
late account responses, partial failure/retry, disabled contexts, and a failed
recording opening without live fallback. SDK compilation, these new tests and
device playback validation are pending the review build. No tests are disabled.
