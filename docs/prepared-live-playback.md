# Prepared live playback

Live games restore their primary and alternative channels from a small local
snapshot before the full provider catalog or TV guide is read. Opening a saved
game does not wait for an EPG download, schedule request, index build, or a search
through the provider's channels. Playback still needs a working stream connection.

The snapshot includes today's and tomorrow's available schedule and only the
matched channels and their guide evidence. It lives in Application Support, is
written atomically, and is isolated by provider ID and connection settings. Channel
numbers from different accounts never become interchangeable. A removed provider
also loses its snapshot. Missing or damaged snapshots fall back to the existing
first-load path without discarding the separate channel/guide caches.
Playlist feeds retain only the prepared channels' source addresses in a compact
encrypted payload, using the existing playlist credential boundary; playback
does not decrypt the full playlist, and source tokens are not written in cleartext.

Schedule restoration is independent of whether a primary channel was matched.
The combined Sports screen can publish a provider's cached schedule before the
root finishes loading its full catalog. Existing on-disk daily matches are
converted locally into prepared results without downloading the guide again.
An expired or absent primary can use another already prepared, verified feed.
Live and Search taps open that saved selection directly; they do not launch a
quality-discovery task or rematch the lineup.

A full matching baseline is due after 24 hours. Scores keep updating normally;
they do not repeat successful channel searches. New or rescheduled events, changed
broadcasters, changed channel slots, and changed guide evidence get background
matching. An unchanged primary remains usable if only an alternative disappears.
Unmatched games retain bounded retries, including provider top-ups near kickoff.
Channel and guide responses share one index rebuild instead of racing two builds.

Both platforms perform maintenance while active and on resume. Neither platform
guarantees a daily task while the app is suspended or closed. A missed refresh
therefore does not block opening a prepared game. Preparation may carry for up to
48 hours, with exact event identity and the original guide evidence checked again
at selection; ended guide evidence cannot authorize a later program. First setup,
an event without saved evidence, and a multi-day absence can require loading.

"Refreshing Data" appears only on TV Guide. Sports, Library, Search, and Settings
do not show that popup, and background metadata refresh does not retune a player.

## Release notes

Apple TV 104 only:

- Live games with newly available channels become playable before preparation
  of the rest of the schedule finishes.
- If a selected game is still being prepared, it opens as soon as its result is
  ready, without repeatedly asking you to select it again.

iPhone stays at 158; this repair has no iOS behavior changes.

iPhone 158 and Apple TV 103:

- Saved live games open faster, with their channels and alternatives ready when
  you return to Lineup.
- Schedules and TV listings refresh in the background while you browse or watch.
- The data refresh popup now appears only in TV Guide.
- Live events appear from the saved schedule sooner, and tapping a prepared game
  starts playback directly, including a saved alternative when needed.

## Verification

Shared XCTest coverage exercises local-only playback with no session validation,
alternative quality/order preservation, account binding, credential removal,
disabled providers, changed event identities, recycled slots, unrelated EPG
updates, program expiry, snapshot age, corruption recovery, and provider deletion.
An injected offline provider session verifies that failed refreshes preserve the
last good snapshot. A held XMLTV response verifies playback while a guide is
downloading and discovery of a newly added alternative after it completes.
The startup regressions include the Columbus Blue Jackets–Carolina Hurricanes
matchup, migration from the existing daily cache, alternative-only and expired
primary results, cold combined-provider startup, and an older catalog request
held open while a ready cached source becomes available.
TV-only regressions cover a newly available Thursday Night Football feed while
another saved live event already works. They check both independent early
playback and a completed no-match result, retaining rejection of another matchup.
The Foundation daily checks cover the exact 24-hour refresh and 48-hour retention
boundaries, including clock rollback. Both full simulator suites remain enabled.
Both build workflows also compile and execute the shared provider download
transport before the full SDK build. This covers injected sessions, progress,
empty responses, and propagation of offline errors.

Device review should include a cached relaunch with a deliberately slow EPG,
primary and alternative playback before it finishes, TV Guide-only progress,
an offline refresh failure, switching accounts with overlapping stream IDs,
midnight rollover, and the first setup without a snapshot. Build success cannot
establish actual provider stream availability or a measured launch-time guarantee.
