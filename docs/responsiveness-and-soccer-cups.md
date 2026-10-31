# Responsiveness audit and domestic soccer cups

This continues the refresh/tennis repair in PR113. Its earlier review builds,
iPhone 976 and TV 716 at `7f6025830bd86d0e8969ca944ea73978e67c12ac`, passed.
Those results do not validate the additional changes described here.
The later iPhone 978 workflow passed at `4c5b070c025931a1c1823ed40e6f5c6061ecf188`;
the follow-up below is newer and requires its own SDK/device verification.

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

## Remaining device feedback and score-refresh repair

The user still reports poor iPhone responsiveness, including Settings scroll
stutters, delayed taps and page jumps. Their October 27 MetricKit aggregate
records 23 hangs averaging 1.12 seconds and a 1.14 GB peak memory footprint.
It has no build number or sampled call stacks identifying the blocking code.
It confirms historical stalls, not the cause or performance of a particular
current build. Launch Timing text has not yet been provided.

A separate source defect can stall score updates: `refreshSchedule` kept its
in-flight flag set while awaiting channel matching and cached-match promotion.
Later score polls were rejected until that work finished. Publication now
finishes independently and queues maintenance through one coalescing worker,
with cancellation/provider fences and iPhone background suspension preserved.
Core schedule, UFC and expanded-feed requests also start concurrently instead
of starting some only after other sports finish. Sports refreshes immediately
on entry, then at the existing 30-second interval, on both platforms. This is
polling, not instant push scoring; upstream freshness still applies.
Score-cache writes also use the bounded latest-snapshot queue, so a slow disk
cannot accumulate a retained task/full schedule for every newly published score.

The reported matchup is New Jersey–Colorado. A read-only check of event
401892598 (October 28 local date) found both the VPS response and ESPN already
showing Colorado 5–New Jersey 2, final. This establishes present server data;
it cannot reconstruct what the app/server returned during the user's live test.
No VPS deployment or provider-playback change was made for this repair.

Device Reports now retains Apple's detailed diagnostic payloads, including hang
stack addresses and binary UUIDs, when iOS supplies them. Serialization, restore,
export assembly and persistence happen off the UI actor. The history is limited
to six deduplicated payloads, with a 2 MB limit per payload, and stays local
until the user taps Copy. CI preserves the exact Release app's matching dSYM
and UUID/commit/run metadata for 30 days so received app frames can be resolved.
This instrumentation does not itself repair the remaining phone-wide lag.

The Settings regression now mounts the real `MainView`/TabView instead of only
the Settings page, with the 30,000-item Library fixture and repeated diagnostics
updates. It samples scroll position during both solid/glass compact transitions,
instead of checking only the settled endpoint. No speculative navigation or
playback-engine rewrite was made without a reproduced cause.

## Follow-up after native verification and renewed full-scope request

Both iPhone 979 and TV 719 compiled their Release apps at `ff984f6`, but native
tests blocked publication. The iPhone suite ran 789 tests with one existing
skip and two failed assertions in the new Settings case: compact state never
became active. Its test window had not supplied an active scene, so production
correctly disabled its scroll observer. The fixture now supplies `.active`, as
the existing navigation integration test does; all transition/offset assertions
remain. TV 719 ran 304 tests; both failures were the new full-screen color checks.
Its screenshots show a neutral canvas: the layout still had an inner solid
background covering the newly moved canvas. That remaining fill is removed;
Sports' unused NavigationStack is also removed (all its destinations use their
own covers) so it cannot draw another ground over the canvas. The same
top/center/bottom pixel checks and screenshots remain enabled.

Further source inspection found two additional UI-thread work paths:

- Audio activation used `queue.sync` from the UI actor, waiting for both earlier
  audio deactivation and hardware/category changes. It now awaits a serial
  hardware coordinator. Starting a stream returns immediately to UI work;
  engine selection, URLs, buffers and quality policy are unchanged. Stop/new
  selections invalidate pending startup, and old failures cannot remove a new
  audio lease. A pending user Pause or background suspension is honored before
  opening a decoder. Aether PiP callbacks are also fenced to the current request.
  Synthetic blocked-hardware tests exercise ordering, replacement, failures and
  cleanup locally. Replaying the former `queue.sync` pattern fails the same
  UI-availability test after a deliberately blocked three-second hardware call;
  the real asynchronous implementation passes. This is a controlled host replay,
  not a physical-phone timing. Native tests additionally verify no late decoder after Stop
  or Pause. Launch Timing records actual audio activation duration.
- The Library hero still metadata-remapped the entire chosen shelf before
  selecting ten featured titles. The hero now returns its original source;
  visible hero views select the ten titles lazily, then resolve metadata for
  those titles. The hero settings picker also uses original names/counts and
  validates selection without remapping every shelf. Large-library observation
  coverage verifies these source reads do not depend on item metadata choices.
  Shelf presence/counts and shelf-management rows likewise use original sources;
  cards resolve their own visible metadata. Legacy series-history joins now run
  on a utility snapshot with cancellation/source-generation checks before use.

These are confirmed source paths and controlled regressions, not a claim that
the historical device report has identified either as its sole cause. Current
Apple SDK/native tests and physical-device behavior still require verification.

## Full-screen Apple TV Sports canvas

The focused team-color canvas now belongs to the outside of the Sports layout,
past the clipped NavigationStack. Sports hides the native tab-bar background,
and its score ticker no longer paints an opaque fixed-color strip. One existing
gradient and its bounded animation cover the screen; the cards/player/ticker
layout and focus behavior are retained. A native rendering test mounts the
actual Sports view in a tab container and checks the top, center and bottom
edges for two focused palettes. This was the user's queued visual follow-up.

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

- The Foundation preflight runs 32 actual XCTest cases locally: 13 expanded
  sports cases, 12 phone refresh/Guide cases, 3 blocked-audio-work cases and
  4 existing TV work-policy cases.
  The host harness includes actual bundled directories and captured ESPN JSON.
- A 30,000-channel query completed in about 0.082 seconds on the Linux host
  while its UI actor ran 794 heartbeat iterations. This establishes that this
  query does not monopolize that actor; it is not an iPhone timing or FPS claim.
- Thirty-three repository checks, fifteen saved-match checks, iOS/tvOS Swift
  syntax parsing, TV focus and whitespace checks pass locally.
- Added native tests for a 30,000-item cache restore yielding the UI actor,
  title-only observation, rejecting a removed profile's cache, and the real
  iPhone Settings retaining its scroller/position during repeated diagnostics
  updates with that cache, now inside the actual tab container and transitions.
  Added native checks that sequential hockey score updates publish while the
  maintenance worker is blocked and preserve the saved playable feed, plus
  bounded/deduplicated detailed diagnostic history. SDK execution of the new
  tests remains pending. Existing native tests remain enabled.
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

Apple TV: Less Library metadata/cache work, continued score refresh during
channel preparation, a Sports team-color background covering the entire screen,
and the same four soccer cups. Existing Settings presentation is retained.
