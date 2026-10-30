# Responsiveness audit and domestic soccer cups

This continues the refresh/tennis repair in PR113. Its earlier review builds,
iPhone 976 and TV 716 at `7f6025830bd86d0e8969ca944ea73978e67c12ac`, passed.
Those results do not validate the additional changes described here.

## Confirmed additional work paths

- iPhone Guide filtered and locale-sorted the provider's full channel list on
  the UI actor. It now builds a cancellable background result for the current
  catalog/query, rejecting results after a provider, filter, or query change.
  Inactive tabs keep their rows and scroll state without waking another query.
  Favorites, recents, hidden categories, radio exclusions, search and the
  game picker's recommended channel retain their existing behavior.
- Media-library initialization synchronously read/decoded saved shelves from
  every server. Snapshot reading and legacy item scoping now run in the
  background. Network reloads join restoration before fetching fresh shelves,
  and a removed or already refreshed profile cannot receive a stale restore.
- Library snapshot writes previously retained one task/snapshot per update,
  each awaiting its predecessor. They now share the bounded latest-snapshot
  queue used by prepared sports matches. Removing a source discards its
  pending write and waits for active writes before deleting its cache.
- Settings requested `heroCatalog.title`, which remapped metadata across all
  shelves just to show one name. A title-only lookup avoids item metadata.
  The actual hero resolves its source shelf before remapping that shelf.
  iPhone Settings observes playback diagnostics only inside Diagnostics,
  instead of redrawing its root for every live log/snapshot update.
- Game selection no longer builds a Set of every provider channel for each
  preference decision. It supplies only the verified choices the resolver
  can select. Favorites filtering uses a Set instead of searching the saved
  order once per channel. Matching reuses its college-channel membership Set.

Playback startup was checked for preparation/discovery work. The existing
saved-match path, strict per-event validation, playback-confirmed quality cache,
engine selection, buffers, source URLs, audio and Picture in Picture policy are
preserved. No speculative video probes or quality reductions were introduced.
These are code-path findings; no physical device was connected for profiling.

## Soccer coverage

Added Carabao Cup (`eng.league_cup`, ESPN 3920), FA Cup (`eng.fa`, 3918),
Copa del Rey (`esp.copa_del_rey`, 3951), and Supercopa de España
(`esp.super_cup`, 8102) to the shared competition directory and updater.
There are now 22 competitions and 584 soccer teams. All original 374 soccer
IDs, names, abbreviations, crests and memberships were checked and retained;
non-soccer teams are unchanged. Cup-only entrants without an ESPN crest use
the existing initials fallback. Existing follows keep their ESPN club identity.
Cup-only clubs also participate in wrong-team channel rejection.

Live checks compared dedicated cup scoreboards with the global soccer feed:
Carabao Cup on 2026-10-29 (1 fixture), FA Cup on 2026-11-06 (2), Copa del Rey
on 2026-10-29 (23), and Supercopa on 2027-02-02 (1). Every returned cup event
was also in the global feed for its day. The normal shared polling/cache path
is unchanged; no new per-cup polling loop or VPS deployment is needed.
This sample establishes upstream inclusion for those dates, not guaranteed
future upstream completeness or a particular IPTV provider's live pictures.

## Verification

- The Foundation preflight runs 28 actual XCTest cases locally: 13 expanded
  sports cases, 11 phone refresh/Guide cases and 4 existing TV work-policy cases.
  The host harness includes actual bundled directories and captured ESPN JSON.
- A 30,000-channel query completed in about 0.082 seconds on the Linux host
  while its UI actor ran 794 heartbeat iterations. This establishes that this
  query does not monopolize that actor; it is not an iPhone timing or FPS claim.
- Thirty-three repository checks, fifteen saved-match checks, iOS/tvOS Swift
  syntax parsing, TV focus and whitespace checks pass locally.
- Added native tests for a 30,000-item cache restore yielding the UI actor,
  title-only observation, rejecting a removed profile's cache, and the real
  iPhone Settings retaining its scroller/position during repeated diagnostics
  updates with that cache. Existing native tests remain enabled.
- Cup tests parse genuine captures for all four competitions, reject archives
  and unsupported competitions, retain follow identity, and reject a cup-only
  club channel borrowing another game's guide entry.

Full Apple SDK builds, the new native Settings/cache tests, and actual device
navigation/first-picture/thermal measurements remain pending the new review
builds. Passing earlier builds or these host tests does not establish that the
reported unusable Settings behavior or phone-wide slowdown is resolved.

## Release-note draft

iPhone: Smoother Guide filtering, less work during Library startup and in
Settings, bounded cache updates, and less repeated work when selecting games.
Adds Carabao Cup, FA Cup, Copa del Rey and Spanish Supercopa coverage.

Apple TV: Less Library metadata/cache work and the same four soccer cups.
Existing Settings and Sports presentation is retained.
